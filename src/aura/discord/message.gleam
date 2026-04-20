//// Discord message-content helpers.

import gleam/string

const discord_max_chars = 1990

/// Clip content to Discord's message size limit, appending an ellipsis when
/// truncated. Discord's hard cap is 2000 chars; we leave a margin for the
/// `...` suffix to make the truncation self-describing.
pub fn clip_to_discord_limit(content: String) -> String {
  case string.length(content) > discord_max_chars {
    True -> string.slice(content, 0, discord_max_chars) <> " ..."
    False -> content
  }
}
