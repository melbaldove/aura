-module(aura_time_ffi).
-export([system_time_ms/0]).

system_time_ms() ->
    erlang:system_time(millisecond).
