//// Reuse Aura's Codex authentication, request format, and stream parser.

import aura/llm
import aura/models
import gleam/int
import gleam/json
import gleam/result

pub fn generate(
  model: String,
  messages: List(llm.Message),
  timeout: Int,
) -> Result(String, String) {
  let deadline = monotonic_ms() + timeout
  use config <- result.try(
    models.build_llm_config_with_codex_reasoning_effort(model, "low")
    |> result.map_error(fn(_) { "Codex authentication is unavailable" }),
  )
  let remaining = int.max(0, deadline - monotonic_ms())
  case remaining <= 0 {
    True -> Error("timeout")
    False -> {
      let body =
        llm.build_codex_text_request_body(
          config.model,
          messages,
          config.codex_reasoning_effort,
        )
        |> json.to_string
      stream(
        config.base_url <> "/responses",
        config.api_key,
        config.model,
        body,
        remaining,
      )
    }
  }
}

@external(erlang, "aura_jev_ffi", "codex_stream")
fn stream(
  url: String,
  auth: String,
  model: String,
  body: String,
  timeout: Int,
) -> Result(String, String)

@external(erlang, "aura_jev_ffi", "monotonic_ms")
fn monotonic_ms() -> Int
