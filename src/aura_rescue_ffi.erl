-module(aura_rescue_ffi).
-export([rescue/1]).

%% Run a zero-arity function, catching any crash.
%% Returns {ok, Result} or {error, ReasonBinary}.
rescue(Fun) ->
    try
        {ok, Fun()}
    catch
        Class:Reason ->
            Msg = io_lib:format("~p:~p", [Class, Reason]),
            {error, list_to_binary(Msg)}
    end.
