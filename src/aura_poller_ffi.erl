-module(aura_poller_ffi).
-export([wait_for_exit/0]).

%% Wait for an EXIT message from a linked process.
%% Must be called from a process that has trap_exits enabled.
wait_for_exit() ->
    receive
        {'EXIT', _Pid, _Reason} -> nil
    after 300000 ->
        nil
    end.
