-module(aura_google_http_ffi).
-export([request/7, request_for_test/8, request_for_test_with_timeout/9,
         retry_after_ms/4]).

-define(CONNECT_TIMEOUT_MS, 5000).
-define(IDLE_TIMEOUT_MS, 5000).
-define(REQUEST_TIMEOUT_MS, 15000).
-define(STATUS_LINE_BYTES, 1024).
-define(MAX_HEADER_COUNT, 64).
-define(MAX_HEADER_BYTES, 32768).
-define(MAX_RETRY_AFTER_BYTES, 128).
-define(MIN_RETRY_MS, 1000).
-define(MAX_RETRY_MS, 3600000).
-define(MAX_FALLBACK_MS, 60000).

request(Method, Url, Bearer, ContentType, Body, BodyLimit, AttemptNumber) ->
    do_request(Method, Url, Bearer, ContentType, Body, BodyLimit,
               AttemptNumber, production, ?REQUEST_TIMEOUT_MS).

request_for_test(Method, Url, Bearer, ContentType, Body, BodyLimit,
                 AttemptNumber, Origin) ->
    do_request(Method, Url, Bearer, ContentType, Body, BodyLimit,
               AttemptNumber, {test_origin, Origin}, ?REQUEST_TIMEOUT_MS).

request_for_test_with_timeout(Method, Url, Bearer, ContentType, Body,
                              BodyLimit, AttemptNumber, Origin, TimeoutMs)
  when is_integer(TimeoutMs), TimeoutMs >= 50,
       TimeoutMs =< ?REQUEST_TIMEOUT_MS ->
    do_request(Method, Url, Bearer, ContentType, Body, BodyLimit,
               AttemptNumber, {test_origin, Origin}, TimeoutMs);
request_for_test_with_timeout(_, _, _, _, _, _, _, _, _) ->
    {before_dispatch, <<"google_http_request_invalid">>}.

do_request(Method, Url, Bearer, ContentType, Body, BodyLimit,
           AttemptNumber, Target, TimeoutMs) ->
    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    case validate_prepared(Method, Url, Bearer, ContentType, Body,
                           BodyLimit, AttemptNumber, Target) of
        {error, ErrorClass} -> {before_dispatch, ErrorClass};
        {ok, Destination} ->
            case connect(Destination, Deadline) of
                {error, _} ->
                    {before_dispatch, <<"google_http_connect_failed">>};
                {ok, Socket} ->
                    RequestBytes = build_request(Method, Url, Bearer,
                                                 ContentType, Body),
                    case socket_send(Socket, RequestBytes) of
                        ok ->
                            Outcome = receive_response_bounded(
                                        Socket, BodyLimit, AttemptNumber,
                                        Deadline),
                            socket_close(Socket),
                            Outcome;
                        {error, _} ->
                            socket_close(Socket),
                            {after_dispatch, <<"google_http_transport_failed">>}
                    end
            end
    end.

validate_prepared(Method, Url, Bearer, ContentType, Body, BodyLimit,
                  AttemptNumber, Target) ->
    case valid_prepared_shape(Method, Bearer, ContentType, Body, BodyLimit,
                              AttemptNumber) of
        false -> {error, <<"google_http_request_invalid">>};
        true -> destination(Url, Target)
    end.

valid_prepared_shape(<<"GET">>, Bearer, <<>>, <<>>, 1048576, Attempt)
  when byte_size(Bearer) > 0, byte_size(Bearer) =< 8192,
       Attempt > 0, Attempt =< 16 -> true;
valid_prepared_shape(<<"POST">>, <<>>,
                     <<"application/x-www-form-urlencoded">>, Body,
                     65536, Attempt)
  when byte_size(Body) > 0, byte_size(Body) =< 32768,
       Attempt > 0, Attempt =< 16 -> true;
valid_prepared_shape(_, _, _, _, _, _) -> false.

