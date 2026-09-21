-module(aura_jev_ffi).
-export([read_script/0, monotonic_ms/0, codex_stream/5, bounded_stream/2]).

read_script() ->
    case code:priv_dir(aura) of
        {error, _} -> {error, <<"Jev browser assets are unavailable">>};
        Dir ->
            case file:read_file(filename:join(Dir, "jev_browser.js")) of
                {ok, Script} -> {ok, Script};
                _ -> {error, <<"Jev browser script is unavailable">>}
            end
    end.

monotonic_ms() -> erlang:monotonic_time(millisecond).

%% A guardian owns the stream. It cancels when the browser worker dies or its
%% absolute deadline expires. Progress messages never extend the deadline.
codex_stream(Url, Auth, Model, Body, Timeout) ->
    bounded_stream(fun(Receiver) ->
        aura_stream_ffi:chat_stream(Url, Auth, Model, Body, Receiver)
    end, Timeout).

bounded_stream(Start, Timeout) when Timeout > 0 ->
    Owner = self(), Ref = make_ref(), Deadline = monotonic_ms() + Timeout,
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
    Remaining = max(0, Deadline - monotonic_ms()),
    case Remaining of
        0 -> {error, <<"timeout">>};
        _ -> receive_codex(OwnerMonitor, StreamMonitor, Deadline, Remaining)
    end.

receive_codex(OwnerMonitor, StreamMonitor, Deadline, Remaining) ->
    receive
        {stream_delta, _} -> collect_codex(OwnerMonitor, StreamMonitor, Deadline);
        stream_reasoning -> collect_codex(OwnerMonitor, StreamMonitor, Deadline);
        {stream_complete, Content, <<"[]">>, _} -> {ok, Content};
        {stream_complete, _, _, _} -> {error, <<"Unexpected Codex tool call">>};
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
