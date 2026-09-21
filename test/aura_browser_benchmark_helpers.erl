-module(aura_browser_benchmark_helpers).
-export([codex_stream/5, unique_id/0, monotonic_ms/0, with_cleanup/2, tick/1, reset/0]).

unique_id() -> integer_to_binary(erlang:system_time(nanosecond), 36).

%% A guardian owns the stream. It cancels when the browser worker dies or its
%% absolute deadline expires. Progress messages never extend the deadline.
codex_stream(Url, Auth, Model, Body, Timeout) ->
    bounded_stream(fun(Receiver) ->
        aura_stream_ffi:chat_stream(Url, Auth, Model, Body, Receiver)
    end, Timeout).

bounded_stream(Start, Timeout) when Timeout > 0 ->
    Owner = self(), Ref = make_ref(), Deadline = erlang:monotonic_time(millisecond) + Timeout,
    {Guardian, Monitor} = spawn_monitor(fun() ->
        OwnerMonitor = monitor(process, Owner),
        Receiver = self(),
        {Stream, StreamMonitor} = spawn_monitor(fun() -> Start(Receiver) end),
        Result = collect_codex(OwnerMonitor, StreamMonitor, Deadline),
        case Result of
            {ok, _} -> ok;
            _ -> stop_codex(Stream, StreamMonitor)
        end,
        demonitor(OwnerMonitor, [flush]),
        Owner ! {Ref, Result}
    end),
    receive
        {Ref, Result} -> demonitor(Monitor, [flush]), Result;
        {'DOWN', Monitor, process, Guardian, _} ->
            {error, <<"Codex text worker stopped">>}
    end;
bounded_stream(_, _) -> {error, <<"timeout">>}.

collect_codex(OwnerMonitor, StreamMonitor, Deadline) ->
    Remaining = max(0, Deadline - erlang:monotonic_time(millisecond)),
    case Remaining of
        0 -> {error, <<"timeout">>};
        _ -> receive_codex(OwnerMonitor, StreamMonitor, Deadline, Remaining)
    end.

receive_codex(OwnerMonitor, StreamMonitor, Deadline, Remaining) ->
    receive
        {stream_delta, _} -> collect_codex(OwnerMonitor, StreamMonitor, Deadline);
        stream_reasoning -> collect_codex(OwnerMonitor, StreamMonitor, Deadline);
        {stream_complete, Content, Calls, _} -> {ok, {Content, Calls}};
        {stream_error, _} -> {error, <<"Codex text request failed">>};
        {'DOWN', OwnerMonitor, process, _, _} -> {error, <<"Browser worker stopped">>};
        {'DOWN', StreamMonitor, process, _, _} -> {error, <<"Codex text stream stopped">>}
    after Remaining -> {error, <<"timeout">>}
    end.

stop_codex(Stream, Monitor) ->
    aura_stream_ffi:cancel_stream(Stream),
    receive
        stream_cancelled -> ok;
        {'DOWN', Monitor, process, Stream, _} -> ok
    after 1000 -> exit(Stream, kill)
    end,
    demonitor(Monitor, [flush]).

monotonic_ms() -> erlang:monotonic_time(millisecond).

with_cleanup(Sessions, Fun) ->
    try Fun()
    after
        [aura_browser_ffi:run(S, <<>>, <<"close">>, [], 10000) || S <- Sessions]
    end.

tick(Key) ->
    N = case get({browser_benchmark, Key}) of undefined -> 0; V -> V end,
    put({browser_benchmark, Key}, N + 1),
    N.

reset() ->
    [erase(K) || {K = {browser_benchmark, _}, _} <- get()],
    nil.
