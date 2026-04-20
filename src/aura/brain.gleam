import aura/acp/flare_manager
import aura/acp/monitor as acp_monitor
import aura/acp/types as acp_types
import aura/brain_tools
import aura/browser
import aura/channel_actor
import aura/channel_supervisor
import aura/stream_worker
import aura/tool_worker
import aura/vision_worker
import aura/clients/browser_runner.{type BrowserRunner}
import aura/clients/discord_client.{type DiscordClient}
import aura/clients/llm_client.{type LLMClient}
import aura/clients/skill_runner.{type SkillRunner}
import aura/compressor
import aura/config
import aura/conversation
import aura/db
import aura/discord
import aura/discord/message as discord_message
import aura/discord/rest
import aura/discord/types as discord_types
import aura/web
import aura/domain
import aura/llm
import aura/memory
import aura/models
import aura/notification
import aura/review
import aura/scheduler
import aura/shell
import aura/skill
import aura/structured_memory
import aura/time
import aura/tools
import aura/validator
import aura/vision
import aura/xdg
import gleam/dict
import gleam/erlang/process
import gleam/int
import logging
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import simplifile

// ---------------------------------------------------------------------------
// FFI
// ---------------------------------------------------------------------------

@external(erlang, "aura_rescue_ffi", "rescue")
fn rescue(fun: fn() -> a) -> Result(a, String)

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const max_tool_iterations = 80

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
  PostWelcome(channel_id: String)
  StoreExchange(
    channel_id: String,
    messages: List(llm.Message),
    domain_name: String,
    prompt_tokens: Int,
  )
  CompressionComplete(
    channel_id: String,
    new_history: List(llm.Message),
    new_comp_state: conversation.CompressorState,
    snapshot_len: Int,
  )
  RegisterThread(thread_id: String, domain_name: String)
  SetScheduler(process.Subject(scheduler.SchedulerMessage))
  UpdateReviewCount(channel_id: String, count: Int)
  UpdateSkillReviewCount(channel_id: String, count: Int)
  HandleInteraction(
    interaction_id: String,
    interaction_token: String,
    custom_id: String,
    channel_id: String,
  )
  RegisterProposal(proposal: brain_tools.PendingProposal)
  RegisterShellApproval(approval: brain_tools.PendingShellApproval)
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
    acp_subject: process.Subject(flare_manager.FlareMsg),
    discord: DiscordClient,
    llm: LLMClient,
    skill_runner: SkillRunner,
    browser_runner: BrowserRunner,
    channel_supervisor: process.Subject(channel_supervisor.SupervisorMessage),
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
    acp_subject: process.Subject(flare_manager.FlareMsg),
    validation_rules: List(validator.Rule),
    skills_dir: String,
    db_subject: process.Subject(db.DbMessage),
    built_in_tools: List(llm.ToolDefinition),
    conversations: conversation.Buffers,
    self_subject: Option(process.Subject(BrainMessage)),
    global_config: config.GlobalConfig,
    domain_configs: List(#(String, config.DomainConfig)),
    thread_domains: dict.Dict(String, String),
    scheduler_subject: Option(process.Subject(scheduler.SchedulerMessage)),
    review_counts: dict.Dict(String, Int),
    skill_review_counts: dict.Dict(String, Int),
    compressor_states: dict.Dict(String, conversation.CompressorState),
    brain_context: Int,
    pending_proposals: dict.Dict(String, brain_tools.PendingProposal),
    pending_shell_approvals: dict.Dict(String, brain_tools.PendingShellApproval),
    shell_patterns: shell.CompiledPatterns,
    acp_progress_msgs: dict.Dict(String, #(String, String)),
    // session_name -> #(channel_id, message_id)
    discord: DiscordClient,
    llm_client: LLMClient,
    skill_runner: SkillRunner,
    browser_runner: BrowserRunner,
    channel_supervisor: process.Subject(channel_supervisor.SupervisorMessage),
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
  let domain_section = case domain_names {
    [] -> "\n\nNo domains configured yet."
    names -> "\n\nActive domains: " <> string.join(names, ", ")
  }

  let skill_lines =
    list.map(skill_infos, fn(s) { "- " <> s.name <> ": " <> s.description })
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
  <> "\n\nCurrent time: " <> time.now_datetime_string() <> " (Asia/Manila)"
  <> "\n\nKeep responses concise and direct. Use Discord markdown where appropriate."
  <> domain_section
  <> skills_section
  <> memory_section
  <> user_section
  <> "\n\nTool usage rules:"
  <> "\n- Use tools only when needed to answer the question. Most questions can be answered from context."
  <> "\n- Do NOT recursively explore directories."
  <> "\n- If you already know the answer from the system context above, respond directly without tools."
  <> "\n- NEVER fabricate tool results. If you need data (calendar events, tickets, files), you MUST call the tool. Do not generate fake data from memory of past results."
  <> "\n- NEVER write to external systems (Jira comments, ticket transitions, assignments, emails, Slack messages) unless the user explicitly asks you to. Read-only by default."
  <> "\n- When asked to triage, investigate, plan, or work on a ticket — ignite a flare. Do NOT try to do the work inline in chat."
  <> "\n- Flare prompts must NEVER instruct the agent to write to MEMORY.md, STATE.md, or USER.md. Flares report their findings back to you. YOU decide what to persist to memory after reviewing the results."
  <> "\n- For domain creation, use the propose tool to request approval."
  <> "\n\nMemory guidance:"
  <> "\nYou have three types of persistent memory, all keyed by topic:"
  <> "\n- **state** — current domain status. What's in flight right now: active tickets, PRs, blockers. Upsert by key (e.g. key='PROJ-101', key='pr-42')."
  <> "\n- **memory** — durable domain knowledge. Decisions, patterns, conventions. Upsert by key (e.g. key='jira-patterns', key='branch-workflow')."
  <> "\n- **user** — user profile (global). Preferences, communication style, role."
  <> "\nAll entries are keyed. Use `set` to create or update, `remove` to delete. No need to read before writing — set is an upsert."
  <> "\nState and memory are per-domain. When in a domain channel, they target that domain's files. In #aura, they target global files."
  <> "\nUpdate state and memory after significant actions:"
  <> "\n- Flare reports back → review findings, set state for what was done, set memory for what was learned"
  <> "\n- Igniting a flare → set state that it's in progress"
  <> "\n- Ticket status change → set state"
  <> "\n- Discovering a codebase pattern → set memory"
  <> "\n\nSkills guidance:"
  <> "\nBefore using run_skill, call view_skill first to read the skill's full instructions. The instructions contain exact commands, argument format, and examples. Never guess CLI syntax."
  <> "\nWhen using a skill and finding it outdated, incomplete, or wrong, update it immediately with create_skill — don't wait to be asked."
  <> "\n\nFlare self-knowledge:"
  <> "\nYou are Aura. Flares are YOUR extensions — ACP sessions you dispatch to do work."
  <> "\n- Flares DO NOT lose context. On deploy/restart, active flares auto-rekindle with --resume, which loads the full prior conversation. The agent has all its previous context."
  <> "\n- If a rekindled flare reports 'idle' or 'nothing to do', it's waiting for direction — not confused. Send a follow-up prompt telling it what to do next."
  <> "\n- Session names change on rekindle. The flare ID (f-...) is permanent. After a restart, call flare(list) to see current session names."
  <> "\n- Rekindle continues existing work. Ignite starts fresh. NEVER kill + ignite to continue the same work."
  <> "\n- Flares are long-running. Treat them like persistent workspaces, not single-use commands."
  <> "\n- After handback: park. Park is the default terminal action — the flare may be useful again."
  <> "\n- park when you're done prompting for now (handback arrived, waiting on user, waiting on something external). A parked flare auto-rekindles on the next prompt."
  <> "\n- kill and archive require explicit user request. Never decide to kill or archive on your own. 'Looks done' is not enough — ask first."
  <> "\n- If a handback reports failure, still park (not kill). The user may want to diagnose or retry."
  <> "\n- 'refused by user' means ACP permissions are misconfigured, not a human decision."
  <> "\n- Before acting on flare state, ALWAYS call flare(list). Do not guess."
  <> "\n- flare(list) shows thread= for each flare. When the user says 'rekindle the flare' in a thread, match the current channel_id to the flare's thread_id. NEVER guess which flare — look it up."
  <> "\n- flare(list) and flare(status) show 'working' or 'idle'. If a flare is working, leave it alone. If idle, re-prompt with specific instructions or park if nothing more to say right now."
  <> "\n- Never say 'lost context', 'context wiped', or 'model switch'. These do not happen. If a flare seems unresponsive, re-prompt it with specific instructions."
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

  // Resolve context length for compression thresholds
  let brain_context = case
    models.resolve_context_length(config.models.brain, config.brain_context)
  {
    Ok(len) -> len
    Error(e) -> {
      logging.log(logging.Warning, "[brain] Warning: " <> e <> ", defaulting to 128000")
      128_000
    }
  }

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
      acp_subject: brain_config.acp_subject,
      validation_rules: brain_config.validation_rules,
      skill_infos: brain_config.skill_infos,
      skills_dir: xdg.skills_dir(brain_config.paths),
      db_subject: brain_config.db_subject,
      built_in_tools: brain_tools.make_built_in_tools(),
      conversations: conversation.new(),
      thread_domains: dict.new(),
      self_subject: None,
      global_config: brain_config.global,
      domain_configs: brain_config.domain_configs,
      scheduler_subject: None,
      review_counts: dict.new(),
      skill_review_counts: dict.new(),
      compressor_states: dict.new(),
      brain_context: brain_context,
      pending_proposals: dict.new(),
      pending_shell_approvals: dict.new(),
      shell_patterns: shell.compile_patterns(),
      acp_progress_msgs: dict.new(),
      discord: brain_config.discord,
      llm_client: brain_config.llm,
      skill_runner: brain_config.skill_runner,
      browser_runner: brain_config.browser_runner,
      channel_supervisor: brain_config.channel_supervisor,
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
          logging.log(logging.Info, "[brain] Route: " <> name)
          Some(name)
        }
        NeedsClassification -> {
          // Check cache first, then Discord API for parent channel
          case dict.get(state.thread_domains, msg.channel_id) {
            Ok(name) -> {
              logging.log(logging.Info, "[brain] Route: " <> name <> " (via thread cache)")
              Some(name)
            }
            Error(_) -> {
              // Look up parent channel from Discord — is this a thread?
              case
                state.discord.get_channel_parent(msg.channel_id)
              {
                Ok("") -> {
                  logging.log(logging.Info, "[brain] Route: #aura")
                  None
                }
                Ok(parent_id) -> {
                  // Check if parent is a domain channel
                  case route_message(parent_id, state.domains) {
                    DirectRoute(name) -> {
                      logging.log(logging.Info, 
                        "[brain] Route: " <> name <> " (via thread parent)",
                      )
                      // Cache it for next time
                      case state.self_subject {
                        Some(subj) ->
                          process.send(
                            subj,
                            RegisterThread(
                              thread_id: msg.channel_id,
                              domain_name: name,
                            ),
                          )
                        None -> Nil
                      }
                      Some(name)
                    }
                    NeedsClassification -> {
                      logging.log(logging.Info, "[brain] Route: #aura")
                      None
                    }
                  }
                }
                Error(_) -> {
                  logging.log(logging.Info, "[brain] Route: #aura")
                  None
                }
              }
            }
          }
        }
      }
      let allowlist =
        state.global_config.experimental.channel_actor_channels
      case list.contains(allowlist, msg.channel_id) {
        True -> {
          logging.log(
            logging.Info,
            "[brain] Channel " <> msg.channel_id <> " routed to channel_actor (experimental)",
          )
          let deps = build_channel_actor_deps(state, msg.channel_id, domain_name)
          let subject =
            channel_supervisor.get_or_start(
              state.channel_supervisor,
              msg.channel_id,
              deps,
            )
          process.send(subject, channel_actor.HandleIncoming(msg))
          actor.continue(state)
        }
        False -> {
          let subj = state.self_subject
          process.spawn_unlinked(fn() {
            case rescue(fn() { handle_with_llm(state, msg, subj, domain_name) }) {
              Ok(_) -> Nil
              Error(reason) -> {
                logging.log(logging.Error, "[brain] CRASH in handle_with_llm: " <> reason)
                let _ =
                  state.discord.send_message(
                    msg.channel_id,
                    "Sorry, I crashed while processing your message. Check the logs.",
                  )
                Nil
              }
            }
          })
          actor.continue(state)
        }
      }
    }
    UpdateDomains(domains) -> {
      logging.log(logging.Info, 
        "[brain] Updated domains: "
        <> string.inspect(list.length(domains))
        <> " entries",
      )
      actor.continue(BrainState(..state, domains: domains))
    }
    HeartbeatFinding(finding) -> {
      case notification.is_urgent(finding) {
        True -> {
          // Post urgent findings immediately
          let channel = resolve_finding_channel(state, finding)
          process.spawn_unlinked(fn() {
            send_discord_response(
              state.discord,
              channel,
              "**URGENT** [" <> finding.source <> "] " <> finding.summary,
            )
          })
          actor.continue(state)
        }
        False -> {
          // Queue for digest
          let new_queue =
            notification.enqueue(state.notification_queue, finding)
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
              logging.log(logging.Info, 
                "[brain] No #aura channel configured for digest delivery",
              )
              Nil
            }
            _ -> {
              process.spawn_unlinked(fn() {
                send_discord_response(state.discord, channel, digest)
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
          let msg =
            "Aura is online. No domains configured yet. Tell me about your first project and I'll set one up."
          process.spawn_unlinked(fn() {
            send_discord_response(state.discord, channel_id, msg)
          })
          actor.continue(BrainState(..state, aura_channel_id: channel_id))
        }
        False ->
          actor.continue(BrainState(..state, aura_channel_id: channel_id))
      }
    }
    AcpEvent(event) -> handle_acp_event(state, event)
    StoreExchange(channel_id, messages, dn, prompt_tok) -> {
      let now = time.now_ms()
      let cache_key = "discord:" <> channel_id
      let #(hydrated, _, _) =
        conversation.get_or_load_db(
          state.conversations,
          state.db_subject,
          "discord",
          channel_id,
          now,
        )
      let new_convos =
        conversation.append_messages(hydrated, cache_key, messages)

      let comp_state = case dict.get(state.compressor_states, cache_key) {
        Ok(s) -> s
        Error(_) -> conversation.new_compressor_state()
      }
      // Update compressor state with real token count from API
      let comp_state = case prompt_tok > 0 {
        True ->
          conversation.CompressorState(
            ..comp_state,
            last_prompt_tokens: prompt_tok,
          )
        False -> comp_state
      }

      let history = conversation.get_history(new_convos, cache_key)
      case
        conversation.needs_full_compression(
          history,
          state.brain_context,
          comp_state.last_prompt_tokens,
        )
      {
        True -> {
          logging.log(logging.Info, "[brain] Full compression triggered for " <> cache_key)
          let snapshot_len = list.length(history)
          let llm_config = state.llm_config
          let db_subject = state.db_subject
          let brain_subject = state.self_subject
          let paths = state.paths
          let brain_context = state.brain_context
          let monitor_model = state.global_config.models.monitor
          process.spawn_unlinked(fn() {
            // Read domain files in the spawned process, not the actor
            let #(a_md, s_md) = load_domain_context_files(paths, dn)
            // Flush memories before compression discards messages
            case models.build_llm_config(monitor_model) {
              Ok(monitor_llm_config) ->
                review.flush_before_compression(
                  monitor_llm_config,
                  history,
                  dn,
                  paths,
                )
              Error(e) -> {
                logging.log(logging.Info, 
                  "[brain] Flush skipped — monitor LLM config failed: " <> e,
                )
                Nil
              }
            }
            let #(new_history, new_comp_state) =
              conversation.compress_history(
                history,
                llm_config,
                comp_state,
                dn,
                a_md,
                s_md,
                db_subject,
                cache_key,
                brain_context,
              )
            case brain_subject {
              Some(subj) ->
                process.send(
                  subj,
                  CompressionComplete(
                    cache_key,
                    new_history,
                    new_comp_state,
                    snapshot_len,
                  ),
                )
              None -> Nil
            }
          })
          actor.continue(BrainState(..state, conversations: new_convos))
        }
        False -> {
          let #(final_convos, new_comp_state) = case
            conversation.needs_tool_pruning(
              history,
              state.brain_context,
              comp_state.last_prompt_tokens,
            )
          {
            True -> {
              let #(pruned, count) =
                compressor.prune_tool_outputs(
                  history,
                  compressor.min_tail_messages,
                )
              case count > 0 {
                True ->
                  logging.log(logging.Info, 
                    "[brain] Tool pruning: cleared "
                    <> int.to_string(count)
                    <> " output(s) for "
                    <> cache_key,
                  )
                False -> Nil
              }
              #(dict.insert(new_convos, cache_key, pruned), comp_state)
            }
            False -> #(new_convos, comp_state)
          }
          let new_comp_states =
            dict.insert(state.compressor_states, cache_key, new_comp_state)
          actor.continue(
            BrainState(
              ..state,
              conversations: final_convos,
              compressor_states: new_comp_states,
            ),
          )
        }
      }
    }
    CompressionComplete(
      channel_id,
      compressed_history,
      new_comp_state,
      snapshot_len,
    ) -> {
      // Merge: compressed history + any messages that arrived during compression
      let current = conversation.get_history(state.conversations, channel_id)
      let current_len = list.length(current)
      let merged = case current_len > snapshot_len {
        True -> {
          // New messages arrived — append the delta to compressed history
          let delta = list.drop(current, snapshot_len)
          let delta_len = list.length(delta)
          logging.log(logging.Info, 
            "[brain] Compression complete for "
            <> channel_id
            <> " (merging "
            <> int.to_string(delta_len)
            <> " new messages)",
          )
          list.append(compressed_history, delta)
        }
        False -> {
          logging.log(logging.Info, "[brain] Compression complete for " <> channel_id)
          compressed_history
        }
      }
      let new_convos = dict.insert(state.conversations, channel_id, merged)
      let new_comp_states =
        dict.insert(state.compressor_states, channel_id, new_comp_state)
      actor.continue(
        BrainState(
          ..state,
          conversations: new_convos,
          compressor_states: new_comp_states,
        ),
      )
    }
    RegisterThread(thread_id:, domain_name:) -> {
      let new_threads =
        dict.insert(state.thread_domains, thread_id, domain_name)
      actor.continue(BrainState(..state, thread_domains: new_threads))
    }
    SetScheduler(subject) -> {
      logging.log(logging.Info, "[brain] Scheduler connected")
      actor.continue(BrainState(..state, scheduler_subject: Some(subject)))
    }
    UpdateReviewCount(channel_id:, count:) -> {
      let new_counts = dict.insert(state.review_counts, channel_id, count)
      actor.continue(BrainState(..state, review_counts: new_counts))
    }
    UpdateSkillReviewCount(channel_id:, count:) -> {
      let new_counts = dict.insert(state.skill_review_counts, channel_id, count)
      actor.continue(BrainState(..state, skill_review_counts: new_counts))
    }
    HandleInteraction(
      interaction_id:,
      interaction_token:,
      custom_id:,
      channel_id: _,
    ) -> {
      // Acknowledge immediately (must respond within 3 seconds)
      process.spawn_unlinked(fn() {
        case rest.send_interaction_response(interaction_id, interaction_token) {
          Ok(_) -> Nil
          Error(e) -> logging.log(logging.Error, "[brain] Failed to ack interaction: " <> e)
        }
      })

      // Parse action and approval_id from custom_id
      case string.split_once(custom_id, ":") {
        Error(_) -> actor.continue(state)
        Ok(#(action, approval_id)) -> {
          case dict.get(state.pending_shell_approvals, approval_id) {
            Ok(shell_approval) ->
              handle_shell_interaction(state, action, shell_approval)
            Error(_) ->
              case dict.get(state.pending_proposals, approval_id) {
                Ok(proposal) ->
                  handle_proposal_interaction(state, action, proposal)
                Error(_) -> {
                  logging.log(logging.Info, "[brain] Unknown approval: " <> approval_id)
                  actor.continue(state)
                }
              }
          }
        }
      }
    }
    RegisterProposal(proposal:) -> {
      // One per channel -- supersede existing
      let new_proposals = case
        list.find(dict.values(state.pending_proposals), fn(p) {
          p.channel_id == proposal.channel_id
        })
      {
        Ok(old) -> {
          process.send(old.reply_to, brain_tools.Expired)
          process.spawn_unlinked(fn() {
            let _ =
              state.discord.edit_message(
                old.channel_id,
                old.message_id,
                "~~Superseded~~",
              )
            Nil
          })
          dict.delete(state.pending_proposals, old.id)
        }
        Error(_) -> state.pending_proposals
      }
      let new_proposals = dict.insert(new_proposals, proposal.id, proposal)
      actor.continue(BrainState(..state, pending_proposals: new_proposals))
    }
    RegisterShellApproval(approval:) -> {
      // One per channel — supersede existing
      let new_approvals = case
        list.find(dict.values(state.pending_shell_approvals), fn(a) {
          a.channel_id == approval.channel_id
        })
      {
        Ok(old) -> {
          process.send(old.reply_to, brain_tools.Expired)
          process.spawn_unlinked(fn() {
            let _ =
              state.discord.edit_message(
                old.channel_id,
                old.message_id,
                "~~Superseded~~",
              )
            Nil
          })
          dict.delete(state.pending_shell_approvals, old.id)
        }
        Error(_) -> state.pending_shell_approvals
      }
      let new_approvals =
        dict.insert(new_approvals, approval.id, approval)
      actor.continue(
        BrainState(..state, pending_shell_approvals: new_approvals),
      )
    }
  }
}

