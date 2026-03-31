-module(aura_time_ffi).
-export([now_ms/0, system_time_ms/0]).

now_ms() ->
    erlang:system_time(millisecond).

system_time_ms() ->
    erlang:system_time(millisecond).
