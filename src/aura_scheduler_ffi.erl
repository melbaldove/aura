-module(aura_scheduler_ffi).
-export([ms_to_time_parts/1]).

ms_to_time_parts(Ms) ->
    Seconds = Ms div 1000,
    %% Seconds from year 0 (Gregorian calendar) to Unix epoch (1970-01-01).
    %% Used to convert between erlang:system_time(millisecond) and calendar module.
    DateTime = calendar:gregorian_seconds_to_datetime(Seconds + 62167219200),
    {{_Year, Month, Day}, {Hour, Minute, _Second}} = DateTime,
    DayOfWeek = calendar:day_of_the_week(element(1, DateTime)),
    %% calendar:day_of_the_week returns 1=Monday..7=Sunday
    %% Convert to 0=Sunday..6=Saturday
    Weekday = case DayOfWeek of
        7 -> 0;
        N -> N
    end,
    {Minute, Hour, Day, Month, Weekday}.
