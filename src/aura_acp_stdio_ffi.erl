-module(aura_acp_stdio_ffi).
-export([start_session/4, send_input/3, close_session/1, receive_event/1,
         poll_snapshot_request/0]).

%% Exported for testing — pure functions only
-export([jsx_encode/1, json_escape/1, extract_field/2, extract_session_id/1,
         parse_jsonrpc_id/1, is_error_response/1]).

%% start_session/4 — Spawn a session owner process that:
%%   1. Opens the child process port (owns it)
%%   2. Runs the initialize + session/new + session/prompt handshake
%%   3. Enters the event loop, forwarding events to EventPid
%%   4. Accepts {send_input, SessionId, Text} messages for subsequent prompts
%%   5. Accepts close message to shut down
%%
%% Returns {ok, {OwnerPid, SessionId}} or {error, Reason} synchronously
%% by waiting for the handshake result.
%%
%% Protocol reference: https://agentclientprotocol.dev
%% Wire format: JSON-RPC 2.0 over newline-delimited JSON (NDJSON) on stdio
start_session(Command, Cwd, Prompt, EventPid) ->
    Self = self(),
    OwnerPid = spawn_link(fun() ->
        session_init(binary_to_list(Command), Cwd, Prompt, EventPid, Self)
    end),
    %% Wait for handshake result from the owner process
    receive
        {handshake_ok, OwnerPid, SessionId} ->
            {ok, {OwnerPid, SessionId}};
        {handshake_error, OwnerPid, Reason} ->
            {error, Reason}
    after 30000 ->
        exit(OwnerPid, kill),
        {error, <<"Handshake timeout">>}
    end.

%% Send input to a running session (subsequent prompt).
send_input(OwnerPid, SessionId, Text) ->
    try
        OwnerPid ! {send_input, SessionId, Text},
        {ok, nil}
    catch
        _:Reason ->
            {error, iolist_to_binary(io_lib:format("~p", [Reason]))}
    end.

%% Close the session.
close_session(OwnerPid) ->
    try
        OwnerPid ! close,
        nil
    catch
        _:_ -> nil
    end.

%% Receive an event from the session owner (called from EventPid's mailbox).
receive_event(TimeoutMs) ->
    receive
        {stdio_event, Type, Data} -> {<<"event">>, Type, Data};
        {stdio_complete, StopReason} -> {<<"complete">>, StopReason, <<>>};
        {stdio_exit, Code} -> {<<"exit">>, integer_to_binary(Code), <<>>};
        {stdio_error, Reason} -> {<<"error">>, Reason, <<>>}
    after TimeoutMs ->
        {<<"timeout">>, <<>>, <<>>}
    end.

%% Non-blocking poll for a snapshot request from the monitor.
%% Returns {ok, ReplySubject} if a request is waiting, or {error, nil} if not.
poll_snapshot_request() ->
    receive
        {snapshot_request, ReplySubject} -> {ok, ReplySubject}
    after 0 ->
        {error, nil}
    end.

%% ---------------------------------------------------------------------------
%% Internal: session owner process
%% ---------------------------------------------------------------------------

session_init(CommandStr, Cwd, Prompt, EventPid, CallerPid) ->
    Port = open_port({spawn, CommandStr}, [
        binary,
        {line, 65536},
        use_stdio,
        exit_status,
        stderr_to_stdout
    ]),
    %% Step 1: Initialize
    %% Spec: params = {protocolVersion, clientCapabilities, clientInfo}
    send_jsonrpc(Port, 0, <<"initialize">>, #{
        <<"protocolVersion">> => 1,
        <<"clientCapabilities">> => #{},
        <<"clientInfo">> => #{
            <<"name">> => <<"aura">>,
            <<"title">> => <<"A.U.R.A.">>,
            <<"version">> => <<"0.1.0">>
        }
    }),
    case wait_response(Port, 0, EventPid, 10000) of
        {error, Reason} ->
            port_close(Port),
            CallerPid ! {handshake_error, self(), Reason};
        {ok, _} ->
            %% Step 2: session/new
            %% Spec: params = {cwd (required), mcpServers (required, can be [])}
            %% Response: result = {sessionId}
            send_jsonrpc(Port, 1, <<"session/new">>, #{
                <<"cwd">> => Cwd,
                <<"mcpServers">> => []
            }),
            case wait_response(Port, 1, EventPid, 10000) of
                {error, Reason2} ->
                    port_close(Port),
                    CallerPid ! {handshake_error, self(), Reason2};
                {ok, SessionResponse} ->
                    SessionId = extract_session_id(SessionResponse),
                    case SessionId of
                        <<"unknown">> ->
                            io:format("[acp-stdio] session/new returned no sessionId: ~s~n",
                                      [binary:part(SessionResponse, 0, min(500, byte_size(SessionResponse)))]),
                            port_close(Port),
                            CallerPid ! {handshake_error, self(), <<"No sessionId in session/new response">>};
                        _ ->
                            %% Step 3: session/prompt
                            %% Spec: params = {sessionId, prompt: [ContentBlock]}
                            send_jsonrpc(Port, 2, <<"session/prompt">>, #{
                                <<"sessionId">> => SessionId,
                                <<"prompt">> => [#{
                                    <<"type">> => <<"text">>,
                                    <<"text">> => Prompt
                                }]
                            }),
                            %% Handshake complete — notify caller
                            CallerPid ! {handshake_ok, self(), SessionId},
                            %% Enter the event loop (prompt response + events arrive here)
                            NextId = 3,
                            session_loop(Port, SessionId, EventPid, NextId)
                    end
            end
    end.

