-module(aura_env_ffi).
-export([get_env/1, set_env/2]).

get_env(Name) ->
    case os:getenv(binary_to_list(Name)) of
        false -> {error, nil};
        Value -> {ok, list_to_binary(Value)}
    end.

set_env(Key, Value) ->
    os:putenv(binary_to_list(Key), binary_to_list(Value)),
    nil.
