import aura/google_http_client

/// Call the generic HTTP FFI through the Erlang fault-test boundary.
pub fn direct_get(
  url: String,
  bearer: String,
  origin: String,
) -> google_http_client.Outcome {
  ffi_direct_get(url, bearer, origin)
}

/// Call the generic HTTP FFI with one short test-only absolute deadline.
pub fn direct_get_with_timeout(
  url: String,
  bearer: String,
  origin: String,
  timeout_ms: Int,
) -> google_http_client.Outcome {
  ffi_direct_get_with_timeout(url, bearer, origin, timeout_ms)
}

@external(erlang, "aura_google_http_fault_test", "direct_get")
fn ffi_direct_get(
  url: String,
  bearer: String,
  origin: String,
) -> google_http_client.Outcome

@external(erlang, "aura_google_http_fault_test", "direct_get_with_timeout")
fn ffi_direct_get_with_timeout(
  url: String,
  bearer: String,
  origin: String,
  timeout_ms: Int,
) -> google_http_client.Outcome
