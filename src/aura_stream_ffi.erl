-module(aura_stream_ffi).
-export([chat_stream/5, receive_stream_message/1]).

%% ---------------------------------------------------------------------------
%% chat_stream/5 — Start a streaming HTTP POST to an OpenAI-compatible
%% chat completions endpoint.  SSE deltas are parsed and forwarded as
%%   {stream_delta, Binary}   — a content chunk
%%   stream_done              — end of stream
%%   {stream_error, Binary}   — fatal error
%% to CallbackPid.
%% ---------------------------------------------------------------------------

chat_stream(Url, ApiKey, _Model, BodyJson, CallbackPid) ->
    ssl:start(),
    inets:start(),
    UrlStr = binary_to_list(Url),
    Headers = [{"authorization", "Bearer " ++ binary_to_list(ApiKey)}],
    ContentType = "application/json",
    Body = binary_to_list(BodyJson),
    case httpc:request(post,
                       {UrlStr, Headers, ContentType, Body},
                       [{timeout, 120000}],
                       [{sync, false}, {stream, self}]) of
        {ok, RequestId} ->
            stream_loop(RequestId, CallbackPid, <<>>),
            nil;
        {error, Reason} ->
            CallbackPid ! {stream_error,
                iolist_to_binary(io_lib:format("~p", [Reason]))},
            nil
    end.

%% ---------------------------------------------------------------------------
%% Main receive loop — accumulates SSE chunks, parses data: lines,
%% extracts delta.content, and forwards to CallbackPid.
%% ---------------------------------------------------------------------------

stream_loop(RequestId, CallbackPid, Buffer) ->
    receive
        {http, {RequestId, stream_start, _Headers}} ->
            stream_loop(RequestId, CallbackPid, Buffer);

        {http, {RequestId, stream, BinBodyPart}} ->
            NewBuffer = <<Buffer/binary, BinBodyPart/binary>>,
            {Remainder, Events} = parse_sse_lines(NewBuffer),
            IsDone = lists:foldl(fun(Event, Done) ->
                case Event of
                    done ->
                        true;
                    {delta, <<>>} ->
                        Done;
                    {delta, Content} ->
                        CallbackPid ! {stream_delta, Content},
                        Done;
                    {reasoning, _} ->
                        %% GLM-5.1 reasoning tokens — signal that stream is alive
                        CallbackPid ! stream_reasoning,
                        Done;
                    {tool_calls, _} ->
                        %% Tool call deltas — ignored in streaming path
                        Done
                end
            end, false, Events),
            case IsDone of
                true ->
                    CallbackPid ! stream_done;
                false ->
                    stream_loop(RequestId, CallbackPid, Remainder)
            end;

        {http, {RequestId, stream_end, _Headers}} ->
            CallbackPid ! stream_done;

        {http, {RequestId, {error, Reason}}} ->
            Msg = iolist_to_binary(
                io_lib:format("Stream error: ~p", [Reason])),
            CallbackPid ! {stream_error, Msg}

    after 120000 ->
        CallbackPid ! {stream_error, <<"Stream timeout">>}
    end.

%% ---------------------------------------------------------------------------
%% SSE line parser
%% Split the buffer on newlines.  Complete lines are parsed; the last
%% (possibly-incomplete) line is kept as remainder for next chunk.
%% ---------------------------------------------------------------------------

parse_sse_lines(Buffer) ->
    Lines = binary:split(Buffer, <<"\n">>, [global]),
    parse_lines(Lines, []).

parse_lines([], Acc) ->
    {<<>>, lists:reverse(Acc)};
parse_lines([Last], Acc) ->
    %% Last element may be an incomplete line — keep as remainder
    {Last, lists:reverse(Acc)};
parse_lines([Line | Rest], Acc) ->
    case Line of
        <<"data: [DONE]", _/binary>> ->
            %% Stream finished — return immediately, drop remainder
            {<<>>, lists:reverse([done | Acc])};
        <<"data: ", Json/binary>> ->
            Event = parse_delta(Json),
            parse_lines(Rest, [Event | Acc]);
        _ ->
            %% Empty lines or comment lines — skip
            parse_lines(Rest, Acc)
    end.

