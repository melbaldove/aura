-module(aura_mcp_stdio_ffi).
-export([start/4, send_line/2, close/1]).

%% ---------------------------------------------------------------------------
%% aura_mcp_stdio_ffi — subprocess + port management for MCP stdio transport.
%%
%% Spawns a child process, owns its Erlang port, reads newline-delimited JSON
%% lines from its stdout, and forwards each raw line to a receiver process as
%% {mcp_line, Handle, RawLine}. On subprocess exit, forwards
%% {mcp_exit, Handle, ExitStatus}.
%%
%% Wire format: JSON-RPC 2.0 over NDJSON on stdio.
%%
%% CRITICAL: port messages {Port, {data, _}} go to the process that called
%% open_port. That's why we spawn a dedicated owner process; the caller
%% (the Gleam mcp_client actor) receives parsed tuples, not port data.
%% Mirrors the pattern in aura_acp_stdio_ffi.erl.
%% ---------------------------------------------------------------------------

%% start/4 — spawn a subprocess and return an opaque handle.
%%
%% Command: charlist or binary, e.g. <<"/usr/bin/node">>.
%% Args: list of strings to pass as command-line arguments.
%% Env: list of {Key, Value} tuples (strings). Empty list means inherit.
%% ReceiverPid: where {mcp_line, Handle, RawLine} and {mcp_exit, Handle, Status}
%%              are delivered.
%%
%% Returns {ok, Handle} on successful spawn, {error, Reason} if spawn fails.
%% The Handle is the owner process pid — we use it to identify messages on the
%% receiver side and to send it commands (send_line, close).
start(Command, Args, Env, ReceiverPid) ->
    Caller = self(),
    OwnerPid = spawn_link(fun() ->
        owner_init(to_string(Command), normalize_args(Args),
                   normalize_env(Env), ReceiverPid, Caller)
    end),
    receive
        {owner_ready, OwnerPid} ->
            {ok, OwnerPid};
        {owner_error, OwnerPid, Reason} ->
            {error, Reason}
    after 5000 ->
        exit(OwnerPid, kill),
        {error, <<"MCP subprocess spawn timeout">>}
    end.

%% send_line/2 — send a JSON-RPC line to the subprocess via its owner.
%% The line should already be a complete JSON-RPC message; the owner appends
%% the newline.
send_line(OwnerPid, JsonLine) ->
    try
        OwnerPid ! {send_line, to_binary(JsonLine)},
        {ok, nil}
    catch
        _:Reason ->
            {error, iolist_to_binary(io_lib:format("~p", [Reason]))}
    end.

%% close/1 — ask the owner to close the port and exit.
close(OwnerPid) ->
    try
        OwnerPid ! close
    catch
        _:_ -> ok
    end,
    nil.

%% ---------------------------------------------------------------------------
%% Internal: owner process
%% ---------------------------------------------------------------------------

owner_init(CommandStr, ArgsList, EnvList, ReceiverPid, Caller) ->
    %% {spawn_executable, Path} requires an absolute or relative path — it
    %% doesn't consult $PATH. If the caller passed a bare name ("escript",
    %% "node"), resolve it with os:find_executable first so MCP configs can
    %% use whatever spelling makes sense for their command.
    case resolve_executable(CommandStr) of
        {error, not_found} ->
            Caller ! {owner_error, self(),
                      iolist_to_binary(["executable not found on PATH: ",
                                        CommandStr])};
        {ok, Resolved} ->
            PortSpec = {spawn_executable, Resolved},
            %% Do NOT include stderr_to_stdout: mixing stderr into stdout
            %% would inject non-JSON lines into the JSON-RPC wire and either
            %% kill the client during handshake or get silently dropped in
            %% Ready. Without it, stderr is inherited from the parent BEAM,
            %% so subprocess error output appears on the main Aura log —
            %% which is what we want for operator visibility.
            PortOpts = [
                binary,
                {line, 65536},
                use_stdio,
                exit_status,
                {args, ArgsList}
                | case EnvList of
                    [] -> [];
                    _ -> [{env, EnvList}]
                  end
            ],
            try open_port(PortSpec, PortOpts) of
                Port when is_port(Port) ->
                    Caller ! {owner_ready, self()},
                    Self = self(),
                    owner_loop(Port, Self, ReceiverPid, <<>>)
            catch
                error:Reason ->
                    Caller ! {owner_error, self(),
                              iolist_to_binary(io_lib:format("open_port failed: ~p", [Reason]))}
            end
    end.

