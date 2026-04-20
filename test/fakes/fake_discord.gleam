import aura/clients/discord_client.{type DiscordClient, DiscordClient}
import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/otp/actor
import gleam/string

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

pub type DiscordEvent {
  Sent(channel_id: String, content: String, msg_id: String)
  Edited(channel_id: String, msg_id: String, new_content: String)
  TypingTriggered(channel_id: String)
  AttachmentSent(channel_id: String, content: String, path: String)
  ThreadCreated(
    parent_channel_id: String,
    msg_id: String,
    name: String,
    thread_id: String,
  )
}

pub opaque type FakeDiscord {
  FakeDiscord(subject: process.Subject(Msg))
}

// ---------------------------------------------------------------------------
// Internal actor types
// ---------------------------------------------------------------------------

type State {
  State(
    events: List(DiscordEvent),
    next_id: Int,
    parents: Dict(String, String),
    thread_scripts: List(String),
  )
}

type Msg {
  RecordSent(
    channel_id: String,
    content: String,
    reply: process.Subject(Result(String, String)),
  )
  RecordEdited(
    channel_id: String,
    msg_id: String,
    new_content: String,
    reply: process.Subject(Result(Nil, String)),
  )
  RecordTyping(
    channel_id: String,
    reply: process.Subject(Result(Nil, String)),
  )
  RecordAttachment(
    channel_id: String,
    content: String,
    path: String,
    reply: process.Subject(Result(String, String)),
  )
  RecordThread(
    parent_channel_id: String,
    msg_id: String,
    name: String,
    reply: process.Subject(Result(String, String)),
  )
  GetSentTo(channel_id: String, reply: process.Subject(List(String)))
  GetAll(reply: process.Subject(List(DiscordEvent)))
  Seed(channel: String, parent: String)
  GetParent(channel_id: String, reply: process.Subject(Result(String, String)))
  GetLatestContentFor(
    channel_id: String,
    reply: process.Subject(Result(String, Nil)),
  )
  PushThreadScript(thread_id: String)
}

// ---------------------------------------------------------------------------
// Actor handler
// ---------------------------------------------------------------------------

fn handle_message(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    RecordSent(channel_id:, content:, reply:) -> {
      let id = "fake-msg-" <> int.to_string(state.next_id)
      let event = Sent(channel_id:, content:, msg_id: id)
      process.send(reply, Ok(id))
      actor.continue(
        State(
          ..state,
          events: [event, ..state.events],
          next_id: state.next_id + 1,
        ),
      )
    }

    RecordEdited(channel_id:, msg_id:, new_content:, reply:) -> {
      let event = Edited(channel_id:, msg_id:, new_content:)
      process.send(reply, Ok(Nil))
      actor.continue(
        State(
          ..state,
          events: [event, ..state.events],
        ),
      )
    }

    RecordTyping(channel_id:, reply:) -> {
      let event = TypingTriggered(channel_id:)
      process.send(reply, Ok(Nil))
      actor.continue(
        State(
          ..state,
          events: [event, ..state.events],
        ),
      )
    }

    RecordAttachment(channel_id:, content:, path:, reply:) -> {
      let id = "fake-msg-" <> int.to_string(state.next_id)
      let event = AttachmentSent(channel_id:, content:, path:)
      process.send(reply, Ok(id))
      actor.continue(
        State(
          ..state,
          events: [event, ..state.events],
          next_id: state.next_id + 1,
        ),
      )
    }

    RecordThread(parent_channel_id:, msg_id:, name:, reply:) -> {
      let #(thread_id, rest_scripts) = case state.thread_scripts {
        [scripted, ..rest] -> #(scripted, rest)
        [] -> #("fake-thread-" <> int.to_string(state.next_id), [])
      }
      let event =
        ThreadCreated(parent_channel_id:, msg_id:, name:, thread_id:)
      process.send(reply, Ok(thread_id))
      actor.continue(
        State(
          events: [event, ..state.events],
          next_id: state.next_id + 1,
          parents: state.parents,
          thread_scripts: rest_scripts,
        ),
      )
    }

    PushThreadScript(thread_id:) ->
      actor.continue(State(
        ..state,
        thread_scripts: list.append(state.thread_scripts, [thread_id]),
      ))

    GetSentTo(channel_id:, reply:) -> {
      let contents =
        state.events
        |> list.reverse
        |> list.filter_map(fn(event) {
          case event {
            Sent(channel_id: cid, content: c, ..) if cid == channel_id ->
              Ok(c)
            _ -> Error(Nil)
          }
        })
      process.send(reply, contents)
      actor.continue(state)
    }

    GetAll(reply:) -> {
      let ordered = list.reverse(state.events)
      process.send(reply, ordered)
      actor.continue(state)
    }

    Seed(channel:, parent:) -> {
      actor.continue(
        State(
          ..state,
          parents: dict.insert(state.parents, channel, parent),
        ),
      )
    }

    GetParent(channel_id:, reply:) -> {
      let result =
        Ok(dict.get(state.parents, channel_id) |> unwrap_or(""))
      process.send(reply, result)
      actor.continue(state)
    }

    GetLatestContentFor(channel_id:, reply:) -> {
      // Walk events in reverse-chronological order (state.events is newest first).
      // Return the content of the latest Edited or Sent event for this channel.
      let latest =
        list.find_map(state.events, fn(event) {
          case event {
            Edited(channel_id: cid, new_content: c, ..) if cid == channel_id ->
              Ok(c)
            Sent(channel_id: cid, content: c, ..) if cid == channel_id ->
              Ok(c)
            _ -> Error(Nil)
          }
        })
      process.send(reply, latest)
      actor.continue(state)
    }
  }
}

