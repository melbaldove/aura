#!/usr/bin/env escript
%% -*- erlang -*-
%% fake_mcp_server.escript — a deterministic, script-driven fake MCP server
%% for `test/aura/mcp/client_test.gleam`.
%%
%% Why an escript (not Python or a Gleam binary)?
%%   - Python isn't in the project's dev environment on the Nix machines we
%%     run tests on.
%%   - A Gleam binary would require a separate build target + entrypoint;
%%     for a single test fixture the compile/invocation overhead isn't worth it.
%%   - escript runs anywhere the BEAM runs, which is exactly where our tests
%%     live. No new dependency.
%%
%% Usage:
%%   fake_mcp_server.escript <script_path>
%%
%% Script file format (one step per line; blank lines + leading `#` are ignored):
%%
%%   EXPECT_REQUEST <method>
%%     — wait for the next line on stdin, assert its method matches, remember
%%       its id for the next RESPOND_*.
%%   EXPECT_NOTIFICATION <method>
%%     — wait for the next line on stdin, assert its method matches and it has
%%       no id. No id is remembered.
%%   RESPOND_RESULT <result_json>
%%     — send a JSON-RPC success response with the remembered id and the given
%%       raw JSON as the "result" field.
%%   RESPOND_ERROR <code> <message>
%%     — send a JSON-RPC error response with the remembered id.
%%   EMIT_NOTIFICATION <method> <params_json>
%%     — send a server-initiated notification.
%%   EMIT_RAW <raw_text>
%%     — send a raw line (not JSON). For malformed-JSON tests.
%%   EXIT
%%     — exit 0 immediately.
%%   EXIT_WITH_CODE <N>
%%     — exit N immediately. For asserting the client's abnormal-stop path.
%%
%% On success (script exhausted), exits 0.
%% On mismatch (wrong method, unexpected id, stdin EOF), writes to stderr and
%% exits 1 — this causes the client to see a subprocess exit and fail, which
%% is itself a useful signal for tests.

main([ScriptPath]) ->
    {ok, Lines} = read_script(ScriptPath),
    loop(Lines, undefined, ScriptPath),
    halt(0);
main(_) ->
    io:format(standard_error, "usage: fake_mcp_server.escript <script>~n", []),
    halt(2).

read_script(Path) ->
    {ok, Bin} = file:read_file(Path),
    Raw = binary:split(Bin, <<"\n">>, [global]),
    Cleaned =
        [L || L <- Raw,
              L =/= <<>>,
              not starts_with(L, <<"#">>)],
    {ok, Cleaned}.

starts_with(Bin, Prefix) ->
    PLen = byte_size(Prefix),
    byte_size(Bin) >= PLen andalso binary:part(Bin, 0, PLen) == Prefix.

loop([], _LastId, _ScriptPath) ->
    ok;
loop([Step | Rest], LastId, ScriptPath) ->
    case parse_step(Step) of
        {expect_request, Method} ->
            Line = read_stdin_line(),
            {ReqMethod, Id} = parse_incoming(Line),
            assert_eq(ReqMethod, Method, Line),
            loop(Rest, Id, ScriptPath);
        {expect_notification, Method} ->
            Line = read_stdin_line(),
            {NotifMethod, Id} = parse_incoming(Line),
            case Id of
                undefined -> ok;
                _ ->
                    fail("expected notification (no id) for method " ++
                         to_list(Method) ++ ", got line: " ++ to_list(Line))
            end,
            assert_eq(NotifMethod, Method, Line),
            maybe_mark_ready(NotifMethod, ScriptPath),
            loop(Rest, LastId, ScriptPath);
        {respond_result, ResultJson} ->
            emit_response(LastId, ResultJson),
            loop(Rest, LastId, ScriptPath);
        {respond_error, Code, Message} ->
            emit_error(LastId, Code, Message),
            loop(Rest, LastId, ScriptPath);
        {emit_notification, Method, ParamsJson} ->
            emit_notification(Method, ParamsJson),
            loop(Rest, LastId, ScriptPath);
        {emit_raw, Raw} ->
            io:put_chars([Raw, <<"\n">>]),
            loop(Rest, LastId, ScriptPath);
        exit_now ->
            halt(0);
        {exit_with_code, Code} ->
            halt(Code);
        skip ->
            loop(Rest, LastId, ScriptPath)
    end.

maybe_mark_ready(<<"notifications/initialized">>, ScriptPath) ->
    %% Test-only readiness sentinel. The Gleam tests use this to avoid fixed
    %% sleeps before issuing the first tools/call.
    file:write_file(ScriptPath ++ ".ready", <<"ready\n">>);
maybe_mark_ready(_, _) ->
    ok.

parse_step(<<"EXPECT_REQUEST ", Rest/binary>>) ->
    {expect_request, trim(Rest)};
parse_step(<<"EXPECT_NOTIFICATION ", Rest/binary>>) ->
    {expect_notification, trim(Rest)};
parse_step(<<"RESPOND_RESULT ", Rest/binary>>) ->
    {respond_result, Rest};
parse_step(<<"RESPOND_ERROR ", Rest/binary>>) ->
    {Code, Msg} = split_first_space(Rest),
    {respond_error, binary_to_integer(Code), Msg};
parse_step(<<"EMIT_NOTIFICATION ", Rest/binary>>) ->
    {Method, Params} = split_first_space(Rest),
    {emit_notification, Method, Params};
parse_step(<<"EMIT_RAW ", Rest/binary>>) ->
    {emit_raw, Rest};
parse_step(<<"EXIT">>) ->
    exit_now;
parse_step(<<"EXIT_WITH_CODE ", Rest/binary>>) ->
    {exit_with_code, binary_to_integer(trim(Rest))};