%% The main session loop: reads port data, handles send_input/close commands.
session_loop(Port, SessionId, EventPid, NextId) ->
    receive
        %% Port data
        {Port, {data, {eol, Line}}} ->
            CleanLine = binary:replace(Line, <<"\r">>, <<>>),
            handle_line(CleanLine, EventPid),
            session_loop(Port, SessionId, EventPid, NextId);
        {Port, {data, {noeol, _}}} ->
            session_loop(Port, SessionId, EventPid, NextId);
        {Port, {exit_status, Code}} ->
            EventPid ! {stdio_exit, Code};
        {'EXIT', Port, Reason} ->
            EventPid ! {stdio_error, iolist_to_binary(io_lib:format("~p", [Reason]))};

        %% Commands
        {send_input, SessId, Text} ->
            send_jsonrpc(Port, NextId, <<"session/prompt">>, #{
                <<"sessionId">> => SessId,
                <<"prompt">> => [#{
                    <<"type">> => <<"text">>,
                    <<"text">> => Text
                }]
            }),
            session_loop(Port, SessionId, EventPid, NextId + 1);
        close ->
            %% Spec: session/cancel notification
            send_notification(Port, <<"session/cancel">>, #{
                <<"sessionId">> => SessionId
            }),
            try port_close(Port) catch _:_ -> ok end
    end.

%% Wait for a JSON-RPC response with a specific id.
%% Forwards any notifications received while waiting to EventPid.
%% Returns {error, Reason} for JSON-RPC error responses.
wait_response(Port, ExpectedId, EventPid, TimeoutMs) ->
    receive
        {Port, {data, {eol, Line}}} ->
            CleanLine = binary:replace(Line, <<"\r">>, <<>>),
            case parse_jsonrpc_id(CleanLine) of
                {ok, Id} when Id == ExpectedId ->
                    %% Check if this is an error response
                    case is_error_response(CleanLine) of
                        {true, ErrMsg} -> {error, ErrMsg};
                        {false, _} -> {ok, CleanLine}
                    end;
                {ok, _OtherId} ->
                    %% Response for a different request — skip
                    wait_response(Port, ExpectedId, EventPid, TimeoutMs);
                notification ->
                    %% Forward notification events
                    handle_line(CleanLine, EventPid),
                    wait_response(Port, ExpectedId, EventPid, TimeoutMs);
                _Other ->
                    wait_response(Port, ExpectedId, EventPid, TimeoutMs)
            end;
        {Port, {data, {noeol, _}}} ->
            wait_response(Port, ExpectedId, EventPid, TimeoutMs);
        {Port, {exit_status, Code}} ->
            {error, iolist_to_binary(io_lib:format("Process exited with code ~p during handshake", [Code]))};
        {'EXIT', Port, Reason} ->
            {error, iolist_to_binary(io_lib:format("Port crashed: ~p", [Reason]))}
    after TimeoutMs ->
        {error, <<"Timeout waiting for response">>}
    end.

