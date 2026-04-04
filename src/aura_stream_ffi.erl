-module(aura_stream_ffi).
-export([chat_stream/5, receive_stream_message/1]).

%% ---------------------------------------------------------------------------
%% chat_stream/5 — Streaming HTTP POST to an OpenAI-compatible endpoint.
%% Handles both content deltas AND tool call deltas.
%%
%% Sends to CallbackPid:
%%   {stream_delta, ContentBinary}     — text content chunk (for progressive display)
%%   stream_reasoning                  — GLM-5.1 reasoning token (stream alive signal)
%%   {stream_complete, Content, ToolCallsJson}  — final result
%%   {stream_error, Binary}            — fatal error
%%
%% ToolCallsJson is "[]" if no tool calls, or a JSON array string like:
%%   [{"id":"call_1","name":"read_file","arguments":"{\"path\":\".\"}" }]
%% ---------------------------------------------------------------------------

chat_stream(Url, ApiKey, _Model, BodyJson, CallbackPid) ->
    %% Idempotent — no-op after first call. Called here to ensure
    %% availability regardless of startup order.
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
            %% State: {AccContent, ToolCalls}
            %% ToolCalls = #{Index => {Id, Name, ArgsAcc}}
            try
                stream_loop(RequestId, CallbackPid, <<>>, <<>>, #{})
            catch
                _:Reason ->
                    httpc:cancel_request(RequestId),
                    CallbackPid ! {stream_error, io_lib:format("~p", [Reason])}
            end,
            nil;
        {error, Reason} ->
            CallbackPid ! {stream_error,
                iolist_to_binary(io_lib:format("~p", [Reason]))},
            nil
    end.

stream_loop(RequestId, CallbackPid, Buffer, AccContent, ToolCalls) ->
    receive
        {http, {RequestId, stream_start, _Headers}} ->
            stream_loop(RequestId, CallbackPid, Buffer, AccContent, ToolCalls);

        {http, {RequestId, stream, BinBodyPart}} ->
            NewBuffer = <<Buffer/binary, BinBodyPart/binary>>,
            {Remainder, Events} = parse_sse_lines(NewBuffer),
            {NewContent, NewToolCalls, IsDone} =
                process_events(Events, AccContent, ToolCalls, CallbackPid),
            case IsDone of
                true ->
                    TcJson = tool_calls_to_json(NewToolCalls),
                    CallbackPid ! {stream_complete, NewContent, TcJson};
                false ->
                    stream_loop(RequestId, CallbackPid, Remainder,
                                NewContent, NewToolCalls)
            end;

        {http, {RequestId, stream_end, _Headers}} ->
            TcJson = tool_calls_to_json(ToolCalls),
            CallbackPid ! {stream_complete, AccContent, TcJson};

        {http, {RequestId, {error, Reason}}} ->
            Msg = iolist_to_binary(
                io_lib:format("Stream error: ~p", [Reason])),
            CallbackPid ! {stream_error, Msg}

    after 120000 ->
        CallbackPid ! {stream_error, <<"Stream timeout">>}
    end.

%% Process parsed SSE events, updating content and tool call accumulators
process_events([], Content, ToolCalls, _Pid) ->
    {Content, ToolCalls, false};
process_events([done | _], Content, ToolCalls, _Pid) ->
    {Content, ToolCalls, true};
process_events([Event | Rest], Content, ToolCalls, Pid) ->
    case Event of
        {delta, <<>>} ->
            process_events(Rest, Content, ToolCalls, Pid);
        {delta, Text} ->
            Pid ! {stream_delta, Text},
            process_events(Rest, <<Content/binary, Text/binary>>, ToolCalls, Pid);
        {reasoning, _} ->
            Pid ! stream_reasoning,
            process_events(Rest, Content, ToolCalls, Pid);
        {tool_call_delta, Index, Id, Name, Args} ->
            NewTC = update_tool_call(ToolCalls, Index, Id, Name, Args),
            process_events(Rest, Content, NewTC, Pid);
        _ ->
            process_events(Rest, Content, ToolCalls, Pid)
    end.

%% Update tool call accumulator. First delta for an index has id+name,
%% subsequent deltas append to arguments.
update_tool_call(ToolCalls, Index, Id, Name, Args) ->
    case maps:find(Index, ToolCalls) of
        {ok, {ExId, ExName, ExArgs}} ->
            NewId = case Id of <<>> -> ExId; _ -> Id end,
            NewName = case Name of <<>> -> ExName; _ -> Name end,
            NewArgs = <<ExArgs/binary, Args/binary>>,
            maps:put(Index, {NewId, NewName, NewArgs}, ToolCalls);
        error ->
            maps:put(Index, {Id, Name, Args}, ToolCalls)
    end.

%% Convert tool calls map to JSON array string
tool_calls_to_json(ToolCalls) when map_size(ToolCalls) == 0 ->
    <<"[]">>;
tool_calls_to_json(ToolCalls) ->
    Entries = lists:sort(maps:to_list(ToolCalls)),
    JsonItems = lists:map(fun({_Index, {Id, Name, Args}}) ->
        %% Escape the arguments string for embedding in JSON
        EscArgs = json_escape(Args),
        iolist_to_binary([
            <<"{\"id\":\"">>, Id,
            <<"\",\"name\":\"">>, Name,
            <<"\",\"arguments\":\"">>, EscArgs,
            <<"\"}">>
        ])
    end, Entries),
    iolist_to_binary([<<"[">>, lists:join(<<",">>, JsonItems), <<"]">>]).

json_escape(Bin) ->
    json_escape(Bin, <<>>).
json_escape(<<>>, Acc) ->
    Acc;
json_escape(<<"\\", Rest/binary>>, Acc) ->
    json_escape(Rest, <<Acc/binary, "\\\\">>);
json_escape(<<"\"", Rest/binary>>, Acc) ->
    json_escape(Rest, <<Acc/binary, "\\\"">>);
json_escape(<<"\n", Rest/binary>>, Acc) ->
    json_escape(Rest, <<Acc/binary, "\\n">>);
json_escape(<<"\r", Rest/binary>>, Acc) ->
    json_escape(Rest, <<Acc/binary, "\\r">>);
json_escape(<<"\t", Rest/binary>>, Acc) ->
    json_escape(Rest, <<Acc/binary, "\\t">>);
json_escape(<<C, Rest/binary>>, Acc) ->
    json_escape(Rest, <<Acc/binary, C>>).

%% ---------------------------------------------------------------------------
%% SSE line parser
%% ---------------------------------------------------------------------------

parse_sse_lines(Buffer) ->
    Lines = binary:split(Buffer, <<"\n">>, [global]),
    parse_lines(Lines, []).

parse_lines([], Acc) ->
    {<<>>, lists:reverse(Acc)};
parse_lines([Last], Acc) ->
    {Last, lists:reverse(Acc)};
parse_lines([Line | Rest], Acc) ->
    case Line of
        <<"data: [DONE]", _/binary>> ->
            {<<>>, lists:reverse([done | Acc])};
        <<"data: ", Json/binary>> ->
            Event = parse_delta(Json),
            parse_lines(Rest, [Event | Acc]);
        _ ->
            parse_lines(Rest, Acc)
    end.

%% ---------------------------------------------------------------------------
%% JSON delta parser — handles content, reasoning_content, and tool_calls
%% without requiring a JSON library.
%% ---------------------------------------------------------------------------

parse_delta(Json) ->
    %% Check for content first (most common)
    case extract_json_string_field(Json, <<"\"content\"">>) of
        {ok, Content} -> {delta, Content};
        error ->
            %% Check reasoning_content (GLM-5.1 thinking phase)
            case extract_json_string_field(Json, <<"\"reasoning_content\"">>) of
                {ok, _} -> {reasoning, thinking};
                error ->
                    %% Check tool_calls
                    case binary:match(Json, <<"\"tool_calls\"">>) of
                        nomatch -> {delta, <<>>};
                        _ -> parse_tool_call_delta(Json)
                    end
            end
    end.

%% Parse a streaming tool_call delta.
%% Format: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_x","function":{"name":"fn","arguments":"piece"}}]}}]}
parse_tool_call_delta(Json) ->
    Index = case extract_json_int_field(Json, <<"\"index\"">>) of
        {ok, I} -> I;
        error -> 0
    end,
    Id = case extract_json_string_field(Json, <<"\"id\"">>) of
        {ok, V} -> V;
        error -> <<>>
    end,
    Name = case extract_json_string_field(Json, <<"\"name\"">>) of
        {ok, N} -> N;
        error -> <<>>
    end,
    Args = case extract_json_string_field(Json, <<"\"arguments\"">>) of
        {ok, A} -> A;
        error -> <<>>
    end,
    {tool_call_delta, Index, Id, Name, Args}.

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

extract_json_int_field(Json, FieldName) ->
    case binary:match(Json, FieldName) of
        nomatch -> error;
        {Pos, Len} ->
            After = binary:part(Json, Pos + Len,
                                byte_size(Json) - Pos - Len),
            After2 = skip_ws_colon(After),
            extract_int(After2, <<>>)
    end.

extract_int(<<D, Rest/binary>>, Acc) when D >= $0, D =< $9 ->
    extract_int(Rest, <<Acc/binary, D>>);
extract_int(_, <<>>) ->
    error;
extract_int(_, Acc) ->
    {ok, binary_to_integer(Acc)}.

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
    extract_json_string(Rest, <<Acc/binary, "\\u", A, B, C, D>>);
extract_json_string(<<"\"", _/binary>>, Acc) ->
    {ok, Acc};
extract_json_string(<<C, Rest/binary>>, Acc) ->
    extract_json_string(Rest, <<Acc/binary, C>>);
extract_json_string(<<>>, _Acc) ->
    error.

%% ---------------------------------------------------------------------------
%% receive_stream_message/1 — Receive a stream event from the mailbox.
%% ---------------------------------------------------------------------------

receive_stream_message(TimeoutMs) ->
    receive
        {stream_delta, Delta}               -> {<<"delta">>, Delta, <<>>};
        stream_reasoning                    -> {<<"reasoning">>, <<>>, <<>>};
        {stream_complete, Content, TcJson}  -> {<<"complete">>, Content, TcJson};
        {stream_error, Err}                 -> {<<"error">>, Err, <<>>};
        stream_done                         -> {<<"done">>, <<>>, <<>>}
    after TimeoutMs ->
        {<<"timeout">>, <<>>, <<>>}
    end.
