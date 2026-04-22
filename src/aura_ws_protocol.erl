-module(aura_ws_protocol).

%% Shared RFC 6455 WebSocket protocol helpers. Both aura_ws_ffi (SSL)
%% and aura_ws_plain_ffi (plain TCP) call into this module for the
%% socket-agnostic parts — handshake validation, frame parsing,
%% masking. Socket-specific bits (connect/send/recv/close, fragmented
%% I/O loops) stay in the FFI modules.

-export([
    compute_accept_key/1,
    validate_accept/2,
    extract_frames/1,
    opcode_to_type/1,
    encode_text_frame/1,
    encode_data_frame/2,
    encode_control_frame/2,
    mask_data/2,
    max_frame_size/0
]).

-define(MAX_FRAME_SIZE, 16777216). %% 16MB max frame size

max_frame_size() -> ?MAX_FRAME_SIZE.

%% RFC 6455: Sec-WebSocket-Accept = base64(SHA1(Key ++ GUID))
compute_accept_key(Key) ->
    GUID = <<"258EAFA5-E914-47DA-95CA-C5AB0DC85B11">>,
    Hash = crypto:hash(sha, <<Key/binary, GUID/binary>>),
    base64:encode(Hash).

validate_accept(RespData, ExpectedAccept) ->
    Lines = binary:split(RespData, <<"\r\n">>, [global]),
    find_accept_header(Lines, ExpectedAccept).

find_accept_header([], _Expected) ->
    {error, <<"Missing Sec-WebSocket-Accept header">>};
find_accept_header([Line | Rest], Expected) ->
    case binary:split(Line, <<": ">>) of
        [Name, Value] ->
            case string:lowercase(binary_to_list(Name)) of
                "sec-websocket-accept" ->
                    Trimmed = string:trim(binary_to_list(Value)),
                    case list_to_binary(Trimmed) =:= Expected of
                        true -> ok;
                        false ->
                            {error, <<"Sec-WebSocket-Accept mismatch">>}
                    end;
                _ ->
                    find_accept_header(Rest, Expected)
            end;
        _ ->
            find_accept_header(Rest, Expected)
    end.

%% Extract complete WebSocket frames from buffer.
%% Returns {ok, [{Type, Payload}], Rest} or {error, frame_too_large}
extract_frames(Buffer) ->
    extract_frames(Buffer, []).

extract_frames(<<>>, Acc) ->
    {ok, lists:reverse(Acc), <<>>};

%% Small frames (payload < 126 bytes), unmasked (server -> client)
extract_frames(<<_Fin:1, _Rsv:3, Opcode:4, 0:1, Len:7,
                 Payload:Len/binary, Rest/binary>>, Acc) when Len < 126 ->
    Type = opcode_to_type(Opcode),
    extract_frames(Rest, [{Type, Payload} | Acc]);

%% Medium frames (payload 126-65535 bytes), unmasked
extract_frames(<<_Fin:1, _Rsv:3, Opcode:4, 0:1, 126:7, Len:16,
                 Payload:Len/binary, Rest/binary>>, Acc) ->
    case Len > ?MAX_FRAME_SIZE of
        true -> {error, frame_too_large};
        false ->
            Type = opcode_to_type(Opcode),
            extract_frames(Rest, [{Type, Payload} | Acc])
    end;

%% Large frames (payload > 65535 bytes), unmasked
extract_frames(<<_Fin:1, _Rsv:3, Opcode:4, 0:1, 127:7, Len:64,
                 Payload:Len/binary, Rest/binary>>, Acc) ->
    case Len > ?MAX_FRAME_SIZE of
        true -> {error, frame_too_large};
        false ->
            Type = opcode_to_type(Opcode),
            extract_frames(Rest, [{Type, Payload} | Acc])
    end;

%% Incomplete frame — return what we have and keep the rest in buffer
extract_frames(Incomplete, Acc) ->
    {ok, lists:reverse(Acc), Incomplete}.

opcode_to_type(1) -> text;
opcode_to_type(2) -> binary;
opcode_to_type(8) -> close;
opcode_to_type(9) -> ping;
opcode_to_type(10) -> pong;
opcode_to_type(Other) -> {unknown, Other}.

%% Encode a text frame (client -> server, must be masked per RFC 6455)
encode_text_frame(Data) when is_binary(Data) ->
    encode_data_frame(1, Data).

encode_data_frame(Opcode, Data) ->
    Len = byte_size(Data),
    MaskKey = crypto:strong_rand_bytes(4),
    Masked = mask_data(Data, MaskKey),
    Header = if
        Len < 126 ->
            <<1:1, 0:3, Opcode:4, 1:1, Len:7>>;
        Len < 65536 ->
            <<1:1, 0:3, Opcode:4, 1:1, 126:7, Len:16>>;
        true ->
            <<1:1, 0:3, Opcode:4, 1:1, 127:7, Len:64>>
    end,
    <<Header/binary, MaskKey/binary, Masked/binary>>.

%% Encode a control frame (ping/pong/close — must be masked, max 125 bytes)
encode_control_frame(Opcode, Payload) ->
    Len = byte_size(Payload),
    TruncLen = min(Len, 125),
    TruncPayload = binary:part(Payload, 0, TruncLen),
    MaskKey = crypto:strong_rand_bytes(4),
    Masked = mask_data(TruncPayload, MaskKey),
    <<1:1, 0:3, Opcode:4, 1:1, TruncLen:7, MaskKey/binary, Masked/binary>>.

%% XOR mask data with 4-byte key (RFC 6455 Section 5.3)
mask_data(Data, Key) ->
    mask_data(Data, Key, 0, <<>>).

mask_data(<<>>, _Key, _I, Acc) ->
    Acc;
mask_data(<<B:8, Rest/binary>>, Key, I, Acc) ->
    <<_:I/binary, K:8, _/binary>> = Key,
    mask_data(Rest, Key, (I + 1) rem 4, <<Acc/binary, (B bxor K):8>>).
