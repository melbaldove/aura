import aura/acp/manager
import aura/acp/monitor as acp_monitor
import aura/acp/session_store
import aura/acp/types as acp_types
import aura/brain_tools
import aura/config
import aura/domain
import aura/time
import aura/conversation
import aura/db
import aura/discord
import aura/discord/rest
import aura/llm
import aura/models
import aura/notification
import aura/scheduler
import aura/skill
import aura/structured_memory
import aura/validator
import aura/vision
import aura/xdg
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/erlang/process
import gleam/result
import gleam/string

// ---------------------------------------------------------------------------
// FFI
// ---------------------------------------------------------------------------

@external(erlang, "aura_rescue_ffi", "rescue")
fn rescue(fun: fn() -> a) -> Result(a, String)

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const max_tool_iterations = 20

const stream_idle_timeout_ms = 120_000

const stream_check_interval_ms = 500

const progressive_edit_chars = 150

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
  RegisterAcpSession(
    session: manager.ActiveSession,
    prompt: String,
    cwd: String,
  )
  PostWelcome(channel_id: String)
  StoreExchange(channel_id: String, messages: List(llm.Message))
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
    acp_store_path: String,
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

/// Build system prompt from soul, domains, skills, memory, and user profile.
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
  <> "\n- NEVER write to external systems (Jira comments, ticket transitions, assignments, emails, Slack messages) unless the user explicitly asks you to. Read-only by default."
  <> "\n- When asked to triage, investigate, plan, or work on a ticket — dispatch an ACP session. Do NOT try to do the work inline in chat."
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