fn handle_proposal_interaction(
  state: BrainState,
  action: String,
  proposal: brain_tools.PendingProposal,
) -> actor.Next(BrainState, BrainMessage) {
  let new_proposals = dict.delete(state.pending_proposals, proposal.id)
  let now = time.now_ms()
  let expired = now - proposal.requested_at_ms > 900_000
  case expired {
    True -> {
      logging.log(logging.Info, "[brain] Proposal expired: " <> proposal.id)
      process.send(proposal.reply_to, brain_tools.Expired)
      process.spawn_unlinked(fn() {
        let _ =
          state.discord.edit_message(
            proposal.channel_id,
            proposal.message_id,
            "**Expired** -- proposal timed out after 15 minutes.",
          )
        Nil
      })
      actor.continue(BrainState(..state, pending_proposals: new_proposals))
    }
    False ->
      case action {
        "approve" -> {
          case
            tools.write_file(
              proposal.path,
              state.paths.data,
              proposal.content,
              state.validation_rules,
              True,
            )
          {
            Ok(_) -> {
              process.send(proposal.reply_to, brain_tools.Approved)
              process.spawn_unlinked(fn() {
                let _ =
                  state.discord.edit_message(
                    proposal.channel_id,
                    proposal.message_id,
                    "**Approved** -- wrote `" <> proposal.path <> "`",
                  )
                Nil
              })
            }
            Error(e) -> {
              process.send(proposal.reply_to, brain_tools.Rejected)
              process.spawn_unlinked(fn() {
                let _ =
                  state.discord.edit_message(
                    proposal.channel_id,
                    proposal.message_id,
                    "**Failed** -- " <> e,
                  )
                Nil
              })
            }
          }
          actor.continue(BrainState(..state, pending_proposals: new_proposals))
        }
        "reject" -> {
          process.send(proposal.reply_to, brain_tools.Rejected)
          process.spawn_unlinked(fn() {
            let _ =
              state.discord.edit_message(
                proposal.channel_id,
                proposal.message_id,
                "**Rejected**",
              )
            Nil
          })
          actor.continue(BrainState(..state, pending_proposals: new_proposals))
        }
        _ -> actor.continue(state)
      }
  }
}

