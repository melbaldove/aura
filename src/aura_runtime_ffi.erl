-module(aura_runtime_ffi).
-export([get_plain_arguments/0, halt/1, sleep_forever/0]).

get_plain_arguments() ->
    [unicode:characters_to_binary(Arg) || Arg <- init:get_plain_arguments()].

halt(Code) ->
    erlang:halt(Code).

sleep_forever() ->
    receive
        stop -> ok
    end.
