//// Platform-neutral outbound transport. Every platform (Discord,
//// Blather, …) implements these functions for its wire protocol;
//// callers (brain, channel_actor, tools) go through a `Transport`
//// value without caring which platform they're talking to.
////
//// The shape was promoted from the original `DiscordClient` record —
//// these are the operations the brain already performs and that every
//// chat-style platform supports.
////
//// Operations that a given platform genuinely cannot perform must
//// return `Error(_)` — not a silent success — so callers notice.
//// See ENGINEERING.md #12 ("no silent errors").

pub type Transport {
  Transport(
    /// Post a new message in a channel. Returns the new message id.
    send_message: fn(String, String) -> Result(String, String),
    /// Replace the content of an existing message. Platforms that don't
    /// support edits must return `Error`.
    edit_message: fn(String, String, String) -> Result(Nil, String),
    /// Show a typing indicator in the channel. Fire-and-forget.
    trigger_typing: fn(String) -> Result(Nil, String),
    /// Resolve a child channel/thread to its parent channel. Platforms
    /// without a parent/child relationship must return `Error`; do not
    /// echo the input id back.
    get_channel_parent: fn(String) -> Result(String, String),
    /// Post a message with a file attachment. Returns the new message id.
    send_message_with_attachment: fn(String, String, String) ->
      Result(String, String),
    /// Create a thread rooted at a specific message. Returns the new
    /// thread/channel id. Platforms without threads must return `Error`.
    create_thread_from_message: fn(String, String, String) ->
      Result(String, String),
  )
}
