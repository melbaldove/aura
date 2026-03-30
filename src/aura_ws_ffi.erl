-module(aura_ws_ffi).
-export([connect/3]).

%% Connect to a Discord gateway WebSocket and relay frames to a Gleam process.
%% Returns {ok, Pid} where Pid is the relay process.
%% The relay process sends {ws_text, Binary} messages to the CallbackPid.
connect(Host, Path, CallbackPid) ->
    spawn_link(fun() -> ws_loop(Host, Path, CallbackPid) end).

ws_loop(Host, Path, CallbackPid) ->
    ssl:start(),
    Port = 443,
    Opts = [{verify, verify_peer},
            {cacerts, public_key:cacerts_get()},
            {server_name_indication, binary_to_list(Host)},
            {customize_hostname_check, [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]},
            binary, {active, false}],
    {ok, Socket} = ssl:connect(binary_to_list(Host), Port, Opts, 10000),

    %% WebSocket upgrade
    Key = base64:encode(crypto:strong_rand_bytes(16)),
    Req = [<<"GET ">>, Path, <<" HTTP/1.1\r\n">>,
           <<"Host: ">>, Host, <<"\r\n">>,
           <<"Upgrade: websocket\r\n">>,
           <<"Connection: Upgrade\r\n">>,
           <<"Sec-WebSocket-Key: ">>, Key, <<"\r\n">>,
           <<"Sec-WebSocket-Version: 13\r\n">>,
           <<"\r\n">>],
    ssl:send(Socket, Req),

    %% Read upgrade response
    {ok, RespData} = ssl:recv(Socket, 0, 10000),

    %% Check for 101
    case binary:match(RespData, <<"101">>) of
        nomatch ->
            CallbackPid ! {ws_error, <<"Upgrade failed">>},
            ssl:close(Socket);
        _ ->
            %% Extract any data after the HTTP headers (piggybacked frame)
            case binary:split(RespData, <<"\r\n\r\n">>) of
                [_Headers, Extra] when byte_size(Extra) > 0 ->
                    process_frames(Extra, Socket, CallbackPid);
                _ -> ok
            end,
            %% Switch to active mode and relay
            ssl:setopts(Socket, [{active, true}]),
            relay_loop(Socket, CallbackPid, <<>>)
    end.

relay_loop(Socket, CallbackPid, Buffer) ->
    receive
        {ssl, Socket, Data} ->
            NewBuffer = <<Buffer/binary, Data/binary>>,
            {Frames, Rest} = extract_frames(NewBuffer),
            lists:foreach(fun(Frame) ->
                CallbackPid ! {ws_text, Frame}
            end, Frames),
            relay_loop(Socket, CallbackPid, Rest);
        {ssl_closed, Socket} ->
            CallbackPid ! ws_closed;
        {ssl_error, Socket, Reason} ->
            CallbackPid ! {ws_error, list_to_binary(io_lib:format("~p", [Reason]))};
        {ws_send, Data} ->
            Frame = encode_text_frame(Data),
            ssl:send(Socket, Frame),
            relay_loop(Socket, CallbackPid, Buffer);
        ws_close ->
            ssl:close(Socket)
    end.

process_frames(Data, Socket, CallbackPid) ->
    {Frames, _Rest} = extract_frames(Data),
    lists:foreach(fun(Frame) ->
        CallbackPid ! {ws_text, Frame}
    end, Frames).

%% Extract complete WebSocket text frames from buffer
extract_frames(Buffer) ->
    extract_frames(Buffer, []).

extract_frames(<<>>, Acc) ->
    {lists:reverse(Acc), <<>>};
extract_frames(<<1:1, 0:3, 1:4, 0:1, Len:7, Payload:Len/binary, Rest/binary>>, Acc) when Len < 126 ->
    extract_frames(Rest, [Payload | Acc]);
extract_frames(<<1:1, 0:3, 1:4, 0:1, 126:7, Len:16, Payload:Len/binary, Rest/binary>>, Acc) ->
    extract_frames(Rest, [Payload | Acc]);
extract_frames(<<1:1, 0:3, 1:4, 0:1, 127:7, Len:64, Payload:Len/binary, Rest/binary>>, Acc) ->
    extract_frames(Rest, [Payload | Acc]);
extract_frames(Incomplete, Acc) ->
    {lists:reverse(Acc), Incomplete}.

%% Encode a text frame (client must mask)
encode_text_frame(Data) when is_binary(Data) ->
    Len = byte_size(Data),
    MaskKey = crypto:strong_rand_bytes(4),
    Masked = mask_data(Data, MaskKey, 0, <<>>),
    if
        Len < 126 ->
            <<1:1, 0:3, 1:4, 1:1, Len:7, MaskKey/binary, Masked/binary>>;
        Len < 65536 ->
            <<1:1, 0:3, 1:4, 1:1, 126:7, Len:16, MaskKey/binary, Masked/binary>>;
        true ->
            <<1:1, 0:3, 1:4, 1:1, 127:7, Len:64, MaskKey/binary, Masked/binary>>
    end.

mask_data(<<>>, _Key, _I, Acc) -> Acc;
mask_data(<<B:8, Rest/binary>>, Key, I, Acc) ->
    <<_:I/binary, K:8, _/binary>> = <<Key/binary, Key/binary, Key/binary, Key/binary>>,
    mask_data(Rest, Key, (I + 1) rem 4, <<Acc/binary, (B bxor K):8>>).
