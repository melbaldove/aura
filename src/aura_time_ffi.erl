-module(aura_time_ffi).
-export([system_time_ms/0, parse_rfc3339_ms/1, valid_calendar_date/1]).

system_time_ms() ->
    erlang:system_time(millisecond).

parse_rfc3339_ms(Value) ->
    try
        {ok, calendar:rfc3339_to_system_time(binary_to_list(Value), [{unit, millisecond}])}
    catch
        _:_ -> {error, nil}
    end.

valid_calendar_date(<<Year:4/binary, "-", Month:2/binary, "-", Day:2/binary>>) ->
    try calendar:valid_date(binary_to_integer(Year),
                            binary_to_integer(Month),
                            binary_to_integer(Day))
    catch
        _:_ -> false
    end;
valid_calendar_date(_) -> false.