fn handle_shell_interaction(
  state: BrainState,
  action: String,
  approval: brain_tools.PendingShellApproval,
) -> actor.Next(BrainState, BrainMessage) {
  let new_approvals =
    dict.delete(state.pending_shell_approvals, approval.id)
  let now = time.now_ms()
  let expired = now - approval.requested_at_ms > 900_000
  case expired {
    True -> {
      process.send(approval.reply_to, brain_tools.Expired)
      process.spawn_unlinked(fn() {
        let _ =
          state.discord.edit_message(
            approval.channel_id,
            approval.message_id,
            "**Expired** -- approval timed out after 15 minutes.",
          )
        Nil
      })
      actor.continue(
        BrainState(..state, pending_shell_approvals: new_approvals),
      )
    }
    False ->
  case action {
    "approve" -> {
      process.send(approval.reply_to, brain_tools.Approved)
      process.spawn_unlinked(fn() {
        let _ =
          state.discord.edit_message(
            approval.channel_id,
            approval.message_id,
            ":white_check_mark: **Approved** -- `" <> approval.command <> "`",
          )
        Nil
      })
      actor.continue(
        BrainState(..state, pending_shell_approvals: new_approvals),
      )
    }
    "reject" -> {
      process.send(approval.reply_to, brain_tools.Rejected)
      process.spawn_unlinked(fn() {
        let _ =
          state.discord.edit_message(
            approval.channel_id,
            approval.message_id,
            ":x: **Rejected**",
          )
        Nil
      })
      actor.continue(
        BrainState(..state, pending_shell_approvals: new_approvals),
      )
    }
    _ -> actor.continue(state)
  }
  }
}

