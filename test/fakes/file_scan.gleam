/// Test whether one file contains the exact byte sequence.
pub fn contains(path: String, value: String) -> Bool {
  ffi_contains(path, value)
}

@external(erlang, "aura_google_execution_test", "file_contains")
fn ffi_contains(path: String, value: String) -> Bool