%% Parse a JSON-RPC line and forward as an event if it's a notification.
%% Spec: session/update notifications have params.update.sessionUpdate as discriminator.
%% Event types: agent_message_chunk, tool_call, tool_call_update, plan, etc.
%% Content for text chunks: params.update.content.text
handle_line(Line, EventPid) ->
    case binary:match(Line, <<"\"method\":\"session/update\"">>) of
        {_, _} ->
            EventType = extract_field(Line, <<"\"sessionUpdate\":\"">>),
            %% For text content, we need the "text" value inside the "content" object,
            %% not the "type":"text" discriminator. Use the pattern that follows "text":"
            %% after "content":{ to avoid matching "type":"text".
            Content = extract_content_text(Line),
            EventPid ! {stdio_event, EventType, Content};
        nomatch ->
            %% Check for stopReason (prompt response)
            %% Spec: result = {stopReason: "end_turn"|"max_tokens"|"cancelled"|...}
            case binary:match(Line, <<"\"stopReason\"">>) of
                {_, _} ->
                    StopReason = extract_field(Line, <<"\"stopReason\":\"">>),
                    EventPid ! {stdio_complete, StopReason};
                nomatch ->
                    ok
            end
    end.

%% ---------------------------------------------------------------------------
%% JSON helpers (lightweight — no JSON parser dependency)
%% ---------------------------------------------------------------------------

send_jsonrpc(Port, Id, Method, Params) ->
    ParamsJson = jsx_encode(Params),
    Msg = iolist_to_binary([
        <<"{\"jsonrpc\":\"2.0\",\"id\":">>,
        integer_to_binary(Id),
        <<",\"method\":\"">>, Method,
        <<"\",\"params\":">>, ParamsJson,
        <<"}">>
    ]),
    port_command(Port, [Msg, <<"\n">>]).

send_notification(Port, Method, Params) ->
    ParamsJson = jsx_encode(Params),
    Msg = iolist_to_binary([
        <<"{\"jsonrpc\":\"2.0\",\"method\":\"">>, Method,
        <<"\",\"params\":">>, ParamsJson,
        <<"}">>
    ]),
    port_command(Port, [Msg, <<"\n">>]).

%% Minimal JSON encoder for maps, lists, binaries, integers, atoms.
jsx_encode(Map) when is_map(Map) ->
    Pairs = maps:fold(fun(K, V, Acc) ->
        Key = if is_binary(K) -> K; is_atom(K) -> atom_to_binary(K) end,
        Pair = iolist_to_binary([<<"\"">>, json_escape(Key), <<"\":">>, jsx_encode(V)]),
        [Pair | Acc]
    end, [], Map),
    iolist_to_binary([<<"{">>, lists:join(<<",">>, lists:reverse(Pairs)), <<"}">>]);
jsx_encode(List) when is_list(List) ->
    Items = [jsx_encode(I) || I <- List],
    iolist_to_binary([<<"[">>, lists:join(<<",">>, Items), <<"]">>]);
jsx_encode(Bin) when is_binary(Bin) ->
    iolist_to_binary([<<"\"">>, json_escape(Bin), <<"\"">>]);
jsx_encode(Int) when is_integer(Int) ->
    integer_to_binary(Int);
jsx_encode(true) -> <<"true">>;
jsx_encode(false) -> <<"false">>;
jsx_encode(null) -> <<"null">>;
jsx_encode(nil) -> <<"null">>.

json_escape(Bin) ->
    json_escape(Bin, <<>>).
json_escape(<<>>, Acc) -> Acc;
json_escape(<<"\\", R/binary>>, Acc) -> json_escape(R, <<Acc/binary, "\\\\">>);
json_escape(<<"\"", R/binary>>, Acc) -> json_escape(R, <<Acc/binary, "\\\"">>);
json_escape(<<"\n", R/binary>>, Acc) -> json_escape(R, <<Acc/binary, "\\n">>);
json_escape(<<"\r", R/binary>>, Acc) -> json_escape(R, <<Acc/binary, "\\r">>);
json_escape(<<"\t", R/binary>>, Acc) -> json_escape(R, <<Acc/binary, "\\t">>);
json_escape(<<C, R/binary>>, Acc) -> json_escape(R, <<Acc/binary, C>>).

%% Extract the "id" from a JSON-RPC message.
parse_jsonrpc_id(Line) ->
    case binary:match(Line, <<"\"id\":">>) of
        {Pos, Len} ->
            After = binary:part(Line, Pos + Len, byte_size(Line) - Pos - Len),
            After2 = skip_ws(After),
            case After2 of
                <<"null", _/binary>> -> notification;
                _ -> extract_int(After2)
            end;
        nomatch ->
            notification
    end.

extract_int(<<D, Rest/binary>>) when D >= $0, D =< $9 ->
    extract_int(Rest, <<D>>);
extract_int(_) -> other.
extract_int(<<D, Rest/binary>>, Acc) when D >= $0, D =< $9 ->
    extract_int(Rest, <<Acc/binary, D>>);
extract_int(_, Acc) ->
    {ok, binary_to_integer(Acc)}.

skip_ws(<<" ", R/binary>>) -> skip_ws(R);
skip_ws(<<"\t", R/binary>>) -> skip_ws(R);
skip_ws(Other) -> Other.

%% Check if a JSON-RPC response contains an error.
%% Spec: error responses have {"error":{"code":N,"message":"...",...}}
is_error_response(Line) ->
    case binary:match(Line, <<"\"error\":{">>) of
        {_, _} ->
            Msg = extract_field(Line, <<"\"message\":\"">>),
            Details = extract_field(Line, <<"\"details\":\"">>),
            case {Msg, Details} of
                {<<>>, <<>>} -> {true, <<"Unknown JSON-RPC error">>};
                {M, <<>>} -> {true, M};
                {M, D} -> {true, iolist_to_binary([M, <<": ">>, D])}
            end;
        nomatch ->
            {false, <<>>}
    end.

%% Extract a string field value after a marker like <<"\"stopReason\":\"">>.
extract_field(Line, Marker) ->
    case binary:match(Line, Marker) of
        {Pos, Len} ->
            After = binary:part(Line, Pos + Len, byte_size(Line) - Pos - Len),
            extract_until_quote(After, <<>>);
        nomatch ->
            <<>>
    end.

extract_until_quote(<<"\\\"", R/binary>>, Acc) ->
    extract_until_quote(R, <<Acc/binary, "\"">>);
extract_until_quote(<<"\"", _/binary>>, Acc) -> Acc;
extract_until_quote(<<C, R/binary>>, Acc) ->
    extract_until_quote(R, <<Acc/binary, C>>);
extract_until_quote(<<>>, Acc) -> Acc.

%% Extract text content from a session/update notification.
%% The update structure is: params.update.content.text
%% We must match "text":" that appears AFTER "content":{ to avoid
%% matching the "type":"text" discriminator.
%% Spec: {"params":{"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"..."}}}}
extract_content_text(Line) ->
    %% Find the content object, then find "text":" within it
    case binary:match(Line, <<"\"content\":{">>) of
        {Pos, Len} ->
            AfterContent = binary:part(Line, Pos + Len, byte_size(Line) - Pos - Len),
            %% Now search for "text":" within the content object
            extract_field(AfterContent, <<"\"text\":\"">>);
        nomatch ->
            %% Some update types (tool_call, plan) have different content structures.
            %% For tool_call, try to extract the title as content.
            case binary:match(Line, <<"\"title\":\"">>) of
                {TPos, TLen} ->
                    After = binary:part(Line, TPos + TLen, byte_size(Line) - TPos - TLen),
                    extract_until_quote(After, <<>>);
                nomatch ->
                    <<>>
            end
    end.

extract_session_id(Line) ->
    case extract_field(Line, <<"\"sessionId\":\"">>) of
        <<>> -> <<"unknown">>;
        Id -> Id
    end.
