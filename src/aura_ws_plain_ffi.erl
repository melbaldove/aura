-module(aura_ws_plain_ffi).
-export([connect/4]).

%% Plain-TCP WebSocket client (ws://, not wss://). Mirrors aura_ws_ffi
%% but uses gen_tcp instead of ssl so it can talk to VPN-local services
%% that aren't TLS-fronted (like the Blather dev server on
%% 10.0.0.2:18100). Socket-agnostic protocol logic (handshake, frame
%% parse, masking) is shared via aura_ws_protocol.
%%
%% connect(Host, Port, Path, CallbackPid) -> Pid
%% The relay process sends {ws_text, Binary} | ws_closed | {ws_error, Binary}
%% messages to CallbackPid, identical to the SSL FFI.
connect(Host, Port, Path, CallbackPid) ->
    spawn(fun() ->
        try
            ws_loop(Host, Port, Path, CallbackPid)
        catch
            Class:Reason:Stack ->
                Msg = iolist_to_binary(io_lib:format("~p:~p ~p", [Class, Reason, Stack])),
                CallbackPid ! {ws_error, Msg}
        end
    end).

ws_loop(Host, Port, Path, CallbackPid) ->
    HostStr = binary_to_list(Host),
    Opts = [binary, {active, false}, {packet, raw}],

    case gen_tcp:connect(HostStr, Port, Opts, 10000) of
        {ok, Socket} ->
            case do_handshake(Socket, Host, Path) of
                {ok, Extra} ->
                    case Extra of
                        <<>> -> ok;
                        _ ->
                            try
                                process_frames(Extra, Socket, CallbackPid)
                            catch
                                _:Reason ->
                                    catch gen_tcp:close(Socket),
                                    CallbackPid ! {ws_error, io_lib:format("~p", [Reason])},
                                    ok
                            end
                    end,
                    relay_loop_recv(Socket, CallbackPid, <<>>);
                {error, Reason} ->
                    CallbackPid ! {ws_error, Reason},
                    catch gen_tcp:close(Socket)
            end;
        {error, Reason} ->
            Msg = iolist_to_binary(
                io_lib:format("TCP connect failed: ~p", [Reason])),
            CallbackPid ! {ws_error, Msg}
    end.

do_handshake(Socket, Host, Path) ->
    Key = base64:encode(crypto:strong_rand_bytes(16)),
    ExpectedAccept = aura_ws_protocol:compute_accept_key(Key),

    Req = [<<"GET ">>, Path, <<" HTTP/1.1\r\n">>,
           <<"Host: ">>, Host, <<"\r\n">>,
           <<"Upgrade: websocket\r\n">>,
           <<"Connection: Upgrade\r\n">>,
           <<"Sec-WebSocket-Key: ">>, Key, <<"\r\n">>,
           <<"Sec-WebSocket-Version: 13\r\n">>,
           <<"\r\n">>],
    gen_tcp:send(Socket, Req),

    case gen_tcp:recv(Socket, 0, 10000) of
        {ok, RespData} ->
            case binary:match(RespData, <<"101">>) of
                nomatch ->
                    {error, <<"Upgrade failed: server did not return 101">>};
                _ ->
                    case aura_ws_protocol:validate_accept(RespData, ExpectedAccept) of
                        ok ->
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

relay_loop_recv(Socket, CallbackPid, Buffer) ->
    receive
        {ws_send, Data} ->
            Frame = aura_ws_protocol:encode_text_frame(Data),
            gen_tcp:send(Socket, Frame),
            relay_loop_recv(Socket, CallbackPid, Buffer);
        ws_close ->
            CloseFrame = aura_ws_protocol:encode_control_frame(8, <<3:8, 232:8>>),
            gen_tcp:send(Socket, CloseFrame),
            gen_tcp:close(Socket),
            CallbackPid ! ws_closed
    after 0 ->
        case gen_tcp:recv(Socket, 0, 500) of
            {ok, Data} ->
                NewBuffer = <<Buffer/binary, Data/binary>>,
                case aura_ws_protocol:extract_frames(NewBuffer) of
                    {ok, Frames, Rest} ->
                        lists:foreach(fun(Frame) ->
                            handle_frame(Frame, Socket, CallbackPid)
                        end, Frames),
                        relay_loop_recv(Socket, CallbackPid, Rest);
                    {error, frame_too_large} ->
                        CallbackPid ! {ws_error, <<"Frame exceeds maximum size">>},
                        catch gen_tcp:close(Socket)
                end;
            {error, timeout} ->
                relay_loop_recv(Socket, CallbackPid, Buffer);
            {error, closed} ->
                CallbackPid ! ws_closed;
            {error, Reason} ->
                CallbackPid ! {ws_error, iolist_to_binary(
                    io_lib:format("TCP error: ~p", [Reason]))},
                catch gen_tcp:close(Socket)
        end
    end.

handle_frame({text, Payload}, _Socket, CallbackPid) ->
    CallbackPid ! {ws_text, Payload};
handle_frame({binary, Payload}, _Socket, CallbackPid) ->
    CallbackPid ! {ws_text, Payload};
handle_frame({close, _Payload}, Socket, CallbackPid) ->
    CloseFrame = <<1:1, 0:3, 8:4, 1:1, 0:7, 0:32>>,
    gen_tcp:send(Socket, CloseFrame),
    CallbackPid ! ws_closed;
handle_frame({ping, Payload}, Socket, _CallbackPid) ->
    PongFrame = aura_ws_protocol:encode_control_frame(10, Payload),
    gen_tcp:send(Socket, PongFrame);
handle_frame({pong, _Payload}, _Socket, _CallbackPid) ->
    ok;
handle_frame({unknown, _Opcode, _Payload}, _Socket, _CallbackPid) ->
    ok.

process_frames(Data, Socket, CallbackPid) ->
    case aura_ws_protocol:extract_frames(Data) of
        {ok, Frames, _Rest} ->
            lists:foreach(fun(Frame) ->
                handle_frame(Frame, Socket, CallbackPid)
            end, Frames);
        {error, frame_too_large} ->
            CallbackPid ! {ws_error, <<"Frame exceeds maximum size">>}
    end.
