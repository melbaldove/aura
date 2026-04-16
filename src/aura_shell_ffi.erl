-module(aura_shell_ffi).
-export([run_shell/3, normalize_command/1]).

%% Execute a shell command via /bin/sh -c, capturing stdout+stderr.
%% Returns {ok, {ExitCode, Output}} | {error, Reason}.
run_shell(Command, TimeoutMs, Cwd) ->
    try
        CmdStr = binary_to_list(Command),
        CwdStr = binary_to_list(Cwd),
        PortOpts = [
            {args, ["-c", CmdStr]},
            {cd, CwdStr},
            exit_status,
            binary,
            stderr_to_stdout,
            {env, [{"PATH", os:getenv("PATH")},
                   {"HOME", os:getenv("HOME")},
                   {"TERM", "dumb"}]}
        ],
        Port = open_port({spawn_executable, "/bin/sh"}, PortOpts),
        collect_output(Port, <<>>, TimeoutMs)
    catch
        _:Reason ->
            {error, list_to_binary(io_lib:format("~p", [Reason]))}
    end.

%% Pre-compiled ANSI escape regex, cached via persistent_term.
ansi_re() ->
    case persistent_term:get(aura_ansi_re, undefined) of
        undefined ->
            {ok, Re} = re:compile(<<"\\e\\[[0-9;]*[a-zA-Z]">>),
            persistent_term:put(aura_ansi_re, Re),
            Re;
        Re -> Re
    end.

collect_output(Port, Acc, TimeoutMs) ->
    receive
        {Port, {data, Data}} ->
            collect_output(Port, <<Acc/binary, Data/binary>>, TimeoutMs);
        {Port, {exit_status, Status}} ->
            {ok, {Status, Acc}}
    after TimeoutMs ->
        port_close(Port),
        {error, <<"timeout">>}
    end.

%% Normalize a command for security scanning:
%% 1. Strip ANSI escape sequences
%% 2. Remove null bytes
%% 3. Unicode NFKC normalization
normalize_command(Command) when is_binary(Command) ->
    AnsiRe = ansi_re(),
    NoAnsi = re:replace(Command, AnsiRe, <<>>, [global, {return, binary}]),
    %% Remove null bytes
    NoNull = binary:replace(NoAnsi, <<0>>, <<>>, [global]),
    %% NFKC normalization (collapses fullwidth Latin, etc.)
    case unicode:characters_to_nfkc_binary(NoNull) of
        Result when is_binary(Result) -> Result;
        _ -> NoNull
    end.
