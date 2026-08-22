-module(aura_google_http_fake_ffi).
-export([start/2, start_drip/2, last_request/0]).

start(RawResponse, DelayMs) when is_binary(RawResponse), is_integer(DelayMs),
                                  DelayMs >= 0, DelayMs =< 10000 ->
    case gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true},
                            {ip, {127,0,0,1}}]) of
        {ok, Listener} ->
            {ok, {_Address, Port}} = inet:sockname(Listener),
            spawn(fun() -> serve_once(Listener, RawResponse, DelayMs) end),
            {ok, iolist_to_binary(io_lib:format("http://127.0.0.1:~B", [Port]))};
        {error, _} -> {error, <<"google_http_fake_start_failed">>}
    end;
start(_, _) -> {error, <<"google_http_fake_input_invalid">>}.

start_drip(RawResponse, IntervalMs)
  when is_binary(RawResponse), is_integer(IntervalMs),
       IntervalMs > 0, IntervalMs =< 1000 ->
    case gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true},
                            {ip, {127,0,0,1}}]) of
        {ok, Listener} ->
            {ok, {_Address, Port}} = inet:sockname(Listener),
            spawn(fun() -> serve_drip(Listener, RawResponse, IntervalMs) end),
            {ok, iolist_to_binary(io_lib:format("http://127.0.0.1:~B", [Port]))};
        {error, _} -> {error, <<"google_http_fake_start_failed">>}
    end;
start_drip(_, _) -> {error, <<"google_http_fake_input_invalid">>}.

last_request() ->
    persistent_term:get({?MODULE, last_request}, <<>>).

serve_once(Listener, RawResponse, DelayMs) ->
    case gen_tcp:accept(Listener, 5000) of
        {ok, Socket} ->
            Request = receive_headers(Socket, <<>>, 32768),
            persistent_term:put({?MODULE, last_request}, Request),
            case DelayMs of
                0 -> ok;
                _ -> timer:sleep(DelayMs)
            end,
            case RawResponse of
                <<>> -> ok;
                _ -> gen_tcp:send(Socket, RawResponse)
            end,
            gen_tcp:close(Socket);
        _ -> ok
    end,
    gen_tcp:close(Listener).

serve_drip(Listener, RawResponse, IntervalMs) ->
    case gen_tcp:accept(Listener, 5000) of
        {ok, Socket} ->
            Request = receive_headers(Socket, <<>>, 32768),
            persistent_term:put({?MODULE, last_request}, Request),
            send_drip(Socket, RawResponse, IntervalMs),
            gen_tcp:close(Socket);
        _ -> ok
    end,
    gen_tcp:close(Listener).

send_drip(_Socket, <<>>, _IntervalMs) -> ok;
send_drip(Socket, <<Byte, Rest/binary>>, IntervalMs) ->
    case gen_tcp:send(Socket, <<Byte>>) of
        ok ->
            timer:sleep(IntervalMs),
            send_drip(Socket, Rest, IntervalMs);
        {error, _} -> ok
    end.

receive_headers(_Socket, Acc, Remaining) when Remaining =< 0 -> Acc;
receive_headers(Socket, Acc, Remaining) ->
    case binary:match(Acc, <<"\r\n\r\n">>) of
        {_, _} -> Acc;
        nomatch ->
            case gen_tcp:recv(Socket, 0, 1000) of
                {ok, Part} ->
                    receive_headers(Socket, <<Acc/binary, Part/binary>>,
                                    Remaining - byte_size(Part));
                _ -> Acc
            end
    end.
