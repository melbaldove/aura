import aura/acp/manager
import aura/acp/monitor as acp_monitor
import aura/acp/types as acp_types
import aura/brain_tools
import aura/compressor
import aura/config
import aura/conversation
import aura/db
import aura/discord
import aura/discord/rest
import aura/domain
import aura/llm
import aura/memory
import aura/models
import aura/notification
import aura/review
import aura/scheduler
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
import gleam/io
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

const max_tool_iterations = 40

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
    acp_subject: process.Subject(manager.AcpMessage),
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
    acp_subject: process.Subject(manager.AcpMessage),
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
  <> "\n- When asked to triage, investigate, plan, or work on a ticket — dispatch an ACP session. Do NOT try to do the work inline in chat."
  <> "\n- For domain creation, use the propose tool to request approval."
  <> "\n\nMemory guidance:"
  <> "\nYou have three types of persistent memory, all keyed by topic:"
  <> "\n- **state** — current domain status. What's in flight right now: active tickets, PRs, blockers. Upsert by key (e.g. key='HY-5195', key='pr-216')."
  <> "\n- **memory** — durable domain knowledge. Decisions, patterns, conventions. Upsert by key (e.g. key='jira-patterns', key='branch-workflow')."
  <> "\n- **user** — user profile (global). Preferences, communication style, role."
  <> "\nAll entries are keyed. Use `set` to create or update, `remove` to delete. No need to read before writing — set is an upsert."
  <> "\nState and memory are per-domain. When in a domain channel, they target that domain's files. In #aura, they target global files."
  <> "\nUpdate state and memory after significant actions:"
  <> "\n- Closing/completing an ACP session → set state for what was done, set memory for what was learned"
  <> "\n- Dispatching an ACP session → set state that it's in progress"
  <> "\n- Ticket status change → set state"
  <> "\n- Discovering a codebase pattern → set memory"
  <> "\n\nSkills guidance:"
  <> "\nBefore using run_skill, call view_skill first to read the skill's full instructions. The instructions contain exact commands, argument format, and examples. Never guess CLI syntax."
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

  // Resolve context length for compression thresholds
  let brain_context = case
    models.resolve_context_length(config.models.brain, config.brain_context)
  {
    Ok(len) -> len
    Error(e) -> {
      io.println("[brain] Warning: " <> e <> ", defaulting to 128000")
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
          // Check cache first, then Discord API for parent channel
          case dict.get(state.thread_domains, msg.channel_id) {
            Ok(name) -> {
              io.println("[brain] Route: " <> name <> " (via thread cache)")
              Some(name)
            }
            Error(_) -> {
              // Look up parent channel from Discord — is this a thread?
              case
                rest.get_channel_parent(state.discord_token, msg.channel_id)
              {
                Ok("") -> {
                  io.println("[brain] Route: #aura")
                  None
                }
                Ok(parent_id) -> {
                  // Check if parent is a domain channel
                  case route_message(parent_id, state.domains) {
                    DirectRoute(name) -> {
                      io.println(
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
                      io.println("[brain] Route: #aura")
                      None
                    }
                  }
                }
                Error(_) -> {
                  io.println("[brain] Route: #aura")
                  None
                }
              }
            }
          }
        }
      }
      let subj = state.self_subject
      process.spawn_unlinked(fn() {
        case rescue(fn() { handle_with_llm(state, msg, subj, domain_name) }) {
          Ok(_) -> Nil
          Error(reason) -> {
            io.println("[brain] CRASH in handle_with_llm: " <> reason)
            let _ =
              rest.send_message(
                state.discord_token,
                msg.channel_id,
                "Sorry, I crashed while processing your message. Check the logs.",
                [],
              )
            Nil
          }
        }
      })
      actor.continue(state)
    }
    UpdateDomains(domains) -> {
      io.println(
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
              state.discord_token,
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
              io.println(
                "[brain] No #aura channel configured for digest delivery",
              )
              Nil
            }
            _ -> {
              process.spawn_unlinked(fn() {
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
          let msg =
            "Aura is online. No domains configured yet. Tell me about your first project and I'll set one up."
          process.spawn_unlinked(fn() {
            send_discord_response(state.discord_token, channel_id, msg)
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
          io.println("[brain] Full compression triggered for " <> cache_key)
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
                io.println(
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
                  io.println(
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
          io.println(
            "[brain] Compression complete for "
            <> channel_id
            <> " (merging "
            <> int.to_string(delta_len)
            <> " new messages)",
          )
          list.append(compressed_history, delta)
        }
        False -> {
          io.println("[brain] Compression complete for " <> channel_id)
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
      io.println("[brain] Scheduler connected")
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
          Error(e) -> io.println("[brain] Failed to ack interaction: " <> e)
        }
      })

      // Parse action and proposal_id from custom_id
      case string.split_once(custom_id, ":") {
        Error(_) -> actor.continue(state)
        Ok(#(action, proposal_id)) -> {
          case dict.get(state.pending_proposals, proposal_id) {
            Error(_) -> {
              io.println("[brain] Unknown proposal: " <> proposal_id)
              actor.continue(state)
            }
            Ok(proposal) -> {
              // Check timeout (15 minutes = 900_000ms)
              let now = time.now_ms()
              let expired = now - proposal.requested_at_ms > 900_000
              case expired {
                True -> {
                  io.println("[brain] Proposal expired: " <> proposal_id)
                  process.send(proposal.reply_to, brain_tools.Expired)
                  process.spawn_unlinked(fn() {
                    let _ =
                      rest.edit_message(
                        state.discord_token,
                        proposal.channel_id,
                        proposal.message_id,
                        "**Expired** -- proposal timed out after 15 minutes.",
                      )
                    Nil
                  })
                  let new_proposals =
                    dict.delete(state.pending_proposals, proposal_id)
                  actor.continue(
                    BrainState(..state, pending_proposals: new_proposals),
                  )
                }
                False -> {
                  case action {
                    "approve" -> {
                      let new_proposals =
                        dict.delete(state.pending_proposals, proposal_id)
                      // Execute the write with validation (approved = True bypasses tier)
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
                          // Notify the blocked propose tool that it's approved
                          process.send(proposal.reply_to, brain_tools.Approved)
                          process.spawn_unlinked(fn() {
                            let _ =
                              rest.edit_message(
                                state.discord_token,
                                proposal.channel_id,
                                proposal.message_id,
                                "**Approved** -- wrote `"
                                  <> proposal.path
                                  <> "`",
                              )
                            Nil
                          })
                        }
                        Error(e) -> {
                          // Write failed (validation error) — still notify the tool
                          process.send(proposal.reply_to, brain_tools.Rejected)
                          process.spawn_unlinked(fn() {
                            let _ =
                              rest.edit_message(
                                state.discord_token,
                                proposal.channel_id,
                                proposal.message_id,
                                "**Failed** -- " <> e,
                              )
                            Nil
                          })
                        }
                      }
                      actor.continue(
                        BrainState(..state, pending_proposals: new_proposals),
                      )
                    }
                    "reject" -> {
                      let new_proposals =
                        dict.delete(state.pending_proposals, proposal_id)
                      process.send(proposal.reply_to, brain_tools.Rejected)
                      process.spawn_unlinked(fn() {
                        let _ =
                          rest.edit_message(
                            state.discord_token,
                            proposal.channel_id,
                            proposal.message_id,
                            "**Rejected**",
                          )
                        Nil
                      })
                      actor.continue(
                        BrainState(..state, pending_proposals: new_proposals),
                      )
                    }
                    unknown -> {
                      io.println(
                        "[brain] Unknown interaction action: "
                        <> unknown
                        <> " for proposal "
                        <> proposal_id,
                      )
                      actor.continue(state)
                    }
                  }
                }
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
              rest.edit_message(
                state.discord_token,
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
        <> "\n`tmux attach -t "
        <> session_name
        <> "`"
      let channel = resolve_acp_channel(state, session_name, domain)
      process.spawn_unlinked(fn() {
        send_discord_response(state.discord_token, channel, msg)
      })
      actor.continue(state)
    }
    acp_monitor.AcpAlert(session_name, domain, status, summary) -> {
      let status_str = acp_types.status_to_string(status)
      let title = extract_summary_field(summary, "Title:")
      let title_display = case title {
        "" -> session_name
        _ -> title
      }

      let elapsed_str = case
        manager.get_session(state.acp_subject, session_name)
      {
        Ok(session) -> {
          let elapsed_min = { time.now_ms() - session.started_at_ms } / 60_000
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

      let done = extract_summary_field(summary, "Done:")
      let current = extract_summary_field(summary, "Current:")
      let needs = extract_summary_field(summary, "Needs input:")
      let next = extract_summary_field(summary, "Next:")
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
        send_discord_response(state.discord_token, channel, msg)
      })
      actor.continue(state)
    }
    acp_monitor.AcpCompleted(session_name, domain, report) -> {
      let outcome = acp_types.outcome_to_string(report.outcome)
      let msg = "**ACP Complete** [" <> outcome <> "] -- " <> report.anchor
      let channel = resolve_acp_channel(state, session_name, domain)
      process.spawn_unlinked(fn() {
        send_discord_response(state.discord_token, channel, msg)
      })
      actor.continue(state)
    }
    acp_monitor.AcpTimedOut(session_name, domain) -> {
      let msg =
        "**ACP Timeout** -- Session still alive. `tmux attach -t "
        <> session_name
        <> "`"
      let channel = resolve_acp_channel(state, session_name, domain)
      process.spawn_unlinked(fn() {
        send_discord_response(state.discord_token, channel, msg)
      })
      actor.continue(state)
    }
    acp_monitor.AcpFailed(session_name, domain, error) -> {
      let msg = "**ACP Failed** -- " <> error
      let channel = resolve_acp_channel(state, session_name, domain)
      process.spawn_unlinked(fn() {
        send_discord_response(state.discord_token, channel, msg)
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
        Error(e) -> io.println("[brain] Failed to write domain log: " <> e)
      }

      // Build elapsed time from session
      let elapsed_str = case
        manager.get_session(state.acp_subject, session_name)
      {
        Ok(session) -> {
          let elapsed_min = { time.now_ms() - session.started_at_ms } / 60_000
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

      // Build body from structured fields
      let body = case is_idle {
        True -> {
          // Idle: show Done + Needs input + nudge
          let done = extract_summary_field(summary, "Done:")
          let needs = extract_summary_field(summary, "Needs input:")
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
          // Active: show Status + Done + Current + Needs input + Next
          let status_line = case status {
            "" -> ""
            _ -> "**Status:** " <> status
          }
          let done = extract_summary_field(summary, "Done:")
          let current = extract_summary_field(summary, "Current:")
          let needs = extract_summary_field(summary, "Needs input:")
          let next = extract_summary_field(summary, "Next:")
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
      process.spawn_unlinked(fn() {
        send_discord_response(state.discord_token, channel, msg)
      })
      actor.continue(state)
    }
  }
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
  case manager.get_session(state.acp_subject, session_name) {
    Ok(session) ->
      case session.thread_id {
        "" -> resolve_domain_channel(state, domain)
        id -> id
      }
    Error(_) -> resolve_domain_channel(state, domain)
  }
}

fn resolve_finding_channel(
  state: BrainState,
  finding: notification.Finding,
) -> String {
  resolve_domain_channel(state, finding.domain)
}

/// Extract a field from a structured summary.
/// Given "Done: fixed the bug\nCurrent: running tests", extract_summary_field(text, "Done:") returns "fixed the bug".
fn extract_summary_field(text: String, field: String) -> String {
  case string.split(text, "\n") {
    [] -> ""
    lines -> {
      case
        list.find(lines, fn(line) {
          string.starts_with(string.trim(line), field)
        })
      {
        Ok(line) ->
          string.trim(string.drop_start(string.trim(line), string.length(field)))
        Error(_) -> ""
      }
    }
  }
}

/// Spawn a process that sends typing indicators every 8 seconds.
/// Returns the PID of the typing process. Kill it to stop.
fn start_typing_loop(token: String, channel_id: String) -> process.Pid {
  process.spawn_unlinked(fn() { typing_loop(token, channel_id) })
}

fn typing_loop(token: String, channel_id: String) -> Nil {
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
  // Discord message limit is 2000 chars
  let safe_content = case string.length(content) > 1990 {
    True -> string.slice(content, 0, 1990) <> " ..."
    False -> content
  }
  case msg_id {
    "" -> {
      case rest.send_message(token, channel_id, safe_content, []) {
        Ok(id) -> id
        Error(_) -> ""
      }
    }
    existing -> {
      let _ = rest.edit_message(token, channel_id, existing, safe_content)
      existing
    }
  }
}

fn stop_typing_loop(pid: process.Pid) -> Nil {
  process.kill(pid)
}

fn send_discord_response(
  token: String,
  channel_id: String,
  content: String,
) -> Nil {
  io.println(
    "[brain] Sending to channel "
    <> channel_id
    <> ": "
    <> string.slice(content, 0, 100),
  )
  // Discord message limit is 2000 chars
  let safe_content = case string.length(content) > 1990 {
    True -> string.slice(content, 0, 1990) <> " ..."
    False -> content
  }
  case rest.send_message(token, channel_id, safe_content, []) {
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
  io.println(
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
        rest.create_thread_from_message(
          state.discord_token,
          msg.channel_id,
          msg.message_id,
          thread_name,
        )
      {
        Ok(thread_id) -> {
          io.println(
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
          io.println("[brain] Failed to create thread: " <> e)
          msg.channel_id
        }
      }
    }
    False -> msg.channel_id
  }

  // Start a typing indicator loop that refreshes every 8 seconds
  let typing_stop = start_typing_loop(state.discord_token, response_channel)

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

  // Load domain context if routed to a domain
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

  let system_prompt = system_prompt <> domain_prompt <> fs_section

  // Inject ACP session context if this message is in an ACP thread
  let acp_context = case
    list.find(manager.list_sessions(state.acp_subject), fn(s) {
      s.thread_id == msg.channel_id
    })
  {
    Ok(session) -> {
      "\n\n## Active ACP Session"
      <> "\nYou are in an ACP session thread."
      <> "\nSession: "
      <> session.session_name
      <> "\nState: "
      <> manager.session_state_to_string(session.state)
      <> "\nDomain: "
      <> session.domain
      <> "\nTask: "
      <> string.slice(session.prompt, 0, 300)
      <> "\n\nUse acp_status to check progress, acp_prompt to send instructions, acp_list to see all sessions."
    }
    Error(_) -> ""
  }
  let system_prompt = system_prompt <> acp_context

  // Vision preprocessing — describe attached images before tool loop
  let enriched_content = preprocess_vision(state, msg, domain_name)

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
  io.println(
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

  // Look up domain config once for cwd + provider settings
  let #(domain_cwd, acp_provider, acp_binary, acp_worktree) = case domain_name {
    Some(name) ->
      case list.find(state.domain_configs, fn(dc) { dc.0 == name }) {
        Ok(#(_, cfg)) -> #(
          cfg.cwd,
          cfg.acp_provider,
          cfg.acp_binary,
          cfg.acp_worktree,
        )
        Error(_) -> #(".", "claude-code", "", True)
      }
    None -> #(".", "claude-code", "", True)
  }

  let base_dir = case domain_name {
    Some(_) -> domain_cwd
    None -> state.paths.data
  }

  let tool_ctx =
    brain_tools.ToolContext(
      base_dir: base_dir,
      discord_token: state.discord_token,
      guild_id: state.guild_id,
      message_id: msg.message_id,
      channel_id: response_channel,
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
      on_propose: fn(proposal) {
        case brain_subject_opt {
          Some(subj) -> process.send(subj, RegisterProposal(proposal: proposal))
          None -> Nil
        }
      },
    )

  let result =
    tool_loop_with_retry(state, tool_ctx, response_channel, initial_messages, 3)

  // Stop typing indicator before any final edits
  stop_typing_loop(typing_stop)

  let token = state.discord_token
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
              io.println(
                "[brain] DB save failed for " <> channel_id <> ": " <> e,
              )
          }
        }
        Error(e) ->
          io.println(
            "[brain] Failed to resolve conversation for "
            <> channel_id
            <> ": "
            <> e,
          )
      }

      let full = conversation.format_full_message(traces, response_text)
      let _ = send_or_edit(token, channel_id, msg_id, full)

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
      let skill_review_count = case
        dict.get(state.skill_review_counts, response_channel)
      {
        Ok(c) -> c
        Error(_) -> 0
      }
      let new_tool_calls = list.length(traces)
      let new_skill_review_count =
        review.maybe_spawn_skill_review(
          state.global_config.memory.skill_review_interval,
          domain_for_review,
          response_channel,
          state.discord_token,
          full_history,
          skill_review_count,
          new_tool_calls,
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
      io.println("[brain] Error: " <> err)
      let _ =
        rest.send_message(
          token,
          channel_id,
          "Sorry, I encountered an error.",
          [],
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
          io.println(
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
              io.println(
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
          io.println(
            "[brain] Pre-flight: messages exceed context, pruning tool outputs",
          )
          let #(pruned, count) =
            compressor.prune_tool_outputs(
              messages,
              compressor.min_tail_messages,
            )
          case count > 0 {
            True ->
              io.println(
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
          llm.chat_streaming_with_tools(
            state.llm_config,
            messages,
            state.built_in_tools,
            self_pid,
          )
        })

      // Collect the streaming response (content + tool calls)
      case
        collect_stream_response(
          state.discord_token,
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
              let calls = brain_tools.expand_tool_calls(calls)
              // Execute tool calls and continue the loop
              io.println(
                "[brain] "
                <> int.to_string(list.length(calls))
                <> " tool call(s)",
              )

              // Execute each tool and build traces + result messages
              let #(rev_traces, rev_results) =
                list.fold(calls, #([], []), fn(acc, call) {
                  let #(acc_traces, acc_results) = acc
                  io.println(
                    "[brain] Tool: " <> call.name <> " args: " <> call.arguments,
                  )
                  let #(tool_result, parsed_args) =
                    brain_tools.execute_tool(tool_ctx, call)
                  let result_text = brain_tools.tool_result_text(tool_result)
                  let result_preview = string.slice(result_text, 0, 100)
                  io.println("[brain] Result: " <> result_preview)

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

              // Format current traces for progressive display
              let progress_text =
                conversation.format_traces(new_traces) <> "\n\n*Thinking...*"

              // Send or edit message with current trace progress
              let new_message_id =
                send_or_edit(
                  state.discord_token,
                  channel_id,
                  message_id,
                  progress_text,
                )

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
                new_traces,
                new_message_id,
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

/// Collect a streaming LLM response, progressively editing Discord.
/// Returns (content, tool_calls_json, message_id, prompt_tokens).
fn collect_stream_response(
  token: String,
  channel_id: String,
  message_id: String,
  traces: List(conversation.ToolTrace),
  timeout_ms: Int,
) -> Result(#(String, String, String, Int), String) {
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
) -> Result(#(String, String, String, Int), String) {
  case remaining_ms <= 0 {
    True -> Error("Stream timeout")
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
                send_or_edit(token, channel_id, msg_id, display),
                string.length(new_acc),
              )
            }
            False -> #(msg_id, last_edit_len)
          }
          // Data received — reset idle timeout to 120s
          collect_stream_loop(
            token,
            channel_id,
            new_msg_id,
            traces,
            new_acc,
            new_edit_len,
            stream_idle_timeout_ms,
          )
        }
        StreamReasoning -> {
          // GLM-5.1 thinking — stream is alive, reset idle timeout
          collect_stream_loop(
            token,
            channel_id,
            msg_id,
            traces,
            accumulated,
            last_edit_len,
            stream_idle_timeout_ms,
          )
        }
        StreamComplete(content, tool_calls_json, prompt_tokens) -> {
          // Stream finished — do final Discord edit if we have content
          let final_msg_id = case
            string.length(content) > 0
            && string.length(content) != last_edit_len
          {
            True -> {
              let display = conversation.format_full_message(traces, content)
              send_or_edit(token, channel_id, msg_id, display)
            }
            False -> msg_id
          }
          Ok(#(content, tool_calls_json, final_msg_id, prompt_tokens))
        }
        StreamDone -> {
          // Legacy done signal — treat as complete with no tool calls
          Ok(#(accumulated, "[]", msg_id, 0))
        }
        StreamError(err) -> Error("Stream error: " <> err)
        StreamTimeout -> {
          collect_stream_loop(
            token,
            channel_id,
            msg_id,
            traces,
            accumulated,
            last_edit_len,
            remaining_ms - wait,
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
          io.println(
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
          io.println(
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
          io.println(
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
          let vision_config =
            vision.resolve_vision_config(state.global_config, domain_config)
          case vision.is_enabled(vision_config) {
            False -> {
              io.println("[brain] Vision not configured, skipping image")
              msg.content
            }
            True -> {
              io.println("[brain] Processing image attachment: " <> first_url)
              case describe_image(vision_config, first_url) {
                Ok(description) -> {
                  io.println(
                    "[brain] Vision description: "
                    <> string.slice(description, 0, 100),
                  )
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
  use llm_config <- result.try(models.build_llm_config(vision_config.model_spec))
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
