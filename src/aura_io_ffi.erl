-module(aura_io_ffi).
-export([get_line/1, get_password/1, set_permissions/2, log_stdout/1]).

get_line(Prompt) ->
    case io:get_line(Prompt) of
        eof -> {error, <<"eof">>};
        {error, Reason} -> {error, list_to_binary(io_lib:format("~p", [Reason]))};
        Data -> {ok, string:trim(unicode:characters_to_binary(Data))}
    end.

get_password(Prompt) ->
    %% Note: echo suppression removed — causes crashes under gleam run.
    %% Credentials are visible during input. Acceptable for local-only use.
    get_line(Prompt).

set_permissions(Path, Mode) ->
    file:change_mode(binary_to_list(Path), Mode),
    nil.

%% Log to the init process's group leader, ensuring output reaches
%% the daemon's stdout regardless of which process calls it.
%% Spawned processes (gen_tcp handlers, process.spawn_unlinked) may
%% have a different group leader that doesn't route to the log file.
log_stdout(Message) ->
    case erlang:whereis(init) of
        undefined ->
            io:format("~ts~n", [Message]);
        Pid ->
            {group_leader, GroupLeader} = erlang:process_info(Pid, group_leader),
            io:format(GroupLeader, "~ts~n", [Message])
    end,
    nil.
