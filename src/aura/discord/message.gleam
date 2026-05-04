//// Discord message-content helpers.

import gleam/list
import gleam/string

pub const discord_max_chars = 1990

/// Split content into Discord-sized messages without dropping text.
pub fn split_to_discord_messages(content: String) -> List(String) {
  case content {
    "" -> [""]
    _ -> split_loop(content, [])
  }
}

fn split_loop(remaining: String, chunks: List(String)) -> List(String) {
  case string.length(remaining) > discord_max_chars {
    False -> list.reverse([remaining, ..chunks])
    True -> {
      let chunk = string.slice(remaining, 0, discord_max_chars)
      let rest = string.drop_start(remaining, discord_max_chars)
      split_loop(rest, [chunk, ..chunks])
    }
  }
}

/// First Discord-sized chunk of content, suitable for editing a single message.
pub fn first_chunk(content: String) -> String {
  case split_to_discord_messages(content) {
    [first, ..] -> first
    [] -> ""
  }
}
