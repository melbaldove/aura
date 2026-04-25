-module(aura_socket_ffi).
-export([start_listener/2, connect_and_send/2, cleanup_socket/1]).

%% ---------------------------------------------------------------------------
%% start_listener/2 — Start a Unix socket listener that dispatches commands.
%%
%% SocketPath: binary — path to the Unix socket file
%% Handler: fun(Command :: binary()) -> binary() — processes a command, returns response
%%
%% Spawns a listener process that accepts connections, reads one line per
%% connection, calls Handler, sends the response, and closes the connection.
%% Returns the listener pid.
%% ---------------------------------------------------------------------------

start_listener(SocketPath, Handler) ->
    PathStr = binary_to_list(SocketPath),
    %% Remove stale socket from a previous crash
    file:delete(PathStr),
    case gen_tcp:listen(0, [
        binary,
        {ifaddr, {local, PathStr}},
        {packet, line},
        {active, false},
        {reuseaddr, true}
    ]) of
        {ok, ListenSock} ->
            Pid = spawn_link(fun() -> accept_loop(ListenSock, Handler) end),
            io:format("[ctl] Listening on ~s~n", [PathStr]),
            {ok, Pid};
        {error, Reason} ->
            io:format("[ctl] Failed to bind ~s: ~p~n", [PathStr, Reason]),
            {error, iolist_to_binary(io_lib:format("~p", [Reason]))}
    end.

accept_loop(ListenSock, Handler) ->
    case gen_tcp:accept(ListenSock) of
        {ok, Sock} ->
            spawn(fun() -> handle_connection(Sock, Handler) end),
            accept_loop(ListenSock, Handler);
        {error, closed} ->
            ok;
        {error, _Reason} ->
            accept_loop(ListenSock, Handler)
    end.

handle_connection(Sock, Handler) ->
    case gen_tcp:recv(Sock, 0, 5000) of
        {ok, Data} ->
            Command = string:trim(Data),
            Response = try
                Handler(Command)
            catch
                _:Err ->
                    iolist_to_binary(io_lib:format("ERROR: ~p", [Err]))
            end,
            gen_tcp:send(Sock, [Response, <<"\n">>]),
            gen_tcp:close(Sock);
        {error, _} ->
            gen_tcp:close(Sock)
    end.

%% ---------------------------------------------------------------------------
%% connect_and_send/2 — CLI client: connect to socket, send command, read response.
%%
%% SocketPath: binary — path to the Unix socket file
%% Command: binary — the command to send (newline appended automatically)
%%
%% Returns {ok, Response :: binary()} or {error, Reason :: binary()}.
%% ---------------------------------------------------------------------------

connect_and_send(SocketPath, Command) ->
    PathStr = binary_to_list(SocketPath),
    case gen_tcp:connect({local, PathStr}, 0, [
        binary,
        {packet, line},
        {active, false}
    ], 5000) of
        {ok, Sock} ->
            ok = gen_tcp:send(Sock, [Command, <<"\n">>]),
            Result = case gen_tcp:recv(Sock, 0, 180000) of
                {ok, Data} -> {ok, string:trim(Data)};
                {error, Reason} -> {error, iolist_to_binary(io_lib:format("~p", [Reason]))}
            end,
            gen_tcp:close(Sock),
            Result;
        {error, enoent} ->
            {error, <<"Aura is not running (socket not found)">>};
        {error, econnrefused} ->
            {error, <<"Aura is not running (connection refused)">>};
        {error, Reason} ->
            {error, iolist_to_binary(io_lib:format("~p", [Reason]))}
    end.

%% ---------------------------------------------------------------------------
%% cleanup_socket/1 — Remove the socket file.
%% ---------------------------------------------------------------------------

cleanup_socket(SocketPath) ->
    file:delete(binary_to_list(SocketPath)),
    nil.
