import gleam/int
import gleam/string

/// Current time in milliseconds since epoch.
pub fn now_ms() -> Int {
  system_time_ms_ffi()
}

/// Today's date as "YYYY-MM-DD".
pub fn today_date_string() -> String {
  let #(#(year, month, day), _time) = erlang_localtime()
  int.to_string(year) <> "-" <> pad_zero(month) <> "-" <> pad_zero(day)
}

/// Current date and time as "YYYY-MM-DD HH:MM" (local time).
pub fn now_datetime_string() -> String {
  let #(#(year, month, day), #(hour, minute, _second)) = erlang_localtime()
  int.to_string(year)
  <> "-"
  <> pad_zero(month)
  <> "-"
  <> pad_zero(day)
  <> " "
  <> pad_zero(hour)
  <> ":"
  <> pad_zero(minute)
}

/// Format an epoch-milliseconds timestamp as "YYYY-MM-DD HH:MM" in UTC.
/// Used where a stable, timezone-independent display is needed (e.g. tool
/// output shown back to the LLM / user).
pub fn format_ms_utc(ms: Int) -> String {
  let seconds = ms / 1000
  // Seconds from year 0 to Unix epoch (1970-01-01).
  let epoch_offset = 62_167_219_200
  let #(#(year, month, day), #(hour, minute, _second)) =
    erlang_seconds_to_datetime(seconds + epoch_offset)
  int.to_string(year)
  <> "-"
  <> pad_zero(month)
  <> "-"
  <> pad_zero(day)
  <> " "
  <> pad_zero(hour)
  <> ":"
  <> pad_zero(minute)
}

/// Format an epoch-milliseconds timestamp as an RFC3339 UTC timestamp.
pub fn format_ms_rfc3339_utc(ms: Int) -> String {
  let seconds = ms / 1000
  // Seconds from year 0 to Unix epoch (1970-01-01).
  let epoch_offset = 62_167_219_200
  let #(#(year, month, day), #(hour, minute, second)) =
    erlang_seconds_to_datetime(seconds + epoch_offset)
  int.to_string(year)
  <> "-"
  <> pad_zero(month)
  <> "-"
  <> pad_zero(day)
  <> "T"
  <> pad_zero(hour)
  <> ":"
  <> pad_zero(minute)
  <> ":"
  <> pad_zero(second)
  <> "Z"
}

/// Parse one bounded RFC 3339 UTC timestamp into epoch milliseconds.
pub fn parse_rfc3339_utc_ms(value: String) -> Result(Int, Nil) {
  case
    value != ""
    && string.byte_size(value) <= 64
    && string.ends_with(value, "Z")
    && !string.contains(value, "\n")
    && !string.contains(value, "\r")
  {
    True -> parse_rfc3339_ms_ffi(value)
    False -> Error(Nil)
  }
}

/// Parse one bounded RFC 3339 timestamp with `Z` or a numeric offset.
pub fn parse_rfc3339_ms(value: String) -> Result(Int, Nil) {
  case
    value != ""
    && string.byte_size(value) <= 64
    && !string.contains(value, "\n")
    && !string.contains(value, "\r")
  {
    True -> parse_rfc3339_ms_ffi(value)
    False -> Error(Nil)
  }
}

/// Return true only for one valid Gregorian `YYYY-MM-DD` date.
pub fn valid_calendar_date(value: String) -> Bool {
  case string.byte_size(value) == 10 {
    True -> valid_calendar_date_ffi(value)
    False -> False
  }
}

fn pad_zero(n: Int) -> String {
  case n < 10 {
    True -> "0" <> int.to_string(n)
    False -> int.to_string(n)
  }
}

@external(erlang, "aura_time_ffi", "system_time_ms")
fn system_time_ms_ffi() -> Int

@external(erlang, "aura_time_ffi", "parse_rfc3339_ms")
fn parse_rfc3339_ms_ffi(value: String) -> Result(Int, Nil)

@external(erlang, "aura_time_ffi", "valid_calendar_date")
fn valid_calendar_date_ffi(value: String) -> Bool

@external(erlang, "calendar", "local_time")
fn erlang_localtime() -> #(#(Int, Int, Int), #(Int, Int, Int))

@external(erlang, "calendar", "gregorian_seconds_to_datetime")
fn erlang_seconds_to_datetime(
  seconds: Int,
) -> #(#(Int, Int, Int), #(Int, Int, Int))
