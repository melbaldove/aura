-module(aura_ws_ffi).
-export([connect/3]).

-define(MAX_FRAME_SIZE, 16777216). %% 16MB max frame size

%% Connect to a Discord gateway WebSocket and relay frames to a Gleam process.
%% Returns the PID of the relay process.
%% The relay process sends {ws_text, Binary} | ws_closed | {ws_error, Binary}
%% messages to the CallbackPid.
connect(Host, Path, CallbackPid) ->
    spawn_link(fun() ->
        try
            ws_loop(Host, Path, CallbackPid)
        catch
            Class:Reason:Stack ->
                Msg = iolist_to_binary(io_lib:format("~p:~p ~p", [Class, Reason, Stack])),
                CallbackPid ! {ws_error, Msg}
        end
    end).

ws_loop(Host, Path, CallbackPid) ->
    ssl:start(),
    Port = 443,
    HostStr = binary_to_list(Host),
    Opts = [{verify, verify_peer},
            {cacerts, public_key:cacerts_get()},
            {server_name_indication, HostStr},
            {customize_hostname_check,
                [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]},
            binary, {active, false}],

    case ssl:connect(HostStr, Port, Opts, 10000) of
        {ok, Socket} ->
            case do_handshake(Socket, Host, Path) of
                {ok, Extra} ->
                    %% Process any piggybacked frames from the upgrade response
                    case Extra of
                        <<>> -> ok;
                        _ -> process_frames(Extra, Socket, CallbackPid)
                    end,
                    %% Use {active, once} for backpressure control
                    ssl:setopts(Socket, [{active, once}]),
                    relay_loop(Socket, CallbackPid, <<>>);
                {error, Reason} ->
                    CallbackPid ! {ws_error, Reason},
                    ssl:close(Socket)
            end;
        {error, Reason} ->
            Msg = iolist_to_binary(
                io_lib:format("SSL connect failed: ~p", [Reason])),
            CallbackPid ! {ws_error, Msg}
    end.

%% Perform the WebSocket upgrade handshake with Sec-WebSocket-Accept validation
do_handshake(Socket, Host, Path) ->
    Key = base64:encode(crypto:strong_rand_bytes(16)),
    ExpectedAccept = compute_accept_key(Key),

    Req = [<<"GET ">>, Path, <<" HTTP/1.1\r\n">>,
           <<"Host: ">>, Host, <<"\r\n">>,
           <<"Upgrade: websocket\r\n">>,
           <<"Connection: Upgrade\r\n">>,
           <<"Sec-WebSocket-Key: ">>, Key, <<"\r\n">>,
           <<"Sec-WebSocket-Version: 13\r\n">>,
           <<"\r\n">>],
    ssl:send(Socket, Req),

    case ssl:recv(Socket, 0, 10000) of
        {ok, RespData} ->
            case binary:match(RespData, <<"101">>) of
                nomatch ->
                    {error, <<"Upgrade failed: server did not return 101">>};
                _ ->
                    %% Validate Sec-WebSocket-Accept
                    case validate_accept(RespData, ExpectedAccept) of
                        ok ->
                            %% Extract data after headers
                            Extra = case binary:split(RespData, <<"\r\n\r\n">>) of
                                [_Headers, Body] -> Body;
                                _ -> <<>>
                            end,
                            {ok, Extra};
                        {error, _} = Err ->
                            Err
                    end
            end;
        {error, Reason} ->
            {error, iolist_to_binary(
                io_lib:format("Handshake recv failed: ~p", [Reason]))}
    end.

%% RFC 6455: Sec-WebSocket-Accept = base64(SHA1(Key ++ GUID))
compute_accept_key(Key) ->
    GUID = <<"258EAFA5-E914-47DA-95CA-C5AB0DC85B11">>,
    Hash = crypto:hash(sha, <<Key/binary, GUID/binary>>),
    base64:encode(Hash).

validate_accept(RespData, ExpectedAccept) ->
    %% Find Sec-WebSocket-Accept header in the response
    %% Parse headers line by line to avoid case/whitespace issues
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

%% Main relay loop — receives SSL data with {active, once} backpressure
relay_loop(Socket, CallbackPid, Buffer) ->
    receive
        {ssl, Socket, Data} ->
            NewBuffer = <<Buffer/binary, Data/binary>>,
            case extract_frames(NewBuffer) of
                {ok, Frames, Rest} ->
                    lists:foreach(fun(Frame) ->
                        handle_frame(Frame, Socket, CallbackPid)
                    end, Frames),
                    %% Re-enable {active, once} after processing
                    ssl:setopts(Socket, [{active, once}]),
                    relay_loop(Socket, CallbackPid, Rest);
                {error, frame_too_large} ->
                    CallbackPid ! {ws_error, <<"Frame exceeds maximum size">>},
                    ssl:close(Socket)
            end;
        {ssl_closed, Socket} ->
            CallbackPid ! ws_closed;
        {ssl_error, Socket, Reason} ->
            CallbackPid ! {ws_error, iolist_to_binary(
                io_lib:format("SSL error: ~p", [Reason]))};
        {ws_send, Data} ->
            Frame = encode_text_frame(Data),
            ssl:send(Socket, Frame),
            relay_loop(Socket, CallbackPid, Buffer);
        ws_close ->
            %% Send a close frame before closing
            CloseFrame = <<1:1, 0:3, 8:4, 1:1, 2:7,
                           0:32,  %% mask key (zeros — close frames are small)
                           3:8, 232:8>>,  %% 1000 = normal closure, masked with zero key
            ssl:send(Socket, CloseFrame),
            ssl:close(Socket),
            CallbackPid ! ws_closed
    end.

%% Handle different frame types
handle_frame({text, Payload}, _Socket, CallbackPid) ->
    CallbackPid ! {ws_text, Payload};
handle_frame({binary, Payload}, _Socket, CallbackPid) ->
    %% Forward binary frames as text (Discord doesn't use binary, but handle it)
    CallbackPid ! {ws_text, Payload};
handle_frame({close, _Payload}, Socket, CallbackPid) ->
    %% Respond with close frame
    CloseFrame = <<1:1, 0:3, 8:4, 1:1, 0:7, 0:32>>,
    ssl:send(Socket, CloseFrame),
    CallbackPid ! ws_closed;
handle_frame({ping, Payload}, Socket, _CallbackPid) ->
    %% Respond with pong
    PongFrame = encode_control_frame(10, Payload),
    ssl:send(Socket, PongFrame);
handle_frame({pong, _Payload}, _Socket, _CallbackPid) ->
    %% Ignore pongs
    ok;
handle_frame({unknown, _Opcode, _Payload}, _Socket, _CallbackPid) ->
    ok.

process_frames(Data, Socket, CallbackPid) ->
    case extract_frames(Data) of
        {ok, Frames, _Rest} ->
            lists:foreach(fun(Frame) ->
                handle_frame(Frame, Socket, CallbackPid)
            end, Frames);
        {error, frame_too_large} ->
            CallbackPid ! {ws_error, <<"Frame exceeds maximum size">>}
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
