import aura/acp/manager
import aura/acp/monitor as acp_monitor
import aura/acp/types as acp_types
import aura/config
import aura/discord
import aura/discord/rest
import aura/llm
import aura/memory
import aura/models
import aura/notification
import aura/workstream
import aura/workstream_sup
import aura/xdg
import gleam/io
import gleam/list
import gleam/otp/actor
import gleam/erlang/process
import gleam/result
import gleam/string

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

pub type WorkstreamInfo {
  WorkstreamInfo(name: String, channel_id: String)
}

pub type RouteDecision {
  DirectRoute(workstream_name: String)
  NeedsClassification
}

pub type BrainMessage {
  HandleMessage(discord.IncomingMessage)
  UpdateWorkstreams(List(WorkstreamInfo))
  HeartbeatFinding(notification.Finding)
  DeliverDigest
  AcpEvent(acp_monitor.AcpEvent)
}

pub type BrainState {
  BrainState(
    discord_token: String,
    llm_config: llm.LlmConfig,
    paths: xdg.Paths,
    workstreams: List(WorkstreamInfo),
    soul: String,
    registry: List(workstream_sup.WorkstreamEntry),
    notification_queue: notification.NotificationQueue,
    aura_channel_id: String,
    acp_manager: manager.AcpManager,
  )
}

// ---------------------------------------------------------------------------
// Pure functions (testable)
// ---------------------------------------------------------------------------

/// Route based on channel_id matching known workstreams
pub fn route_message(
  channel_id: String,
  workstreams: List(WorkstreamInfo),
) -> RouteDecision {
  case list.find(workstreams, fn(ws) { ws.channel_id == channel_id }) {
    Ok(ws) -> DirectRoute(ws.name)
    Error(_) -> NeedsClassification
  }
}

/// Build system prompt from SOUL.md content
pub fn build_system_prompt(soul_content: String) -> String {
  "You are responding in a Discord server. Stay in character.\n\n"
  <> soul_content
  <> "\n\nKeep responses concise and direct. Use Discord markdown where appropriate."
}

/// Build a routing classification prompt (for #aura messages)
pub fn build_routing_prompt(
  message_content: String,
  workstream_names: List(String),
) -> String {
  "Classify the following message into one of these workstreams: "
  <> string.join(workstream_names, ", ")
  <> "\n\nMessage: "
  <> message_content
  <> "\n\nRespond with just the workstream name, or \"none\" if it doesn't match any."
}

// ---------------------------------------------------------------------------
// Actor
// ---------------------------------------------------------------------------

const default_soul = "You are Aura, a helpful AI assistant. Be direct and concise."

/// Start the brain actor
pub fn start(
  config: config.GlobalConfig,
  paths: xdg.Paths,
  workstreams: List(WorkstreamInfo),
  registry: List(workstream_sup.WorkstreamEntry),
  acp_max_concurrent: Int,
) -> Result(process.Subject(BrainMessage), String) {
  // Read SOUL.md
  let soul_file = xdg.soul_path(paths)
  let soul = case memory.read_file(soul_file) {
    Ok(content) -> content
    Error(_) -> {
      io.println("[brain] SOUL.md not found at " <> soul_file <> ", using default")
      default_soul
    }
  }

  // Build LLM config from brain model spec
  use llm_config <- result.try(models.build_llm_config(config.models.brain))

  let state =
    BrainState(
      discord_token: config.discord.token,
      llm_config: llm_config,
      paths: paths,
      workstreams: workstreams,
      soul: soul,
      registry: registry,
      notification_queue: notification.new_queue(),
      aura_channel_id: "",
      acp_manager: manager.new(acp_max_concurrent),
    )

  actor.new(state)
  |> actor.on_message(handle_message)
  |> actor.start
  |> result.map(fn(started) { started.data })
  |> result.map_error(fn(err) {
    "Failed to start brain actor: " <> string.inspect(err)
  })
}

