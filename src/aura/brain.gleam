import aura/acp/manager
import aura/acp/monitor as acp_monitor
import aura/acp/types as acp_types
import aura/config
import aura/domain
import aura/time
import aura/conversation
import aura/db
import aura/discord
import aura/discord/rest
import aura/llm
import aura/memory
import aura/models
import aura/notification
import aura/scheduler
import aura/skill
import aura/structured_memory
import aura/tools
import aura/validator
import aura/vision
import aura/web
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

/// Maps a domain name to its Discord channel ID for routing.
pub type DomainInfo {
  DomainInfo(name: String, channel_id: String)
}

/// Outcome of routing a Discord message. `DirectRoute` means the channel
/// matched a known domain; `NeedsClassification` means the brain handles
/// it directly.
pub type RouteDecision {
  DirectRoute(domain_name: String)
  NeedsClassification
}

/// Messages the brain actor accepts from other processes and the supervisor.
pub type BrainMessage {
  HandleMessage(discord.IncomingMessage)
  UpdateDomains(List(DomainInfo))
  HeartbeatFinding(notification.Finding)
  DeliverDigest
  AcpEvent(acp_monitor.AcpEvent)
  PostWelcome(channel_id: String)
  StoreExchange(channel_id: String, user_msg: String, assistant_msg: String)
  SetScheduler(process.Subject(scheduler.SchedulerMessage))
}

