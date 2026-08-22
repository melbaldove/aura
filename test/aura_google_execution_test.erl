-module(aura_google_execution_test).
-export([file_contains/2]).

file_contains(Path, Value) ->
    case file:read_file(Path) of
        {ok, Bytes} -> binary:match(Bytes, Value) =/= nomatch;
        {error, _} -> false
    end.
