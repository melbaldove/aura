//// Dynamic per-channel actor supervisor.
////
//// Owns a `Dict(channel_key, Subject(ChannelMessage))`. Callers pass a
//// platform-qualified key (for example, `discord:123`) so two transports can
//// reuse native channel IDs without sharing actor state.

import aura/channel_actor
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Down, type Monitor, type Pid, type Subject}
import gleam/list
import gleam/otp/actor
import gleam/result
import gleam/string

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

type ChildRef {
  ChildRef(
    subject: Subject(channel_actor.ChannelMessage),
    pid: Pid,
    monitor: Monitor,
  )
}

pub opaque type SupervisorMessage {
  GetOrStart(
    channel_key: String,
    deps: channel_actor.Deps,
    reply: Subject(Result(Subject(channel_actor.ChannelMessage), String)),
  )
  ChildDown(channel_key: String)
  MonitorDown(Down)
}

type SupervisorState {
  SupervisorState(
    children: Dict(String, ChildRef),
    self: Subject(SupervisorMessage),
  )
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Start the channel supervisor actor.
pub fn start() -> Result(Subject(SupervisorMessage), actor.StartError) {
  actor.new_with_initialiser(5000, fn(self_subject) {
    let state = SupervisorState(children: dict.new(), self: self_subject)
    let selector =
      process.new_selector()
      |> process.select(self_subject)
      |> process.select_monitors(MonitorDown)
    Ok(
      actor.initialised(state)
      |> actor.selecting(selector)
      |> actor.returning(self_subject),
    )
  })
  |> actor.on_message(handle_message)
  |> actor.start
  |> result.map(fn(started) { started.data })
}

/// Return the existing actor subject for `channel_key`, or start a new one
/// using `deps` and cache it. Same key always returns the same subject while
/// the child is alive.
pub fn get_or_start(
  sup: Subject(SupervisorMessage),
  channel_key: String,
  deps: channel_actor.Deps,
) -> Result(Subject(channel_actor.ChannelMessage), String) {
  process.call(sup, 5000, fn(reply) {
    GetOrStart(channel_key: channel_key, deps: deps, reply: reply)
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
    GetOrStart(channel_key:, deps:, reply:) -> {
      case dict.get(state.children, channel_key) {
        Ok(existing) -> {
          case process.is_alive(existing.pid) {
            True -> {
              process.send(reply, Ok(existing.subject))
              actor.continue(state)
            }
            False -> {
              let cleaned = remove_child(state, channel_key)
              start_child(cleaned, channel_key, deps, reply)
            }
          }
        }
        Error(Nil) -> start_child(state, channel_key, deps, reply)
      }
    }

    ChildDown(channel_key:) -> {
      actor.continue(remove_child(state, channel_key))
    }

    MonitorDown(down) -> {
      let next_state = case down {
        process.ProcessDown(monitor:, ..) ->
          case find_channel_for_monitor(state.children, monitor) {
            Ok(channel_key) -> remove_child(state, channel_key)
            Error(Nil) -> state
          }
        process.PortDown(..) -> state
      }
      actor.continue(next_state)
    }
  }
}

fn start_child(
  state: SupervisorState,
  channel_key: String,
  deps: channel_actor.Deps,
  reply: Subject(Result(Subject(channel_actor.ChannelMessage), String)),
) -> actor.Next(SupervisorState, SupervisorMessage) {
  case channel_actor.start(deps) {
    Ok(child_subject) -> {
      case process.subject_owner(child_subject) {
        Ok(pid) -> {
          let monitor = process.monitor(pid)
          // The supervisor owns child lifecycle via explicit monitors. Leaving
          // the actor.start link in place would let a child crash kill the cache.
          process.unlink(pid)
          let child =
            ChildRef(subject: child_subject, pid: pid, monitor: monitor)
          let children = dict.insert(state.children, channel_key, child)
          let next_state = SupervisorState(..state, children: children)
          process.send(reply, Ok(child_subject))
          actor.continue(next_state)
        }
        Error(Nil) -> {
          process.send(reply, Error("channel actor started without an owner"))
          actor.continue(state)
        }
      }
    }
    Error(start_err) -> {
      process.send(
        reply,
        Error("failed to start channel actor: " <> string.inspect(start_err)),
      )
      actor.continue(state)
    }
  }
}

fn remove_child(state: SupervisorState, channel_key: String) -> SupervisorState {
  case dict.get(state.children, channel_key) {
    Ok(child) -> {
      process.demonitor_process(child.monitor)
      let children = dict.delete(state.children, channel_key)
      SupervisorState(..state, children: children)
    }
    Error(Nil) -> state
  }
}

fn find_channel_for_monitor(
  children: Dict(String, ChildRef),
  monitor: Monitor,
) -> Result(String, Nil) {
  children
  |> dict.to_list
  |> list.find_map(fn(entry) {
    case entry {
      #(channel_key, child) if child.monitor == monitor -> Ok(channel_key)
      _ -> Error(Nil)
    }
  })
}
