//// Blather implementation of the platform-neutral `Transport`.
//// Production code builds a `Transport` here and injects it into the
//// brain just like the Discord client. The shape matches so callers
//// never branch on platform.
////
//// Unsupported operations return `Error(_)` per the Transport contract
//// (see src/aura/transport.gleam): editing is supported; attachment
//// send, thread creation, and parent resolution are deferred until
//// later phases wire up Blather-specific endpoints.

import aura/blather/rest
import aura/config.{type BlatherConfig}
import aura/transport.{type Transport, Transport}

pub fn production(config: BlatherConfig) -> Transport {
  Transport(
    send_message: fn(channel_id, content) {
      rest.send_message(config.url, config.api_key, channel_id, content)
    },
    edit_message: fn(channel_id, msg_id, content) {
      rest.edit_message(config.url, config.api_key, channel_id, msg_id, content)
    },
    trigger_typing: fn(channel_id) {
      rest.trigger_typing(config.url, config.api_key, channel_id)
    },
    get_channel_parent: fn(_channel_id) {
      Error("blather: get_channel_parent not yet implemented")
    },
    send_message_with_attachment: fn(_channel_id, _content, _file_path) {
      Error("blather: send_message_with_attachment not yet implemented")
    },
    create_thread_from_message: fn(_channel_id, _msg_id, _name) {
      Error("blather: create_thread_from_message not yet implemented")
    },
  )
}
