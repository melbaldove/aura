//// Discord message-content helpers.

import gleam/int
import gleam/list
import gleam/string

pub const discord_max_chars = 1990

const discord_chunk_body_chars = 1800

/// Split content into Discord-sized messages without dropping text.
pub fn split_to_discord_messages(content: String) -> List(String) {
  case content {
    "" -> [""]
    _ ->
      case string.length(content) <= discord_max_chars {
        True -> [content]
        False -> split_loop(content, []) |> label_chunks
      }
  }
}

fn split_loop(remaining: String, chunks: List(String)) -> List(String) {
  case string.length(remaining) > discord_chunk_body_chars {
    False -> list.reverse([remaining, ..chunks])
    True -> {
      let chunk = string.slice(remaining, 0, discord_chunk_body_chars)
      let rest = string.drop_start(remaining, discord_chunk_body_chars)
      split_loop(rest, [chunk, ..chunks])
    }
  }
}

fn label_chunks(chunks: List(String)) -> List(String) {
  let total = list.length(chunks)
  list.index_map(chunks, fn(chunk, index) {
    "Part "
    <> int.to_string(index + 1)
    <> "/"
    <> int.to_string(total)
    <> "\n"
    <> chunk
  })
}

/// First Discord-sized chunk of content, suitable for editing a single message.
pub fn first_chunk(content: String) -> String {
  case split_to_discord_messages(content) {
    [first, ..] -> first
    [] -> ""
  }
}
