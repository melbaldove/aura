-module(aura_browser_ffi).
-export([run/5, url_has_secret/1]).

%% Hard cap on output captured from a single command. Prevents OOM when
%% agent-browser returns a huge snapshot of a big page.
-define(MAX_OUTPUT_BYTES, 10 * 1024 * 1024).

%% Pre-compiled secret-in-URL regex, cached via persistent_term.
secret_re() ->
    case persistent_term:get(aura_browser_secret_re, undefined) of
        undefined ->
            {ok, Re} = re:compile(
                <<"(sk-ant-|sk-proj-|sk-[a-zA-Z0-9]{20,}|ghp_|ghu_|gho_|github_pat_|AKIA[0-9A-Z]{16})">>
            ),
            persistent_term:put(aura_browser_secret_re, Re),
            Re;
        Re -> Re
    end.

%% Check if a URL contains a recognizable API key or token. Tests the raw
%% URL and its percent-decoded form to catch encoding tricks.
url_has_secret(Url) when is_binary(Url) ->
    Re = secret_re(),
    Decoded = case catch uri_string:percent_decode(Url) of
        D when is_binary(D) -> D;
        _ -> Url
    end,
    case re:run(Url, Re) of
        {match, _} -> true;
        nomatch ->
            case re:run(Decoded, Re) of
                {match, _} -> true;
                nomatch -> false
            end
    end.

%% Invoke `npx agent-browser <backend-flag> --json <action> [args...]`.
%% Session is either a local session name (used with --session) or ignored
%% when CdpUrl is non-empty (used with --cdp).
%% Returns {ok, Output} | {error, Reason}.
run(Session, CdpUrl, Action, Args, TimeoutMs) ->
    try
        SessionStr = binary_to_list(Session),
        CdpStr = binary_to_list(CdpUrl),
        ActionStr = binary_to_list(Action),
        ArgsList = [binary_to_list(A) || A <- Args],
        %% --session isolates the daemon; --session-name persists cookies +
        %% localStorage across daemon restarts (deploys, reboots). Both use
        %% the same name. --session-name does not apply to CDP-attached
        %% browsers — the attached browser manages its own state.
        BackendFlag = case CdpStr of
            "" -> ["--session", SessionStr, "--session-name", SessionStr];
            Url -> ["--cdp", Url]
        end,
        SocketDir = filename:join(
            "/tmp",
            "aura-browser-" ++ SessionStr
        ),
        ok = filelib:ensure_dir(SocketDir ++ "/"),
        case file:make_dir(SocketDir) of
            ok -> ok;
            {error, eexist} -> ok;
            {error, MakeErr} -> throw({socket_dir_failed, MakeErr})
        end,
        CmdArgs = ["agent-browser" | BackendFlag]
            ++ ["--json", ActionStr | ArgsList],
        Npx = case os:find_executable("npx") of
            false -> throw(npx_not_found);
            Path -> Path
        end,
        BrowserEnv = [
            {"PATH", os:getenv("PATH")},
            {"HOME", os:getenv("HOME")},
            {"AGENT_BROWSER_SOCKET_DIR", SocketDir}
        ],
        PortOpts = [
            {args, CmdArgs},
            {env, BrowserEnv},
            exit_status,
            binary,
            stderr_to_stdout
        ],
        Port = open_port({spawn_executable, Npx}, PortOpts),
        collect_output(Port, <<>>, TimeoutMs)
    catch
        throw:npx_not_found ->
            {error, <<"npx not found on PATH. Install Node.js.">>};
        throw:{socket_dir_failed, Err} ->
            {error, list_to_binary(io_lib:format("socket_dir_failed: ~p", [Err]))};
        _:Reason ->
            {error, list_to_binary(io_lib:format("~p", [Reason]))}
    end.

collect_output(Port, Acc, TimeoutMs) ->
    receive
        {Port, {data, Data}} ->
            NewAcc = <<Acc/binary, Data/binary>>,
            case byte_size(NewAcc) > ?MAX_OUTPUT_BYTES of
                true ->
                    port_close(Port),
                    {error, <<"agent-browser output exceeded size cap">>};
                false ->
                    collect_output(Port, NewAcc, TimeoutMs)
            end;
        {Port, {exit_status, 0}} ->
            {ok, Acc};
        {Port, {exit_status, Status}} ->
            {error, list_to_binary(
                io_lib:format("agent-browser exited with status ~p: ~s",
                              [Status, Acc])
            )}
    after TimeoutMs ->
        port_close(Port),
        {error, <<"timeout">>}
    end.
