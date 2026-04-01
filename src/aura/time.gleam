import gleam/int
import gleam/string

/// Current time in milliseconds since epoch.
pub fn now_ms() -> Int {
  system_time_ms_ffi()
}

/// Today's date as "YYYY-MM-DD".
pub fn today_date_string() -> String {
  let #(#(year, month, day), _time) = erlang_localtime()
  int.to_string(year)
  <> "-"
  <> pad_zero(month)
  <> "-"
  <> pad_zero(day)
}

fn pad_zero(n: Int) -> String {
  case n < 10 {
    True -> "0" <> int.to_string(n)
    False -> int.to_string(n)
  }
}

@external(erlang, "aura_time_ffi", "system_time_ms")
fn system_time_ms_ffi() -> Int

@external(erlang, "calendar", "local_time")
fn erlang_localtime() -> #(#(Int, Int, Int), #(Int, Int, Int))