parse_step(Other) ->
    fail("unrecognised script step: " ++ to_list(Other)).

split_first_space(Bin) ->
    case binary:split(Bin, <<" ">>) of
        [A, B] -> {A, B};
        [A] -> {A, <<>>}
    end.

trim(Bin) ->
    Bin1 = case byte_size(Bin) > 0 andalso binary:at(Bin, 0) == $\s of
        true -> binary:part(Bin, 1, byte_size(Bin) - 1);
        false -> Bin
    end,
    BLen = byte_size(Bin1),
    case BLen > 0 andalso binary:at(Bin1, BLen - 1) == $\s of
        true -> binary:part(Bin1, 0, BLen - 1);
        false -> Bin1
    end.

read_stdin_line() ->
    case io:get_line("") of
        eof ->
            fail("stdin closed while expecting input line");
        Line when is_list(Line) ->
            L = list_to_binary(Line),
            strip_newline(L);
        Line when is_binary(Line) ->
            strip_newline(Line)
    end.

strip_newline(Bin) ->
    Size = byte_size(Bin),
    case Size >= 1 andalso binary:at(Bin, Size - 1) == $\n of
        true ->
            Size1 = Size - 1,
            case Size1 >= 1 andalso binary:at(Bin, Size1 - 1) == $\r of
                true -> binary:part(Bin, 0, Size1 - 1);
                false -> binary:part(Bin, 0, Size1)
            end;
        false -> Bin
    end.

%% Returns {MethodBinary, IdOrUndefined}.
%% Uses light string matching, not a real JSON parser — tests send simple
%% well-formed JSON.
parse_incoming(Line) ->
    Method = extract_string_field(Line, <<"\"method\":\"">>),
    Id = case extract_int_after(Line, <<"\"id\":">>) of
        undefined -> undefined;
        N -> N
    end,
    {Method, Id}.

extract_string_field(Line, Marker) ->
    case binary:match(Line, Marker) of
        nomatch -> <<>>;
        {Pos, Len} ->
            After = binary:part(Line, Pos + Len, byte_size(Line) - Pos - Len),
            extract_until_quote(After, <<>>)
    end.

extract_until_quote(<<"\\\"", R/binary>>, Acc) ->
    extract_until_quote(R, <<Acc/binary, "\"">>);
extract_until_quote(<<"\"", _/binary>>, Acc) -> Acc;
extract_until_quote(<<C, R/binary>>, Acc) ->
    extract_until_quote(R, <<Acc/binary, C>>);
extract_until_quote(<<>>, Acc) -> Acc.

extract_int_after(Line, Marker) ->
    case binary:match(Line, Marker) of
        nomatch -> undefined;
        {Pos, Len} ->
            After = binary:part(Line, Pos + Len, byte_size(Line) - Pos - Len),
            extract_int(After, <<>>)
    end.

extract_int(<<D, Rest/binary>>, <<>>) when D >= $0, D =< $9 ->
    extract_int(Rest, <<D>>);
extract_int(<<D, Rest/binary>>, Acc) when D >= $0, D =< $9 ->
    extract_int(Rest, <<Acc/binary, D>>);
extract_int(_, <<>>) -> undefined;
extract_int(_, Acc) -> binary_to_integer(Acc).

emit_response(undefined, _) ->
    fail("RESPOND_RESULT with no preceding EXPECT_REQUEST");
emit_response(Id, ResultJson) ->
    Line = iolist_to_binary([
        <<"{\"jsonrpc\":\"2.0\",\"id\":">>,
        integer_to_binary(Id),
        <<",\"result\":">>, ResultJson,
        <<"}\n">>
    ]),
    io:put_chars(Line).

emit_error(undefined, _, _) ->
    fail("RESPOND_ERROR with no preceding EXPECT_REQUEST");
emit_error(Id, Code, Message) ->
    Line = iolist_to_binary([
        <<"{\"jsonrpc\":\"2.0\",\"id\":">>, integer_to_binary(Id),
        <<",\"error\":{\"code\":">>, integer_to_binary(Code),
        <<",\"message\":\"">>, json_escape(Message), <<"\"}}\n">>
    ]),
    io:put_chars(Line).

emit_notification(Method, ParamsJson) ->
    Line = iolist_to_binary([
        <<"{\"jsonrpc\":\"2.0\",\"method\":\"">>, Method,
        <<"\",\"params\":">>, ParamsJson, <<"}\n">>
    ]),
    io:put_chars(Line).

json_escape(Bin) ->
    json_escape(Bin, <<>>).
json_escape(<<>>, Acc) -> Acc;
json_escape(<<"\\", R/binary>>, Acc) -> json_escape(R, <<Acc/binary, "\\\\">>);
json_escape(<<"\"", R/binary>>, Acc) -> json_escape(R, <<Acc/binary, "\\\"">>);
json_escape(<<"\n", R/binary>>, Acc) -> json_escape(R, <<Acc/binary, "\\n">>);
json_escape(<<C, R/binary>>, Acc) -> json_escape(R, <<Acc/binary, C>>).

assert_eq(Got, Expected, _Line) when Got == Expected -> ok;
assert_eq(Got, Expected, Line) ->
    fail("method mismatch: expected=" ++ to_list(Expected) ++
         " got=" ++ to_list(Got) ++
         " line=" ++ to_list(Line)).

fail(Msg) ->
    io:format(standard_error, "[fake_mcp_server] ~s~n", [Msg]),
    halt(1).

to_list(B) when is_binary(B) -> binary_to_list(B);
to_list(L) when is_list(L) -> L;
to_list(X) -> io_lib:format("~p", [X]).
