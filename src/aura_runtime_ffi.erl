-module(aura_runtime_ffi).
-export([halt/1, sleep_forever/0]).

halt(Code) ->
    erlang:halt(Code).

sleep_forever() ->
    receive
        stop -> ok
    end.
