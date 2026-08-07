-module(aura_hook_ffi).
-export([spawn_stream/2]).

%% ---------------------------------------------------------------------------
%% spawn_stream/2 — run a command via /bin/sh -c, streaming stdout+stderr and
%% the exit status to a Gleam subject.
%%
%% Subject: a Gleam subject tuple {subject, Pid, Tag}. Messages delivered:
%%   {Tag, {hook_line, Line :: binary()}}   one output line
%%   {Tag, {hook_exit, Code :: integer()}}  child exit status
%% ---------------------------------------------------------------------------

spawn_stream(Cmd, {subject, Owner, Tag}) ->
    Pid = spawn_link(fun() ->
        Port = open_port(
            {spawn_executable, "/bin/sh"},
            [
                {args, ["-c", binary_to_list(Cmd)]},
                stream,
                {line, 4096},
                stderr_to_stdout,
                exit_status
            ]
        ),
        loop(Port, Owner, Tag)
    end),
    {ok, Pid}.

loop(Port, Owner, Tag) ->
    receive
        {Port, {data, {eol, Line}}} ->
            Owner ! {Tag, {hook_line, Line}},
            loop(Port, Owner, Tag);
        {Port, {data, {noeol, Line}}} ->
            Owner ! {Tag, {hook_line, Line}},
            loop(Port, Owner, Tag);
        {Port, {exit_status, Code}} ->
            Owner ! {Tag, {hook_exit, Code}}
    end.
