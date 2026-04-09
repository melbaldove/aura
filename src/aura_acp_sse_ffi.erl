-module(aura_acp_sse_ffi).
-export([subscribe/3, receive_sse_event/1]).

%% subscribe/3 — Connect to an SSE endpoint and stream events to CallbackPid.
%% Sends to CallbackPid:
%%   {sse_event, EventType, Data}  — parsed SSE event
%%   {sse_error, Reason}           — connection error
%%   sse_done                      — stream ended
subscribe(Url, Headers, CallbackPid) ->
    ssl:start(),
    inets:start(),
    UrlStr = binary_to_list(Url),
    HeaderList = lists:map(fun({K, V}) ->
        {binary_to_list(K), binary_to_list(V)}
    end, Headers),
    FullHeaders = [{"accept", "text/event-stream"} | HeaderList],
    case httpc:request(get,
                       {UrlStr, FullHeaders},
                       [{timeout, infinity}],
                       [{sync, false}, {stream, self}]) of
        {ok, RequestId} ->
            try
                sse_loop(RequestId, CallbackPid, <<>>, <<>>, <<>>)
            catch
                _:Reason ->
                    httpc:cancel_request(RequestId),
                    CallbackPid ! {sse_error, iolist_to_binary(io_lib:format("~p", [Reason]))}
            end,
            nil;
        {error, Reason} ->
            CallbackPid ! {sse_error, iolist_to_binary(io_lib:format("~p", [Reason]))},
            nil
    end.

sse_loop(RequestId, CallbackPid, Buffer, CurrentEvent, CurrentData) ->
    receive
        {http, {RequestId, stream_start, _Headers}} ->
            sse_loop(RequestId, CallbackPid, Buffer, CurrentEvent, CurrentData);

        {http, {RequestId, stream, BinPart}} ->
            NewBuffer = <<Buffer/binary, BinPart/binary>>,
            {Remainder, NewEvent, NewData} =
                parse_sse_buffer(NewBuffer, CurrentEvent, CurrentData, CallbackPid),
            sse_loop(RequestId, CallbackPid, Remainder, NewEvent, NewData);

        {http, {RequestId, stream_end, _Headers}} ->
            %% Flush any pending event
            case CurrentData of
                <<>> -> ok;
                _ -> CallbackPid ! {sse_event, CurrentEvent, CurrentData}
            end,
            CallbackPid ! sse_done;

        {http, {RequestId, {error, Reason}}} ->
            CallbackPid ! {sse_error, iolist_to_binary(io_lib:format("~p", [Reason]))}

    after 300000 ->
        %% 5 minute timeout — connection may have died silently
        httpc:cancel_request(RequestId),
        CallbackPid ! {sse_error, <<"SSE connection timeout">>}
    end.

%% Parse SSE lines from buffer.
%% SSE format: "event: type\ndata: json\n\n"
parse_sse_buffer(Buffer, Event, Data, Pid) ->
    case binary:split(Buffer, <<"\n">>) of
        [Buffer] ->
            %% No complete line yet
            {Buffer, Event, Data};
        [RawLine, Rest] ->
            %% Strip \r if present (SSE spec allows \r\n line endings)
            Line = binary:replace(RawLine, <<"\r">>, <<>>),
            case Line of
                <<"event: ", EventType/binary>> ->
                    parse_sse_buffer(Rest, string:trim(EventType), Data, Pid);
                <<"data: ", EventData/binary>> ->
                    parse_sse_buffer(Rest, Event, EventData, Pid);
                <<>> ->
                    %% Empty line = end of event
                    case Data of
                        <<>> -> parse_sse_buffer(Rest, <<>>, <<>>, Pid);
                        _ ->
                            Pid ! {sse_event, Event, Data},
                            parse_sse_buffer(Rest, <<>>, <<>>, Pid)
                    end;
                _ ->
                    %% Ignore other lines (comments starting with :, etc)
                    parse_sse_buffer(Rest, Event, Data, Pid)
            end
    end.

%% receive_sse_event/1 — Receive an SSE event from the mailbox.
receive_sse_event(TimeoutMs) ->
    receive
        {sse_event, EventType, Data} -> {<<"event">>, EventType, Data};
        {sse_error, Err}             -> {<<"error">>, Err, <<>>};
        sse_done                     -> {<<"done">>, <<>>, <<>>}
    after TimeoutMs ->
        {<<"timeout">>, <<>>, <<>>}
    end.
