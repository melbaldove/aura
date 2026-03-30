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
import aura/skill
import aura/tools
import aura/validator
import aura/workstream
import aura/workstream_sup
import aura/xdg
import gleam/dict
import gleam/dynamic/decode
import gleam/int
import gleam/io
import gleam/json
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
  PostWelcome(channel_id: String)
}

pub type BrainState {
  BrainState(
    discord_token: String,
    llm_config: llm.LlmConfig,
    paths: xdg.Paths,
    workstreams: List(WorkstreamInfo),
    soul: String,
    skill_names: List(String),
    registry: List(workstream_sup.WorkstreamEntry),
    notification_queue: notification.NotificationQueue,
    aura_channel_id: String,
    acp_manager: manager.AcpManager,
    validation_rules: List(validator.Rule),
    skill_infos: List(skill.SkillInfo),
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
pub fn build_system_prompt(
  soul_content: String,
  workstream_names: List(String),
  skill_names: List(String),
) -> String {
  let ws_section = case workstream_names {
    [] -> "\n\nNo workstreams configured yet."
    names -> "\n\nActive workstreams: " <> string.join(names, ", ")
  }

  let skills_section = case skill_names {
    [] -> "\nNo skills installed."
    names -> "\nInstalled skills: " <> string.join(names, ", ")
  }

  "You are responding in a Discord server. Stay in character.\n\n"
  <> soul_content
  <> "\n\nKeep responses concise and direct. Use Discord markdown where appropriate."
  <> ws_section
  <> skills_section
  <> "\n\nYou can create workstreams when users ask. To create a workstream, respond with a structured command block:\n"
  <> "```aura-command\n"
  <> "CREATE_WORKSTREAM\n"
  <> "name: <slug-name>\n"
  <> "description: <description>\n"
  <> "cwd: <repo-path-or-empty>\n"
  <> "tools: <comma-separated-or-empty>\n"
  <> "```\n"
  <> "Follow this with a confirmation message for the user."
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
  skill_names: List(String),
  acp_max_concurrent: Int,
  validation_rules: List(validator.Rule),
  skill_infos: List(skill.SkillInfo),
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
      skill_names: skill_names,
      registry: registry,
      notification_queue: notification.new_queue(),
      aura_channel_id: "",
      acp_manager: manager.new(acp_max_concurrent),
      validation_rules: validation_rules,
      skill_infos: skill_infos,
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
          io.println("[brain] Route: DirectRoute(" <> name <> ")")
          // Spawn a process to avoid blocking the brain actor
          process.spawn(fn() {
            handle_routed_message(state, name, msg)
          })
          actor.continue(state)
        }
        NeedsClassification -> {
          io.println("[brain] Route: NeedsClassification")
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
    PostWelcome(channel_id) -> {
      case list.is_empty(state.workstreams) {
        True -> {
          let msg = "Aura is online. No workstreams configured yet. Tell me about your first project and I'll set one up."
          process.spawn(fn() {
            send_discord_response(state.discord_token, channel_id, msg)
          })
          actor.continue(BrainState(..state, aura_channel_id: channel_id))
        }
        False -> actor.continue(BrainState(..state, aura_channel_id: channel_id))
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
      // Show typing indicator while workstream processes
      let _ = rest.trigger_typing(state.discord_token, msg.channel_id)

      let reply_subject = process.new_subject()

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

/// Spawn a process that sends typing indicators every 8 seconds.
/// Returns the PID of the typing process. Kill it to stop.
fn start_typing_loop(
  token: String,
  channel_id: String,
) -> process.Pid {
  process.spawn(fn() {
    typing_loop(token, channel_id)
  })
}

fn typing_loop(
  token: String,
  channel_id: String,
) -> Nil {
  let _ = rest.trigger_typing(token, channel_id)
  process.sleep(8000)
  typing_loop(token, channel_id)
}

fn stop_typing_loop(pid: process.Pid) -> Nil {
  process.kill(pid)
}

fn send_discord_response(token: String, channel_id: String, content: String) -> Nil {
  io.println("[brain] Sending to channel " <> channel_id)
  case rest.send_message(token, channel_id, content, []) {
    Ok(_) -> Nil
    Error(err) -> {
      io.println("[brain] Failed to send message: " <> err)
      Nil
    }
  }
}

fn handle_with_llm(state: BrainState, msg: discord.IncomingMessage) -> Nil {
  io.println("[brain] Processing message from " <> msg.author_name <> " in channel " <> msg.channel_id)

  // Start a typing indicator loop that refreshes every 8 seconds
  let typing_stop = start_typing_loop(state.discord_token, msg.channel_id)

  let ws_names = list.map(state.workstreams, fn(ws) { ws.name })
  let system_prompt = build_system_prompt(state.soul, ws_names, state.skill_names)
  let initial_messages = [
    llm.SystemMessage(system_prompt),
    llm.UserMessage(msg.content),
  ]

  let result = tool_loop(state, msg.channel_id, initial_messages, 0)

  // Stop typing indicator before sending response
  stop_typing_loop(typing_stop)
  case result {
    Ok(response_text) -> send_discord_response(state.discord_token, msg.channel_id, response_text)
    Error(err) -> {
      io.println("[brain] Tool loop error: " <> err)
      send_discord_response(state.discord_token, msg.channel_id, "Sorry, I encountered an error.")
    }
  }
}

fn tool_loop(
  state: BrainState,
  channel_id: String,
  messages: List(llm.Message),
  iteration: Int,
) -> Result(String, String) {
  case iteration >= 10 {
    True -> Error("Tool loop exceeded maximum iterations")
    False -> {
      case llm.chat_with_tools(state.llm_config, messages, built_in_tools()) {
        Ok(response) -> {
          case response.tool_calls {
            [] -> {
              // No tool calls — return the text response
              Ok(response.content)
            }
            calls -> {
              // Execute tool calls and continue the loop
              io.println("[brain] " <> int.to_string(list.length(calls)) <> " tool call(s)")
              let tool_results = list.map(calls, fn(call) {
                io.println("[brain] Tool: " <> call.name)
                let result = execute_tool(state, call)
                io.println("[brain] Result: " <> string.slice(result, 0, 100))
                llm.ToolResultMessage(call.id, result)
              })

              // Build new messages: original + assistant response + tool results
              let new_messages = list.append(messages, [
                llm.AssistantToolCallMessage(response.content, calls),
                ..tool_results
              ])

              tool_loop(state, channel_id, new_messages, iteration + 1)
            }
          }
        }
        Error(err) -> Error(err)
      }
    }
  }
}

fn execute_tool(state: BrainState, call: llm.ToolCall) -> String {
  let args = parse_tool_args(call.arguments)

  case call.name {
    "read_file" -> {
      case tools.read_file(state.paths.data, get_arg(args, "path")) {
        Ok(content) -> content
        Error(e) -> "Error: " <> e
      }
    }
    "write_file" -> {
      let path = get_arg(args, "path")
      let content = get_arg(args, "content")
      case tools.write_file(state.paths.data, path, content, state.validation_rules, False) {
        Ok(_) -> "File written: " <> path
        Error(e) -> "Error: " <> e
      }
    }
    "append_file" -> {
      let path = get_arg(args, "path")
      let content = get_arg(args, "content")
      case tools.append_file(state.paths.data, path, content, state.validation_rules, False) {
        Ok(_) -> "Appended to: " <> path
        Error(e) -> "Error: " <> e
      }
    }
    "list_directory" -> {
      case tools.list_directory(state.paths.data, get_arg(args, "path")) {
        Ok(listing) -> listing
        Error(e) -> "Error: " <> e
      }
    }
    "run_skill" -> {
      case tools.run_skill(state.skill_infos, get_arg(args, "name"), get_arg(args, "args")) {
        Ok(output) -> output
        Error(e) -> "Error: " <> e
      }
    }
    "propose" -> {
      case tools.propose(get_arg(args, "description"), get_arg(args, "details")) {
        Ok(output) -> output
        Error(e) -> "Error: " <> e
      }
    }
    _ -> "Error: Unknown tool " <> call.name
  }
}

fn parse_tool_args(json_str: String) -> List(#(String, String)) {
  case json.parse(json_str, decode.dict(decode.string, decode.string)) {
    Ok(d) -> dict.to_list(d)
    Error(_) -> []
  }
}

fn get_arg(args: List(#(String, String)), key: String) -> String {
  case list.find(args, fn(pair) { pair.0 == key }) {
    Ok(#(_, value)) -> value
    Error(_) -> ""
  }
}

fn built_in_tools() -> List(llm.ToolDefinition) {
  [
    llm.ToolDefinition(name: "read_file", description: "Read a file from the Aura workspace", parameters: [
      llm.ToolParam(name: "path", param_type: "string", description: "Relative file path", required: True),
    ]),
    llm.ToolDefinition(name: "write_file", description: "Write content to a workspace file. Logs, anchors, events, MEMORY.md write immediately. Config and identity files require propose() first.", parameters: [
      llm.ToolParam(name: "path", param_type: "string", description: "Relative file path", required: True),
      llm.ToolParam(name: "content", param_type: "string", description: "File content", required: True),
    ]),
    llm.ToolDefinition(name: "append_file", description: "Append content to a workspace file. Same rules as write_file.", parameters: [
      llm.ToolParam(name: "path", param_type: "string", description: "Relative file path", required: True),
      llm.ToolParam(name: "content", param_type: "string", description: "Content to append", required: True),
    ]),
    llm.ToolDefinition(name: "list_directory", description: "List contents of a workspace directory", parameters: [
      llm.ToolParam(name: "path", param_type: "string", description: "Directory path (use '.' for root)", required: True),
    ]),
    llm.ToolDefinition(name: "run_skill", description: "Run an external CLI skill", parameters: [
      llm.ToolParam(name: "name", param_type: "string", description: "Skill name", required: True),
      llm.ToolParam(name: "args", param_type: "string", description: "Arguments string", required: True),
    ]),
    llm.ToolDefinition(name: "propose", description: "Propose a change requiring user approval", parameters: [
      llm.ToolParam(name: "description", param_type: "string", description: "What you want to do", required: True),
      llm.ToolParam(name: "details", param_type: "string", description: "Details of the change", required: True),
    ]),
  ]
}
