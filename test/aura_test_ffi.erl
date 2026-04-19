-module(aura_test_ffi).
-export([set_env/2, unique_integer/0]).

set_env(Key, Value) ->
    os:putenv(binary_to_list(Key), binary_to_list(Value)).

unique_integer() ->
    erlang:unique_integer([positive]).
