//// Blather has thread replies, not Discord-style thread channels.
//// Aura's brain and channel actors already route conversations by a
//// single channel id, so Blather thread replies use a synthetic channel
//// id that carries both the parent channel and root message id.

import gleam/option.{type Option, None, Some}
import gleam/string

const delimiter = "#thread:"

/// Build Aura's synthetic channel id for a Blather thread.
pub fn make(parent_channel_id: String, thread_id: String) -> String {
  parent_channel_id <> delimiter <> thread_id
}

/// Parse a synthetic Blather thread channel id into parent channel and
/// thread root message id. Normal channel ids return `None`.
pub fn parse(channel_id: String) -> Option(#(String, String)) {
  case string.split_once(channel_id, on: delimiter) {
    Ok(#(parent_channel_id, thread_id)) -> {
      case parent_channel_id, thread_id {
        "", _ -> None
        _, "" -> None
        _, _ -> Some(#(parent_channel_id, thread_id))
      }
    }
    Error(_) -> None
  }
}

/// Return the API channel id to use in Blather REST paths.
pub fn api_channel_id(channel_id: String) -> String {
  case parse(channel_id) {
    Some(#(parent_channel_id, _)) -> parent_channel_id
    None -> channel_id
  }
}

/// Return the optional Blather `threadId` for REST message bodies.
pub fn thread_id(channel_id: String) -> Option(String) {
  case parse(channel_id) {
    Some(#(_, thread_id)) -> Some(thread_id)
    None -> None
  }
}

/// Resolve a synthetic thread channel id to its parent channel.
pub fn parent(channel_id: String) -> Result(String, String) {
  case parse(channel_id) {
    Some(#(parent_channel_id, _)) -> Ok(parent_channel_id)
    None -> Error("blather: channel has no parent")
  }
}
