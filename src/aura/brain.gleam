import aura/acp/flare_manager
import aura/acp/monitor as acp_monitor
import aura/acp/types as acp_types
import aura/brain_tools
import aura/channel_actor
import aura/channel_supervisor
import aura/clients/browser_runner.{type BrowserRunner}
import aura/clients/discord_client.{type DiscordClient}
import aura/clients/llm_client.{type LLMClient}
import aura/clients/skill_runner.{type SkillRunner}
import aura/config
import aura/db
import aura/discord
import aura/discord/message as discord_message
import aura/discord/rest
import aura/llm
import aura/memory
import aura/models
import aura/notification
import aura/review_runner
import aura/scheduler
import aura/shell
import aura/skill
import aura/stream_worker
import aura/structured_memory
import aura/time
import aura/tool_worker
import aura/validator
import aura/vision
import aura/vision_worker
import aura/xdg
import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import logging

// ---------------------------------------------------------------------------
// FFI
// ---------------------------------------------------------------------------

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
  RegisterThread(thread_id: String, domain_name: String)
  SetScheduler(process.Subject(scheduler.SchedulerMessage))
  HandleInteraction(
    interaction_id: String,
    interaction_token: String,
    custom_id: String,
    channel_id: String,
  )
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
    review_runner: review_runner.ReviewRunner,
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
    self_subject: Option(process.Subject(BrainMessage)),
    global_config: config.GlobalConfig,
    domain_configs: List(#(String, config.DomainConfig)),
    thread_domains: dict.Dict(String, String),
    scheduler_subject: Option(process.Subject(scheduler.SchedulerMessage)),
    brain_context: Int,
    shell_patterns: shell.CompiledPatterns,
    acp_progress_msgs: dict.Dict(String, #(String, String)),
    // session_name -> #(channel_id, message_id)
    discord: DiscordClient,
    llm_client: LLMClient,
    skill_runner: SkillRunner,
    browser_runner: BrowserRunner,
    channel_supervisor: process.Subject(channel_supervisor.SupervisorMessage),
    review_runner: review_runner.ReviewRunner,
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
      logging.log(
        logging.Warning,
        "[brain] Warning: " <> e <> ", defaulting to 128000",
      )
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
      thread_domains: dict.new(),
      self_subject: None,
      global_config: brain_config.global,
      domain_configs: brain_config.domain_configs,
      scheduler_subject: None,
      brain_context: brain_context,
      shell_patterns: shell.compile_patterns(),
      acp_progress_msgs: dict.new(),
      discord: brain_config.discord,
      llm_client: brain_config.llm,
      skill_runner: brain_config.skill_runner,
      browser_runner: brain_config.browser_runner,
      channel_supervisor: brain_config.channel_supervisor,
      review_runner: brain_config.review_runner,
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
              logging.log(
                logging.Info,
                "[brain] Route: " <> name <> " (via thread cache)",
              )
              Some(name)
            }
            Error(_) -> {
              // Look up parent channel from Discord — is this a thread?
              case state.discord.get_channel_parent(msg.channel_id) {
                Ok("") -> {
                  logging.log(logging.Info, "[brain] Route: #aura")
                  None
                }
                Ok(parent_id) -> {
                  // Check if parent is a domain channel
                  case route_message(parent_id, state.domains) {
                    DirectRoute(name) -> {
                      logging.log(
                        logging.Info,
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
      // Thread creation for top-level domain channels
      let is_top_level_domain =
        list.any(state.domains, fn(d) { d.channel_id == msg.channel_id })
      let #(routed_channel_id, new_state) = case
        is_top_level_domain,
        domain_name
      {
        True, Some(name) -> {
          let thread_name = string.slice(msg.content, 0, 50)
          case
            state.discord.create_thread_from_message(
              msg.channel_id,
              msg.message_id,
              thread_name,
            )
          {
            Ok(thread_id) -> {
              logging.log(
                logging.Info,
                "[brain] Created thread " <> thread_id <> " for domain " <> name,
              )
              let updated =
                BrainState(
                  ..state,
                  thread_domains: dict.insert(
                    state.thread_domains,
                    thread_id,
                    name,
                  ),
                )
              #(thread_id, updated)
            }
            Error(e) -> {
              logging.log(
                logging.Error,
                "[brain] Thread creation failed: "
                  <> e
                  <> ", routing to original channel",
              )
              #(msg.channel_id, state)
            }
          }
        }
        _, _ -> #(msg.channel_id, state)
      }
      logging.log(logging.Info, "[brain] Routing msg to " <> routed_channel_id)
      let routed_msg =
        discord.IncomingMessage(..msg, channel_id: routed_channel_id)
      let deps =
        build_channel_actor_deps(new_state, routed_channel_id, domain_name)
      let subject =
        channel_supervisor.get_or_start(
          new_state.channel_supervisor,
          routed_channel_id,
          deps,
        )
      process.send(subject, channel_actor.HandleIncoming(routed_msg))
      actor.continue(new_state)
    }
    UpdateDomains(domains) -> {
      logging.log(
        logging.Info,
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
              logging.log(
                logging.Info,
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
    RegisterThread(thread_id:, domain_name:) -> {
      let new_threads =
        dict.insert(state.thread_domains, thread_id, domain_name)
      actor.continue(BrainState(..state, thread_domains: new_threads))
    }
    SetScheduler(subject) -> {
      logging.log(logging.Info, "[brain] Scheduler connected")
      actor.continue(BrainState(..state, scheduler_subject: Some(subject)))
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
          Error(e) ->
            logging.log(
              logging.Error,
              "[brain] Failed to ack interaction: " <> e,
            )
        }
      })

      // Parse three-part custom_id: "{action}:{channel_id}:{approval_id}"
      case string.split(custom_id, ":") {
        [action, ch, approval_id] -> {
          let domain_name = case dict.get(state.thread_domains, ch) {
            Ok(d) -> Some(d)
            Error(_) -> None
          }
          let deps = build_channel_actor_deps(state, ch, domain_name)
          let subject =
            channel_supervisor.get_or_start(state.channel_supervisor, ch, deps)
          process.send(
            subject,
            channel_actor.HandleInteractionResolve(action, approval_id),
          )
          actor.continue(state)
        }
        _ -> {
          logging.log(
            logging.Info,
            "[brain] Unknown approval custom_id: " <> custom_id,
          )
          actor.continue(state)
        }
      }
    }
  }
}

fn handle_acp_event(
  state: BrainState,
  event: acp_monitor.AcpEvent,
) -> actor.Next(BrainState, BrainMessage) {
  case event {
    acp_monitor.AcpStarted(session_name, domain, task_id) -> {
      let msg = "**ACP Started** -- " <> task_id <> "\n`" <> session_name <> "`"
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
          let msg = "**ACP Complete** [" <> outcome <> "] -- " <> report.anchor
          process.spawn_unlinked(fn() {
            send_discord_response(state.discord, channel, msg)
          })
          let new_msgs = dict.delete(state.acp_progress_msgs, session_name)
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
          // Route handback via channel_actor keyed on the flare's thread_id.
          route_handback_to_channel_actor(state, session_name, domain, text)
          let new_msgs = dict.delete(state.acp_progress_msgs, session_name)
          actor.continue(BrainState(..state, acp_progress_msgs: new_msgs))
        }
      }
    }
    acp_monitor.AcpTurnCompleted(session_name, domain, result_text) -> {
      // Turn completed but session still alive — handback the results
      // so brain can respond naturally and optionally send follow-up prompts
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
          // Route handback via channel_actor keyed on the flare's thread_id.
          route_handback_to_channel_actor(state, session_name, domain, text)
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
        Error(e) ->
          logging.log(
            logging.Error,
            "[brain] Failed to write domain log: " <> e,
          )
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
              BrainState(
                ..state,
                acp_progress_msgs: dict.insert(progress_msgs, sn, #(
                  channel,
                  message_id,
                )),
              )
            Error(err) -> {
              logging.log(
                logging.Error,
                "[brain] Failed to send progress: " <> err,
              )
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
      logging.log(
        logging.Info,
        "[brain] Blocked flare result_text for "
          <> session_name
          <> ": "
          <> reason,
      )
      Nil
    }
    Ok(_) ->
      case flare_manager.get_flare_by_session_name(acp_subject, session_name) {
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

  // Resolve ACP fields from domain config, mirroring old build_llm_context logic.
  let #(acp_provider, acp_binary, acp_worktree, acp_server_url, acp_agent_name) =
    case domain_name {
      Some(name) ->
        case list.find(state.domain_configs, fn(dc) { dc.0 == name }) {
          Ok(#(_, cfg)) -> #(
            cfg.acp_provider,
            cfg.acp_binary,
            cfg.acp_worktree,
            cfg.acp_server_url,
            cfg.acp_agent_name,
          )
          Error(_) -> #("claude-code", "", True, "", "")
        }
      None -> #("claude-code", "", True, "", "")
    }

  let domain_names = list.map(state.domains, fn(d) { d.name })
  channel_actor.Deps(
    channel_id: channel_id,
    discord_token: state.discord_token,
    guild_id: state.guild_id,
    db_subject: state.db_subject,
    acp_subject: state.acp_subject,
    scheduler_subject: state.scheduler_subject,
    paths: state.paths,
    domain: domain_name,
    review_interval: state.global_config.memory.review_interval,
    skill_review_interval: state.global_config.memory.skill_review_interval,
    notify_on_review: state.global_config.memory.notify_on_review,
    monitor_model: state.global_config.models.monitor,
    review_runner: state.review_runner,
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
    acp_provider: acp_provider,
    acp_binary: acp_binary,
    acp_worktree: acp_worktree,
    acp_server_url: acp_server_url,
    acp_agent_name: acp_agent_name,
    llm_config: state.llm_config,
    vision_config: vision_llm_config,
    resolved_vision_config: resolved_vision,
    built_in_tools: state.built_in_tools,
    stream_spawn: stream_worker.spawn,
    tool_spawn: tool_worker.spawn,
    vision_spawn: vision_worker.spawn,
    brain_context: state.brain_context,
    soul: state.soul,
    domain_names: domain_names,
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

/// Route a handback event to the channel_actor for the flare's thread_id.
/// Looks up the flare by session_name to get its thread_id, then sends
/// HandleHandback to the channel_actor managing that thread. Logs a warning
/// when the flare is unknown.
fn route_handback_to_channel_actor(
  state: BrainState,
  session_name: String,
  _domain: String,
  text: String,
) -> Nil {
  case flare_manager.get_session(state.acp_subject, session_name) {
    Ok(flare) -> {
      let domain_name = case
        list.find(state.domains, fn(d) { d.name == flare.domain })
      {
        Ok(_) -> Some(flare.domain)
        Error(_) -> None
      }
      let deps = build_channel_actor_deps(state, flare.thread_id, domain_name)
      let subject =
        channel_supervisor.get_or_start(
          state.channel_supervisor,
          flare.thread_id,
          deps,
        )
      process.send(
        subject,
        channel_actor.HandleHandback(flare.id, flare.session_name, text),
      )
    }
    Error(_) ->
      logging.log(
        logging.Info,
        "[brain] Handback for unknown flare: " <> session_name,
      )
  }
}

fn resolve_finding_channel(
  state: BrainState,
  finding: notification.Finding,
) -> String {
  resolve_domain_channel(state, finding.domain)
}

fn send_discord_response(
  discord: DiscordClient,
  channel_id: String,
  content: String,
) -> Nil {
  logging.log(
    logging.Info,
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
