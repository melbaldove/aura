// src/aura/browser.gleam
import gleam/string

pub type Action {
  Navigate
  Snapshot
  Click
  Type
  Press
  Back
  Vision
}

/// Resolve the agent-browser session name from an optional LLM-provided
/// name and the current channel_id. Returns Error if neither is available.
pub fn resolve_session(
  session_arg: String,
  channel_id: String,
) -> Result(String, String) {
  case session_arg, channel_id {
    "", "" ->
      Error(
        "session arg required when no channel_id is available "
        <> "(e.g. scheduled tasks, dreaming)",
      )
    "", ch -> Ok("aura-ch-" <> ch)
    name, _ -> Ok("aura-named-" <> name)
  }
}