resolve_executable(Path) ->
    case lists:member($/, Path) of
        true ->
            case filelib:is_regular(Path) of
                true -> {ok, Path};
                false -> {error, not_found}
            end;
        false ->
            case os:find_executable(Path) of
                false -> {error, not_found};
                Found -> {ok, Found}
            end
    end.

owner_loop(Port, Handle, ReceiverPid, Buffer) ->
    receive
        %% Line completed (terminated with newline within the 65536 byte limit).
        {Port, {data, {eol, Line}}} ->
            CleanLine = iolist_to_binary([Buffer, strip_cr(Line)]),
            ReceiverPid ! {mcp_line, Handle, CleanLine},
            owner_loop(Port, Handle, ReceiverPid, <<>>);

        %% Line fragment — no newline yet within the buffer window. Accumulate.
        {Port, {data, {noeol, Fragment}}} ->
            owner_loop(Port, Handle, ReceiverPid,
                       iolist_to_binary([Buffer, Fragment]));

        %% Subprocess exited. Flush any remaining buffer as a final line if
        %% non-empty, then report exit and terminate.
        {Port, {exit_status, Code}} ->
            case Buffer of
                <<>> -> ok;
                _ -> ReceiverPid ! {mcp_line, Handle, Buffer}
            end,
            ReceiverPid ! {mcp_exit, Handle, Code};

        {'EXIT', Port, _Reason} ->
            ReceiverPid ! {mcp_exit, Handle, -1};

        %% Write a JSON-RPC line to the subprocess stdin.
        {send_line, Line} ->
            %% port_command will raise if the port is closed; let it crash in
            %% that case — the owner gets an EXIT and cleans up.
            try port_command(Port, [Line, <<"\n">>]) catch _:_ -> ok end,
            owner_loop(Port, Handle, ReceiverPid, Buffer);

        %% Explicit shutdown. Close the port; the exit_status message may or
        %% may not arrive depending on whether the subprocess exits cleanly.
        close ->
            try port_close(Port) catch _:_ -> ok end,
            ReceiverPid ! {mcp_exit, Handle, 0};

        _ ->
            owner_loop(Port, Handle, ReceiverPid, Buffer)
    end.

%% ---------------------------------------------------------------------------
%% Helpers
%% ---------------------------------------------------------------------------

%% open_port {spawn_executable, ...} requires a string path.
to_string(V) when is_binary(V) -> binary_to_list(V);
to_string(V) when is_list(V) -> V.

to_binary(V) when is_binary(V) -> V;
to_binary(V) when is_list(V) -> iolist_to_binary(V).

%% Gleam gives us Lists of strings; strings on Erlang are binaries. But
%% {args, [...]} wants strings (charlists). Convert as needed.
normalize_args(Args) ->
    lists:map(fun to_string/1, Args).

%% {env, [...]} takes {Name, Value} tuples of strings (charlists) or
%% false to unset. Gleam gives us tuples of binaries.
normalize_env(Env) ->
    lists:map(fun({K, V}) -> {to_string(K), to_string(V)} end, Env).

%% Strip trailing \r if the child emits CRLF.
strip_cr(Bin) ->
    Size = byte_size(Bin),
    case Size > 0 andalso binary:at(Bin, Size - 1) == $\r of
        true -> binary:part(Bin, 0, Size - 1);
        false -> Bin
    end.
