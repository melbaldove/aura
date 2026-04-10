-module(aura_acp_stdio_ffi).
-export([start/2, send_line/2, close/1, receive_line/1]).

%% Start a child process. Returns the port.
%% The port reads lines from stdout and can be written to via send_line.
start(Command, CallbackPid) ->
    CommandStr = binary_to_list(Command),
    Port = open_port({spawn, CommandStr}, [
        binary,
        {line, 65536},
        use_stdio,
        exit_status,
        stderr_to_stdout
    ]),
    %% Spawn a reader that forwards lines to CallbackPid
    spawn_link(fun() -> reader_loop(Port, CallbackPid) end),
    Port.

%% Send a line to the child process stdin (appends newline).
send_line(Port, Data) ->
    try
        port_command(Port, [Data, <<"\n">>]),
        {ok, nil}
    catch
        _:Reason ->
            {error, iolist_to_binary(io_lib:format("~p", [Reason]))}
    end.

%% Close the port (kills the child process).
close(Port) ->
    try
        port_close(Port),
        nil
    catch
        _:_ -> nil
    end.

%% Receive a line from the reader process mailbox.
receive_line(TimeoutMs) ->
    receive
        {stdio_line, Line} -> {<<"line">>, Line};
        {stdio_exit, Code} -> {<<"exit">>, integer_to_binary(Code)};
        {stdio_error, Reason} -> {<<"error">>, Reason}
    after TimeoutMs ->
        {<<"timeout">>, <<>>}
    end.

%% Internal: read lines from port and forward to callback pid.
reader_loop(Port, Pid) ->
    receive
        {Port, {data, {eol, Line}}} ->
            %% Strip \r if present
            CleanLine = binary:replace(Line, <<"\r">>, <<>>),
            Pid ! {stdio_line, CleanLine},
            reader_loop(Port, Pid);
        {Port, {data, {noeol, _Partial}}} ->
            %% Partial line -- wait for more
            reader_loop(Port, Pid);
        {Port, {exit_status, Code}} ->
            Pid ! {stdio_exit, Code};
        {'EXIT', Port, Reason} ->
            Pid ! {stdio_error, iolist_to_binary(io_lib:format("~p", [Reason]))}
    end.