destination(Url, production) ->
    case uri_string:parse(Url) of
        #{scheme := <<"https">>, host := Host} = Parts
          when Host =:= <<"gmail.googleapis.com">>;
               Host =:= <<"www.googleapis.com">>;
               Host =:= <<"oauth2.googleapis.com">> ->
            Port = maps:get(port, Parts, 443),
            case Port of
                443 -> {ok, {ssl, Host, 443}};
                _ -> {error, <<"google_http_origin_invalid">>}
            end;
        _ -> {error, <<"google_http_origin_invalid">>}
    end;
destination(Url, {test_origin, Origin}) ->
    case {uri_string:parse(Url), uri_string:parse(Origin)} of
        {#{scheme := <<"https">>, host := ProductionHost},
         #{scheme := <<"http">>, host := <<"127.0.0.1">>, port := Port}}
          when (ProductionHost =:= <<"gmail.googleapis.com">> orelse
                ProductionHost =:= <<"www.googleapis.com">> orelse
                ProductionHost =:= <<"oauth2.googleapis.com">>),
               is_integer(Port), Port > 0, Port =< 65535 ->
            {ok, {tcp, <<"127.0.0.1">>, Port}};
        _ -> {error, <<"google_http_test_origin_invalid">>}
    end.

connect({tcp, Host, Port}, Deadline) ->
    case gen_tcp:connect(binary_to_list(Host), Port,
                         [binary, {active, false}, {packet, raw},
                          {recbuf, 4096},
                          {send_timeout, ?IDLE_TIMEOUT_MS},
                          {send_timeout_close, true}],
                         connect_timeout(Deadline)) of
        {ok, Socket} -> {ok, {tcp, Socket}};
        Error -> Error
    end;
connect({ssl, Host, Port}, Deadline) ->
    ssl:start(),
    MatchFun = public_key:pkix_verify_hostname_match_fun(https),
    Options = [binary, {active, false}, {packet, raw}, {recbuf, 4096},
               {verify, verify_peer}, {cacerts, public_key:cacerts_get()},
               {server_name_indication, binary_to_list(Host)},
               {alpn_advertised_protocols, [<<"http/1.1">>]},
               {customize_hostname_check, [{match_fun, MatchFun}]}],
    case ssl:connect(binary_to_list(Host), Port, Options,
                     connect_timeout(Deadline)) of
        {ok, Socket} -> {ok, {ssl, Socket}};
        Error -> Error
    end.

build_request(Method, Url, Bearer, ContentType, Body) ->
    Parts = uri_string:parse(Url),
    Host = maps:get(host, Parts),
    Path = maps:get(path, Parts, <<"/">>),
    Target = case maps:get(query, Parts, undefined) of
        undefined -> Path;
        Query -> <<Path/binary, "?", Query/binary>>
    end,
    Base = [Method, " ", Target, " HTTP/1.1\r\n",
            "host: ", Host, "\r\n",
            "accept: application/json\r\n",
            "accept-encoding: identity\r\n",
            "connection: close\r\n"],
    Auth = case Bearer of
        <<>> -> [];
        _ -> ["authorization: Bearer ", Bearer, "\r\n"]
    end,
    Entity = case Method of
        <<"POST">> -> ["content-type: ", ContentType, "\r\n",
                        "content-length: ", integer_to_binary(byte_size(Body)),
                        "\r\n"];
        _ -> []
    end,
    iolist_to_binary([Base, Auth, Entity, "\r\n", Body]).

receive_response_bounded(Socket, BodyLimit, AttemptNumber, Deadline) ->
    case read_status_line(Socket, Deadline) of
        {error, ErrorClass} -> {after_dispatch, ErrorClass};
        {ok, Status} ->
            case read_header_lines(Socket, Deadline, 0, 0, []) of
                {error, ErrorClass} -> {after_dispatch, ErrorClass};
                {ok, Headers} ->
                    case validate_response_headers(Status, Headers, BodyLimit) of
                        {error, ErrorClass} ->
                            {after_dispatch, ErrorClass};
                        {ok, Framing, RetryAfter} ->
                            case read_bounded_body(Socket, Framing, BodyLimit,
                                                   Deadline) of
                                {error, ErrorClass} ->
                                    {after_dispatch, ErrorClass};
                                {ok, Body} ->
                                    finish_response(Status, RetryAfter, Body,
                                                    AttemptNumber)
                            end
                    end
            end
    end.

read_status_line(Socket, Deadline) ->
    case socket_set_packet(Socket, raw, 0) of
        ok ->
            case read_line_bounded(Socket, ?STATUS_LINE_BYTES, Deadline, <<>>) of
                {ok, Line0} ->
                    Line = trim_crlf(Line0),
                    case parse_status(Line) of
                        {ok, Status} -> {ok, Status};
                        error -> {error, <<"google_http_response_invalid">>}
                    end;
                {error, line_too_large} ->
                    {error, <<"google_http_status_line_too_large">>};
                {error, timeout} ->
                    {error, <<"google_http_idle_timeout">>};
                {error, request_timeout} ->
                    {error, <<"google_http_request_timeout">>};
                {error, _} ->
                    {error, <<"google_http_transport_failed">>}
            end;
        {error, _} -> {error, <<"google_http_transport_failed">>}
    end.

read_header_lines(_Socket, _Deadline, Count, _Bytes, _Acc)
  when Count > ?MAX_HEADER_COUNT ->
    {error, <<"google_http_headers_too_large">>};
read_header_lines(_Socket, _Deadline, _Count, Bytes, _Acc)
  when Bytes > ?MAX_HEADER_BYTES ->
    {error, <<"google_http_headers_too_large">>};
read_header_lines(Socket, Deadline, Count, Bytes, Acc) ->
    case socket_set_packet(Socket, raw, 0) of
        ok ->
            case read_line_bounded(
                   Socket, ?MAX_HEADER_BYTES - Bytes, Deadline, <<>>) of
                {ok, <<"\r\n">>} -> {ok, lists:reverse(Acc)};
                {ok, <<"\n">>} -> {ok, lists:reverse(Acc)};
                {ok, Line0} ->
                    Line = trim_crlf(Line0),
                    NewBytes = Bytes + byte_size(Line0),
                    case parse_header_line(Line) of
                        {ok, Header} ->
                            read_header_lines(Socket, Deadline, Count + 1,
                                              NewBytes, [Header | Acc]);
                        error ->
                            {error, <<"google_http_response_invalid">>}
                    end;
                {error, line_too_large} ->
                    {error, <<"google_http_headers_too_large">>};
                {error, timeout} ->
                    {error, <<"google_http_idle_timeout">>};
                {error, request_timeout} ->
                    {error, <<"google_http_request_timeout">>};
                {error, _} ->
                    {error, <<"google_http_transport_failed">>}
            end;
        {error, _} -> {error, <<"google_http_transport_failed">>}
    end.

parse_header_line(Line) ->
    case binary:split(Line, <<":">>) of
        [Name, Value] when byte_size(Name) > 0 ->
            Lower = string:lowercase(binary_to_list(Name)),
            case valid_header_name(Lower) of
                true -> {ok, {Lower, string:trim(Value)}};
                false -> error
            end;
        _ -> error
    end.

read_bounded_body(Socket, {length, Length}, _Limit, Deadline) ->
    case socket_set_packet(Socket, raw, 0) of
        ok -> read_exact_bounded(Socket, Length, Deadline, <<>>);
        {error, _} -> {error, <<"google_http_transport_failed">>}
    end;
read_bounded_body(Socket, chunked, Limit, Deadline) ->
    read_chunks_bounded(Socket, Limit, Deadline, <<>>).

read_exact_bounded(_Socket, 0, _Deadline, Acc) -> {ok, Acc};
read_exact_bounded(Socket, Remaining, Deadline, Acc) ->
    Count = erlang:min(Remaining, 8192),
    case bounded_recv(Socket, Count, Deadline) of
        {ok, Part} when byte_size(Part) =:= Count ->
            read_exact_bounded(Socket, Remaining - Count, Deadline,
                               <<Acc/binary, Part/binary>>);
        {error, timeout} -> {error, <<"google_http_idle_timeout">>};
        {error, request_timeout} ->
            {error, <<"google_http_request_timeout">>};
        {error, _} -> {error, <<"google_http_transport_failed">>};
        _ -> {error, <<"google_http_response_invalid">>}
    end.

read_chunks_bounded(Socket, Remaining, Deadline, Acc) ->
    case socket_set_packet(Socket, raw, 0) of
        ok ->
            case read_line_bounded(Socket, 32, Deadline, <<>>) of
                {ok, Line0} ->
                    case parse_chunk_size(trim_crlf(Line0)) of
                        {ok, 0} -> read_chunk_terminator(Socket, Deadline, Acc);
                        {ok, Size} when Size =< Remaining ->
                            case socket_set_packet(Socket, raw, 0) of
                                ok ->
                                    case read_exact_bounded(
                                           Socket, Size + 2, Deadline, <<>>) of
                                        {ok, <<Data:Size/binary, "\r\n">>} ->
                                            read_chunks_bounded(
                                              Socket, Remaining - Size,
                                              Deadline,
                                              <<Acc/binary, Data/binary>>);
                                        {ok, _} ->
                                            {error,
                                             <<"google_http_response_invalid">>};
                                        Error -> Error
                                    end;
                                {error, _} ->
                                    {error,
                                     <<"google_http_transport_failed">>}
                            end;
                        {ok, _} ->
                            {error, <<"google_http_response_too_large">>};
                        error ->
                            {error, <<"google_http_response_invalid">>}
                    end;
                {error, line_too_large} ->
                    {error, <<"google_http_response_too_large">>};
                {error, timeout} ->
                    {error, <<"google_http_idle_timeout">>};
                {error, request_timeout} ->
                    {error, <<"google_http_request_timeout">>};
                {error, _} ->
                    {error, <<"google_http_transport_failed">>}
            end;
        {error, _} -> {error, <<"google_http_transport_failed">>}
    end.

read_chunk_terminator(Socket, Deadline, Acc) ->
    case socket_set_packet(Socket, raw, 0) of
        ok ->
            case read_line_bounded(Socket, ?MAX_HEADER_BYTES, Deadline, <<>>) of
                {ok, <<"\r\n">>} -> {ok, Acc};
                {ok, <<"\n">>} -> {ok, Acc};
                {ok, _} -> {error, <<"google_http_response_invalid">>};
                {error, line_too_large} ->
                    {error, <<"google_http_headers_too_large">>};
                {error, timeout} -> {error, <<"google_http_idle_timeout">>};
                {error, request_timeout} ->
                    {error, <<"google_http_request_timeout">>};
                {error, _} ->
                    {error, <<"google_http_transport_failed">>}
            end;
        {error, _} -> {error, <<"google_http_transport_failed">>}
    end.

finish_response(Status, RetryAfter, Body, AttemptNumber) ->
    case valid_utf8(Body) of
        false -> {after_dispatch, <<"google_http_response_invalid">>};
        true when Status >= 300, Status < 400 ->
            {after_dispatch, <<"google_http_redirect_not_allowed">>};
        true ->
            Delay = retry_after_ms(Status, RetryAfter,
                                   erlang:system_time(millisecond),
                                   AttemptNumber),
            {response, {http_response, Status, Delay, Body}}
    end.

trim_crlf(Value) ->
    Size = byte_size(Value),
    case Value of
        <<Line:(Size - 2)/binary, "\r\n">> when Size >= 2 -> Line;
        <<Line:(Size - 1)/binary, "\n">> when Size >= 1 -> Line;
        _ -> Value
    end.

socket_set_packet({tcp, Socket}, Packet, PacketSize) ->
    inet:setopts(Socket, [{packet, Packet}, {packet_size, PacketSize}]);
socket_set_packet({ssl, Socket}, Packet, PacketSize) ->
    ssl:setopts(Socket, [{packet, Packet}, {packet_size, PacketSize}]).

bounded_recv(Socket, Count, Deadline) ->
    Remaining = Deadline - erlang:monotonic_time(millisecond),
    case Remaining =< 0 of
        true -> {error, request_timeout};
        false ->
            Timeout = erlang:min(?IDLE_TIMEOUT_MS, Remaining),
            Result = case Socket of
                {tcp, TcpSocket} -> gen_tcp:recv(TcpSocket, Count, Timeout);
                {ssl, SslSocket} -> ssl:recv(SslSocket, Count, Timeout)
            end,
            case {Result, Remaining =< ?IDLE_TIMEOUT_MS} of
                {{error, timeout}, true} -> {error, request_timeout};
                _ -> Result
            end
    end.

connect_timeout(Deadline) ->
    erlang:max(1, erlang:min(
      ?CONNECT_TIMEOUT_MS,
      Deadline - erlang:monotonic_time(millisecond))).

read_line_bounded(_Socket, Limit, _Deadline, Acc)
  when byte_size(Acc) > Limit + 2 ->
    {error, line_too_large};
read_line_bounded(Socket, Limit, Deadline, Acc) ->
    case bounded_recv(Socket, 1, Deadline) of
        {ok, <<"\n">>} ->
            Line = <<Acc/binary, "\n">>,
            case byte_size(trim_crlf(Line)) =< Limit of
                true -> {ok, Line};
                false -> {error, line_too_large}
            end;
        {ok, Byte} when byte_size(Byte) =:= 1 ->
            read_line_bounded(Socket, Limit, Deadline, <<Acc/binary, Byte/binary>>);
        Error -> Error
    end.

parse_status(Line) ->
    case binary:split(Line, <<" ">>, [global]) of
        [<<"HTTP/1.1">>, Code | _] when byte_size(Code) =:= 3 ->
            try binary_to_integer(Code) of
                Status when Status >= 100, Status =< 599 -> {ok, Status};
                _ -> error
            catch _:_ -> error end;
        _ -> error
    end.

valid_header_name([]) -> false;
valid_header_name(Name) ->
    lists:all(fun(C) ->
        (C >= $a andalso C =< $z) orelse
        (C >= $0 andalso C =< $9) orelse C =:= $-
    end, Name).

validate_response_headers(Status, Headers, BodyLimit) ->
    Encoding = one_header("content-encoding", Headers),
    Length = one_header("content-length", Headers),
    Transfer = one_header("transfer-encoding", Headers),
    Retry = one_header("retry-after", Headers),
    case {allowed_encoding(Encoding), retry_value(Retry),
          body_framing(Status, Length, Transfer, BodyLimit)} of
        {false, _, _} ->
            {error, <<"google_http_content_encoding_not_allowed">>};
        {_, {error, ErrorClass}, _} -> {error, ErrorClass};
        {_, _, {error, ErrorClass}} -> {error, ErrorClass};
        {true, {ok, RetryAfter}, {ok, Framing}} ->
            {ok, Framing, RetryAfter}
    end.

one_header(Name, Headers) ->
    case [Value || {Key, Value} <- Headers, Key =:= Name] of
        [] -> absent;
        [Value] -> {value, Value};
        _ -> duplicate
    end.

allowed_encoding(absent) -> true;
allowed_encoding({value, Value}) ->
    string:lowercase(binary_to_list(Value)) =:= "identity";
allowed_encoding(_) -> false.

retry_value(absent) -> {ok, <<>>};
retry_value({value, Value}) when byte_size(Value) =< ?MAX_RETRY_AFTER_BYTES ->
    {ok, Value};
retry_value(_) -> {error, <<"google_http_retry_after_invalid">>}.

body_framing(_Status, duplicate, _Transfer, _Limit) ->
    {error, <<"google_http_response_invalid">>};
body_framing(_Status, _Length, duplicate, _Limit) ->
    {error, <<"google_http_response_invalid">>};
body_framing(_Status, {value, _}, {value, _}, _Limit) ->
    {error, <<"google_http_response_invalid">>};
body_framing(_Status, absent, {value, Value}, _Limit) ->
    case string:lowercase(binary_to_list(Value)) of
        "chunked" -> {ok, chunked};
        _ -> {error, <<"google_http_response_invalid">>}
    end;
body_framing(_Status, {value, Value}, absent, Limit) ->
    try binary_to_integer(Value) of
        Length when Length >= 0, Length =< Limit -> {ok, {length, Length}};
        Length when Length > Limit ->
            {error, <<"google_http_response_too_large">>};
        _ -> {error, <<"google_http_response_invalid">>}
    catch _:_ -> {error, <<"google_http_response_invalid">>} end;
body_framing(Status, absent, absent, _Limit)
  when Status =:= 204; Status =:= 304 -> {ok, {length, 0}};
body_framing(_, absent, absent, _) ->
    {error, <<"google_http_response_invalid">>}.

parse_chunk_size(<<>>) -> error;
parse_chunk_size(Value) when byte_size(Value) =< 16 ->
    case lists:all(fun is_hex/1, binary_to_list(Value)) of
        true ->
            try list_to_integer(binary_to_list(Value), 16) of
                Size -> {ok, Size}
            catch _:_ -> error end;
        false -> error
    end;
parse_chunk_size(_) -> error.

is_hex(C) ->
    (C >= $0 andalso C =< $9) orelse
    (C >= $a andalso C =< $f) orelse
    (C >= $A andalso C =< $F).

valid_utf8(Value) ->
    case unicode:characters_to_binary(Value, utf8, utf8) of
        Result when is_binary(Result) -> true;
        _ -> false
    end.

socket_send({tcp, Socket}, Value) -> gen_tcp:send(Socket, Value);
socket_send({ssl, Socket}, Value) -> ssl:send(Socket, Value).


socket_close({tcp, Socket}) -> catch gen_tcp:close(Socket);
socket_close({ssl, Socket}) -> catch ssl:close(Socket).

retry_after_ms(Status, Value, NowMs, AttemptNumber)
  when is_integer(Status), is_binary(Value), is_integer(NowMs),
       is_integer(AttemptNumber), AttemptNumber > 0 ->
    case retryable_status(Status) of
        false -> 0;
        true ->
            Parsed = case byte_size(Value) =< ?MAX_RETRY_AFTER_BYTES of
                true -> parse_retry_after(Value, NowMs);
                false -> invalid
            end,
            case Parsed of
                invalid -> fallback_delay(AttemptNumber);
                Delay -> clamp_retry(Delay)
            end
    end;
retry_after_ms(_, _, _, _) -> 0.

retryable_status(429) -> true;
retryable_status(Status) when Status >= 500, Status =< 599 -> true;
retryable_status(_) -> false.

parse_retry_after(<<>>, _NowMs) -> invalid;
parse_retry_after(Value, NowMs) ->
    try binary_to_integer(Value) of
        Seconds when Seconds >= 0 -> Seconds * 1000;
        _ -> invalid
    catch _:_ -> parse_http_date(Value, NowMs) end.

parse_http_date(Value, NowMs) ->
    try httpd_util:convert_request_date(binary_to_list(Value)) of
        {{Year, Month, Day}, {Hour, Minute, Second}} ->
            Target = calendar:datetime_to_gregorian_seconds(
                       {{Year, Month, Day}, {Hour, Minute, Second}}),
            Epoch = calendar:datetime_to_gregorian_seconds(
                      {{1970, 1, 1}, {0, 0, 0}}),
            erlang:max(0, (Target - Epoch) * 1000 - NowMs);
        _ -> invalid
    catch _:_ -> invalid end.

fallback_delay(AttemptNumber) ->
    erlang:min(?MAX_FALLBACK_MS,
               ?MIN_RETRY_MS * (1 bsl erlang:min(AttemptNumber - 1, 10))).

clamp_retry(Value) when Value < ?MIN_RETRY_MS -> ?MIN_RETRY_MS;
clamp_retry(Value) when Value > ?MAX_RETRY_MS -> ?MAX_RETRY_MS;
clamp_retry(Value) -> Value.