/// Configuration passed to brain.start — replaces positional params.
pub type BrainConfig {
  BrainConfig(
    global: config.GlobalConfig,
    paths: xdg.Paths,
    soul: String,
    domains: List(DomainInfo),
    domain_configs: List(#(String, config.DomainConfig)),
    skill_infos: List(skill.SkillInfo),
    validation_rules: List(validator.Rule),
    db_subject: process.Subject(db.DbMessage),
  )
}

/// Runtime state of the brain actor. Holds all active handles, caches,
/// and configuration needed to process messages and drive the LLM tool loop.
pub type BrainState {
  BrainState(
    discord_token: String,
    guild_id: String,
    llm_config: llm.LlmConfig,
    paths: xdg.Paths,
    domains: List(DomainInfo),
    soul: String,
    skill_infos: List(skill.SkillInfo),
    notification_queue: notification.NotificationQueue,
    aura_channel_id: String,
    acp_manager: manager.AcpManager,
    validation_rules: List(validator.Rule),
    skills_dir: String,
    db_subject: process.Subject(db.DbMessage),
    built_in_tools: List(llm.ToolDefinition),
    conversations: conversation.Buffers,
    self_subject: Option(process.Subject(BrainMessage)),
    global_config: config.GlobalConfig,
    domain_configs: List(#(String, config.DomainConfig)),
    scheduler_subject: Option(process.Subject(scheduler.SchedulerMessage)),
  )
}

// ---------------------------------------------------------------------------
// Pure functions (testable)
// ---------------------------------------------------------------------------

/// Route based on channel_id matching known domains
pub fn route_message(
  channel_id: String,
  domains: List(DomainInfo),
) -> RouteDecision {
  case list.find(domains, fn(d) { d.channel_id == channel_id }) {
    Ok(d) -> DirectRoute(d.name)
    Error(_) -> NeedsClassification
  }
}

/// Build system prompt from SOUL.md content
pub fn build_system_prompt(
  soul_content: String,
  domain_names: List(String),
  skill_infos: List(skill.SkillInfo),
  memory_content: String,
  user_content: String,
) -> String {
  let ws_section = case domain_names {
    [] -> "\n\nNo domains configured yet."
    names -> "\n\nActive domains: " <> string.join(names, ", ")
  }

  let skill_lines = list.map(skill_infos, fn(s) {
    "- " <> s.name <> ": " <> s.description
  })
  let skills_section = case skill_lines {
    [] -> "\nNo skills installed."
    lines -> "\nInstalled skills:\n" <> string.join(lines, "\n")
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
  <> "\n- Do NOT recursively explore directories."
  <> "\n- If you already know the answer from the system context above, respond directly without tools."
  <> "\n- NEVER fabricate tool results. If you need data (calendar events, tickets, files), you MUST call the tool. Do not generate fake data from memory of past results."
  <> "\n- For domain creation, use the propose tool to request approval."
  <> "\n\nMemory guidance:"
  <> "\nYou have persistent memory across sessions. Save durable facts using the memory tool: user preferences, environment details, tool quirks, and stable conventions. Memory is injected into every turn, so keep it compact and focused on facts that will still matter later."
  <> "\nPrioritize what reduces future user steering — the most valuable memory is one that prevents the user from having to correct or remind you again."
  <> "\nDo NOT save: task progress, session outcomes, completed-work logs, temporary TODO state, trivial info, or easily re-discovered facts."
  <> "\n\nSkills guidance:"
  <> "\nBefore using run_skill, call view_skill first to read the skill's full instructions. The instructions contain exact commands, argument format, and examples. Never guess CLI syntax."
  <> "\nAfter completing a complex task (3+ tool calls), fixing a tricky error, or discovering a non-trivial workflow, save the approach as a skill with create_skill so you can reuse it next time."
  <> "\nWhen using a skill and finding it outdated, incomplete, or wrong, update it immediately with create_skill — don't wait to be asked."
}

/// Build a routing classification prompt (for #aura messages)
pub fn build_routing_prompt(
  message_content: String,
  domain_names: List(String),
) -> String {
  "Classify the following message into one of these domains: "
  <> string.join(domain_names, ", ")
  <> "\n\nMessage: "
  <> message_content
  <> "\n\nRespond with just the domain name, or \"none\" if it doesn't match any."
}

// ---------------------------------------------------------------------------
// Actor
// ---------------------------------------------------------------------------

const default_soul = "You are Aura, a helpful AI assistant. Be direct and concise."

/// Start the brain actor
pub fn start(
  brain_config: BrainConfig,
) -> Result(process.Subject(BrainMessage), String) {
  let config = brain_config.global
  // Build LLM config from brain model spec
  use llm_config <- result.try(models.build_llm_config(config.models.brain))

  let base_state =
    BrainState(
      discord_token: config.discord.token,
      guild_id: config.discord.guild,
      llm_config: llm_config,
      paths: brain_config.paths,
      domains: brain_config.domains,
      soul: brain_config.soul,

      notification_queue: notification.new_queue(),
      aura_channel_id: "",
      acp_manager: manager.new(config.acp_global_max_concurrent),
      validation_rules: brain_config.validation_rules,
      skill_infos: brain_config.skill_infos,
      skills_dir: xdg.skills_dir(brain_config.paths),
      db_subject: brain_config.db_subject,
      built_in_tools: make_built_in_tools(),
      conversations: conversation.new(),
      self_subject: None,
      global_config: brain_config.global,
      domain_configs: brain_config.domain_configs,
      scheduler_subject: None,
    )

  actor.new_with_initialiser(10_000, fn(self_subject) {
    let state = BrainState(..base_state, self_subject: Some(self_subject))
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
      let domain_name = case route_message(msg.channel_id, state.domains) {
        DirectRoute(name) -> {
          io.println("[brain] Route: " <> name)
          Some(name)
        }
        NeedsClassification -> {
          io.println("[brain] Route: #aura")
          None
        }
      }
      let subj = state.self_subject
      process.spawn_unlinked(fn() {
        handle_with_llm(state, msg, subj, domain_name)
      })
      actor.continue(state)
    }
    UpdateDomains(domains) -> {
      io.println("[brain] Updated domains: " <> string.inspect(list.length(domains)) <> " entries")
      actor.continue(BrainState(..state, domains: domains))
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
      case list.is_empty(state.domains) {
        True -> {
          let msg = "Aura is online. No domains configured yet. Tell me about your first project and I'll set one up."
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
        acp_monitor.AcpStarted(session_name, domain, task_id) -> {
          let msg =
            "**ACP Started** — "
            <> task_id
            <> "\n`tmux attach -t "
            <> session_name
            <> "`"
          let channel = resolve_domain_channel(state, domain)
          process.spawn(fn() {
            send_discord_response(state.discord_token, channel, msg)
          })
          actor.continue(state)
        }
        acp_monitor.AcpAlert(session_name, domain, status, summary) -> {
          let status_str = acp_types.status_to_string(status)
          let msg =
            "**ACP Alert** ["
            <> status_str
            <> "] — "
            <> summary
            <> "\n`tmux attach -t "
            <> session_name
            <> "`"
          let channel = resolve_domain_channel(state, domain)
          process.spawn(fn() {
            send_discord_response(state.discord_token, channel, msg)
          })
          actor.continue(state)
        }
        acp_monitor.AcpCompleted(session_name, domain, report) -> {
          let outcome = acp_types.outcome_to_string(report.outcome)
          let msg =
            "**ACP Complete** [" <> outcome <> "] — " <> report.anchor
          handle_acp_completion(state, session_name, domain, msg)
        }
        acp_monitor.AcpTimedOut(session_name, domain) -> {
          let msg =
            "**ACP Timeout** — Session still alive. `tmux attach -t "
            <> session_name
            <> "`"
          handle_acp_completion(state, session_name, domain, msg)
        }
        acp_monitor.AcpFailed(session_name, domain, error) -> {
          let msg = "**ACP Failed** — " <> error
          handle_acp_completion(state, session_name, domain, msg)
        }
      }
    }
    StoreExchange(channel_id, user_msg, assistant_msg) -> {
      // DB write already done by the spawned process before Discord delivery.
      // This handler only updates the in-memory cache.
      let now = time.now_ms()
      let cache_key = "discord:" <> channel_id
      let #(hydrated, _, _) = conversation.get_or_load_db(state.conversations, state.db_subject, "discord", channel_id, now)
      let new_convos = conversation.append(hydrated, cache_key, user_msg, assistant_msg)

      // Compress if needed
      let final_convos = case conversation.needs_compression(new_convos, cache_key, 200_000) {
        True -> {
          io.println("[brain] Compressing conversation for " <> cache_key)
          conversation.compress_buffer(new_convos, cache_key, state.llm_config)
        }
        False -> new_convos
      }

      actor.continue(BrainState(..state, conversations: final_convos))
    }
    SetScheduler(subject) -> {
      io.println("[brain] Scheduler connected")
      actor.continue(BrainState(..state, scheduler_subject: Some(subject)))
    }
  }
}

fn handle_acp_completion(
  state: BrainState,
  session_name: String,
  domain: String,
  msg: String,
) -> actor.Next(BrainState, BrainMessage) {
  let channel = resolve_domain_channel(state, domain)
  process.spawn(fn() {
    send_discord_response(state.discord_token, channel, msg)
  })
  let new_manager = manager.unregister(state.acp_manager, session_name)
  actor.continue(BrainState(..state, acp_manager: new_manager))
}

fn resolve_domain_channel(state: BrainState, domain: String) -> String {
  case list.find(state.domains, fn(d) { d.name == domain }) {
    Ok(d) -> d.channel_id
    Error(_) -> state.aura_channel_id
  }
}

fn resolve_finding_channel(state: BrainState, finding: notification.Finding) -> String {
  resolve_domain_channel(state, finding.domain)
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

/// Send a new message or edit an existing one. Returns the message ID.
fn send_or_edit(
  token: String,
  channel_id: String,
  msg_id: String,
  content: String,
) -> String {
  case msg_id {
    "" -> {
      case rest.send_message(token, channel_id, content, []) {
        Ok(id) -> id
        Error(_) -> ""
      }
    }
    existing -> {
      let _ = rest.edit_message(token, channel_id, existing, content)
      existing
    }
  }
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
  domain_name: Option(String),
) -> Nil {
  io.println("[brain] Processing message from " <> msg.author_name <> " in channel " <> msg.channel_id)

  // Start a typing indicator loop that refreshes every 8 seconds
  let typing_stop = start_typing_loop(state.discord_token, msg.channel_id)

  let ws_names = list.map(state.domains, fn(d) { d.name })
  let memory_content = case structured_memory.format_for_display(xdg.memory_path(state.paths)) {
    Ok(c) -> c
    Error(_) -> ""
  }
  let user_content = case structured_memory.format_for_display(xdg.user_path(state.paths)) {
    Ok(c) -> c
    Error(_) -> ""
  }
  let system_prompt = build_system_prompt(state.soul, ws_names, state.skill_infos, memory_content, user_content)

  // Load domain context if routed to a domain
  let domain_prompt = case domain_name {
    Some(name) -> {
      let config_dir = xdg.domain_config_dir(state.paths, name)
      let data_dir = xdg.domain_data_dir(state.paths, name)
      let ctx = domain.load_context(config_dir, data_dir, state.skill_infos)
      "\n\n" <> domain.build_domain_prompt(ctx)
    }
    None -> ""
  }
  let system_prompt = system_prompt <> domain_prompt

  // Vision preprocessing — describe attached images before tool loop
  let enriched_content = case msg.attachments {
    [] -> msg.content
    attachments -> {
      let image_urls = vision.extract_image_urls(attachments)
      case image_urls {
        [] -> msg.content
        [first_url, ..] -> {
          // Resolve vision config for this domain
          let domain_config = case domain_name {
            Some(name) -> {
              case list.find(state.domain_configs, fn(dc) { dc.0 == name }) {
                Ok(#(_, cfg)) -> Some(cfg)
                Error(_) -> None
              }
            }
            None -> None
          }
          let vision_config = vision.resolve_vision_config(state.global_config, domain_config)
          case vision.is_enabled(vision_config) {
            False -> {
              io.println("[brain] Vision not configured, skipping image")
              msg.content
            }
            True -> {
              io.println("[brain] Processing image attachment: " <> first_url)
              case describe_image(vision_config, first_url) {
                Ok(description) -> {
                  io.println("[brain] Vision description: " <> string.slice(description, 0, 100))
                  "[Image: " <> description <> "]\n\n" <> msg.content
                }
                Error(err) -> {
                  io.println("[brain] Vision error: " <> err)
                  msg.content
                }
              }
            }
          }
        }
      }
    }
  }

  // Load conversation history (from memory or DB)
  let now_ts = time.now_ms()
  let #(_, _, history) = conversation.get_or_load_db(state.conversations, state.db_subject, "discord", msg.channel_id, now_ts)
  io.println("[brain] Loaded " <> int.to_string(list.length(history)) <> " history messages for " <> msg.channel_id)

  // Log what the LLM will see (for debugging context issues)
  list.each(history, fn(m) {
    let #(role, content) = case m {
      llm.SystemMessage(c) -> #("system", c)
      llm.UserMessage(c) -> #("user", c)
      llm.UserMessageWithImage(c, _) -> #("user+image", c)
      llm.AssistantMessage(c) -> #("assistant", c)
      llm.AssistantToolCallMessage(c, _) -> #("assistant+tools", c)
      llm.ToolResultMessage(_, c) -> #("tool", c)
    }
    io.println("[brain] history [" <> role <> "]: " <> string.slice(content, 0, 80))
  })

  let initial_messages = list.flatten([
    [llm.SystemMessage(system_prompt)],
    history,
    [llm.UserMessage(enriched_content)],
  ])

  let result = tool_loop_progressive(state, msg.channel_id, initial_messages, [], "", 0)

  // Stop typing indicator before any final edits
  stop_typing_loop(typing_stop)

  let token = state.discord_token
  let channel_id = msg.channel_id

  case result {
    Ok(#(response_text, traces, msg_id)) -> {
      // Save to DB FIRST — before Discord delivery — so the next turn sees this exchange
      let now = time.now_ms()
      case db.resolve_conversation(state.db_subject, "discord", channel_id, now) {
        Ok(convo_id) -> {
          case conversation.save_to_db(state.db_subject, convo_id, enriched_content, response_text, msg.author_id, msg.author_name, now) {
            Ok(_) -> Nil
            Error(e) -> io.println("[brain] DB save failed for " <> channel_id <> ": " <> e)
          }
        }
        Error(e) -> io.println("[brain] Failed to resolve conversation for " <> channel_id <> ": " <> e)
      }

      let full = conversation.format_full_message(traces, response_text)
      let _ = send_or_edit(token, channel_id, msg_id, full)

      // Update in-memory cache (async via actor mailbox — not blocking)
      case brain_subject_opt {
        Some(subj) -> process.send(subj, StoreExchange(channel_id, enriched_content, response_text))
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

/// Drain any remaining stream messages from the mailbox.
fn drain_stream_messages() -> Nil {
  case receive_stream_message(0) {
    StreamTimeout -> Nil
    StreamDone -> Nil
    StreamComplete(_, _) -> Nil
    StreamError(_) -> Nil
    StreamDelta(_) -> drain_stream_messages()
    StreamReasoning -> drain_stream_messages()
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
      // Spawn streaming LLM call with tools
      let self_pid = process.self()
      let _ = process.spawn_unlinked(fn() {
        llm.chat_streaming_with_tools(state.llm_config, messages, state.built_in_tools, self_pid)
      })

      // Collect the streaming response (content + tool calls)
      case collect_stream_response(state.discord_token, channel_id, message_id, traces, 120_000) {
        Ok(#(content, tool_calls_json, msg_id)) -> {
          let response = parse_streaming_result(content, tool_calls_json)
          case response.tool_calls {
            [] -> {
              // No tool calls — return the text response with accumulated traces
              Ok(#(response.content, traces, msg_id))
            }
            calls -> {
              // Execute tool calls and continue the loop
              io.println("[brain] " <> int.to_string(list.length(calls)) <> " tool call(s)")

              // Execute each tool and build traces + result messages
              let #(new_traces, tool_results) = list.fold(calls, #(traces, []), fn(acc, call) {
                let #(acc_traces, acc_results) = acc
                io.println("[brain] Tool: " <> call.name <> " args: " <> call.arguments)
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
              let new_message_id = send_or_edit(state.discord_token, channel_id, message_id, progress_text)

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

/// Collect a streaming LLM response, progressively editing Discord.
/// Returns (content, tool_calls_json, message_id).
fn collect_stream_response(
  token: String,
  channel_id: String,
  message_id: String,
  traces: List(conversation.ToolTrace),
  timeout_ms: Int,
) -> Result(#(String, String, String), String) {
  collect_stream_loop(token, channel_id, message_id, traces, "", 0, timeout_ms)
}

fn collect_stream_loop(
  token: String,
  channel_id: String,
  msg_id: String,
  traces: List(conversation.ToolTrace),
  accumulated: String,
  last_edit_len: Int,
  remaining_ms: Int,
) -> Result(#(String, String, String), String) {
  case remaining_ms <= 0 {
    True -> Error("Stream timeout")
    False -> {
      let wait = case remaining_ms > 500 { True -> 500 False -> remaining_ms }
      case receive_stream_message(wait) {
        StreamDelta(delta) -> {
          let new_acc = accumulated <> delta
          // Progressive edit every 150 chars
          let #(new_msg_id, new_edit_len) = case string.length(new_acc) - last_edit_len > 150 {
            True -> {
              let display = conversation.format_full_message(traces, new_acc <> " ...")
              #(send_or_edit(token, channel_id, msg_id, display), string.length(new_acc))
            }
            False -> #(msg_id, last_edit_len)
          }
          // Data received — reset idle timeout to 120s
          collect_stream_loop(token, channel_id, new_msg_id, traces, new_acc, new_edit_len, 120_000)
        }
        StreamReasoning -> {
          // GLM-5.1 thinking — stream is alive, reset idle timeout
          collect_stream_loop(token, channel_id, msg_id, traces, accumulated, last_edit_len, 120_000)
        }
        StreamComplete(content, tool_calls_json) -> {
          // Stream finished — do final Discord edit if we have content
          let final_msg_id = case string.length(content) > 0 && string.length(content) != last_edit_len {
            True -> {
              let display = conversation.format_full_message(traces, content)
              send_or_edit(token, channel_id, msg_id, display)
            }
            False -> msg_id
          }
          Ok(#(content, tool_calls_json, final_msg_id))
        }
        StreamDone -> {
          // Legacy done signal — treat as complete with no tool calls
          Ok(#(accumulated, "[]", msg_id))
        }
        StreamError(err) -> Error("Stream error: " <> err)
        StreamTimeout -> {
          collect_stream_loop(token, channel_id, msg_id, traces, accumulated, last_edit_len, remaining_ms - wait)
        }
      }
    }
  }
}

/// Parse the streaming result into an LlmResponse.
fn parse_streaming_result(content: String, tool_calls_json: String) -> llm.LlmResponse {
  case tool_calls_json {
    "[]" -> llm.LlmResponse(content: content, tool_calls: [])
    json_str -> {
      // Parse tool calls from JSON: [{"id":"...","name":"...","arguments":"..."}]
      case parse_tool_calls_json(json_str) {
        Ok(calls) -> llm.LlmResponse(content: content, tool_calls: calls)
        Error(_) -> llm.LlmResponse(content: content, tool_calls: [])
      }
    }
  }
}

fn parse_tool_calls_json(json_str: String) -> Result(List(llm.ToolCall), String) {
  let decoder = decode.list({
    use id <- decode.field("id", decode.string)
    use name <- decode.field("name", decode.string)
    use arguments <- decode.field("arguments", decode.string)
    decode.success(llm.ToolCall(id: id, name: name, arguments: arguments))
  })
  json.parse(json_str, decoder)
  |> result.map_error(fn(_) { "Failed to parse tool calls JSON" })
}

fn execute_tool(state: BrainState, call: llm.ToolCall) -> String {
  let args = parse_tool_args(call.arguments)
  case get_arg(args, "_parse_error") {
    "" -> execute_tool_dispatch(state, call.name, args)
    raw -> {
      io.println("[brain] Failed to parse tool args for " <> call.name <> ": " <> string.slice(raw, 0, 200))
      "Error: failed to parse tool arguments. Check the argument format and try again."
    }
  }
}

fn execute_tool_dispatch(state: BrainState, name: String, args: List(#(String, String))) -> String {
  case name {
    "read_file" -> {
      case require_arg(args, "path") {
        Error(e) -> e
        Ok(path) -> {
          case tools.read_file(state.paths.data, path) {
            Ok(content) -> content
            Error(e) -> "Error: " <> e
          }
        }
      }
    }
    "write_file" -> {
      case require_arg(args, "path") {
        Error(e) -> e
        Ok(path) -> case require_arg(args, "content") {
          Error(e) -> e
          Ok(content) -> {
            case tools.write_file(state.paths.data, path, content, state.validation_rules, False) {
              Ok(_) -> "File written: " <> path
              Error(e) -> "Error: " <> e
            }
          }
        }
      }
    }
    "append_file" -> {
      case require_arg(args, "path") {
        Error(e) -> e
        Ok(path) -> case require_arg(args, "content") {
          Error(e) -> e
          Ok(content) -> {
            case tools.append_file(state.paths.data, path, content, state.validation_rules, False) {
              Ok(_) -> "Appended to: " <> path
              Error(e) -> "Error: " <> e
            }
          }
        }
      }
    }
    "list_directory" -> {
      case require_arg(args, "path") {
        Error(e) -> e
        Ok(path) -> {
          case tools.list_directory(state.paths.data, path) {
            Ok(listing) -> listing
            Error(e) -> "Error: " <> e
          }
        }
      }
    }
    "view_skill" -> {
      case require_arg(args, "name") {
        Error(e) -> e
        Ok(skill_name) -> {
          case list.find(state.skill_infos, fn(s) { s.name == skill_name }) {
            Ok(info) -> {
              case memory.read_file(info.path <> "/SKILL.md") {
                Ok(content) -> content
                Error(_) -> "Error: SKILL.md not found for " <> skill_name
              }
            }
            Error(_) -> "Error: Skill not found: " <> skill_name
          }
        }
      }
    }
    "run_skill" -> {
      case require_arg(args, "name") {
        Error(e) -> e
        Ok(skill_name) -> {
          case tools.run_skill(state.skill_infos, skill_name, get_arg(args, "args")) {
            Ok(output) -> output
            Error(e) -> "Error: " <> e
          }
        }
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
                let #(id, tname, parent_id) = t
                tname <> " (id: " <> id <> ", parent: " <> parent_id <> ")"
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
      case require_arg(args, "name") {
        Error(e) -> e
        Ok(skill_name) -> case require_arg(args, "content") {
          Error(e) -> e
          Ok(content) -> {
            case skill.create(state.skills_dir, skill_name, content) {
              Ok(_) -> "Skill created: " <> skill_name <> ". Available immediately via list_skills and run_skill."
              Error(e) -> "Error: " <> e
            }
          }
        }
      }
    }
    "list_skills" -> {
      case skill.list_with_details(state.skills_dir) {
        Ok(listing) -> listing
        Error(e) -> "Error: " <> e
      }
    }
    "memory" -> {
      case require_arg(args, "action") {
        Error(e) -> e
        Ok(action) -> {
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
    "web_search" -> {
      case require_arg(args, "query") {
        Error(e) -> e
        Ok(query) -> {
          let limit = case int.parse(get_arg(args, "limit")) {
            Ok(n) -> n
            Error(_) -> 5
          }
          case web.search(query, limit) {
            Ok(results) -> web.format_search_results(results)
            Error(e) -> "Error: " <> e
          }
        }
      }
    }
    "web_fetch" -> {
      case require_arg(args, "url") {
        Error(e) -> e
        Ok(url) -> {
          case web.fetch(url, 3000) {
            Ok(content) -> content
            Error(e) -> "Error: " <> e
          }
        }
      }
    }
    "manage_schedule" -> {
      case require_arg(args, "action") {
        Error(e) -> e
        Ok(action) -> {
          case action {
            "create" | "delete" -> {
              let description = case action {
                "create" -> "Create schedule: " <> get_arg(args, "name") <> " (" <> get_arg(args, "type") <> ")"
                _ -> "Delete schedule: " <> get_arg(args, "name")
              }
              case tools.propose(description, string.inspect(args)) {
                Ok(output) -> output
                Error(e) -> "Error: " <> e
              }
            }
            _ -> {
              case state.scheduler_subject {
                None -> "Error: Scheduler not started"
                Some(subj) -> {
                  let reply_subject = process.new_subject()
                  process.send(subj, scheduler.ManageSchedule(action, args, reply_subject))
                  case process.receive(reply_subject, 5000) {
                    Ok(response) -> response
                    Error(_) -> "Error: Scheduler timeout"
                  }
                }
              }
            }
          }
        }
      }
    }
    _ -> "Error: Unknown tool " <> name
  }
}

pub fn parse_tool_args(json_str: String) -> List(#(String, String)) {
  case json.parse(json_str, decode.dict(decode.string, decode.string)) {
    Ok(d) -> dict.to_list(d)
    Error(_) -> {
      // GLM-5.1 sometimes concatenates multiple JSON objects: {...}{...}{...}
      // Try to parse just the first object by finding the first '}'
      case string.split_once(json_str, "}{") {
        Ok(#(first, _)) -> {
          case json.parse(first <> "}", decode.dict(decode.string, decode.string)) {
            Ok(d) -> dict.to_list(d)
            Error(_) -> [#("_parse_error", json_str)]
          }
        }
        Error(_) -> [#("_parse_error", json_str)]
      }
    }
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

fn require_arg(args: List(#(String, String)), key: String) -> Result(String, String) {
  case get_arg(args, key) {
    "" -> Error("Error: missing required argument '" <> key <> "'")
    value -> Ok(value)
  }
}

fn make_built_in_tools() -> List(llm.ToolDefinition) {
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
    llm.ToolDefinition(name: "view_skill", description: "Read a skill's full instructions before using it. Returns the SKILL.md content with exact commands, argument format, and examples. Always call this before run_skill.", parameters: [
      llm.ToolParam(name: "name", param_type: "string", description: "Skill name", required: True),
    ]),
    llm.ToolDefinition(name: "run_skill", description: "Run an installed skill as a CLI subprocess. Call view_skill first to learn the exact command syntax.", parameters: [
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
    llm.ToolDefinition(name: "web_search", description: "Search the web using Brave Search. Use when you need current information, documentation, or facts not in your training data or conversation history.", parameters: [
      llm.ToolParam(name: "query", param_type: "string", description: "Search query", required: True),
      llm.ToolParam(name: "limit", param_type: "string", description: "Max results (default 5)", required: False),
    ]),
    llm.ToolDefinition(name: "web_fetch", description: "Fetch a web page and extract its text content. Use after web_search to read a specific result, or when the user provides a URL to read.", parameters: [
      llm.ToolParam(name: "url", param_type: "string", description: "The URL to fetch", required: True),
    ]),
    llm.ToolDefinition(name: "manage_schedule", description: "Manage scheduled tasks. Use 'list' to see all schedules. Use 'create' to add a new schedule (requires user approval). Use 'delete' to remove a schedule (requires user approval). Use 'pause' or 'resume' to toggle a schedule immediately.", parameters: [
      llm.ToolParam(name: "action", param_type: "string", description: "One of: list, create, delete, pause, resume", required: True),
      llm.ToolParam(name: "name", param_type: "string", description: "Schedule name (for create/delete/pause/resume)", required: False),
      llm.ToolParam(name: "type", param_type: "string", description: "Schedule type: 'interval' or 'cron' (for create)", required: False),
      llm.ToolParam(name: "every", param_type: "string", description: "Interval like '15m', '1h' (for create with type=interval)", required: False),
      llm.ToolParam(name: "cron", param_type: "string", description: "Cron expression like '0 9 * * *' (for create with type=cron)", required: False),
      llm.ToolParam(name: "skill", param_type: "string", description: "Skill name to invoke (for create)", required: False),
      llm.ToolParam(name: "args", param_type: "string", description: "Arguments for the skill (for create)", required: False),
      llm.ToolParam(name: "domains", param_type: "string", description: "Comma-separated domain names (for create)", required: False),
      llm.ToolParam(name: "model", param_type: "string", description: "LLM model for urgency classification (for create, default zai/glm-5-turbo)", required: False),
    ]),
  ]
}


/// Call the vision model to describe an image.
fn describe_image(
  vision_config: vision.ResolvedVisionConfig,
  image_url: String,
) -> Result(String, String) {
  use llm_config <- result.try(
    models.build_llm_config(vision_config.model_spec)
  )
  let messages = [
    llm.UserMessageWithImage(
      content: vision_config.prompt,
      image_url: image_url,
    ),
  ]
  llm.chat_with_options(llm_config, messages, None)
}

// ---------------------------------------------------------------------------
// Streaming support
// ---------------------------------------------------------------------------

/// Events received from the streaming FFI via receive_stream_message_ffi.
type StreamEvent {
  StreamDelta(String)
  StreamReasoning
  StreamComplete(String, String)
  StreamDone
  StreamError(String)
  StreamTimeout
}

/// Receive a stream event from the process mailbox.
/// The Erlang FFI returns {<<"delta">>, Bin} | {<<"done">>, <<>>} |
/// {<<"error">>, Bin} | {<<"timeout">>, <<>>}.
@external(erlang, "aura_stream_ffi", "receive_stream_message")
fn receive_stream_message_ffi(timeout_ms: Int) -> #(String, String, String)

fn receive_stream_message(timeout_ms: Int) -> StreamEvent {
  case receive_stream_message_ffi(timeout_ms) {
    #("delta", text, _) -> StreamDelta(text)
    #("reasoning", _, _) -> StreamReasoning
    #("complete", content, tc_json) -> StreamComplete(content, tc_json)
    #("done", _, _) -> StreamDone
    #("error", err, _) -> StreamError(err)
    _ -> StreamTimeout
  }
}