// ---------------------------------------------------------------------------
// Actor
// ---------------------------------------------------------------------------
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
      acp_manager: manager.new(
        config.acp_global_max_concurrent,
        brain_config.acp_store_path,
      ),
      validation_rules: brain_config.validation_rules,
      skill_infos: brain_config.skill_infos,
      skills_dir: xdg.skills_dir(brain_config.paths),
      db_subject: brain_config.db_subject,
      built_in_tools: brain_tools.make_built_in_tools(),
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
        case rescue(fn() { handle_with_llm(state, msg, subj, domain_name) }) {
          Ok(_) -> Nil
          Error(reason) -> {
            io.println("[brain] CRASH in handle_with_llm: " <> reason)
            let _ = rest.send_message(state.discord_token, msg.channel_id, "Sorry, I crashed while processing your message. Check the logs.", [])
            Nil
          }
        }
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
    AcpEvent(event) -> handle_acp_event(state, event)
    RegisterAcpSession(session:, prompt:, cwd:) -> {
      let new_manager =
        manager.register(state.acp_manager, session, prompt, cwd)
      actor.continue(BrainState(..state, acp_manager: new_manager))
    }
    StoreExchange(channel_id, messages) -> {
      // DB write already done by the spawned process before Discord delivery.
      // This handler only updates the in-memory cache.
      let now = time.now_ms()
      let cache_key = "discord:" <> channel_id
      let #(hydrated, _, _) = conversation.get_or_load_db(state.conversations, state.db_subject, "discord", channel_id, now)
      let new_convos = conversation.append_messages(hydrated, cache_key, messages)

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

fn handle_acp_event(state: BrainState, event: acp_monitor.AcpEvent) -> actor.Next(BrainState, BrainMessage) {
  case event {
    acp_monitor.AcpStarted(session_name, domain, task_id) -> {
      // Transition: Starting → Running
      let new_manager =
        manager.update_state(state.acp_manager, session_name, manager.Running)
      let msg =
        "**ACP Started** — "
        <> task_id
        <> "\n`tmux attach -t "
        <> session_name
        <> "`"
      let channel = resolve_acp_channel(state, session_name, domain)
      process.spawn(fn() {
        send_discord_response(state.discord_token, channel, msg)
      })
      actor.continue(BrainState(..state, acp_manager: new_manager))
    }
    acp_monitor.AcpAlert(session_name, domain, status, summary) -> {
      // Alerts are informational — state stays Running
      let status_str = acp_types.status_to_string(status)
      let msg =
        "**ACP Alert** ["
        <> status_str
        <> "] — "
        <> summary
        <> "\n`tmux attach -t "
        <> session_name
        <> "`"
      let channel = resolve_acp_channel(state, session_name, domain)
      process.spawn(fn() {
        send_discord_response(state.discord_token, channel, msg)
      })
      actor.continue(state)
    }
    acp_monitor.AcpCompleted(session_name, domain, report) -> {
      let outcome = acp_types.outcome_to_string(report.outcome)
      let msg =
        "**ACP Complete** [" <> outcome <> "] — " <> report.anchor
      handle_acp_completion(state, session_name, domain, msg, manager.Complete)
    }
    acp_monitor.AcpTimedOut(session_name, domain) -> {
      let msg =
        "**ACP Timeout** — Session still alive. `tmux attach -t "
        <> session_name
        <> "`"
      handle_acp_completion(state, session_name, domain, msg, manager.TimedOut)
    }
    acp_monitor.AcpProgress(session_name, domain, summary) -> {
      let msg = "**ACP Progress** `" <> session_name <> "`\n" <> summary
      let channel = resolve_acp_channel(state, session_name, domain)
      process.spawn(fn() {
        send_discord_response(state.discord_token, channel, msg)
      })
      actor.continue(state)
    }
    acp_monitor.AcpFailed(session_name, domain, error) -> {
      let msg = "**ACP Failed** — " <> error
      handle_acp_completion(
        state,
        session_name,
        domain,
        msg,
        manager.Failed(error),
      )
    }
  }
}

fn handle_acp_completion(
  state: BrainState,
  session_name: String,
  domain: String,
  msg: String,
  terminal_state: manager.SessionState,
) -> actor.Next(BrainState, BrainMessage) {
  // Resolve channel BEFORE unregistering so we can still find the thread_id
  let channel = resolve_acp_channel(state, session_name, domain)
  process.spawn(fn() {
    send_discord_response(state.discord_token, channel, msg)
  })
  // Set terminal state, then unregister
  let new_manager =
    manager.update_state(state.acp_manager, session_name, terminal_state)
  let new_manager =
    manager.unregister(new_manager, session_name, terminal_state)
  actor.continue(BrainState(..state, acp_manager: new_manager))
}

fn resolve_domain_channel(state: BrainState, domain: String) -> String {
  case list.find(state.domains, fn(d) { d.name == domain }) {
    Ok(d) -> d.channel_id
    Error(_) -> state.aura_channel_id
  }
}

/// Resolve the channel for ACP events: use the session's thread if available,
/// otherwise fall back to the domain channel.
fn resolve_acp_channel(state: BrainState, session_name: String, domain: String) -> String {
  case manager.get_session(state.acp_manager, session_name) {
    Ok(session) -> case session.thread_id {
      "" -> resolve_domain_channel(state, domain)
      id -> id
    }
    Error(_) -> resolve_domain_channel(state, domain)
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

  // Inject ACP session context if this message is in an ACP thread
  let acp_context = case list.find(
    session_store.load(state.acp_manager.store_path),
    fn(s) { s.thread_id == msg.channel_id },
  ) {
    Ok(session) -> {
      "\n\n## Active ACP Session"
      <> "\nYou are in an ACP session thread."
      <> "\nSession: " <> session.session_name
      <> "\nState: " <> session.state
      <> "\nDomain: " <> session.domain
      <> "\nTask: " <> string.slice(session.prompt, 0, 300)
      <> "\n\nUse acp_status to check progress, acp_prompt to send instructions, acp_list to see all sessions."
    }
    Error(_) -> ""
  }
  let system_prompt = system_prompt <> acp_context

  // Vision preprocessing — describe attached images before tool loop
  let enriched_content = preprocess_vision(state, msg, domain_name)

    // Load conversation history (from memory or DB)
  let now_ts = time.now_ms()
  let #(_, _, history) = conversation.get_or_load_db(state.conversations, state.db_subject, "discord", msg.channel_id, now_ts)
  io.println("[brain] Loaded " <> int.to_string(list.length(history)) <> " history messages for " <> msg.channel_id)

  let initial_messages = list.flatten([
    [llm.SystemMessage(system_prompt)],
    history,
    [llm.UserMessage(enriched_content)],
  ])

  let tool_ctx = brain_tools.ToolContext(
    data_dir: state.paths.data,
    discord_token: state.discord_token,
    guild_id: state.guild_id,
    message_id: msg.message_id,
    channel_id: msg.channel_id,
    paths: state.paths,
    skill_infos: state.skill_infos,
    skills_dir: state.skills_dir,
    validation_rules: state.validation_rules,
    db_subject: state.db_subject,
    scheduler_subject: state.scheduler_subject,
    acp_manager: state.acp_manager,
    acp_store_path: state.acp_manager.store_path,
    on_acp_event: fn(event) {
      case brain_subject_opt {
        Some(subj) -> process.send(subj, AcpEvent(event))
        None -> Nil
      }
    },
    on_register_acp: fn(session, prompt, cwd) {
      case brain_subject_opt {
        Some(subj) ->
          process.send(
            subj,
            RegisterAcpSession(session: session, prompt: prompt, cwd: cwd),
          )
        None -> Nil
      }
    },
    monitor_model: state.global_config.models.monitor,
    domain_name: option.unwrap(domain_name, "aura"),
    domain_cwd: case domain_name {
      Some(name) -> {
        case list.find(state.domain_configs, fn(dc) { dc.0 == name }) {
          Ok(#(_, cfg)) -> cfg.cwd
          Error(_) -> "."
        }
      }
      None -> "."
    },
  )

  let result = tool_loop_with_retry(state, tool_ctx, msg.channel_id, initial_messages, 3)

  // Stop typing indicator before any final edits
  stop_typing_loop(typing_stop)

  let token = state.discord_token
  let channel_id = msg.channel_id

  case result {
    Ok(#(response_text, traces, msg_id, new_messages, final_channel_id)) -> {
      let channel_id = final_channel_id
      // Build the full turn: user message + tool chain + final response
      let user_msg = llm.UserMessage(enriched_content)
      let all_turn_messages = [user_msg, ..new_messages]

      // Save to DB FIRST — before Discord delivery — so the next turn sees this exchange
      let now = time.now_ms()
      case db.resolve_conversation(state.db_subject, "discord", channel_id, now) {
        Ok(convo_id) -> {
          case conversation.save_exchange_to_db(state.db_subject, convo_id, all_turn_messages, msg.author_id, msg.author_name, now) {
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
        Some(subj) -> process.send(subj, StoreExchange(channel_id, all_turn_messages))
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
fn tool_loop_with_retry(
  state: BrainState,
  tool_ctx: brain_tools.ToolContext,
  channel_id: String,
  messages: List(llm.Message),
  retries_left: Int,
) -> Result(#(String, List(conversation.ToolTrace), String, List(llm.Message), String), String) {
  case tool_loop_progressive(state, tool_ctx, channel_id, messages, [], "", 0, []) {
    Ok(result) -> Ok(result)
    Error(err) -> {
      case retries_left > 0 && string.contains(err, "timeout") {
        True -> {
          io.println("[brain] Stream timeout, retrying (" <> int.to_string(retries_left) <> " left)...")
          process.sleep(2000)
          tool_loop_with_retry(state, tool_ctx, channel_id, messages, retries_left - 1)
        }
        False -> Error(err)
      }
    }
  }
}

fn tool_loop_progressive(
  state: BrainState,
  tool_ctx: brain_tools.ToolContext,
  channel_id: String,
  messages: List(llm.Message),
  traces: List(conversation.ToolTrace),
  message_id: String,
  iteration: Int,
  new_messages: List(llm.Message),
) -> Result(#(String, List(conversation.ToolTrace), String, List(llm.Message), String), String) {
  case iteration >= max_tool_iterations {
    True -> Error("Tool loop exceeded maximum iterations")
    False -> {
      // Spawn streaming LLM call with tools
      let self_pid = process.self()
      let _ = process.spawn_unlinked(fn() {
        llm.chat_streaming_with_tools(state.llm_config, messages, state.built_in_tools, self_pid)
      })

      // Collect the streaming response (content + tool calls)
      case collect_stream_response(state.discord_token, channel_id, message_id, traces, stream_idle_timeout_ms) {
        Ok(#(content, tool_calls_json, msg_id)) -> {
          let response = parse_streaming_result(content, tool_calls_json)
          case response.tool_calls {
            [] -> {
              // No tool calls — return the text response with accumulated traces
              let final_new_messages = list.append(new_messages, [llm.AssistantMessage(response.content)])
              Ok(#(response.content, traces, msg_id, final_new_messages, channel_id))
            }
            calls -> {
              // Execute tool calls and continue the loop
              io.println("[brain] " <> int.to_string(list.length(calls)) <> " tool call(s)")

              // Execute each tool and build traces + result messages
              let #(rev_traces, rev_results) = list.fold(calls, #([], []), fn(acc, call) {
                let #(acc_traces, acc_results) = acc
                io.println("[brain] Tool: " <> call.name <> " args: " <> call.arguments)
                let result = brain_tools.execute_tool(tool_ctx, call)
                let result_preview = string.slice(result, 0, 100)
                io.println("[brain] Result: " <> result_preview)

                let is_error = string.starts_with(result, "Error")
                let parsed_args = brain_tools.parse_tool_args(call.arguments)
                let trace = conversation.ToolTrace(
                  name: call.name,
                  args: brain_tools.format_tool_args(parsed_args),
                  result: result,
                  is_error: is_error,
                )
                #([trace, ..acc_traces], [llm.ToolResultMessage(call.id, result), ..acc_results])
              })
              let new_traces = list.append(traces, list.reverse(rev_traces))
              let tool_results = list.reverse(rev_results)

              // Check if any tool redirected output to a thread
              let #(channel_id, message_id) = list.fold(tool_results, #(channel_id, message_id), fn(acc, msg) {
                case msg {
                  llm.ToolResultMessage(_, content) -> {
                    case string.starts_with(content, "___REDIRECT_CHANNEL___:") {
                      // Switch to thread and reset message_id so next send creates a new message
                      True -> #(string.drop_start(content, 23), "")
                      False -> acc
                    }
                  }
                  _ -> acc
                }
              })

              // Format current traces for progressive display
              let progress_text = conversation.format_traces(new_traces) <> "\n\n*Thinking...*"

              // Send or edit message with current trace progress
              let new_message_id = send_or_edit(state.discord_token, channel_id, message_id, progress_text)

              // Track new messages from this iteration: assistant tool call + tool results
              let iteration_messages = [
                llm.AssistantToolCallMessage(response.content, calls),
                ..tool_results
              ]
              let updated_new_messages = list.append(new_messages, iteration_messages)

              // Build full messages for the next LLM call: all prior messages + this iteration
              let updated_messages = list.append(messages, iteration_messages)

              tool_loop_progressive(state, tool_ctx, channel_id, updated_messages, new_traces, new_message_id, iteration + 1, updated_new_messages)
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
      let wait = case remaining_ms > stream_check_interval_ms { True -> stream_check_interval_ms False -> remaining_ms }
      case receive_stream_message(wait) {
        StreamDelta(delta) -> {
          let new_acc = accumulated <> delta
          // Progressive edit every 150 chars
          let #(new_msg_id, new_edit_len) = case string.length(new_acc) - last_edit_len > progressive_edit_chars {
            True -> {
              let display = conversation.format_full_message(traces, new_acc <> " ...")
              #(send_or_edit(token, channel_id, msg_id, display), string.length(new_acc))
            }
            False -> #(msg_id, last_edit_len)
          }
          // Data received — reset idle timeout to 120s
          collect_stream_loop(token, channel_id, new_msg_id, traces, new_acc, new_edit_len, stream_idle_timeout_ms)
        }
        StreamReasoning -> {
          // GLM-5.1 thinking — stream is alive, reset idle timeout
          collect_stream_loop(token, channel_id, msg_id, traces, accumulated, last_edit_len, stream_idle_timeout_ms)
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
      case llm.parse_flat_tool_calls_json(json_str) {
        Ok(calls) -> llm.LlmResponse(content: content, tool_calls: calls)
        Error(_) -> llm.LlmResponse(content: content, tool_calls: [])
      }
    }
  }
}


// ---------------------------------------------------------------------------
// Vision preprocessing
// ---------------------------------------------------------------------------

/// Preprocess message content with vision descriptions for image attachments.
fn preprocess_vision(
  state: BrainState,
  msg: discord.IncomingMessage,
  domain_name: Option(String),
) -> String {
  case msg.attachments {
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