%% ---------------------------------------------------------------------------
%% JSON delta parser — extracts "content" field without a JSON library.
%% The SSE payload structure is predictable:
%%   {"choices":[{"delta":{"content":"text"}}]}
%% ---------------------------------------------------------------------------

parse_delta(Json) ->
    case extract_json_string_field(Json, <<"\"content\"">>) of
        {ok, Content} -> {delta, Content};
        error ->
            %% Check for reasoning_content (GLM-5.1 sends this during "thinking" phase)
            case extract_json_string_field(Json, <<"\"reasoning_content\"">>) of
                {ok, _Reasoning} -> {reasoning, thinking};
                error ->
                    case binary:match(Json, <<"\"tool_calls\"">>) of
                        nomatch -> {delta, <<>>};
                        _ -> {tool_calls, Json}
                    end
            end
    end.

extract_json_string_field(Json, FieldName) ->
    case binary:match(Json, FieldName) of
        nomatch -> error;
        {Pos, Len} ->
            After = binary:part(Json, Pos + Len,
                                byte_size(Json) - Pos - Len),
            After2 = skip_ws_colon(After),
            case After2 of
                <<"null", _/binary>> -> error;
                <<"\"", Rest/binary>> -> extract_json_string(Rest, <<>>);
                _ -> error
            end
    end.

skip_ws_colon(<<" ", Rest/binary>>)  -> skip_ws_colon(Rest);
skip_ws_colon(<<":", Rest/binary>>)  -> skip_ws_colon(Rest);
skip_ws_colon(<<"\t", Rest/binary>>) -> skip_ws_colon(Rest);
skip_ws_colon(Other)                 -> Other.

extract_json_string(<<"\\\"", Rest/binary>>, Acc) ->
    extract_json_string(Rest, <<Acc/binary, "\"">>);
extract_json_string(<<"\\n", Rest/binary>>, Acc) ->
    extract_json_string(Rest, <<Acc/binary, "\n">>);
extract_json_string(<<"\\r", Rest/binary>>, Acc) ->
    extract_json_string(Rest, <<Acc/binary, "\r">>);
extract_json_string(<<"\\t", Rest/binary>>, Acc) ->
    extract_json_string(Rest, <<Acc/binary, "\t">>);
extract_json_string(<<"\\\\", Rest/binary>>, Acc) ->
    extract_json_string(Rest, <<Acc/binary, "\\">>);
extract_json_string(<<"\\/", Rest/binary>>, Acc) ->
    extract_json_string(Rest, <<Acc/binary, "/">>);
extract_json_string(<<"\\u", A, B, C, D, Rest/binary>>, Acc) ->
    %% Pass through unicode escapes as-is for safety
    extract_json_string(Rest, <<Acc/binary, "\\u", A, B, C, D>>);
extract_json_string(<<"\"", _/binary>>, Acc) ->
    {ok, Acc};
extract_json_string(<<C, Rest/binary>>, Acc) ->
    extract_json_string(Rest, <<Acc/binary, C>>);
extract_json_string(<<>>, _Acc) ->
    error.

%% ---------------------------------------------------------------------------
%% receive_stream_message/1 — Receive a stream event from the mailbox.
%% Returns a tagged binary tuple so Gleam can pattern match on it without
%% needing atom support.
%%   {<<"delta">>, ContentBinary}
%%   {<<"done">>,  <<>>}
%%   {<<"error">>, ReasonBinary}
%%   {<<"timeout">>, <<>>}
%% ---------------------------------------------------------------------------

receive_stream_message(TimeoutMs) ->
    receive
        {stream_delta, Delta} -> {<<"delta">>, Delta};
        stream_reasoning      -> {<<"reasoning">>, <<>>};
        stream_done           -> {<<"done">>, <<>>};
        {stream_error, Err}   -> {<<"error">>, Err}
    after TimeoutMs ->
        {<<"timeout">>, <<>>}
    end.
