-module(aura_test_ffi).
-export([set_env/2]).

set_env(Key, Value) ->
    os:putenv(binary_to_list(Key), binary_to_list(Value)).