fn handle_message(
  state: BrainState,
  message: BrainMessage,
) -> actor.Next(BrainState, BrainMessage) {
  case message {
    HandleMessage(msg) -> {
      case route_message(msg.channel_id, state.workstreams) {
        DirectRoute(name) -> {
          // Spawn a process to avoid blocking the brain actor
          process.spawn(fn() {
            handle_routed_message(state, name, msg)
          })
          actor.continue(state)
        }
        NeedsClassification -> {
          // Handle directly with brain's LLM (for #aura channel)
          process.spawn(fn() {
            handle_with_llm(state, msg)
          })
          actor.continue(state)
        }
      }
    }
    UpdateWorkstreams(ws) -> {
      io.println("[brain] Updated workstreams: " <> string.inspect(list.length(ws)) <> " entries")
      actor.continue(BrainState(..state, workstreams: ws))
    }
    HeartbeatFinding(finding) -> {
      case notification.is_urgent(finding) {
        True -> {
          // Post urgent findings immediately
          let channel = resolve_finding_channel(state, finding)
          process.spawn(fn() {
            send_discord_response(state.discord_token, channel, "**URGENT** [" <> finding.source <> "] " <> finding.summary)
          })
          actor.continue(state)
        }
        False -> {
          // Queue for digest
          let new_queue = notification.enqueue(state.notification_queue, finding)
          actor.continue(BrainState(..state, notification_queue: new_queue))
        }
      }
    }
    DeliverDigest -> {
      let #(findings, new_queue) = notification.drain(state.notification_queue)
      case findings {
        [] -> actor.continue(BrainState(..state, notification_queue: new_queue))
        _ -> {
          let digest = notification.format_digest(findings)
          let channel = state.aura_channel_id
          case channel {
            "" -> {
              io.println("[brain] No #aura channel configured for digest delivery")
              Nil
            }
            _ -> {
              process.spawn(fn() {
                send_discord_response(state.discord_token, channel, digest)
              })
              Nil
            }
          }
          actor.continue(BrainState(..state, notification_queue: new_queue))
        }
      }
    }
    AcpEvent(event) -> {
      case event {
        acp_monitor.AcpStarted(session_name, workstream, task_id) -> {
          let msg =
            "**ACP Started** — "
            <> task_id
            <> "\n`tmux attach -t "
            <> session_name
            <> "`"
          let channel = resolve_workstream_channel(state, workstream)
          process.spawn(fn() {
            send_discord_response(state.discord_token, channel, msg)
          })
          actor.continue(state)
        }
        acp_monitor.AcpAlert(session_name, workstream, status, summary) -> {
          let status_str = acp_types.status_to_string(status)
          let msg =
            "**ACP Alert** ["
            <> status_str
            <> "] — "
            <> summary
            <> "\n`tmux attach -t "
            <> session_name
            <> "`"
          let channel = resolve_workstream_channel(state, workstream)
          process.spawn(fn() {
            send_discord_response(state.discord_token, channel, msg)
          })
          actor.continue(state)
        }
        acp_monitor.AcpCompleted(session_name, workstream, report) -> {
          let outcome = acp_types.outcome_to_string(report.outcome)
          let msg =
            "**ACP Complete** [" <> outcome <> "] — " <> report.anchor
          handle_acp_completion(state, session_name, workstream, msg)
        }
        acp_monitor.AcpTimedOut(session_name, workstream) -> {
          let msg =
            "**ACP Timeout** — Session still alive. `tmux attach -t "
            <> session_name
            <> "`"
          handle_acp_completion(state, session_name, workstream, msg)
        }
        acp_monitor.AcpFailed(session_name, workstream, error) -> {
          let msg = "**ACP Failed** — " <> error
          handle_acp_completion(state, session_name, workstream, msg)
        }
      }
    }
  }
}

fn handle_acp_completion(
  state: BrainState,
  session_name: String,
  workstream: String,
  msg: String,
) -> actor.Next(BrainState, BrainMessage) {
  let channel = resolve_workstream_channel(state, workstream)
  process.spawn(fn() {
    send_discord_response(state.discord_token, channel, msg)
  })
  let new_manager = manager.unregister(state.acp_manager, session_name)
  actor.continue(BrainState(..state, acp_manager: new_manager))
}

fn resolve_workstream_channel(state: BrainState, workstream: String) -> String {
  case list.find(state.workstreams, fn(ws) { ws.name == workstream }) {
    Ok(ws) -> ws.channel_id
    Error(_) -> state.aura_channel_id
  }
}

fn resolve_finding_channel(state: BrainState, finding: notification.Finding) -> String {
  resolve_workstream_channel(state, finding.workstream)
}

fn handle_routed_message(
  state: BrainState,
  workstream_name: String,
  msg: discord.IncomingMessage,
) -> Nil {
  case list.find(state.registry, fn(e) { e.name == workstream_name }) {
    Ok(entry) -> {
      // Create a subject for receiving the response
      let reply_subject = process.new_subject()

      // Send task to workstream
      process.send(
        entry.subject,
        workstream.HandleTask(message: msg, reply_to: reply_subject),
      )

      // Wait for response (with 60s timeout)
      case process.receive(from: reply_subject, within: 60_000) {
        Ok(response) -> {
          case response {
            workstream.WorkstreamResponse(_, channel_id, content) ->
              send_discord_response(state.discord_token, channel_id, content)
            workstream.WorkstreamError(_, channel_id, error) -> {
              io.println("[brain] Workstream error: " <> error)
              send_discord_response(
                state.discord_token,
                channel_id,
                "Sorry, I encountered an error.",
              )
            }
          }
        }
        Error(Nil) -> {
          io.println(
            "[brain] Workstream " <> workstream_name <> " timed out",
          )
          send_discord_response(
            state.discord_token,
            msg.channel_id,
            "Request timed out.",
          )
        }
      }
    }
    Error(Nil) -> {
      io.println("[brain] Workstream not found: " <> workstream_name)
      handle_with_llm(state, msg)
    }
  }
}

fn send_discord_response(token: String, channel_id: String, content: String) -> Nil {
  case rest.send_message(token, channel_id, content, []) {
    Ok(_) -> Nil
    Error(err) -> {
      io.println("[brain] Failed to send message: " <> err)
      Nil
    }
  }
}

fn handle_with_llm(state: BrainState, msg: discord.IncomingMessage) -> Nil {
  let prompt = build_system_prompt(state.soul)
  let messages = [llm.SystemMessage(prompt), llm.UserMessage(msg.content)]

  case llm.chat(state.llm_config, messages) {
    Ok(response) -> send_discord_response(state.discord_token, msg.channel_id, response)
    Error(err) -> {
      io.println("[brain] LLM error: " <> err)
      send_discord_response(state.discord_token, msg.channel_id, "Sorry, I encountered an error processing your message.")
    }
  }
}