fn handle_acp_event(
  state: BrainState,
  event: acp_monitor.AcpEvent,
) -> actor.Next(BrainState, BrainMessage) {
  case event {
    acp_monitor.AcpStarted(session_name, domain, task_id) -> {
      let msg =
        "**ACP Started** -- "
        <> task_id
        <> "\n`"
        <> session_name
        <> "`"
      let channel = resolve_acp_channel(state, session_name, domain)
      process.spawn_unlinked(fn() {
        send_discord_response(state.discord, channel, msg)
      })
      // Clear progress message ID so next progress creates a new message
      let new_msgs = dict.delete(state.acp_progress_msgs, session_name)
      actor.continue(BrainState(..state, acp_progress_msgs: new_msgs))
    }
    acp_monitor.AcpAlert(session_name, domain, status, summary) -> {
      let status_str = acp_types.status_to_string(status)
      let title = acp_monitor.extract_field(summary, "Title:")
      let title_display = case title {
        "" -> session_name
        _ -> title
      }

      let elapsed_str = case
        flare_manager.get_session(state.acp_subject, session_name)
      {
        Ok(flare) -> {
          let elapsed_min = { time.now_ms() - flare.started_at_ms } / 60_000
          int.to_string(elapsed_min) <> "m elapsed"
        }
        Error(_) -> ""
      }

      let header =
        "\u{26A0}\u{FE0F} **"
        <> title_display
        <> "** \u{00B7} "
        <> elapsed_str
        <> " \u{00B7} "
        <> status_str
        <> "\n`"
        <> session_name
        <> "`"

      let done = acp_monitor.extract_field(summary, "Done:")
      let current = acp_monitor.extract_field(summary, "Current:")
      let needs = acp_monitor.extract_field(summary, "Needs input:")
      let next = acp_monitor.extract_field(summary, "Next:")
      let parts = [
        "**Status:** " <> status_str,
        case done {
          "" -> ""
          _ -> "**Done:** " <> done
        },
        case current {
          "" -> ""
          _ -> "**Current:** " <> current
        },
        case needs {
          "" | "none" | "None" -> ""
          _ -> "**Needs input:** " <> needs
        },
        case next {
          "" -> ""
          _ -> "**Next:** " <> next
        },
      ]
      let body = list.filter(parts, fn(p) { p != "" }) |> string.join("\n")
      let msg = header <> "\n\n" <> body

      let channel = resolve_acp_channel(state, session_name, domain)
      process.spawn_unlinked(fn() {
        send_discord_response(state.discord, channel, msg)
      })
      actor.continue(state)
    }
    acp_monitor.AcpCompleted(session_name, domain, report, result_text) -> {
      let channel = resolve_acp_channel(state, session_name, domain)
      case result_text {
        "" -> {
          let outcome = acp_types.outcome_to_string(report.outcome)
          let msg =
            "**ACP Complete** [" <> outcome <> "] -- " <> report.anchor
          process.spawn_unlinked(fn() {
            send_discord_response(state.discord, channel, msg)
          })
          let new_msgs =
            dict.delete(state.acp_progress_msgs, session_name)
          actor.continue(BrainState(..state, acp_progress_msgs: new_msgs))
        }
        text -> {
          // Persist result_text to flares table for dreaming synthesis
          persist_flare_result(
            state.acp_subject,
            state.db_subject,
            session_name,
            text,
          )
          let domain_name = case
            list.find(state.domains, fn(d) { d.name == domain })
          {
            Ok(d) -> Some(d.name)
            Error(_) -> None
          }
          process.spawn_unlinked(fn() {
            handle_handback(
              state,
              channel,
              domain_name,
              session_name,
              text,
            )
          })
          let new_msgs =
            dict.delete(state.acp_progress_msgs, session_name)
          actor.continue(BrainState(..state, acp_progress_msgs: new_msgs))
        }
      }
    }
    acp_monitor.AcpTurnCompleted(session_name, domain, result_text) -> {
      // Turn completed but session still alive — handback the results
      // so brain can respond naturally and optionally send follow-up prompts
      let channel = resolve_acp_channel(state, session_name, domain)
      case result_text {
        "" -> actor.continue(state)
        text -> {
          // Persist result_text to flares table for dreaming synthesis
          persist_flare_result(
            state.acp_subject,
            state.db_subject,
            session_name,
            text,
          )
          let domain_name = case
            list.find(state.domains, fn(d) { d.name == domain })
          {
            Ok(d) -> Some(d.name)
            Error(_) -> None
          }
          process.spawn_unlinked(fn() {
            handle_handback(
              state,
              channel,
              domain_name,
              session_name,
              text,
            )
          })
          actor.continue(state)
        }
      }
    }
    acp_monitor.AcpFailed(session_name, domain, error) -> {
      let msg = "**ACP Failed** -- " <> error
      let channel = resolve_acp_channel(state, session_name, domain)
      process.spawn_unlinked(fn() {
        send_discord_response(state.discord, channel, msg)
      })
      actor.continue(state)
    }
    acp_monitor.AcpProgress(
      session_name,
      domain,
      title,
      status,
      summary,
      is_idle,
    ) -> {
      // Write to domain log
      let domain_dir = xdg.domain_data_dir(state.paths, domain)
      case memory.append_domain_log(domain_dir, summary) {
        Ok(_) -> Nil
        Error(e) -> logging.log(logging.Error, "[brain] Failed to write domain log: " <> e)
      }

      // Build elapsed time from session
      let elapsed_str = case
        flare_manager.get_session(state.acp_subject, session_name)
      {
        Ok(flare) -> {
          let elapsed_min = { time.now_ms() - flare.started_at_ms } / 60_000
          int.to_string(elapsed_min) <> "m elapsed"
        }
        Error(_) -> ""
      }

      // Format Discord message
      let icon = case is_idle {
        True -> "\u{23F8}\u{FE0F}"
        False -> "\u{1F4CB}"
      }
      let title_display = case title {
        "" -> session_name
        _ -> title
      }
      let idle_suffix = case is_idle {
        True -> " \u{00B7} idle"
        False -> ""
      }

      let header =
        icon
        <> " **"
        <> title_display
        <> "** \u{00B7} "
        <> elapsed_str
        <> idle_suffix
        <> "\n`"
        <> session_name
        <> "`"

      // Build body from structured fields (same format for tmux and stdio — both LLM-summarized)
      let body = case is_idle {
            True -> {
              let done = acp_monitor.extract_field(summary, "Done:")
              let needs = acp_monitor.extract_field(summary, "Needs input:")
              let parts = [
                case done {
                  "" -> ""
                  _ -> "**Done:** " <> done
                },
                case needs {
                  "" | "none" | "None" -> ""
                  _ -> "**Needs input:** " <> needs
                },
              ]
              let body_text =
                list.filter(parts, fn(p) { p != "" }) |> string.join("\n")
              body_text <> "\n\nWant me to check on this? Reply in this thread."
            }
            False -> {
              let status_line = case status {
                "" -> ""
                _ -> "**Status:** " <> status
              }
              let done = acp_monitor.extract_field(summary, "Done:")
              let current = acp_monitor.extract_field(summary, "Current:")
              let needs = acp_monitor.extract_field(summary, "Needs input:")
              let next = acp_monitor.extract_field(summary, "Next:")
              let parts = [
                status_line,
                case done {
                  "" -> ""
                  _ -> "**Done:** " <> done
                },
                case current {
                  "" -> ""
                  _ -> "**Current:** " <> current
                },
                case needs {
                  "" | "none" | "None" -> ""
                  _ -> "**Needs input:** " <> needs
                },
                case next {
                  "" -> ""
                  _ -> "**Next:** " <> next
                },
              ]
              list.filter(parts, fn(p) { p != "" }) |> string.join("\n")
            }
          }

      let msg = header <> "\n\n" <> body
      let channel = resolve_acp_channel(state, session_name, domain)
      let discord = state.discord

      // Edit existing progress message or send new one
      let new_state = case dict.get(state.acp_progress_msgs, session_name) {
        Ok(#(ch, mid)) -> {
          process.spawn_unlinked(fn() {
            let safe = discord_message.clip_to_discord_limit(msg)
            case discord.edit_message(ch, mid, safe) {
              Ok(_) -> Nil
              Error(_) -> Nil
            }
          })
          state
        }
        Error(_) -> {
          // First progress for this session — send inline to get message ID
          let progress_msgs = state.acp_progress_msgs
          let sn = session_name
          let safe = discord_message.clip_to_discord_limit(msg)
          case discord.send_message(channel, safe) {
            Ok(message_id) ->
              BrainState(..state,
                acp_progress_msgs: dict.insert(progress_msgs, sn, #(channel, message_id)),
              )
            Error(err) -> {
              logging.log(logging.Error, "[brain] Failed to send progress: " <> err)
              state
            }
          }
        }
      }
      actor.continue(new_state)
    }
  }
}

/// Persist a flare's result_text to the DB for dreaming synthesis.
/// Shared by AcpCompleted and AcpTurnCompleted handlers.
/// Security scan before persisting — this text flows into dreaming LLM prompts.
fn persist_flare_result(
  acp_subject: process.Subject(flare_manager.FlareMsg),
  db_subject: process.Subject(db.DbMessage),
  session_name: String,
  result_text: String,
) -> Nil {
  case structured_memory.security_scan(result_text) {
    Error(reason) -> {
      logging.log(logging.Info, 
        "[brain] Blocked flare result_text for "
        <> session_name
        <> ": "
        <> reason,
      )
      Nil
    }
    Ok(_) ->
      case
        flare_manager.get_flare_by_session_name(acp_subject, session_name)
      {
        Ok(flare) -> {
          let _ =
            db.update_flare_result(
              db_subject,
              flare.id,
              result_text,
              time.now_ms(),
            )
          Nil
        }
        Error(_) -> Nil
      }
  }
}

/// Build a `channel_actor.Deps` from the brain's state for the given
/// channel and optional domain. Used when routing a message through the
/// experimental channel_actor path.
fn build_channel_actor_deps(
  state: BrainState,
  channel_id: String,
  domain_name: Option(String),
) -> channel_actor.Deps {
  // Resolve domain cwd from the domain config (if any).
  let domain_cwd = case domain_name {
    Some(name) ->
      case list.find(state.domain_configs, fn(dc) { dc.0 == name }) {
        Ok(#(_, cfg)) -> cfg.cwd
        Error(_) -> "."
      }
    None -> "."
  }
  let base_dir = case domain_name {
    Some(_) -> domain_cwd
    None -> state.paths.data
  }

  // Vision config: tiered domain-over-global resolution, then build the
  // LlmConfig for the resolved model spec.
  let domain_cfg_opt = case domain_name {
    Some(name) ->
      case list.find(state.domain_configs, fn(dc) { dc.0 == name }) {
        Ok(#(_, cfg)) -> Some(cfg)
        Error(_) -> None
      }
    None -> None
  }
  let resolved_vision =
    vision.resolve_vision_config(state.global_config, domain_cfg_opt)
  let vision_llm_config = case
    models.build_llm_config(resolved_vision.model_spec)
  {
    Ok(cfg) -> cfg
    Error(_) -> llm.LlmConfig(base_url: "", api_key: "", model: "")
  }

  channel_actor.Deps(
    channel_id: channel_id,
    discord_token: state.discord_token,
    db_subject: state.db_subject,
    acp_subject: state.acp_subject,
    paths: state.paths,
    discord: state.discord,
    llm_client: state.llm_client,
    skill_runner: state.skill_runner,
    browser_runner: state.browser_runner,
    skill_infos: state.skill_infos,
    skills_dir: state.skills_dir,
    validation_rules: state.validation_rules,
    base_dir: base_dir,
    domain_name: option.unwrap(domain_name, ""),
    domain_cwd: domain_cwd,
    llm_config: state.llm_config,
    vision_config: vision_llm_config,
    built_in_tools: state.built_in_tools,
    stream_spawn: stream_worker.spawn,
    tool_spawn: tool_worker.spawn,
    vision_spawn: vision_worker.spawn,
  )
}

fn resolve_domain_channel(state: BrainState, domain: String) -> String {
  case list.find(state.domains, fn(d) { d.name == domain }) {
    Ok(d) -> d.channel_id
    Error(_) -> state.aura_channel_id
  }
}

fn resolve_acp_channel(
  state: BrainState,
  session_name: String,
  domain: String,
) -> String {
  case flare_manager.get_session(state.acp_subject, session_name) {
    Ok(flare) ->
      case flare.thread_id {
        "" -> resolve_domain_channel(state, domain)
        id -> id
      }
    Error(_) -> resolve_domain_channel(state, domain)
  }
}

/// Build the system prompt and tool context for a channel.
/// Shared between handle_with_llm and handle_handback.
fn build_llm_context(
  state: BrainState,
  channel: String,
  domain_name: Option(String),
) -> #(String, brain_tools.ToolContext) {
  let domain_names = list.map(state.domains, fn(d) { d.name })
  let memory_content = case
    structured_memory.format_for_display(xdg.memory_path(state.paths))
  {
    Ok(c) -> c
    Error(_) -> ""
  }
  let user_content = case
    structured_memory.format_for_display(xdg.user_path(state.paths))
  {
    Ok(c) -> c
    Error(_) -> ""
  }
  let system_prompt =
    build_system_prompt(
      state.soul,
      domain_names,
      state.skill_infos,
      memory_content,
      user_content,
    )

  let domain_prompt = case domain_name {
    Some(name) -> {
      let config_dir = xdg.domain_config_dir(state.paths, name)
      let data_dir = xdg.domain_data_dir(state.paths, name)
      let state_dir = xdg.domain_state_dir(state.paths, name)
      let ctx =
        domain.load_context(config_dir, data_dir, state_dir, state.skill_infos)
      "\n\n" <> domain.build_domain_prompt(ctx)
    }
    None -> ""
  }
  let system_prompt = system_prompt <> domain_prompt

  let #(
    domain_cwd,
    acp_provider,
    acp_binary,
    acp_worktree,
    acp_server_url,
    acp_agent_name,
  ) = case domain_name {
    Some(name) ->
      case list.find(state.domain_configs, fn(dc) { dc.0 == name }) {
        Ok(#(_, cfg)) -> #(
          cfg.cwd,
          cfg.acp_provider,
          cfg.acp_binary,
          cfg.acp_worktree,
          cfg.acp_server_url,
          cfg.acp_agent_name,
        )
        Error(_) -> #(".", "claude-code", "", True, "", "")
      }
    None -> #(".", "claude-code", "", True, "", "")
  }

  let base_dir = case domain_name {
    Some(_) -> domain_cwd
    None -> state.paths.data
  }

  let domain_cfg_opt = case domain_name {
    Some(name) ->
      case list.find(state.domain_configs, fn(dc) { dc.0 == name }) {
        Ok(#(_, cfg)) -> Some(cfg)
        Error(_) -> None
      }
    None -> None
  }
  let vision_config = vision.resolve_vision_config(state.global_config, domain_cfg_opt)
  let tool_vision_fn = fn(image_url: String, question: String) -> Result(String, String) {
    case vision.is_enabled(vision_config) {
      False -> Error("vision not configured (set [models] vision in config.toml)")
      True -> {
        let cfg = case question {
          "" -> vision_config
          q -> vision.ResolvedVisionConfig(..vision_config, prompt: q)
        }
        describe_image(state.llm_client, cfg, image_url)
      }
    }
  }

  let tool_ctx =
    brain_tools.ToolContext(
      base_dir: base_dir,
      discord_token: state.discord_token,
      guild_id: state.guild_id,
      message_id: "",
      channel_id: channel,
      paths: state.paths,
      skill_infos: state.skill_infos,
      skills_dir: state.skills_dir,
      validation_rules: state.validation_rules,
      db_subject: state.db_subject,
      scheduler_subject: state.scheduler_subject,
      acp_subject: state.acp_subject,
      domain_name: option.unwrap(domain_name, "aura"),
      domain_cwd: domain_cwd,
      acp_provider: acp_provider,
      acp_binary: acp_binary,
      acp_worktree: acp_worktree,
      acp_server_url: acp_server_url,
      acp_agent_name: acp_agent_name,
      on_propose: fn(_) { Nil },
      shell_patterns: state.shell_patterns,
      on_shell_approve: fn(_) { Nil },
      vision_fn: tool_vision_fn,
      discord: state.discord,
      llm_client: state.llm_client,
      skill_runner: state.skill_runner,
      browser_runner: state.browser_runner,
    )

  // Build roster summary
  let flares = flare_manager.list_flares(state.acp_subject)
  let active_flares = list.filter(flares, fn(f) { f.status == flare_manager.Active })
  let parked_flares = list.filter(flares, fn(f) { f.status == flare_manager.Parked })
  let roster_section = case list.length(active_flares) + list.length(parked_flares) {
    0 -> ""
    _ -> {
      let active_lines = list.map(active_flares, fn(f) {
        "- \"" <> f.label <> "\" (" <> f.domain <> ") — active, session: " <> f.session_name
      })
      let parked_lines = list.map(parked_flares, fn(f) {
        "- \"" <> f.label <> "\" (" <> f.domain <> ") — parked"
      })
      "\n\n## Flare Roster"
      <> case active_lines { [] -> "" lines -> "\nActive:\n" <> string.join(lines, "\n") }
      <> case parked_lines { [] -> "" lines -> "\nParked:\n" <> string.join(lines, "\n") }
      <> "\n\nUse flare(action='rekindle', ...) to resume a parked flare. Use flare(action='ignite', ...) to start new work."
    }
  }
  let system_prompt = system_prompt <> roster_section

  #(system_prompt, tool_ctx)
}

/// Handle a flare reporting back — load thread conversation, append result
/// as system message, and re-enter the tool loop so the LLM responds naturally.
fn handle_handback(
  state: BrainState,
  channel: String,
  domain_name: Option(String),
  session_name: String,
  result_text: String,
) -> Nil {
  logging.log(logging.Info, 
    "[brain] Handback from " <> session_name <> " to channel " <> channel,
  )

  let system_msg =
    "[Flare reported back: \"" <> session_name <> "\"]\n\n" <> result_text

  let typing_stop = start_typing_loop(state.discord, channel)

  let #(system_prompt, tool_ctx) = build_llm_context(state, channel, domain_name)

  let now_ts = time.now_ms()
  let #(_, _, history) =
    conversation.get_or_load_db(
      state.conversations,
      state.db_subject,
      "discord",
      channel,
      now_ts,
    )

  let initial_messages =
    list.flatten([
      [llm.SystemMessage(system_prompt)],
      history,
      [llm.SystemMessage(system_msg)],
    ])

  let result =
    tool_loop_with_retry(state, tool_ctx, channel, initial_messages, 3)

  stop_typing_loop(typing_stop)

  case result {
    Ok(#(response_text, traces, msg_id, new_messages, _prompt_tokens)) -> {
      let handback_msg = llm.SystemMessage(system_msg)
      let all_turn_messages = [handback_msg, ..new_messages]

      let now = time.now_ms()
      case db.resolve_conversation(state.db_subject, "discord", channel, now) {
        Ok(convo_id) -> {
          case
            conversation.save_exchange_to_db(
              state.db_subject,
              convo_id,
              all_turn_messages,
              "aura",
              "Aura",
              now,
            )
          {
            Ok(_) -> Nil
            Error(e) -> logging.log(logging.Error, "[brain] Handback DB save failed: " <> e)
          }
        }
        Error(e) ->
          logging.log(logging.Info, 
            "[brain] Handback conversation resolve failed: " <> e,
          )
      }

      let full = conversation.format_full_message(traces, response_text)
      let _ = send_or_edit(state.discord, channel, msg_id, full)

      case state.self_subject {
        Some(subj) -> {
          let dn = option.unwrap(domain_name, "aura")
          process.send(
            subj,
            StoreExchange(channel, all_turn_messages, dn, 0),
          )
        }
        None -> Nil
      }
    }
    Error(e) -> {
      logging.log(logging.Error, "[brain] Handback tool loop failed: " <> e)
      let fallback_msg =
        "**Flare reported back** ("
        <> session_name
        <> ")\n\n"
        <> result_text
      send_discord_response(state.discord, channel, fallback_msg)
    }
  }
}

fn resolve_finding_channel(
  state: BrainState,
  finding: notification.Finding,
) -> String {
  resolve_domain_channel(state, finding.domain)
}

/// Spawn a process that sends typing indicators every 8 seconds.
/// Returns the PID of the typing process. Kill it to stop.
fn start_typing_loop(
  discord: DiscordClient,
  channel_id: String,
) -> process.Pid {
  process.spawn_unlinked(fn() { typing_loop(discord, channel_id) })
}

fn typing_loop(discord: DiscordClient, channel_id: String) -> Nil {
  let _ = discord.trigger_typing(channel_id)
  process.sleep(8000)
  typing_loop(discord, channel_id)
}

/// Send a new message or edit an existing one. Returns the message ID.
fn send_or_edit(
  discord: DiscordClient,
  channel_id: String,
  msg_id: String,
  content: String,
) -> String {
  let safe_content = discord_message.clip_to_discord_limit(content)
  case msg_id {
    "" -> {
      case discord.send_message(channel_id, safe_content) {
        Ok(id) -> id
        Error(_) -> ""
      }
    }
    existing -> {
      let _ = discord.edit_message(channel_id, existing, safe_content)
      existing
    }
  }
}

fn stop_typing_loop(pid: process.Pid) -> Nil {
  process.kill(pid)
}

fn send_discord_response(
  discord: DiscordClient,
  channel_id: String,
  content: String,
) -> Nil {
  logging.log(logging.Info, 
    "[brain] Sending to channel "
    <> channel_id
    <> ": "
    <> string.slice(content, 0, 100),
  )
  let safe_content = discord_message.clip_to_discord_limit(content)
  case discord.send_message(channel_id, safe_content) {
    Ok(_) -> Nil
    Error(err) -> {
      logging.log(logging.Error, "[brain] Failed to send message: " <> err)
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
  logging.log(logging.Info, 
    "[brain] Processing message from "
    <> msg.author_name
    <> " in channel "
    <> msg.channel_id,
  )

  // Determine response channel: if this is a top-level domain channel, create a thread.
  // If it's already a thread (or #aura), respond in the same channel.
  let is_domain_channel =
    list.any(state.domains, fn(d) { d.channel_id == msg.channel_id })
  let response_channel = case is_domain_channel {
    True -> {
      // Top-level domain message — create a thread
      let thread_name = string.slice(msg.content, 0, 50)
      case
        state.discord.create_thread_from_message(
          msg.channel_id,
          msg.message_id,
          thread_name,
        )
      {
        Ok(thread_id) -> {
          logging.log(logging.Info, 
            "[brain] Created thread "
            <> thread_id
            <> " for message in "
            <> msg.channel_id,
          )
          // Register thread → domain mapping so subsequent messages route correctly
          case brain_subject_opt, domain_name {
            Some(subj), Some(name) ->
              process.send(
                subj,
                RegisterThread(thread_id: thread_id, domain_name: name),
              )
            _, _ -> Nil
          }
          thread_id
        }
        Error(e) -> {
          logging.log(logging.Error, "[brain] Failed to create thread: " <> e)
          msg.channel_id
        }
      }
    }
    False -> msg.channel_id
  }

  // Start a typing indicator loop that refreshes every 8 seconds
  let typing_stop = start_typing_loop(state.discord, response_channel)

  let #(base_prompt, base_tool_ctx) = build_llm_context(state, response_channel, domain_name)

  // Append file system section and flare context (handle_with_llm-specific)
  let fs_section =
    "\n\n## File System\n"
    <> "You can read any file. Use ~ for home directory.\n"
    <> "\nAura directories:"
    <> "\n  Config: ~/.config/aura/"
    <> "\n  Data: ~/.local/share/aura/"
    <> "\n  State: ~/.local/state/aura/"
    <> case domain_name {
      Some(name) ->
        "\n\nCurrent domain: "
        <> name
        <> "\n  Instructions: ~/.config/aura/domains/"
        <> name
        <> "/AGENTS.md"
        <> "\n  Config: ~/.config/aura/domains/"
        <> name
        <> "/config.toml"
        <> "\n  Memory: ~/.local/share/aura/domains/"
        <> name
        <> "/MEMORY.md"
        <> "\n  State: ~/.local/state/aura/domains/"
        <> name
        <> "/STATE.md"
        <> "\n  Repos: ~/.local/share/aura/domains/"
        <> name
        <> "/repos/"
      None -> ""
    }
    <> "\n\nWrites to logs, memory, state, and skills are autonomous."
    <> "\nAll other writes require approval -- use propose(path, content, description)."

  // Inject flare context if this message is in a flare thread
  let flare_context = case
    list.find(flare_manager.list_sessions(state.acp_subject), fn(s) {
      s.thread_id == msg.channel_id
    })
  {
    Ok(flare) -> {
      "\n\n## Active Flare"
      <> "\nYou are in a flare thread."
      <> "\nSession: "
      <> flare.session_name
      <> "\nState: "
      <> flare_manager.status_to_string(flare.status)
      <> "\nDomain: "
      <> flare.domain
      <> "\nTask: "
      <> string.slice(flare.original_prompt, 0, 300)
      <> "\n\nUse flare(action='status', session_name='...') to check progress, flare(action='prompt', ...) to send instructions, flare(action='list') to see all flares."
    }
    Error(_) -> ""
  }
  let system_prompt = base_prompt <> fs_section <> flare_context

  // Vision preprocessing — describe attached images before tool loop
  let enriched_content = preprocess_attachments(state, msg, domain_name)

  // Load conversation history (from memory or DB)
  let now_ts = time.now_ms()
  let #(_, _, history) =
    conversation.get_or_load_db(
      state.conversations,
      state.db_subject,
      "discord",
      response_channel,
      now_ts,
    )
  logging.log(logging.Info, 
    "[brain] Loaded "
    <> int.to_string(list.length(history))
    <> " history messages for "
    <> response_channel,
  )

  let initial_messages =
    list.flatten([
      [llm.SystemMessage(system_prompt)],
      history,
      [llm.UserMessage(enriched_content)],
    ])

  let tool_ctx =
    brain_tools.ToolContext(
      ..base_tool_ctx,
      message_id: msg.message_id,
      on_propose: fn(proposal) {
        case brain_subject_opt {
          Some(subj) -> process.send(subj, RegisterProposal(proposal: proposal))
          None -> Nil
        }
      },
      on_shell_approve: fn(approval) {
        case brain_subject_opt {
          Some(subj) -> process.send(subj, RegisterShellApproval(approval: approval))
          None -> Nil
        }
      },
    )

  let result =
    tool_loop_with_retry(state, tool_ctx, response_channel, initial_messages, 3)

  // Stop typing indicator before any final edits
  stop_typing_loop(typing_stop)

  let discord = state.discord
  let channel_id = response_channel

  case result {
    Ok(#(response_text, traces, msg_id, new_messages, prompt_tokens)) -> {
      // Build the full turn: user message + tool chain + final response
      let user_msg = llm.UserMessage(enriched_content)
      let all_turn_messages = [user_msg, ..new_messages]

      // Save to DB FIRST — before Discord delivery — so the next turn sees this exchange
      let now = time.now_ms()
      case
        db.resolve_conversation(state.db_subject, "discord", channel_id, now)
      {
        Ok(convo_id) -> {
          case
            conversation.save_exchange_to_db(
              state.db_subject,
              convo_id,
              all_turn_messages,
              msg.author_id,
              msg.author_name,
              now,
            )
          {
            Ok(_) -> Nil
            Error(e) ->
              logging.log(logging.Info, 
                "[brain] DB save failed for " <> channel_id <> ": " <> e,
              )
          }
        }
        Error(e) ->
          logging.log(logging.Info, 
            "[brain] Failed to resolve conversation for "
            <> channel_id
            <> ": "
            <> e,
          )
      }

      let full = conversation.format_full_message(traces, response_text)
      let _ = send_or_edit(discord, channel_id, msg_id, full)

      // Update in-memory cache (async via actor mailbox — not blocking)
      case brain_subject_opt {
        Some(subj) -> {
          let dn = option.unwrap(domain_name, "aura")
          process.send(
            subj,
            StoreExchange(channel_id, all_turn_messages, dn, prompt_tokens),
          )
        }
        None -> Nil
      }

      // Post-response reviews
      let domain_for_review = option.unwrap(domain_name, "aura")
      let full_history = list.flatten([history, all_turn_messages])

      let review_count = case dict.get(state.review_counts, response_channel) {
        Ok(c) -> c
        Error(_) -> 0
      }
      let new_review_count =
        review.maybe_spawn_review(
          state.global_config.memory.review_interval,
          state.global_config.memory.notify_on_review,
          domain_for_review,
          response_channel,
          state.discord_token,
          full_history,
          review_count,
          state.paths,
          state.global_config.models.monitor,
        )
      // Update review count via actor mailbox
      case brain_subject_opt {
        Some(subj) ->
          process.send(
            subj,
            UpdateReviewCount(
              channel_id: response_channel,
              count: new_review_count,
            ),
          )
        None -> Nil
      }

      // Post-response skill review
      let current_count = case
        dict.get(state.skill_review_counts, response_channel)
      {
        Ok(c) -> c
        Error(_) -> 0
      }
      // Reset counter when the LLM saved a skill itself — a fresh save
      // makes the review redundant.
      let #(skill_review_count, new_iterations) = case traces {
        [] -> #(current_count, 0)
        _ ->
          case list.any(traces, fn(t) { t.name == "skill_manage" }) {
            True -> #(0, 0)
            False -> #(current_count, 1)
          }
      }
      let new_skill_review_count =
        review.maybe_spawn_skill_review(
          state.global_config.memory.skill_review_interval,
          domain_for_review,
          response_channel,
          state.discord_token,
          full_history,
          skill_review_count,
          new_iterations,
          state.paths,
          state.global_config.models.monitor,
          state.skills_dir,
        )
      case brain_subject_opt {
        Some(subj) ->
          process.send(
            subj,
            UpdateSkillReviewCount(
              channel_id: response_channel,
              count: new_skill_review_count,
            ),
          )
        None -> Nil
      }
    }
    Error(err) -> {
      logging.log(logging.Error, "[brain] Error: " <> err)
      let _ =
        discord.send_message(
          channel_id,
          "Sorry, I encountered an error.",
        )
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
) -> Result(
  #(String, List(conversation.ToolTrace), String, List(llm.Message), Int),
  String,
) {
  case
    tool_loop_progressive(state, tool_ctx, channel_id, messages, [], "", 0, [])
  {
    Ok(result) -> Ok(result)
    Error(err) -> {
      // Auto-probe: if context overflow, halve brain_context and retry
      let is_context_overflow =
        string.contains(err, "context_length")
        || string.contains(err, "maximum context")
        || string.contains(err, "token limit")
        || string.contains(err, "too many tokens")
        || string.contains(err, "context window")
      case is_context_overflow && retries_left > 0 {
        True -> {
          let new_context = state.brain_context / 2
          logging.log(logging.Info, 
            "[brain] Context overflow detected, halving brain_context to "
            <> int.to_string(new_context),
          )
          let new_state = BrainState(..state, brain_context: new_context)
          tool_loop_with_retry(
            new_state,
            tool_ctx,
            channel_id,
            messages,
            retries_left - 1,
          )
        }
        False ->
          case retries_left > 0 && string.contains(err, "timeout") {
            True -> {
              logging.log(logging.Info, 
                "[brain] Stream timeout, retrying ("
                <> int.to_string(retries_left)
                <> " left)...",
              )
              process.sleep(2000)
              tool_loop_with_retry(
                state,
                tool_ctx,
                channel_id,
                messages,
                retries_left - 1,
              )
            }
            False -> Error(err)
          }
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
) -> Result(
  #(String, List(conversation.ToolTrace), String, List(llm.Message), Int),
  String,
) {
  case iteration >= max_tool_iterations {
    True -> Error("Tool loop exceeded maximum iterations")
    False -> {
      // Pre-flight: if messages exceed context, prune tool outputs inline
      let messages = case
        compressor.estimate_messages_tokens(messages) > state.brain_context
      {
        True -> {
          logging.log(logging.Info, 
            "[brain] Pre-flight: messages exceed context, pruning tool outputs",
          )
          let #(pruned, count) =
            compressor.prune_tool_outputs(
              messages,
              compressor.min_tail_messages,
            )
          case count > 0 {
            True ->
              logging.log(logging.Info, 
                "[brain] Pre-flight: pruned "
                <> int.to_string(count)
                <> " tool output(s)",
              )
            False -> Nil
          }
          pruned
        }
        False -> messages
      }

      // Spawn streaming LLM call with tools
      let self_pid = process.self()
      let _ =
        process.spawn_unlinked(fn() {
          state.llm_client.stream_with_tools(
            state.llm_config,
            messages,
            state.built_in_tools,
            self_pid,
          )
        })

      // Collect the streaming response (content + tool calls)
      case
        collect_stream_response(
          state.discord,
          channel_id,
          message_id,
          traces,
          stream_idle_timeout_ms,
        )
      {
        Ok(#(content, tool_calls_json, msg_id, prompt_tokens)) -> {
          let response = parse_streaming_result(content, tool_calls_json)
          case response.tool_calls {
            [] -> {
              // No tool calls — return the text response with accumulated traces
              let final_new_messages =
                list.reverse([
                  llm.AssistantMessage(response.content),
                  ..list.reverse(new_messages)
                ])
              Ok(#(
                response.content,
                traces,
                msg_id,
                final_new_messages,
                prompt_tokens,
              ))
            }
            calls -> {
              // Expand concatenated JSON tool calls from GLM-5.1
              let calls =
                brain_tools.expand_tool_calls_with_tools(
                  calls,
                  state.built_in_tools,
                )
              // Execute tool calls and continue the loop
              logging.log(logging.Info, 
                "[brain] "
                <> int.to_string(list.length(calls))
                <> " tool call(s)",
              )

              // Execute each tool and build traces + result messages
              let #(rev_traces, rev_results) =
                list.fold(calls, #([], []), fn(acc, call) {
                  let #(acc_traces, acc_results) = acc
                  logging.log(logging.Info, 
                    "[brain] Tool: " <> call.name <> " args: " <> call.arguments,
                  )
                  let #(tool_result, parsed_args) =
                    brain_tools.execute_tool(tool_ctx, call)
                  let result_text = brain_tools.tool_result_text(tool_result)
                  let result_preview = string.slice(result_text, 0, 100)
                  logging.log(logging.Info, "[brain] Result: " <> result_preview)

                  let is_error = string.starts_with(result_text, "Error")
                  let trace =
                    conversation.ToolTrace(
                      name: call.name,
                      args: brain_tools.format_tool_args(parsed_args),
                      result: result_text,
                      is_error: is_error,
                    )
                  #([trace, ..acc_traces], [
                    llm.ToolResultMessage(call.id, result_text),
                    ..acc_results
                  ])
                })
              let new_traces = list.flatten([traces, list.reverse(rev_traces)])
              let tool_results = list.reverse(rev_results)
              let traces_text = conversation.format_traces(new_traces)

              // If the model narrated text before these tool calls, finalize
              // the current Discord message with that text + its traces
              // (chronological: narrative → tools it then ran), and start a
              // fresh message for the next iteration. Pure tool-call
              // iterations keep editing the same message in place.
              let split_next_iteration = !string.is_empty(response.content)
              let #(next_traces, next_message_id) = case split_next_iteration {
                True -> {
                  let finalized = response.content <> "\n\n" <> traces_text
                  // Edit (don't POST a duplicate of) the message the stream
                  // just created with its narrative text.
                  let _ =
                    send_or_edit(
                      state.discord,
                      channel_id,
                      msg_id,
                      finalized,
                    )
                  #([], "")
                }
                False -> {
                  let progress_text = traces_text <> "\n\n*Thinking...*"
                  let mid =
                    send_or_edit(
                      state.discord,
                      channel_id,
                      msg_id,
                      progress_text,
                    )
                  #(new_traces, mid)
                }
              }

              // Track new messages from this iteration: assistant tool call + tool results
              let iteration_messages = [
                llm.AssistantToolCallMessage(response.content, calls),
                ..tool_results
              ]
              let updated_new_messages =
                list.flatten([new_messages, iteration_messages])

              // Build full messages for the next LLM call: all prior messages + this iteration
              let updated_messages =
                list.flatten([messages, iteration_messages])

              tool_loop_progressive(
                state,
                tool_ctx,
                channel_id,
                updated_messages,
                next_traces,
                next_message_id,
                iteration + 1,
                updated_new_messages,
              )
            }
          }
        }
        Error(err) -> Error(err)
      }
    }
  }
}

/// Per-stream instrumentation counters. Captured in the collect_stream_loop
/// state so a heartbeat log line can surface reasoning-vs-delta progress
/// every ~30s, and a final summary fires at termination. Exists purely for
/// observability — no control flow depends on these fields.
type StreamStats {
  StreamStats(
    start_ms: Int,
    reasoning_count: Int,
    delta_count: Int,
    last_heartbeat_ms: Int,
  )
}

const stream_heartbeat_interval_ms = 30_000

fn new_stream_stats() -> StreamStats {
  let now = time.now_ms()
  StreamStats(
    start_ms: now,
    reasoning_count: 0,
    delta_count: 0,
    last_heartbeat_ms: now,
  )
}

fn maybe_heartbeat(stats: StreamStats, content_chars: Int) -> StreamStats {
  let now = time.now_ms()
  case now - stats.last_heartbeat_ms >= stream_heartbeat_interval_ms {
    True -> {
      logging.log(logging.Info,
        "[llm] stream progress: "
        <> int.to_string(stats.reasoning_count)
        <> " reasoning, "
        <> int.to_string(stats.delta_count)
        <> " delta ("
        <> int.to_string(content_chars)
        <> " chars), "
        <> int.to_string({ now - stats.start_ms } / 1000)
        <> "s elapsed",
      )
      StreamStats(..stats, last_heartbeat_ms: now)
    }
    False -> stats
  }
}

fn log_stream_summary(
  stats: StreamStats,
  outcome: String,
  content_chars: Int,
) -> Nil {
  let elapsed = { time.now_ms() - stats.start_ms } / 1000
  logging.log(logging.Info,
    "[llm] stream "
    <> outcome
    <> ": "
    <> int.to_string(stats.reasoning_count)
    <> " reasoning, "
    <> int.to_string(stats.delta_count)
    <> " delta ("
    <> int.to_string(content_chars)
    <> " chars), "
    <> int.to_string(elapsed)
    <> "s total",
  )
}

/// Collect a streaming LLM response, progressively editing Discord.
/// Returns (content, tool_calls_json, message_id, prompt_tokens).
fn collect_stream_response(
  discord: DiscordClient,
  channel_id: String,
  message_id: String,
  traces: List(conversation.ToolTrace),
  timeout_ms: Int,
) -> Result(#(String, String, String, Int), String) {
  collect_stream_loop(
    discord,
    channel_id,
    message_id,
    traces,
    "",
    0,
    timeout_ms,
    new_stream_stats(),
  )
}

fn collect_stream_loop(
  discord: DiscordClient,
  channel_id: String,
  msg_id: String,
  traces: List(conversation.ToolTrace),
  accumulated: String,
  last_edit_len: Int,
  remaining_ms: Int,
  stats: StreamStats,
) -> Result(#(String, String, String, Int), String) {
  case remaining_ms <= 0 {
    True -> {
      log_stream_summary(stats, "idle-timeout", string.length(accumulated))
      Error("Stream timeout")
    }
    False -> {
      let wait = case remaining_ms > stream_check_interval_ms {
        True -> stream_check_interval_ms
        False -> remaining_ms
      }
      case receive_stream_message(wait) {
        StreamDelta(delta) -> {
          let new_acc = accumulated <> delta
          // Progressive edit every 150 chars
          let #(new_msg_id, new_edit_len) = case
            string.length(new_acc) - last_edit_len > progressive_edit_chars
          {
            True -> {
              let display =
                conversation.format_full_message(traces, new_acc <> " ...")
              #(
                send_or_edit(discord, channel_id, msg_id, display),
                string.length(new_acc),
              )
            }
            False -> #(msg_id, last_edit_len)
          }
          let new_stats =
            StreamStats(..stats, delta_count: stats.delta_count + 1)
            |> maybe_heartbeat(string.length(new_acc))
          // Data received — reset idle timeout to 120s
          collect_stream_loop(
            discord,
            channel_id,
            new_msg_id,
            traces,
            new_acc,
            new_edit_len,
            stream_idle_timeout_ms,
            new_stats,
          )
        }
        StreamReasoning -> {
          let new_stats =
            StreamStats(..stats, reasoning_count: stats.reasoning_count + 1)
            |> maybe_heartbeat(string.length(accumulated))
          // GLM-5.1 thinking — stream is alive, reset idle timeout
          collect_stream_loop(
            discord,
            channel_id,
            msg_id,
            traces,
            accumulated,
            last_edit_len,
            stream_idle_timeout_ms,
            new_stats,
          )
        }
        StreamComplete(content, tool_calls_json, prompt_tokens) -> {
          log_stream_summary(stats, "complete", string.length(content))
          // Stream finished — do final Discord edit if we have content
          let final_msg_id = case
            string.length(content) > 0
            && string.length(content) != last_edit_len
          {
            True -> {
              let display = conversation.format_full_message(traces, content)
              send_or_edit(discord, channel_id, msg_id, display)
            }
            False -> msg_id
          }
          Ok(#(content, tool_calls_json, final_msg_id, prompt_tokens))
        }
        StreamDone -> {
          log_stream_summary(stats, "done", string.length(accumulated))
          // Legacy done signal — treat as complete with no tool calls
          Ok(#(accumulated, "[]", msg_id, 0))
        }
        StreamError(err) -> {
          log_stream_summary(stats, "error", string.length(accumulated))
          Error("Stream error: " <> err)
        }
        StreamTimeout -> {
          // Inner check-interval tick (default 500ms) with no event. Not an
          // error — the outer `remaining_ms` budget governs the real idle
          // timeout. Still run the heartbeat so silent periods are visible.
          let new_stats = maybe_heartbeat(stats, string.length(accumulated))
          collect_stream_loop(
            discord,
            channel_id,
            msg_id,
            traces,
            accumulated,
            last_edit_len,
            remaining_ms - wait,
            new_stats,
          )
        }
      }
    }
  }
}

/// Parse the streaming result into an LlmResponse.
fn parse_streaming_result(
  content: String,
  tool_calls_json: String,
) -> llm.LlmResponse {
  case tool_calls_json {
    "[]" -> llm.LlmResponse(content: content, tool_calls: [])
    json_str -> {
      // Parse tool calls from JSON: [{"id":"...","name":"...","arguments":"..."}]
      case llm.parse_flat_tool_calls_json(json_str) {
        Ok(calls) -> llm.LlmResponse(content: content, tool_calls: calls)
        Error(_) -> {
          logging.log(logging.Info, 
            "[brain] Failed to parse tool calls JSON: "
            <> string.slice(json_str, 0, 200),
          )
          llm.LlmResponse(content: content, tool_calls: [])
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Domain context helpers
// ---------------------------------------------------------------------------

fn load_domain_context_files(
  paths: xdg.Paths,
  domain_name: String,
) -> #(String, String) {
  case domain_name {
    "aura" -> #("", "")
    name -> {
      let agents_path = xdg.domain_config_dir(paths, name) <> "/AGENTS.md"
      let state_path = xdg.domain_state_path(paths, name)
      let a_md = case simplifile.read(agents_path) {
        Ok(c) -> c
        Error(e) -> {
          logging.log(logging.Info, 
            "[brain] Failed to read AGENTS.md for "
            <> name
            <> ": "
            <> string.inspect(e),
          )
          ""
        }
      }
      let s_md = case simplifile.read(state_path) {
        Ok(c) -> c
        Error(e) -> {
          logging.log(logging.Info, 
            "[brain] Failed to read STATE.md for "
            <> name
            <> ": "
            <> string.inspect(e),
          )
          ""
        }
      }
      #(a_md, s_md)
    }
  }
}

// ---------------------------------------------------------------------------
// Vision preprocessing
// ---------------------------------------------------------------------------

/// Preprocess message content: fetch text file attachments, describe images.
fn preprocess_attachments(
  state: BrainState,
  msg: discord.IncomingMessage,
  domain_name: Option(String),
) -> String {
  case msg.attachments {
    [] -> msg.content
    attachments -> {
      // First: download every attachment to /tmp and inline local paths so
      // the LLM can pass them to shell/skills. Non-blocking on failure.
      let path_lines = download_attachments_to_tmp(attachments, msg.message_id)

      // Fetch text file attachments and prepend their content. Reads from
      // the local copy when available to avoid a second CDN round-trip.
      let text_content = fetch_text_attachments(attachments, msg.message_id)
      let with_paths = case path_lines {
        "" -> msg.content
        p -> p <> "\n\n" <> msg.content
      }
      let base_content = case text_content {
        "" -> with_paths
        content -> content <> "\n\n" <> with_paths
      }

      // Then: handle image attachments via vision
      let first_image =
        list.find(attachments, fn(a) { vision.is_image_attachment(a) })
      case first_image {
        Error(_) -> base_content
        Ok(att) -> {
          let domain_config = case domain_name {
            Some(name) -> {
              case list.find(state.domain_configs, fn(dc) { dc.0 == name }) {
                Ok(#(_, cfg)) -> Some(cfg)
                Error(_) -> None
              }
            }
            None -> None
          }
          let vision_config =
            vision.resolve_vision_config(state.global_config, domain_config)
          case vision.is_enabled(vision_config) {
            False -> {
              logging.log(logging.Info, "[brain] Vision not configured, skipping image")
              base_content
            }
            True -> {
              // Prefer the local copy as a base64 data URL — Discord CDN
              // URLs with HMAC query strings get rejected by some vision
              // endpoints (e.g. GLM returns 400 on them).
              let local_path =
                attachment_dir(msg.message_id)
                <> "/"
                <> safe_filename(att.filename)
              let image_ref = case browser.read_as_data_url(local_path) {
                Ok(data_url) -> data_url
                Error(e) -> {
                  logging.log(logging.Info, "[brain] data-url fallback failed (" <> e <> "); using CDN URL")
                  att.url
                }
              }
              logging.log(logging.Info, "[brain] Processing image attachment: " <> att.filename)
              case describe_image(state.llm_client, vision_config, image_ref) {
                Ok(description) -> {
                  logging.log(logging.Info,
                    "[brain] Vision description: "
                    <> string.slice(description, 0, 100),
                  )
                  "[Image " <> att.filename <> ": " <> description <> "]\n\n" <> base_content
                }
                Error(err) -> {
                  logging.log(logging.Error, "[brain] Vision error: " <> err)
                  base_content
                }
              }
            }
          }
        }
      }
    }
  }
}

const attachment_tmp_base = "/tmp/aura-attachments"

const attachment_download_timeout_ms = 30_000

/// Drop path separators and navigation elements from a user-supplied
/// filename so it can't escape the per-message tmp dir.
fn safe_filename(name: String) -> String {
  let segments =
    name
    |> string.replace("\\", "/")
    |> string.split("/")
  case list.last(segments) {
    Ok("") | Ok(".") | Ok("..") | Error(_) -> "attachment"
    Ok(seg) -> seg
  }
}

fn attachment_dir(msg_id: String) -> String {
  attachment_tmp_base <> "/" <> msg_id
}

/// Download every attachment to /tmp/aura-attachments/<msg_id>/ and return
/// one line per attachment formatted as `[attachment: /path] filename`.
/// Best-effort: failures are logged but don't block the message.
fn download_attachments_to_tmp(
  attachments: List(discord_types.Attachment),
  msg_id: String,
) -> String {
  let dir = attachment_dir(msg_id)
  case simplifile.create_directory_all(dir) {
    Error(e) -> {
      logging.log(logging.Error, "[brain] Attachment dir create failed for " <> dir <> ": " <> simplifile.describe_error(e))
      ""
    }
    Ok(_) -> {
      let lines = list.filter_map(attachments, fn(att) {
        let path = dir <> "/" <> safe_filename(att.filename)
        case web.fetch_bytes(att.url, attachment_download_timeout_ms) {
          Error(e) -> {
            logging.log(logging.Error, "[brain] Attachment download failed for " <> att.filename <> ": " <> e)
            Error(Nil)
          }
          Ok(bytes) ->
            case simplifile.write_bits(path, bytes) {
              Error(e) -> {
                logging.log(logging.Error, "[brain] Attachment write failed for " <> path <> ": " <> simplifile.describe_error(e))
                Error(Nil)
              }
              Ok(_) -> {
                logging.log(logging.Info, "[brain] Attachment saved: " <> path)
                Ok("[attachment: " <> path <> "] " <> att.filename)
              }
            }
        }
      })
      string.join(lines, "\n")
    }
  }
}

/// Read text file attachments as content for inlining. Prefers the local
/// copy at /tmp/aura-attachments/<msg_id>/; falls back to CDN fetch when
/// the download hook left no file on disk.
fn fetch_text_attachments(
  attachments: List(discord_types.Attachment),
  msg_id: String,
) -> String {
  let dir = attachment_dir(msg_id)
  let text_parts = list.filter_map(attachments, fn(att) {
    case is_text_attachment(att) {
      False -> Error(Nil)
      True -> {
        let local = dir <> "/" <> safe_filename(att.filename)
        let content_result = case simplifile.read(local) {
          Ok(content) -> Ok(content)
          Error(_) -> web.fetch(att.url, 50_000)
        }
        case content_result {
          Ok(content) -> {
            logging.log(logging.Info, "[brain] Inlining text attachment " <> att.filename <> " (" <> int.to_string(string.length(content)) <> " chars)")
            Ok("[File: " <> att.filename <> "]\n```\n" <> content <> "\n```")
          }
          Error(e) -> {
            logging.log(logging.Error, "[brain] Failed to read " <> att.filename <> ": " <> e)
            Error(Nil)
          }
        }
      }
    }
  })
  string.join(text_parts, "\n\n")
}

fn is_text_attachment(att: discord_types.Attachment) -> Bool {
  let ct = string.lowercase(att.content_type)
  let fn_lower = string.lowercase(att.filename)
  string.starts_with(ct, "text/")
  || string.ends_with(fn_lower, ".json")
  || string.ends_with(fn_lower, ".toml")
  || string.ends_with(fn_lower, ".yaml")
  || string.ends_with(fn_lower, ".yml")
  || string.ends_with(fn_lower, ".md")
  || string.ends_with(fn_lower, ".gleam")
  || string.ends_with(fn_lower, ".rs")
  || string.ends_with(fn_lower, ".py")
  || string.ends_with(fn_lower, ".js")
  || string.ends_with(fn_lower, ".ts")
  || string.ends_with(fn_lower, ".swift")
  || string.ends_with(fn_lower, ".sh")
  || string.ends_with(fn_lower, ".sql")
  || string.ends_with(fn_lower, ".csv")
  || string.ends_with(fn_lower, ".xml")
  || string.ends_with(fn_lower, ".html")
  || string.ends_with(fn_lower, ".css")
  || string.ends_with(fn_lower, ".erl")
  || string.ends_with(fn_lower, ".ex")
  || string.ends_with(fn_lower, ".go")
  || string.ends_with(fn_lower, ".java")
  || string.ends_with(fn_lower, ".kt")
  || string.ends_with(fn_lower, ".c")
  || string.ends_with(fn_lower, ".h")
  || string.ends_with(fn_lower, ".cpp")
  || string.ends_with(fn_lower, ".log")
  || string.ends_with(fn_lower, ".env")
  || string.ends_with(fn_lower, ".cfg")
  || string.ends_with(fn_lower, ".ini")
  || string.ends_with(fn_lower, ".conf")
  || ct == "application/json"
  || ct == "application/xml"
  || ct == "application/toml"
}

/// Call the vision model to describe an image. Routed through
/// `LLMClient.chat_text` so tests can inject a fake vision response.
fn describe_image(
  client: LLMClient,
  vision_config: vision.ResolvedVisionConfig,
  image_url: String,
) -> Result(String, String) {
  use llm_config <- result.try(models.build_llm_config(vision_config.model_spec))
  let messages = [
    llm.UserMessageWithImage(
      content: vision_config.prompt,
      image_url: image_url,
    ),
  ]
  client.chat_text(llm_config, messages, None)
}

// ---------------------------------------------------------------------------
// Streaming support
// ---------------------------------------------------------------------------

/// Events received from the streaming FFI via receive_stream_message_ffi.
type StreamEvent {
  StreamDelta(String)
  StreamReasoning
  StreamComplete(content: String, tool_calls_json: String, prompt_tokens: Int)
  StreamDone
  StreamError(String)
  StreamTimeout
}

/// Receive a stream event from the process mailbox.
@external(erlang, "aura_stream_ffi", "receive_stream_message")
fn receive_stream_message_ffi(timeout_ms: Int) -> #(String, String, String, Int)

fn receive_stream_message(timeout_ms: Int) -> StreamEvent {
  case receive_stream_message_ffi(timeout_ms) {
    #("delta", text, _, _) -> StreamDelta(text)
    #("reasoning", _, _, _) -> StreamReasoning
    #("complete", content, tc_json, prompt_tokens) ->
      StreamComplete(content, tc_json, prompt_tokens)
    #("done", _, _, _) -> StreamDone
    #("error", err, _, _) -> StreamError(err)
    _ -> StreamTimeout
  }
}
