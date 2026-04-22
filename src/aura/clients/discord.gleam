//// Discord implementation of the platform-neutral `Transport`.
//// Production code builds a `Transport` here and injects it into
//// actors; tests build a fake in `test/fakes/fake_discord.gleam`.

import aura/discord/rest
import aura/path_utils
import aura/transport.{type Transport, Transport}

pub fn production(token: String) -> Transport {
  Transport(
    send_message: fn(channel_id, content) {
      rest.send_message(token, channel_id, content, [])
    },
    edit_message: fn(channel_id, msg_id, content) {
      rest.edit_message(token, channel_id, msg_id, content)
    },
    trigger_typing: fn(channel_id) { rest.trigger_typing(token, channel_id) },
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
