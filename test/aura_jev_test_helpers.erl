-module(aura_jev_test_helpers).
-export([tick/1, reset/0, set_enabled/1, restore_enabled/1, with_fake_config/1, with_cleanup/2,
         codex_deadline/0, codex_owner_death/0]).

tick(Key) ->
    N = case get({jev_test, Key}) of undefined -> 0; V -> V end,
    put({jev_test, Key}, N + 1),
    N.

reset() ->
    [erase(K) || {K = {jev_test, _}, _} <- get()],
    nil.

set_enabled(Value) ->
    Old = os:getenv("AURA_BROWSER_JEV_ENABLED"),
    os:putenv("AURA_BROWSER_JEV_ENABLED", binary_to_list(Value)),
    case Old of false -> {error, nil}; _ -> {ok, list_to_binary(Old)} end.

restore_enabled({error, nil}) -> os:unsetenv("AURA_BROWSER_JEV_ENABLED"), nil;
restore_enabled({ok, Old}) -> os:putenv("AURA_BROWSER_JEV_ENABLED", binary_to_list(Old)), nil.

with_fake_config(Fun) ->
    Values = [{"AURA_BROWSER_JEV_ENABLED", "true"}, {"TYPESAFE_API_KEY", "fake"},
              {"TEXT_MODEL_API_KEY", "fake"}, {"TEXT_MODEL_BASE_URL", "https://text.example"},
              {"TEXT_MODEL", "fake"}],
    Old = [{K, os:getenv(K)} || {K, _} <- Values],
    try
        [os:putenv(K, V) || {K, V} <- Values],
        Fun()
    after
        [case V of false -> os:unsetenv(K); _ -> os:putenv(K, V) end || {K, V} <- Old]
    end.

with_cleanup(Sessions, Fun) ->
    try Fun()
    after
        [aura_browser_ffi:run(S, <<>>, <<"close">>, [], 10000) || S <- Sessions]
    end.

codex_deadline() ->
    Parent = self(),
    Start = fun(Receiver) -> fake_stream(Receiver, Parent) end,
    Started = erlang:monotonic_time(millisecond),
    Result = aura_jev_ffi:bounded_stream(Start, 30),
    Elapsed = erlang:monotonic_time(millisecond) - Started,
    Cancelled = receive cancelled -> true after 1000 -> false end,
    Result =:= {error, <<"timeout">>} andalso Cancelled andalso Elapsed < 1000.

codex_owner_death() ->
    Parent = self(),
    Start = fun(Receiver) ->
        Parent ! started,
        fake_stream(Receiver, Parent)
    end,
    Worker = spawn(fun() -> aura_jev_ffi:bounded_stream(Start, 5000) end),
    receive started -> ok after 1000 -> error(stream_not_started) end,
    exit(Worker, kill),
    receive cancelled -> true after 1000 -> false end.

fake_stream(Receiver, Parent) ->
    receive
        cancel_stream -> Receiver ! stream_cancelled, Parent ! cancelled
    after 5 ->
        Receiver ! {stream_delta, <<"token">>},
        fake_stream(Receiver, Parent)
    end.
