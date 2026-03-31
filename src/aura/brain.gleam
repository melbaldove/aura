import aura/acp/manager
import aura/acp/monitor as acp_monitor
import aura/acp/types as acp_types
import aura/config
import aura/conversation
import aura/db
import aura/discord
import aura/discord/rest
import aura/llm
import aura/memory
import aura/models
import aura/notification
import aura/skill
import aura/structured_memory
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
import gleam/option.{type Option, None, Some}
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
  StoreExchange(channel_id: String, user_msg: String, assistant_msg: String)
}

pub type BrainState {
  BrainState(
    discord_token: String,
    guild_id: String,
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
    skills_dir: String,
    db_subject: process.Subject(db.DbMessage),
    conversations: conversation.Buffers,
    self_subject: Option(process.Subject(BrainMessage)),
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
  memory_content: String,
  user_content: String,
) -> String {
  let ws_section = case workstream_names {
    [] -> "\n\nNo workstreams configured yet."
    names -> "\n\nActive workstreams: " <> string.join(names, ", ")
  }

  let skills_section = case skill_names {
    [] -> "\nNo skills installed."
    names -> "\nInstalled skills: " <> string.join(names, ", ")
  }

  let memory_section = case memory_content {
    "" -> ""
    content -> "\n\n## Memory\n" <> content
  }

  let user_section = case user_content {
    "" -> ""
    content -> "\n\n## User Profile\n" <> content
  }

  "You are responding in a Discord server. Stay in character.\n\n"
  <> soul_content
  <> "\n\nKeep responses concise and direct. Use Discord markdown where appropriate."
  <> ws_section
  <> skills_section
  <> memory_section
  <> user_section
  <> "\n\nTool usage rules:"
  <> "\n- Use tools only when needed to answer the question. Most questions can be answered from context."
  <> "\n- Be efficient: 1-2 tool calls max per response. Do NOT recursively explore directories."
  <> "\n- If you already know the answer from the system context above, respond directly without tools."
  <> "\n- For workstream creation, use the propose tool to request approval."
  <> "\n\nMemory guidance:"
  <> "\nYou have persistent memory across sessions. Save durable facts using the memory tool: user preferences, environment details, tool quirks, and stable conventions. Memory is injected into every turn, so keep it compact and focused on facts that will still matter later."
  <> "\nPrioritize what reduces future user steering — the most valuable memory is one that prevents the user from having to correct or remind you again."
  <> "\nDo NOT save: task progress, session outcomes, completed-work logs, temporary TODO state, trivial info, or easily re-discovered facts."
  <> "\n\nSkills guidance:"
  <> "\nAfter completing a complex task (3+ tool calls), fixing a tricky error, or discovering a non-trivial workflow, save the approach as a skill with create_skill so you can reuse it next time."
  <> "\nWhen using a skill and finding it outdated, incomplete, or wrong, update it immediately with create_skill — don't wait to be asked."
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
  db_subject: process.Subject(db.DbMessage),
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

  let base_state =
    BrainState(
      discord_token: config.discord.token,
      guild_id: config.discord.guild,
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
      skills_dir: xdg.skills_dir(paths),
      db_subject: db_subject,
      conversations: conversation.new(),
      self_subject: None,
    )

  actor.new_with_initialiser(10_000, fn(self_subject) {
    let state = BrainState(..base_state, self_subject: Some(self_subject), conversations: conversation.new())
    Ok(actor.initialised(state) |> actor.returning(self_subject))
  })
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
          let subj = state.self_subject
          process.spawn_unlinked(fn() {
            handle_with_llm(state, msg, subj)
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
    StoreExchange(channel_id, user_msg, assistant_msg) -> {
      // Write through to database
      let now = erlang_system_time_ms()
      let _ = case db.resolve_conversation(state.db_subject, "discord", channel_id, now) {
        Ok(convo_id) -> conversation.save_to_db(state.db_subject, convo_id, user_msg, assistant_msg, "", "", now)
        Error(e) -> {
          io.println("[brain] DB write failed: " <> e)
          Ok(Nil)
        }
      }

      // Update in-memory cache (load from DB if not in memory)
      let #(hydrated, _, _) = conversation.get_or_load_db(state.conversations, state.db_subject, "discord", channel_id, now)
      let new_convos = conversation.append(hydrated, channel_id, user_msg, assistant_msg)

      // Compress if needed
      let final_convos = case conversation.needs_compression(new_convos, channel_id, 200_000) {
        True -> {
          io.println("[brain] Compressing conversation for " <> channel_id)
          conversation.compress_buffer(new_convos, channel_id, state.llm_config)
        }
        False -> new_convos
      }

      actor.continue(BrainState(..state, conversations: final_convos))
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
      handle_with_llm(state, msg, state.self_subject)
    }
  }
}

/// Spawn a process that sends typing indicators every 8 seconds.
/// Returns the PID of the typing process. Kill it to stop.
fn start_typing_loop(
  token: String,
  channel_id: String,
) -> process.Pid {
  process.spawn_unlinked(fn() {
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

fn handle_with_llm(
  state: BrainState,
  msg: discord.IncomingMessage,
  brain_subject_opt: Option(process.Subject(BrainMessage)),
) -> Nil {
  io.println("[brain] Processing message from " <> msg.author_name <> " in channel " <> msg.channel_id)

  // Start a typing indicator loop that refreshes every 8 seconds
  let typing_stop = start_typing_loop(state.discord_token, msg.channel_id)

  let ws_names = list.map(state.workstreams, fn(ws) { ws.name })
  let memory_content = case structured_memory.format_for_display(xdg.memory_path(state.paths)) {
    Ok(c) -> c
    Error(_) -> ""
  }
  let user_content = case structured_memory.format_for_display(xdg.user_path(state.paths)) {
    Ok(c) -> c
    Error(_) -> ""
  }
  let system_prompt = build_system_prompt(state.soul, ws_names, state.skill_names, memory_content, user_content)

  // Load conversation history (from memory or DB)
  let now_ts = erlang_system_time_ms()
  let #(_, _, history) = conversation.get_or_load_db(state.conversations, state.db_subject, "discord", msg.channel_id, now_ts)
  let initial_messages = list.flatten([
    [llm.SystemMessage(system_prompt)],
    history,
    [llm.UserMessage(msg.content)],
  ])

  let result = tool_loop_progressive(state, msg.channel_id, initial_messages, [], "", 0)

  // Stop typing indicator before sending response
  stop_typing_loop(typing_stop)

  let token = state.discord_token
  let channel_id = msg.channel_id

  case result {
    Ok(#(response_text, traces, msg_id)) -> {
      let full = conversation.format_full_message(traces, response_text)
      case msg_id {
        "" -> {
          let _ = rest.send_message(token, channel_id, full, [])
          Nil
        }
        id -> {
          let _ = rest.edit_message(token, channel_id, id, full)
          Nil
        }
      }
      // Store exchange in conversation history
      case brain_subject_opt {
        Some(subj) -> process.send(subj, StoreExchange(channel_id, msg.content, response_text))
        None -> Nil
      }
    }
    Error(err) -> {
      io.println("[brain] Error: " <> err)
      let _ = rest.send_message(token, channel_id, "Sorry, I encountered an error.", [])
      Nil
    }
  }
}

fn tool_loop_progressive(
  state: BrainState,
  channel_id: String,
  messages: List(llm.Message),
  traces: List(conversation.ToolTrace),
  message_id: String,
  iteration: Int,
) -> Result(#(String, List(conversation.ToolTrace), String), String) {
  case iteration >= 20 {
    True -> Error("Tool loop exceeded maximum iterations")
    False -> {
      case llm.chat_with_tools(state.llm_config, messages, built_in_tools()) {
        Ok(response) -> {
          case response.tool_calls {
            [] -> {
              // No tool calls — return the text response with accumulated traces
              Ok(#(response.content, traces, message_id))
            }
            calls -> {
              // Execute tool calls and continue the loop
              io.println("[brain] " <> int.to_string(list.length(calls)) <> " tool call(s)")

              // Execute each tool and build traces + result messages
              let #(new_traces, tool_results) = list.fold(calls, #(traces, []), fn(acc, call) {
                let #(acc_traces, acc_results) = acc
                io.println("[brain] Tool: " <> call.name)
                let result = execute_tool(state, call)
                let result_preview = string.slice(result, 0, 100)
                io.println("[brain] Result: " <> result_preview)

                let is_error = string.starts_with(result, "Error")
                let trace = conversation.ToolTrace(
                  name: call.name,
                  args: format_tool_args(call.arguments),
                  result: result,
                  is_error: is_error,
                )
                let updated_traces = list.append(acc_traces, [trace])
                let updated_results = list.append(acc_results, [llm.ToolResultMessage(call.id, result)])
                #(updated_traces, updated_results)
              })

              // Format current traces for progressive display
              let progress_text = conversation.format_traces(new_traces) <> "\n\n*Thinking...*"

              // Send or edit message with current trace progress
              let new_message_id = case message_id {
                "" -> {
                  case rest.send_message(state.discord_token, channel_id, progress_text, []) {
                    Ok(id) -> id
                    Error(_) -> ""
                  }
                }
                existing -> {
                  let _ = rest.edit_message(state.discord_token, channel_id, existing, progress_text)
                  existing
                }
              }

              // Build new messages: original + assistant response + tool results
              let new_messages = list.append(messages, [
                llm.AssistantToolCallMessage(response.content, calls),
                ..tool_results
              ])

              tool_loop_progressive(state, channel_id, new_messages, new_traces, new_message_id, iteration + 1)
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
    "list_threads" -> {
      case rest.get_active_threads(state.discord_token, state.guild_id) {
        Ok(threads) -> {
          case threads {
            [] -> "No active threads found."
            _ ->
              list.map(threads, fn(t) {
                let #(id, name, parent_id) = t
                name <> " (id: " <> id <> ", parent: " <> parent_id <> ")"
              })
              |> string.join("\n")
          }
        }
        Error(e) -> "Error: " <> e
      }
    }
    "read_thread" -> {
      let thread_id = get_arg(args, "thread_id")
      let limit = case int.parse(get_arg(args, "limit")) {
        Ok(n) -> n
        Error(_) -> 20
      }
      case rest.get_channel_messages(state.discord_token, thread_id, limit) {
        Ok(messages) -> {
          case messages {
            [] -> "No messages in this thread."
            _ ->
              list.reverse(messages)
              |> list.map(fn(m) {
                let #(author, content) = m
                author <> ": " <> content
              })
              |> string.join("\n")
          }
        }
        Error(e) -> "Error: " <> e
      }
    }
    "create_skill" -> {
      let name = get_arg(args, "name")
      let content = get_arg(args, "content")
      case skill.create(state.skills_dir, name, content) {
        Ok(_) -> "Skill created: " <> name <> ". Available immediately via list_skills and run_skill."
        Error(e) -> "Error: " <> e
      }
    }
    "list_skills" -> {
      case skill.list_with_details(state.skills_dir) {
        Ok(listing) -> listing
        Error(e) -> "Error: " <> e
      }
    }
    "memory" -> {
      let action = get_arg(args, "action")
      let target = get_arg(args, "target")
      let content = get_arg(args, "content")
      let old_text = get_arg(args, "old_text")
      let path = case target {
        "user" -> xdg.user_path(state.paths)
        _ -> xdg.memory_path(state.paths)
      }
      case action {
        "add" -> {
          case structured_memory.add(path, content) {
            Ok(_) -> "Memory saved."
            Error(e) -> "Error: " <> e
          }
        }
        "replace" -> {
          case structured_memory.replace(path, old_text, content) {
            Ok(_) -> "Memory updated."
            Error(e) -> "Error: " <> e
          }
        }
        "remove" -> {
          case structured_memory.remove(path, old_text) {
            Ok(_) -> "Memory entry removed."
            Error(e) -> "Error: " <> e
          }
        }
        "read" -> {
          case structured_memory.format_for_display(path) {
            Ok(display) -> display
            Error(e) -> "Error: " <> e
          }
        }
        _ -> "Error: Unknown action " <> action <> ". Use add, replace, remove, or read."
      }
    }
    "search_sessions" -> {
      let query = get_arg(args, "query")
      let limit = case int.parse(get_arg(args, "limit")) {
        Ok(n) -> n
        Error(_) -> 10
      }
      case db.search(state.db_subject, query, limit) {
        Ok(results) -> {
          case results {
            [] -> "No results found for: " <> query
            _ ->
              list.map(results, fn(r) {
                r.author_name <> " (" <> r.platform <> "): " <> r.snippet
              })
              |> string.join("\n")
          }
        }
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

fn format_tool_args(json_str: String) -> String {
  let args = parse_tool_args(json_str)
  args
  |> list.map(fn(pair) { pair.1 })
  |> string.join(", ")
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
    llm.ToolDefinition(name: "list_threads", description: "List all active threads in the Discord server", parameters: []),
    llm.ToolDefinition(name: "read_thread", description: "Read messages from a Discord thread", parameters: [
      llm.ToolParam(name: "thread_id", param_type: "string", description: "The thread/channel ID to read", required: True),
      llm.ToolParam(name: "limit", param_type: "string", description: "Max messages to fetch (default 20)", required: False),
    ]),
    llm.ToolDefinition(name: "create_skill", description: "Manage skills — your procedural memory. Create reusable approaches for recurring task types. Save as SKILL.md with title, description, and step-by-step instructions. Use after complex tasks (3+ tool calls), tricky error fixes, or discovering non-trivial workflows.", parameters: [
      llm.ToolParam(name: "name", param_type: "string", description: "Skill name (lowercase, hyphens, underscores, e.g. 'deploy-to-prod'). Max 64 chars.", required: True),
      llm.ToolParam(name: "content", param_type: "string", description: "Full SKILL.md content with title, description, and step-by-step instructions", required: True),
    ]),
    llm.ToolDefinition(name: "list_skills", description: "List all available skills with descriptions. Check before creating a new skill to avoid duplicates, or when deciding which skill to run.", parameters: []),
    llm.ToolDefinition(name: "memory", description: "Save durable information to persistent memory that survives across sessions. Memory is injected into future turns, so keep it compact and focused on facts that will still matter later. Save when: user corrects you or says 'remember this', user shares preferences/habits/personal details, you discover environment facts (OS, tools, project structure), you learn conventions or quirks. Priority: user preferences and corrections > environment facts > procedural knowledge. Do NOT save: task progress, session outcomes, completed-work logs, temporary TODO state, trivial or easily re-discovered facts.", parameters: [
      llm.ToolParam(name: "action", param_type: "string", description: "One of: add, replace, remove, read", required: True),
      llm.ToolParam(name: "target", param_type: "string", description: "'user' (who the user is: name, role, preferences, communication style) or 'memory' (agent notes: environment facts, project conventions, tool quirks, lessons learned)", required: True),
      llm.ToolParam(name: "content", param_type: "string", description: "Entry text (for add/replace)", required: False),
      llm.ToolParam(name: "old_text", param_type: "string", description: "Substring to match (for replace/remove)", required: False),
    ]),
    llm.ToolDefinition(name: "search_sessions", description: "Search past conversations across all channels and platforms by keyword. Returns matching message snippets with context. Use when the user references something from a past conversation or you need to recall previous discussions.", parameters: [
      llm.ToolParam(name: "query", param_type: "string", description: "Search terms", required: True),
      llm.ToolParam(name: "limit", param_type: "string", description: "Max results (default 10)", required: False),
    ]),
  ]
}

@external(erlang, "aura_time_ffi", "system_time_ms")
fn erlang_system_time_ms() -> Int
