//// Dependency-injected Discord REST client. Production code routes all
//// Discord calls through this; tests inject fakes.

import aura/discord/rest
import aura/path_utils

pub type DiscordClient {
  DiscordClient(
    send_message: fn(String, String) -> Result(String, String),
    edit_message: fn(String, String, String) -> Result(Nil, String),
    trigger_typing: fn(String) -> Result(Nil, String),
    get_channel_parent: fn(String) -> Result(String, String),
    send_message_with_attachment: fn(String, String, String) -> Result(
      String,
      String,
    ),
    create_thread_from_message: fn(String, String, String) -> Result(
      String,
      String,
    ),
  )
}

pub fn production(token: String) -> DiscordClient {
  DiscordClient(
    send_message: fn(channel_id, content) {
      rest.send_message(token, channel_id, content, [])
    },
    edit_message: fn(channel_id, msg_id, content) {
      rest.edit_message(token, channel_id, msg_id, content)
    },
    trigger_typing: fn(channel_id) {
      rest.trigger_typing(token, channel_id)
    },
    get_channel_parent: fn(channel_id) {
      rest.get_channel_parent(token, channel_id)
    },
    send_message_with_attachment: fn(channel_id, content, file_path) {
      let filename = path_utils.basename_or(file_path, file_path)
      rest.send_message_with_attachment(
        token,
        channel_id,
        content,
        file_path,
        filename,
      )
    },
    create_thread_from_message: fn(channel_id, msg_id, name) {
      rest.create_thread_from_message(token, channel_id, msg_id, name)
    },
  )
}
