-module(aura_oauth_loopback_ffi).
-export([listen_once/1, listen_once_with_timeout/2, close/1, request_once/2]).

-define(MAX_REQUEST, 16384).
-define(MAX_TARGET, 2048).

listen_once(Handler) when is_function(Handler, 3) ->
    listen_once_with_timeout(Handler, 300000).

listen_once_with_timeout(Handler, TimeoutMs)
        when is_function(Handler, 3), is_integer(TimeoutMs),
             TimeoutMs > 0, TimeoutMs =< 300000 ->
    case gen_tcp:listen(0, [binary, {ip, {127,0,0,1}}, {active, false},
                            {reuseaddr, false}, {packet, raw}, {backlog, 1}]) of
        {ok, Socket} ->
            {ok, {{127,0,0,1}, Port}} = inet:sockname(Socket),
            Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
            Pid = spawn_link(fun() -> accept_once(Socket, Port, Handler, Deadline) end),
            {ok, {Pid, Port}};
        {error, Reason} ->
            {error, reason(Reason)}
    end;
listen_once_with_timeout(_, _) ->
    {error, <<"invalid_loopback_timeout">>}.

close(Pid) when is_pid(Pid) ->
    unlink(Pid),
    exit(Pid, shutdown),
    nil.

request_once(Port, Request) when is_integer(Port), is_binary(Request) ->
    case gen_tcp:connect({127,0,0,1}, Port, [binary, {active, false}, {packet, raw}], 1000) of
        {ok, Socket} ->
            Result = case gen_tcp:send(Socket, Request) of
                ok -> receive_all(Socket, []);
                {error, SendReason} -> {error, reason(SendReason)}
            end,
            gen_tcp:close(Socket),
            Result;
        {error, ConnectReason} ->
            {error, reason(ConnectReason)}
    end.

accept_once(ListenSocket, Port, Handler, Deadline) ->
    case gen_tcp:accept(ListenSocket, remaining_ms(Deadline)) of
        {ok, Socket} ->
            gen_tcp:close(ListenSocket),
            Response = case receive_request(Socket, <<>>, Deadline) of
                {ok, Request} -> handle_request(Request, Port, Handler);
                {error, expired} -> expired_response(Handler);
                {error, _} -> invalid_response(Handler)
            end,
            _ = gen_tcp:send(Socket, Response),
            gen_tcp:close(Socket);
        {error, timeout} ->
            _ = safe_handler(Handler, <<"expired">>, <<>>, <<>>),
            gen_tcp:close(ListenSocket);
        {error, _} ->
            gen_tcp:close(ListenSocket)
    end.

receive_request(_Socket, Acc, _Deadline) when byte_size(Acc) > ?MAX_REQUEST ->
    {error, request_too_large};
receive_request(Socket, Acc, Deadline) ->
    case binary:match(Acc, <<"\r\n\r\n">>) of
        {_, _} -> {ok, Acc};
        nomatch ->
            case remaining_ms(Deadline) of
                0 -> {error, expired};
                Remaining -> case gen_tcp:recv(Socket, 0, Remaining) of
                {ok, Chunk} -> receive_request(
                    Socket, <<Acc/binary, Chunk/binary>>, Deadline);
                {error, timeout} -> {error, expired};
                {error, Reason} -> {error, Reason}
                end
            end
    end.

remaining_ms(Deadline) ->
    case Deadline - erlang:monotonic_time(millisecond) of
        Remaining when Remaining > 0 -> Remaining;
        _ -> 0
    end.

handle_request(Request, Port, Handler) ->
    case parse_request(Request, Port) of
        {ok, Kind, State, Value} ->
            Accepted = safe_handler(Handler, Kind, State, Value),
            response(Accepted);
        {error, _} -> invalid_response(Handler)
    end.

invalid_response(Handler) ->
    _ = safe_handler(Handler, <<"invalid">>, <<>>, <<>>),
    response(false).

expired_response(Handler) ->
    _ = safe_handler(Handler, <<"expired">>, <<>>, <<>>),
    response(false).

safe_handler(Handler, Kind, State, Value) ->
    try Handler(Kind, State, Value) of
        true -> true;
        _ -> false
    catch
        _:_ -> false
    end.

parse_request(Request, Port) when byte_size(Request) =< ?MAX_REQUEST ->
    [Head | _] = binary:split(Request, <<"\r\n\r\n">>),
    case binary:split(Head, <<"\r\n">>, [global]) of
        [RequestLine | Headers] ->
            case parse_request_line(RequestLine) of
                {ok, Target} ->
                    ExpectedHost = <<"127.0.0.1:", (integer_to_binary(Port))/binary>>,
                    case exact_host(Headers, ExpectedHost) of
                        true -> parse_target(Target);
                        false -> {error, invalid_host}
                    end;
                Error -> Error
            end;
        _ -> {error, malformed_request}
    end;