fn unwrap_or(r: Result(a, b), default: a) -> a {
  case r {
    Ok(v) -> v
    Error(_) -> default
  }
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Create a new fake Discord client. Returns a `#(FakeDiscord, DiscordClient)`
/// pair — use `FakeDiscord` for assertions, inject `DiscordClient` into code
/// under test.
pub fn new() -> #(FakeDiscord, DiscordClient) {
  let builder =
    actor.new_with_initialiser(5000, fn(subject) {
      let state =
        State(events: [], next_id: 1, parents: dict.new(), thread_scripts: [])
      Ok(actor.initialised(state) |> actor.returning(subject))
    })
    |> actor.on_message(handle_message)

  let assert Ok(started) = actor.start(builder)
  let subj = started.data
  let fake = FakeDiscord(subject: subj)

  let client =
    DiscordClient(
      send_message: fn(channel_id, content) {
        process.call(subj, 1000, fn(reply) {
          RecordSent(channel_id:, content:, reply:)
        })
      },
      edit_message: fn(channel_id, msg_id, new_content) {
        process.call(subj, 1000, fn(reply) {
          RecordEdited(channel_id:, msg_id:, new_content:, reply:)
        })
      },
      trigger_typing: fn(channel_id) {
        process.call(subj, 1000, fn(reply) { RecordTyping(channel_id:, reply:) })
      },
      get_channel_parent: fn(channel_id) {
        process.call(subj, 1000, fn(reply) { GetParent(channel_id:, reply:) })
      },
      send_message_with_attachment: fn(channel_id, content, path) {
        process.call(subj, 1000, fn(reply) {
          RecordAttachment(channel_id:, content:, path:, reply:)
        })
      },
      create_thread_from_message: fn(channel_id, msg_id, name) {
        process.call(subj, 1000, fn(reply) {
          RecordThread(
            parent_channel_id: channel_id,
            msg_id:,
            name:,
            reply:,
          )
        })
      },
    )

  #(fake, client)
}

/// Return the content of every `send_message` call to `channel_id`, in order.
pub fn all_sent_to(fake: FakeDiscord, channel_id: String) -> List(String) {
  process.call(fake.subject, 1000, fn(reply) { GetSentTo(channel_id:, reply:) })
}

/// Return every recorded event, in the order they occurred.
pub fn all_events(fake: FakeDiscord) -> List(DiscordEvent) {
  process.call(fake.subject, 1000, fn(reply) { GetAll(reply:) })
}

/// Pre-populate a channel → parent mapping so `get_channel_parent` returns it.
pub fn seed_channel_parent(
  fake: FakeDiscord,
  channel: String,
  parent: String,
) -> Nil {
  process.send(fake.subject, Seed(channel:, parent:))
}

/// Poll (every 10ms) until at least one message has been sent to `channel_id`,
/// then return its content. Panics with a clear message if `timeout_ms` elapses
/// without a message arriving.
pub fn assert_sent_to(
  fake: FakeDiscord,
  channel_id: String,
  timeout_ms: Int,
) -> String {
  do_assert_sent_to(fake, channel_id, timeout_ms, 0)
}

fn do_assert_sent_to(
  fake: FakeDiscord,
  channel_id: String,
  timeout_ms: Int,
  elapsed: Int,
) -> String {
  case all_sent_to(fake, channel_id) {
    [first, ..] -> first
    [] -> {
      case elapsed >= timeout_ms {
        True ->
          panic as {
            "assert_sent_to: no message sent to channel "
            <> channel_id
            <> " within "
            <> int.to_string(timeout_ms)
            <> "ms"
          }
        False -> {
          // Sleep 10ms via a short process.call timeout trick — we just sleep
          // the current process for 10ms then retry.
          let _ = process.sleep(10)
          do_assert_sent_to(fake, channel_id, timeout_ms, elapsed + 10)
        }
      }
    }
  }
}

/// Poll (every 10ms) until a message containing `expected` has been sent OR
/// edited to `channel_id`, then return its content. This handles the
/// progressive-edit pattern where the brain edits in-place rather than
/// sending new messages. Panics with a clear message on timeout.
pub fn assert_latest_contains(
  fake: FakeDiscord,
  channel_id: String,
  expected: String,
  timeout_ms: Int,
) -> String {
  do_assert_latest_contains(fake, channel_id, expected, timeout_ms, 0)
}

fn do_assert_latest_contains(
  fake: FakeDiscord,
  channel_id: String,
  expected: String,
  timeout_ms: Int,
  elapsed: Int,
) -> String {
  let latest =
    process.call(fake.subject, 1000, fn(reply) {
      GetLatestContentFor(channel_id:, reply:)
    })
  let found = case latest {
    Ok(content) -> string.contains(content, expected)
    Error(Nil) -> False
  }
  case found {
    True -> {
      let assert Ok(content) = latest
      content
    }
    False -> {
      case elapsed >= timeout_ms {
        True ->
          panic as {
            "assert_latest_contains: channel "
            <> channel_id
            <> " never had content containing: "
            <> expected
          }
        False -> {
          let _ = process.sleep(10)
          do_assert_latest_contains(
            fake,
            channel_id,
            expected,
            timeout_ms,
            elapsed + 10,
          )
        }
      }
    }
  }
}

/// Push a scripted thread_id onto the queue. The next `create_thread_from_message`
/// call will consume it (FIFO order) and return that id instead of the default
/// auto-generated `"fake-thread-N"`. Allows tests to assert on a known thread_id.
pub fn script_create_thread(fake: FakeDiscord, thread_id: String) -> Nil {
  process.send(fake.subject, PushThreadScript(thread_id:))
}
