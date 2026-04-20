//// Dynamic per-channel actor supervisor.
////
//// Owns a `Dict(channel_id, Subject(ChannelMessage))`. On `get_or_start`,
//// returns the existing actor subject if one is alive for the channel, or
//// spawns a new one and caches it.

import aura/channel_actor
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import gleam/result

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

pub opaque type SupervisorMessage {
  GetOrStart(
    channel_id: String,
    deps: channel_actor.Deps,
    reply: Subject(Subject(channel_actor.ChannelMessage)),
  )
  ChildDown(channel_id: String)
}

type SupervisorState {
  SupervisorState(
    children: Dict(String, Subject(channel_actor.ChannelMessage)),
    self: Subject(SupervisorMessage),
  )
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Start the channel supervisor actor.
pub fn start() -> Result(Subject(SupervisorMessage), actor.StartError) {
  actor.new_with_initialiser(5000, fn(self_subject) {
    let state =
      SupervisorState(children: dict.new(), self: self_subject)
    Ok(actor.initialised(state) |> actor.returning(self_subject))
  })
  |> actor.on_message(handle_message)
  |> actor.start
  |> result.map(fn(started) { started.data })
}

/// Return the existing actor subject for `channel_id`, or start a new one
/// using `deps` and cache it. Same channel_id always returns the same subject
/// as long as the child is alive.
pub fn get_or_start(
  sup: Subject(SupervisorMessage),
  channel_id: String,
  deps: channel_actor.Deps,
) -> Subject(channel_actor.ChannelMessage) {
  process.call(sup, 5000, fn(reply) {
    GetOrStart(channel_id: channel_id, deps: deps, reply: reply)
  })
}

// ---------------------------------------------------------------------------
// Message handler
// ---------------------------------------------------------------------------

fn handle_message(
  state: SupervisorState,
  message: SupervisorMessage,
) -> actor.Next(SupervisorState, SupervisorMessage) {
  case message {
    GetOrStart(channel_id:, deps:, reply:) -> {
      case dict.get(state.children, channel_id) {
        Ok(existing) -> {
          process.send(reply, existing)
          actor.continue(state)
        }
        Error(Nil) -> {
          case channel_actor.start(deps) {
            Ok(child_subject) -> {
              let children =
                dict.insert(state.children, channel_id, child_subject)
              process.send(reply, child_subject)
              actor.continue(SupervisorState(..state, children: children))
            }
            Error(_start_err) -> {
              // Failed to start; reply with a fresh dead subject so the caller
              // does not block. In practice start failures are rare and will
              // surface in logs from gleam_otp.
              let fallback = process.new_subject()
              process.send(reply, fallback)
              actor.continue(state)
            }
          }
        }
      }
    }

    ChildDown(channel_id:) -> {
      // Remove the entry so the next get_or_start spawns a fresh actor.
      // Process monitoring is wired in Task 4+; this arm is here for forward
      // compatibility.
      let children = dict.delete(state.children, channel_id)
      actor.continue(SupervisorState(..state, children: children))
    }
  }
}
