/// Current time in milliseconds since epoch.
pub fn now_ms() -> Int {
  system_time_ms_ffi()
}

@external(erlang, "aura_time_ffi", "system_time_ms")
fn system_time_ms_ffi() -> Int