parse_request(_, _) ->
    {error, request_too_large}.

parse_request_line(Line) when byte_size(Line) =< (?MAX_TARGET + 32) ->
    case binary:split(Line, <<" ">>, [global]) of
        [<<"GET">>, Target, <<"HTTP/1.1">>] when byte_size(Target) =< ?MAX_TARGET ->
            {ok, Target};
        _ -> {error, invalid_request_line}
    end;
parse_request_line(_) ->
    {error, request_line_too_large}.

exact_host(Headers, Expected) ->
    HostValues = lists:filtermap(fun(Header) ->
        case binary:split(Header, <<":">>) of
            [Name, Value] ->
                case string:lowercase(binary_to_list(Name)) of
                    "host" -> {true, string:trim(Value)};
                    _ -> false
                end;
            _ -> false
        end
    end, Headers),
    length(Headers) =< 64
        andalso lists:all(fun(Header) -> byte_size(Header) =< 4096 end, Headers)
        andalso HostValues =:= [Expected].

parse_target(Target) ->
    case binary:split(Target, <<"?">>) of
        [<<"/callback">>, Query] -> parse_query(Query);
        _ -> {error, invalid_path}
    end.

parse_query(Query) ->
    case decode_pairs(binary:split(Query, <<"&">>, [global]), []) of
        {ok, Pairs} ->
            State = values(<<"state">>, Pairs),
            Code = values(<<"code">>, Pairs),
            Error = values(<<"error">>, Pairs),
            case {State, Code, Error, length(Pairs)} of
                {[S], [C], [], 2} when byte_size(S) > 0, byte_size(S) =< 128,
                                         byte_size(C) > 0, byte_size(C) =< 1024 ->
                    {ok, <<"code">>, S, C};
                {[S], [], [E], 2} when byte_size(S) > 0, byte_size(S) =< 128,
                                         byte_size(E) > 0, byte_size(E) =< 64 ->
                    {ok, <<"error">>, S, E};
                _ -> {error, invalid_query}
            end;
        Error -> Error
    end.

decode_pairs([], Acc) -> {ok, lists:reverse(Acc)};
decode_pairs([Pair | Rest], Acc) ->
    case binary:split(Pair, <<"=">>) of
        [RawKey, RawValue] ->
            try
                true = well_formed_percent_encoding(RawKey),
                true = well_formed_percent_encoding(RawValue),
                Key = uri_string:percent_decode(RawKey),
                Value = uri_string:percent_decode(RawValue),
                decode_pairs(Rest, [{Key, Value} | Acc])
            catch
                _:_ -> {error, invalid_encoding}
            end;
        _ -> {error, invalid_query}
    end.

well_formed_percent_encoding(<<>>) -> true;
well_formed_percent_encoding(<<$%, A, B, Rest/binary>>) ->
    is_hex(A) andalso is_hex(B) andalso well_formed_percent_encoding(Rest);
well_formed_percent_encoding(<<$%, _/binary>>) -> false;
well_formed_percent_encoding(<<_, Rest/binary>>) ->
    well_formed_percent_encoding(Rest).

is_hex(Value) when Value >= $0, Value =< $9 -> true;
is_hex(Value) when Value >= $A, Value =< $F -> true;
is_hex(Value) when Value >= $a, Value =< $f -> true;
is_hex(_) -> false.

values(Key, Pairs) -> [Value || {PairKey, Value} <- Pairs, PairKey =:= Key].

response(true) ->
    <<"HTTP/1.1 200 OK\r\n",
      "Content-Type: text/html; charset=utf-8\r\n",
      "Cache-Control: no-store\r\n",
      "Referrer-Policy: no-referrer\r\n",
      "Content-Security-Policy: default-src 'none'\r\n",
      "Connection: close\r\n\r\n",
      "<html><body>Authorization complete.</body></html>">>;
response(false) ->
    <<"HTTP/1.1 400 Bad Request\r\n",
      "Content-Type: text/html; charset=utf-8\r\n",
      "Cache-Control: no-store\r\n",
      "Referrer-Policy: no-referrer\r\n",
      "Content-Security-Policy: default-src 'none'\r\n",
      "Connection: close\r\n\r\n",
      "<html><body>Authorization failed.</body></html>">>.

receive_all(Socket, Acc) ->
    case gen_tcp:recv(Socket, 0, 2000) of
        {ok, Data} -> receive_all(Socket, [Data | Acc]);
        {error, closed} -> {ok, iolist_to_binary(lists:reverse(Acc))};
        {error, Reason} -> {error, reason(Reason)}
    end.

reason(Value) -> iolist_to_binary(io_lib:format("~p", [Value])).
