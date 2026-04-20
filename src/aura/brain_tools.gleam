import aura/acp/flare_manager
import aura/acp/provider
import aura/acp/types as acp_types
import aura/browser
import aura/clients/browser_runner.{type BrowserRunner}
import aura/clients/discord_client.{type DiscordClient}
import aura/clients/llm_client.{type LLMClient}
import aura/clients/skill_runner.{type SkillRunner}
import aura/db
import aura/discord/rest
import aura/discord/types as discord_types
import aura/llm
import aura/memory
import aura/path_utils
import aura/scheduler
import aura/shell
import aura/skill
import aura/structured_memory
import aura/tier
import aura/time
import aura/tools
import aura/validator
import aura/web
import aura/xdg
import gleam/dict
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import logging

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// Result of executing a tool.
pub type ToolResult {
  TextResult(String)
}

/// A pending write proposal awaiting user approval via Discord buttons.
pub type ProposalResult {
  Approved
  Rejected
  Expired
}

pub type PendingProposal {
  PendingProposal(
    id: String,
    path: String,
    content: String,
    description: String,
    channel_id: String,
    message_id: String,
    tier: Int,
    requested_at_ms: Int,
    reply_to: process.Subject(ProposalResult),
  )
}

/// A pending shell command awaiting user approval via Discord buttons.
pub type PendingShellApproval {
  PendingShellApproval(
    id: String,
    command: String,
    reason: String,
    channel_id: String,
    message_id: String,
    requested_at_ms: Int,
    reply_to: process.Subject(ProposalResult),
  )
}

/// Subset of BrainState fields needed for tool execution.
/// Avoids a circular dependency between brain and brain_tools.
pub type ToolContext {
  ToolContext(
    base_dir: String,
    discord_token: String,
    guild_id: String,
    message_id: String,
    channel_id: String,
    paths: xdg.Paths,
    skill_infos: List(skill.SkillInfo),
    skills_dir: String,
    validation_rules: List(validator.Rule),
    db_subject: process.Subject(db.DbMessage),
    scheduler_subject: Option(process.Subject(scheduler.SchedulerMessage)),
    acp_subject: process.Subject(flare_manager.FlareMsg),
    domain_name: String,
    domain_cwd: String,
    acp_provider: String,
    acp_binary: String,
    acp_worktree: Bool,
    acp_server_url: String,
    acp_agent_name: String,
    on_propose: fn(PendingProposal) -> Nil,
    shell_patterns: shell.CompiledPatterns,
    on_shell_approve: fn(PendingShellApproval) -> Nil,
    vision_fn: fn(String, String) -> Result(String, String),
    discord: DiscordClient,
    llm_client: LLMClient,
    skill_runner: SkillRunner,
    browser_runner: BrowserRunner,
  )
}

// ---------------------------------------------------------------------------
// Tool execution
// ---------------------------------------------------------------------------

/// Execute a tool call against the given tool context.
/// Returns the result and the parsed args (so the caller can build traces
/// without re-parsing).
pub fn execute_tool(
  ctx: ToolContext,
  call: llm.ToolCall,
) -> #(ToolResult, List(#(String, String))) {
  let args = parse_tool_args(call.arguments)
  case get_arg(args, "_parse_error") {
    "" -> #(execute_tool_dispatch(ctx, call.name, args), args)
    raw -> {
      logging.log(
        logging.Info,
        "[brain] Failed to parse tool args for "
          <> call.name
          <> ": "
          <> string.slice(raw, 0, 200),
      )
      #(
        TextResult(
          "Error: failed to parse tool arguments. Check the argument format and try again.",
        ),
        args,
      )
    }
  }
}

fn execute_tool_dispatch(
  ctx: ToolContext,
  name: String,
  args: List(#(String, String)),
) -> ToolResult {
  case name {
    "read_file" -> {
      case require_arg(args, "path") {
        Error(e) -> TextResult(e)
        Ok(path) -> {
          case tools.read_file(path, ctx.base_dir) {
            Ok(content) -> TextResult(content)
            Error(e) -> TextResult("Error: " <> e)
          }
        }
      }
    }
    "write_file" -> {
      case require_arg(args, "path") {
        Error(e) -> TextResult(e)
        Ok(path) ->
          case require_arg(args, "content") {
            Error(e) -> TextResult(e)
            Ok(content) -> {
              case
                tools.write_file(
                  path,
                  ctx.base_dir,
                  content,
                  ctx.validation_rules,
                  False,
                )
              {
                Ok(_) -> TextResult("File written: " <> path)
                Error(e) -> TextResult("Error: " <> e)
              }
            }
          }
      }
    }
    "append_file" -> {
      case require_arg(args, "path") {
        Error(e) -> TextResult(e)
        Ok(path) ->
          case require_arg(args, "content") {
            Error(e) -> TextResult(e)
            Ok(content) -> {
              case
                tools.append_file(
                  path,
                  ctx.base_dir,
                  content,
                  ctx.validation_rules,
                  False,
                )
              {
                Ok(_) -> TextResult("Appended to: " <> path)
                Error(e) -> TextResult("Error: " <> e)
              }
            }
          }
      }
    }
    "list_directory" -> {
      case require_arg(args, "path") {
        Error(e) -> TextResult(e)
        Ok(path) -> {
          case tools.list_directory(path, ctx.base_dir) {
            Ok(listing) -> TextResult(listing)
            Error(e) -> TextResult("Error: " <> e)
          }
        }
      }
    }
    "view_skill" -> {
      case require_arg(args, "name") {
        Error(e) -> TextResult(e)
        Ok(skill_name) -> {
          case list.find(ctx.skill_infos, fn(s) { s.name == skill_name }) {
            Ok(info) -> {
              case memory.read_file(info.path <> "/SKILL.md") {
                Ok(content) -> TextResult(content)
                Error(_) ->
                  TextResult("Error: SKILL.md not found for " <> skill_name)
              }
            }
            Error(_) -> TextResult("Error: Skill not found: " <> skill_name)
          }
        }
      }
    }
    "run_skill" -> {
      case require_arg(args, "name") {
        Error(e) -> TextResult(e)
        Ok(skill_name) -> {
          case
            tools.run_skill(
              ctx.skill_runner,
              ctx.skill_infos,
              skill_name,
              get_arg(args, "args"),
            )
          {
            Ok(output) -> TextResult(output)
            Error(e) -> TextResult("Error: " <> e)
          }
        }
      }
    }
    "propose" -> {
      case require_arg(args, "path") {
        Error(e) -> TextResult(e)
        Ok(path) ->
          case require_arg(args, "content") {
            Error(e) -> TextResult(e)
            Ok(content) -> {
              let description = get_arg(args, "description")
              let resolved = tools.resolve_path(path, ctx.base_dir)
              let tier_val = case tier.for_path(resolved) {
                tier.NeedsApprovalWithPreview -> 3
                tier.NeedsApproval -> 2
                tier.Autonomous -> 1
              }
              // Generate proposal ID
              let proposal_id = "p" <> int.to_string(time.now_ms())

              // Build Discord message with buttons
              let preview = case tier_val {
                3 -> content
                _ ->
                  case string.length(content) > 1500 {
                    True -> string.slice(content, 0, 1500) <> "\n...(truncated)"
                    False -> content
                  }
              }
              let msg_content =
                "**Proposal:** "
                <> description
                <> "\n\n**Path:** `"
                <> path
                <> "`\n\n**Content:**\n```\n"
                <> preview
                <> "\n```"

              let buttons =
                discord_types.approve_reject_buttons(
                  ctx.channel_id,
                  proposal_id,
                )
              case
                rest.send_message_with_components(
                  ctx.discord_token,
                  ctx.channel_id,
                  msg_content,
                  buttons,
                )
              {
                Ok(message_id) -> {
                  // Create a subject to receive the approval result
                  let reply_subject = process.new_subject()
                  let proposal =
                    PendingProposal(
                      id: proposal_id,
                      path: resolved,
                      content: content,
                      description: description,
                      channel_id: ctx.channel_id,
                      message_id: message_id,
                      tier: tier_val,
                      requested_at_ms: time.now_ms(),
                      reply_to: reply_subject,
                    )
                  ctx.on_propose(proposal)
                  // Block until user clicks approve/reject (15 min timeout)
                  case process.receive(reply_subject, 900_000) {
                    Ok(Approved) ->
                      TextResult("Approved. File written to `" <> path <> "`.")
                    Ok(Rejected) -> TextResult("Rejected by user.")
                    Ok(Expired) ->
                      TextResult("Proposal expired (15 minute timeout).")
                    Error(_) ->
                      TextResult("Proposal timed out waiting for approval.")
                  }
                }
                Error(e) -> TextResult("Error posting proposal: " <> e)
              }
            }
          }
      }
    }
    "list_threads" -> {
      case rest.get_active_threads(ctx.discord_token, ctx.guild_id) {
        Ok(threads) -> {
          case threads {
            [] -> TextResult("No active threads found.")
            _ ->
              list.map(threads, fn(t) {
                let #(id, tname, parent_id) = t
                tname <> " (id: " <> id <> ", parent: " <> parent_id <> ")"
              })
              |> string.join("\n")
              |> TextResult
          }
        }
        Error(e) -> TextResult("Error: " <> e)
      }
    }
    "read_thread" -> {
      let thread_id = get_arg(args, "thread_id")
      let limit = case int.parse(get_arg(args, "limit")) {
        Ok(n) -> n
        Error(_) -> 20
      }
      case rest.get_channel_messages(ctx.discord_token, thread_id, limit) {
        Ok(messages) -> {
          case messages {
            [] -> TextResult("No messages in this thread.")
            _ ->
              list.reverse(messages)
              |> list.map(fn(m) {
                let #(author, content) = m
                author <> ": " <> content
              })
              |> string.join("\n")
              |> TextResult
          }
        }
        Error(e) -> TextResult("Error: " <> e)
      }
    }
    "skill_manage" -> dispatch_skill_manage(args, ctx)
    "list_skills" -> {
      case skill.list_with_details(ctx.skills_dir) {
        Ok(listing) -> TextResult(listing)
        Error(e) -> TextResult("Error: " <> e)
      }
    }
    "memory" -> {
      case require_arg(args, "action") {
        Error(e) -> TextResult(e)
        Ok(action) -> {
          let target = get_arg(args, "target")
          let key = get_arg(args, "key")
          let content = get_arg(args, "content")
          let path_result = case target {
            "user" -> Ok(xdg.user_path(ctx.paths))
            "state" -> Ok(xdg.domain_state_path(ctx.paths, ctx.domain_name))
            "memory" -> Ok(xdg.domain_memory_path(ctx.paths, ctx.domain_name))
            unknown ->
              Error(
                "Error: unknown target '"
                <> unknown
                <> "'. Use 'state', 'memory', or 'user'.",
              )
          }
          case path_result {
            Error(e) -> TextResult(e)
            Ok(path) -> {
              case action {
                "set" -> {
                  case key {
                    "" -> TextResult("Error: 'key' is required for set action.")
                    _ ->
                      case structured_memory.set(path, key, content) {
                        Ok(_) ->
                          TextResult(
                            "Saved [" <> key <> "] to " <> target <> ".",
                          )
                        Error(e) -> TextResult("Error: " <> e)
                      }
                  }
                }
                "remove" -> {
                  case key {
                    "" ->
                      TextResult("Error: 'key' is required for remove action.")
                    _ ->
                      case structured_memory.remove(path, key) {
                        Ok(_) ->
                          TextResult(
                            "Removed [" <> key <> "] from " <> target <> ".",
                          )
                        Error(e) -> TextResult("Error: " <> e)
                      }
                  }
                }
                "read" -> {
                  let read_domain = case get_arg(args, "domain") {
                    "" -> ctx.domain_name
                    d -> d
                  }
                  let read_path = case target {
                    "user" -> xdg.user_path(ctx.paths)
                    "state" -> xdg.domain_state_path(ctx.paths, read_domain)
                    _ -> xdg.domain_memory_path(ctx.paths, read_domain)
                  }
                  case structured_memory.format_for_display(read_path) {
                    Ok(display) -> TextResult(display)
                    Error(e) -> TextResult("Error: " <> e)
                  }
                }
                _ ->
                  TextResult(
                    "Error: Unknown action '"
                    <> action
                    <> "'. Use set, remove, or read.",
                  )
              }
            }
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
      case db.search(ctx.db_subject, query, limit) {
        Ok(results) -> {
          case results {
            [] -> TextResult("No results found for: " <> query)
            _ ->
              list.map(results, fn(r) {
                r.author_name <> " (" <> r.platform <> "): " <> r.snippet
              })
              |> string.join("\n")
              |> TextResult
          }
        }
        Error(e) -> TextResult("Error: " <> e)
      }
    }
    "web_search" -> {
      case require_arg(args, "query") {
        Error(e) -> TextResult(e)
        Ok(query) -> {
          let limit = case int.parse(get_arg(args, "limit")) {
            Ok(n) -> n
            Error(_) -> 5
          }
          case web.search(query, limit) {
            Ok(results) -> TextResult(web.format_search_results(results))
            Error(e) -> TextResult("Error: " <> e)
          }
        }
      }
    }
    "web_fetch" -> {
      case require_arg(args, "url") {
        Error(e) -> TextResult(e)
        Ok(url) -> {
          case web.fetch(url, 3000) {
            Ok(content) -> TextResult(content)
            Error(e) -> TextResult("Error: " <> e)
          }
        }
      }
    }
    "manage_schedule" -> {
      case require_arg(args, "action") {
        Error(e) -> TextResult(e)
        Ok(action) -> {
          case action {
            "create" | "delete" -> {
              let description = case action {
                "create" ->
                  "Create schedule: "
                  <> get_arg(args, "name")
                  <> " ("
                  <> get_arg(args, "type")
                  <> ")"
                _ -> "Delete schedule: " <> get_arg(args, "name")
              }
              TextResult(
                "Schedule management requires approval. "
                <> description
                <> ". Use propose() to request this change.",
              )
            }
            _ -> {
              case ctx.scheduler_subject {
                None -> TextResult("Error: Scheduler not started")
                Some(subj) -> {
                  let reply_subject = process.new_subject()
                  process.send(
                    subj,
                    scheduler.ManageSchedule(action, args, reply_subject),
                  )
                  case process.receive(reply_subject, 5000) {
                    Ok(response) -> TextResult(response)
                    Error(_) -> TextResult("Error: Scheduler timeout")
                  }
                }
              }
            }
          }
        }
      }
    }
    "flare" -> {
      let resolve_flare = fn(identifier) {
        // Try session name first, then flare ID, then label
        case
          flare_manager.get_flare_by_session_name(ctx.acp_subject, identifier)
        {
          Ok(f) -> Ok(f)
          Error(_) ->
            case flare_manager.get_flare(ctx.acp_subject, identifier) {
              Ok(f) -> Ok(f)
              Error(_) ->
                flare_manager.get_flare_by_label(ctx.acp_subject, identifier)
            }
        }
      }
      case get_arg(args, "action") {
        "ignite" -> {
          case require_arg(args, "prompt") {
            Error(e) -> TextResult(e)
            Ok(prompt) ->
              case require_arg(args, "repo") {
                Error(e) -> TextResult(e)
                Ok(repo) -> {
                  let task_id = "t" <> int.to_string(time.now_ms())
                  let cwd = ctx.domain_cwd <> "/" <> repo
                  let timeout_ms = case
                    int.parse(get_arg(args, "timeout_minutes"))
                  {
                    Ok(m) -> m * 60_000
                    Error(_) -> 30 * 60_000
                  }
                  let label = string.slice(prompt, 0, 50)
                  let thread_id = ctx.channel_id
                  // Create flare record first
                  case
                    flare_manager.ignite(
                      ctx.acp_subject,
                      label,
                      ctx.domain_name,
                      thread_id,
                      prompt,
                      "{}",
                      "{}",
                      "{}",
                      cwd,
                    )
                  {
                    Ok(flare_id) -> {
                      let task_spec =
                        acp_types.TaskSpec(
                          id: task_id,
                          domain: ctx.domain_name,
                          prompt: prompt,
                          cwd: cwd,
                          timeout_ms: timeout_ms,
                          acceptance_criteria: [],
                          provider: provider.parse_provider(
                            ctx.acp_provider,
                            ctx.acp_binary,
                          ),
                          worktree: ctx.acp_worktree,
                        )
                      case
                        flare_manager.dispatch(
                          ctx.acp_subject,
                          task_spec,
                          thread_id,
                          flare_id,
                        )
                      {
                        Ok(session_name) -> {
                          let details_msg =
                            "Flare ignited: "
                            <> session_name
                            <> "\n\n**Prompt:**\n"
                            <> prompt
                          TextResult("Flare ignited.\n" <> details_msg)
                        }
                        Error(e) -> TextResult("Error dispatching flare: " <> e)
                      }
                    }
                    Error(e) -> TextResult("Error creating flare: " <> e)
                  }
                }
              }
          }
        }
        "status" -> {
          case require_arg(args, "session_name") {
            Error(e) -> TextResult(e)
            Ok(identifier) -> {
              case resolve_flare(identifier) {
                Ok(flare) -> {
                  let elapsed_ms = time.now_ms() - flare.started_at_ms
                  let elapsed_min = elapsed_ms / 60_000
                  let activity = case flare.awaiting_response {
                    True -> " working"
                    False -> " idle"
                  }
                  let state_str =
                    " ["
                    <> flare_manager.status_to_string(flare.status)
                    <> activity
                    <> "] (started "
                    <> int.to_string(elapsed_min)
                    <> "m ago)"
                  TextResult(
                    "Flare: "
                    <> flare.id
                    <> " \""
                    <> flare.label
                    <> "\""
                    <> state_str
                    <> "\nDomain: "
                    <> flare.domain
                    <> case flare.session_name {
                      "" -> ""
                      sn -> "\nSession: " <> sn
                    }
                    <> case flare.session_id {
                      "" -> ""
                      sid -> "\nRun: " <> sid
                    }
                    <> "\nPrompt: "
                    <> string.slice(flare.original_prompt, 0, 200),
                  )
                }
                Error(_) -> TextResult("Flare not found: " <> identifier)
              }
            }
          }
        }
        "list" -> {
          let flares = flare_manager.list_flares(ctx.acp_subject)
          case flares {
            [] -> TextResult("No flares.")
            _ -> {
              list.map(flares, fn(f) {
                let activity = case f.status, f.awaiting_response {
                  flare_manager.Active, True -> " working"
                  flare_manager.Active, False -> " idle"
                  _, _ -> ""
                }
                f.id
                <> " \""
                <> f.label
                <> "\""
                <> " ["
                <> flare_manager.status_to_string(f.status)
                <> activity
                <> "]"
                <> " domain="
                <> f.domain
                <> " thread="
                <> f.thread_id
                <> case f.session_name {
                  "" -> ""
                  sn -> " session=" <> sn
                }
              })
              |> string.join("\n")
              |> TextResult
            }
          }
        }
        "prompt" -> {
          case require_arg(args, "session_name") {
            Error(e) -> TextResult(e)
            Ok(identifier) ->
              case require_arg(args, "prompt") {
                Error(e) -> TextResult(e)
                Ok(message) -> {
                  case resolve_flare(identifier) {
                    Error(_) -> TextResult("Flare not found: " <> identifier)
                    Ok(flare) -> {
                      case
                        flare_manager.resolve_prompt_action(
                          flare.status,
                          flare.id,
                          flare.session_name,
                          message,
                        )
                      {
                        flare_manager.SendToLive(sn) -> {
                          case
                            flare_manager.send_input(
                              ctx.acp_subject,
                              sn,
                              message,
                            )
                          {
                            Ok(_) -> TextResult("Sent to " <> sn)
                            Error(e) -> TextResult("Error: " <> e)
                          }
                        }
                        flare_manager.RekindleFlare(flare_id, prompt) -> {
                          case
                            flare_manager.rekindle(
                              ctx.acp_subject,
                              flare_id,
                              prompt,
                            )
                          {
                            Ok(new_session) ->
                              TextResult("Flare rekindled: " <> new_session)
                            Error(e) -> TextResult("Error: " <> e)
                          }
                        }
                        flare_manager.RejectPrompt(reason) ->
                          TextResult("Error: " <> reason)
                      }
                    }
                  }
                }
              }
          }
        }
        "archive" -> {
          case require_arg(args, "session_name") {
            Error(e) -> TextResult(e)
            Ok(identifier) -> {
              case resolve_flare(identifier) {
                Ok(flare) -> {
                  case flare_manager.archive(ctx.acp_subject, flare.id) {
                    Ok(_) -> TextResult("Flare archived: " <> flare.label)
                    Error(e) -> TextResult("Error: " <> e)
                  }
                }
                Error(_) -> TextResult("Flare not found: " <> identifier)
              }
            }
          }
        }
        "kill" -> {
          case require_arg(args, "session_name") {
            Error(e) -> TextResult(e)
            Ok(identifier) -> {
              case resolve_flare(identifier) {
                Ok(flare) -> {
                  case flare_manager.kill(ctx.acp_subject, flare.session_name) {
                    Ok(_) -> TextResult("Flare aborted: " <> flare.label)
                    Error(e) -> TextResult("Error: " <> e)
                  }
                }
                Error(_) -> {
                  case flare_manager.kill(ctx.acp_subject, identifier) {
                    Ok(_) -> TextResult("Flare aborted: " <> identifier)
                    Error(e) -> TextResult("Error: " <> e)
                  }
                }
              }
            }
          }
        }
        "park" -> {
          case require_arg(args, "session_name") {
            Error(e) -> TextResult(e)
            Ok(identifier) -> {
              case resolve_flare(identifier) {
                Ok(flare) -> {
                  let triggers = get_arg(args, "triggers")
                  case flare_manager.park(ctx.acp_subject, flare.id, triggers) {
                    Ok(_) -> TextResult("Flare parked: " <> flare.label)
                    Error(e) -> TextResult("Error: " <> e)
                  }
                }
                Error(_) -> TextResult("Flare not found: " <> identifier)
              }
            }
          }
        }
        "rekindle" -> {
          case require_arg(args, "session_name") {
            Error(e) -> TextResult(e)
            Ok(identifier) -> {
              case resolve_flare(identifier) {
                Ok(flare) -> {
                  let input = get_arg(args, "prompt")
                  case input {
                    "" -> TextResult("Error: prompt is required for rekindle")
                    _ ->
                      case
                        flare_manager.rekindle(ctx.acp_subject, flare.id, input)
                      {
                        Ok(new_session) ->
                          TextResult("Flare rekindled: " <> new_session)
                        Error(e) -> TextResult("Error: " <> e)
                      }
                  }
                }
                Error(_) -> TextResult("Flare not found: " <> identifier)
              }
            }
          }
        }
        unknown ->
          TextResult(
            "Unknown flare action: "
            <> unknown
            <> ". Use: ignite, status, list, prompt, archive, kill, park, rekindle",
          )
      }
    }
    "shell" -> {
      case require_arg(args, "command") {
        Error(e) -> TextResult(e)
        Ok(command) -> {
          let timeout_ms = parse_timeout_ms(args, 180, 600)
          let cwd = case ctx.domain_cwd {
            "" -> ctx.base_dir
            c -> c
          }

          case shell.scan(command, ctx.shell_patterns) {
            shell.Safe -> execute_shell(command, timeout_ms, cwd)
            shell.Flagged(_, description) ->
              request_shell_approval(ctx, command, description, timeout_ms, cwd)
          }
        }
      }
    }
    "browser" -> {
      case require_arg(args, "action") {
        Error(e) -> TextResult(e)
        Ok(action_str) -> {
          case browser.parse_action(action_str) {
            Error(e) -> TextResult("Error: " <> e)
            Ok(action) -> {
              let session_arg = get_arg(args, "session")
              let cdp_url = get_arg(args, "cdp_url")
              case browser.resolve_session(session_arg, ctx.channel_id) {
                Error(e) -> TextResult("Error: " <> e)
                Ok(session) -> {
                  let timeout_ms = parse_timeout_ms(args, 90, 600)
                  let exec_ctx =
                    browser.ExecContext(
                      session: session,
                      cdp_url: cdp_url,
                      timeout_ms: timeout_ms,
                      run_fn: ctx.browser_runner.run,
                      vision_fn: ctx.vision_fn,
                      url_has_secret_fn: ctx.browser_runner.url_has_secret,
                    )
                  TextResult(browser.execute(action, args, exec_ctx))
                }
              }
            }
          }
        }
      }
    }
    "send_attachment" -> {
      case require_arg(args, "path") {
        Error(e) -> TextResult(e)
        Ok(path) -> {
          let resolved = tools.resolve_path(path, ctx.base_dir)
          let content = get_arg(args, "content")
          let filename = case get_arg(args, "filename") {
            "" -> path_utils.basename_or(resolved, "attachment")
            n -> n
          }
          case
            ctx.discord.send_message_with_attachment(
              ctx.channel_id,
              content,
              resolved,
            )
          {
            Ok(_) -> TextResult("Attachment sent: " <> filename)
            Error(e) -> TextResult("Error sending attachment: " <> e)
          }
        }
      }
    }
    "describe_image" -> {
      case require_arg(args, "path") {
        Error(e) -> TextResult(e)
        Ok(path) -> {
          let resolved = tools.resolve_path(path, ctx.base_dir)
          let question = case get_arg(args, "question") {
            "" ->
              "Describe this image concisely. Focus on text content, numbers, structure, and any actionable information. Be specific."
            q -> q
          }
          case browser.read_as_data_url(resolved) {
            Error(e) -> TextResult("Error reading image: " <> e)
            Ok(data_url) ->
              case ctx.vision_fn(data_url, question) {
                Ok(analysis) -> TextResult(analysis)
                Error(e) -> TextResult("Vision error: " <> e)
              }
          }
        }
      }
    }
    _ -> {
      // GLM-5.1 sometimes uses the skill name directly as the tool name
      // instead of "run_skill". If the unknown tool name matches a known skill,
      // redirect to run_skill execution.
      let is_skill = list.any(ctx.skill_infos, fn(s) { s.name == name })
      case is_skill {
        True -> {
          logging.log(
            logging.Info,
            "[brain] Redirecting unknown tool '"
              <> name
              <> "' to run_skill (matches skill name)",
          )
          case
            tools.run_skill(
              ctx.skill_runner,
              ctx.skill_infos,
              name,
              get_arg(args, "args"),
            )
          {
            Ok(output) -> TextResult(output)
            Error(e) -> TextResult("Error: " <> e)
          }
        }
        False -> TextResult("Error: Unknown tool " <> name)
      }
    }
  }
}

/// Extract the text content from a ToolResult.
pub fn tool_result_text(result: ToolResult) -> String {
  case result {
    TextResult(text) -> text
  }
}

// ---------------------------------------------------------------------------
// Shell execution helpers
// ---------------------------------------------------------------------------

fn execute_shell(command: String, timeout_ms: Int, cwd: String) -> ToolResult {
  case shell.execute(command, timeout_ms, cwd) {
    Ok(result) -> {
      let status = case result.exit_code {
        0 -> ""
        code -> "[exit " <> int.to_string(code) <> "] "
      }
      let truncated_note = case result.truncated {
        True -> " (truncated)"
        False -> ""
      }
      TextResult(status <> result.output <> truncated_note)
    }
    Error(e) -> TextResult("Error: " <> e)
  }
}

fn request_shell_approval(
  ctx: ToolContext,
  command: String,
  description: String,
  timeout_ms: Int,
  cwd: String,
) -> ToolResult {
  let approval_id = "sh" <> int.to_string(time.now_ms())
  let msg_content =
    ":warning: **Shell command flagged:** `"
    <> command
    <> "`\n**Reason:** "
    <> description
  let buttons =
    discord_types.approve_reject_buttons(ctx.channel_id, approval_id)
  case
    rest.send_message_with_components(
      ctx.discord_token,
      ctx.channel_id,
      msg_content,
      buttons,
    )
  {
    Ok(message_id) -> {
      let reply_subject = process.new_subject()
      let approval =
        PendingShellApproval(
          id: approval_id,
          command: command,
          reason: description,
          channel_id: ctx.channel_id,
          message_id: message_id,
          requested_at_ms: time.now_ms(),
          reply_to: reply_subject,
        )
      ctx.on_shell_approve(approval)
      // Block until user clicks approve/reject (15 min timeout)
      case process.receive(reply_subject, 900_000) {
        Ok(Approved) -> execute_shell(command, timeout_ms, cwd)
        Ok(Rejected) -> TextResult("Command rejected by user.")
        Ok(Expired) -> TextResult("Approval expired.")
        Error(_) -> TextResult("Approval timed out.")
      }
    }
    Error(e) -> TextResult("Error posting approval request: " <> e)
  }
}

// ---------------------------------------------------------------------------
// Tool argument helpers
// ---------------------------------------------------------------------------

/// Expand concatenated JSON tool calls from GLM-5.1, using tool definitions
/// to infer the correct tool name from parameter keys when no explicit "name"
/// field is present.
pub fn expand_tool_calls_with_tools(
  calls: List(llm.ToolCall),
  tools: List(llm.ToolDefinition),
) -> List(llm.ToolCall) {
  expand_tool_calls_inner(calls, tools)
}

/// Expand concatenated JSON tool calls from GLM-5.1.
/// When the model sends `{"name":"a","args":"x"}{"name":"b","args":"y"}` as a
/// single ToolCall's arguments, this splits them into separate ToolCalls.
/// Each split object may contain its own "name" field which overrides the
/// outer call's name.
pub fn expand_tool_calls(calls: List(llm.ToolCall)) -> List(llm.ToolCall) {
  list.flat_map(calls, fn(call) {
    case string.contains(call.arguments, "}{") {
      False -> [call]
      True -> {
        // Split on }{ and reconstruct individual JSON objects
        let parts = string.split(call.arguments, "}{")
        let num_parts = list.length(parts)
        list.index_map(parts, fn(part, idx) {
          let json_str = case idx == 0, idx == num_parts - 1 {
            True, True -> part
            True, False -> part <> "}"
            False, True -> "{" <> part
            False, False -> "{" <> part <> "}"
          }
          // Try to extract a "name" field from the split object to allow
          // each concatenated call to target a different tool.
          let name = case
            json.parse(json_str, decode.dict(decode.string, decode.string))
          {
            Ok(d) ->
              case dict.get(d, "name") {
                Ok(n) -> n
                Error(_) -> call.name
              }
            Error(_) -> call.name
          }
          llm.ToolCall(
            id: call.id <> "_" <> int.to_string(idx),
            name: name,
            arguments: json_str,
          )
        })
      }
    }
  })
}

fn expand_tool_calls_inner(
  calls: List(llm.ToolCall),
  tools: List(llm.ToolDefinition),
) -> List(llm.ToolCall) {
  // Build a map from unique required-parameter names to tool names.
  // e.g. "query" -> "web_search", "url" -> "web_fetch"
  let param_to_tool = build_param_tool_map(tools)

  list.flat_map(calls, fn(call) {
    case string.contains(call.arguments, "}{") {
      False -> [call]
      True -> {
        let parts = string.split(call.arguments, "}{")
        let num_parts = list.length(parts)
        list.index_map(parts, fn(part, idx) {
          let json_str = case idx == 0, idx == num_parts - 1 {
            True, True -> part
            True, False -> part <> "}"
            False, True -> "{" <> part
            False, False -> "{" <> part <> "}"
          }
          // Try explicit "name" key first, then infer from parameter keys
          let name = case
            json.parse(json_str, decode.dict(decode.string, decode.string))
          {
            Ok(d) ->
              case dict.get(d, "name") {
                Ok(n) -> n
                Error(_) -> infer_tool_name(d, param_to_tool, call.name)
              }
            Error(_) -> call.name
          }
          llm.ToolCall(
            id: call.id <> "_" <> int.to_string(idx),
            name: name,
            arguments: json_str,
          )
        })
      }
    }
  })
}

/// Build a map from parameter names that uniquely identify a tool to the
/// tool's name.  Only required params that appear in exactly one tool are
/// included — shared param names (like "action") are ambiguous and excluded.
fn build_param_tool_map(
  tools: List(llm.ToolDefinition),
) -> dict.Dict(String, String) {
  // Collect (param_name, tool_name) pairs for every required parameter
  let pairs =
    list.flat_map(tools, fn(tool) {
      tool.parameters
      |> list.filter(fn(p) { p.required })
      |> list.map(fn(p) { #(p.name, tool.name) })
    })
  // Count how many tools use each param name
  let counts =
    list.fold(pairs, dict.new(), fn(acc, pair) {
      let #(param, _) = pair
      let n = case dict.get(acc, param) {
        Ok(c) -> c
        Error(_) -> 0
      }
      dict.insert(acc, param, n + 1)
    })
  // Keep only params that map to exactly one tool
  list.fold(pairs, dict.new(), fn(acc, pair) {
    let #(param, tool_name) = pair
    case dict.get(counts, param) {
      Ok(1) -> dict.insert(acc, param, tool_name)
      _ -> acc
    }
  })
}

/// Given parsed argument keys, try to find a unique tool match via param names.
fn infer_tool_name(
  args: dict.Dict(String, String),
  param_to_tool: dict.Dict(String, String),
  fallback: String,
) -> String {
  let keys = dict.keys(args)
  // Find the first argument key that uniquely identifies a tool
  case
    list.find_map(keys, fn(key) {
      case dict.get(param_to_tool, key) {
        Ok(tool_name) -> Ok(tool_name)
        Error(_) -> Error(Nil)
      }
    })
  {
    Ok(name) -> name
    Error(_) -> fallback
  }
}

/// Parse a JSON string of tool arguments into a list of key-value pairs.
/// Handles GLM-5.1's quirk of concatenating multiple JSON objects.
pub fn parse_tool_args(json_str: String) -> List(#(String, String)) {
  case json.parse(json_str, decode.dict(decode.string, decode.string)) {
    Ok(d) -> dict.to_list(d)
    Error(_) -> {
      // GLM-5.1 sometimes concatenates multiple JSON objects: {...}{...}{...}
      // Try to parse just the first object by finding the first '}'
      case string.split_once(json_str, "}{") {
        Ok(#(first, _)) -> {
          case
            json.parse(first <> "}", decode.dict(decode.string, decode.string))
          {
            Ok(d) -> dict.to_list(d)
            Error(_) -> [#("_parse_error", json_str)]
          }
        }
        Error(_) -> [#("_parse_error", json_str)]
      }
    }
  }
}

/// Format parsed tool arguments for display in traces.
pub fn format_tool_args(args: List(#(String, String))) -> String {
  args
  |> list.map(fn(pair) { pair.1 })
  |> string.join(", ")
}

/// Get an argument value by key, returning empty string if not found.
pub fn get_arg(args: List(#(String, String)), key: String) -> String {
  case list.find(args, fn(pair) { pair.0 == key }) {
    Ok(#(_, value)) -> value
    Error(_) -> ""
  }
}

/// Get a required argument, returning an error if missing.
pub fn require_arg(
  args: List(#(String, String)),
  key: String,
) -> Result(String, String) {
  case get_arg(args, key) {
    "" -> Error("Error: missing required argument '" <> key <> "'")
    value -> Ok(value)
  }
}

fn dispatch_skill_manage(
  args: List(#(String, String)),
  ctx: ToolContext,
) -> ToolResult {
  case require_arg(args, "action") {
    Error(e) -> TextResult(e)
    Ok(action) ->
      case require_arg(args, "name") {
        Error(e) -> TextResult(e)
        Ok(name) -> skill_manage_action(action, name, args, ctx)
      }
  }
}

fn skill_manage_action(
  action: String,
  name: String,
  args: List(#(String, String)),
  ctx: ToolContext,
) -> ToolResult {
  case action {
    "create" ->
      case require_arg(args, "content") {
        Error(e) -> TextResult(e)
        Ok(content) ->
          case skill.create(ctx.skills_dir, name, content) {
            Ok(_) -> TextResult("Skill created: " <> name)
            Error(e) -> TextResult("Error: " <> e)
          }
      }
    "edit" ->
      case require_arg(args, "content") {
        Error(e) -> TextResult(e)
        Ok(content) ->
          case skill.update(ctx.skills_dir, name, content) {
            Ok(_) -> TextResult("Skill updated: " <> name)
            Error(e) -> TextResult("Error: " <> e)
          }
      }
    "patch" ->
      case require_arg(args, "old_str") {
        Error(e) -> TextResult(e)
        Ok(old_str) -> {
          let new_str = get_arg(args, "new_str")
          case skill.patch(ctx.skills_dir, name, old_str, new_str) {
            Ok(_) -> TextResult("Skill patched: " <> name)
            Error(e) -> TextResult("Error: " <> e)
          }
        }
      }
    "delete" ->
      case skill.delete(ctx.skills_dir, name) {
        Ok(_) -> TextResult("Skill deleted: " <> name)
        Error(e) -> TextResult("Error: " <> e)
      }
    _ ->
      TextResult(
        "Error: unknown action '"
        <> action
        <> "'. Use create | edit | patch | delete.",
      )
  }
}

/// Parse the LLM's `timeout` arg (seconds) into milliseconds, with a
/// default and cap (both in seconds). Non-integer values fall back to the
/// default. Used by any tool that exposes a per-call timeout override.
fn parse_timeout_ms(
  args: List(#(String, String)),
  default_s: Int,
  cap_s: Int,
) -> Int {
  case get_arg(args, "timeout") {
    "" -> default_s * 1000
    t ->
      case int.parse(t) {
        Ok(n) -> int.min(n, cap_s) * 1000
        Error(_) -> default_s * 1000
      }
  }
}

// ---------------------------------------------------------------------------
// Tool definitions
// ---------------------------------------------------------------------------

/// Construct the list of built-in tool definitions for the LLM.
pub fn make_built_in_tools() -> List(llm.ToolDefinition) {
  [
    llm.ToolDefinition(
      name: "read_file",
      description: "Read any file. Accepts absolute paths (/...), home-relative (~/...), or relative paths (resolved against domain cwd).",
      parameters: [
        llm.ToolParam(
          name: "path",
          param_type: "string",
          description: "File path (absolute, ~/..., or relative to domain cwd)",
          required: True,
        ),
      ],
    ),
    llm.ToolDefinition(
      name: "write_file",
      description: "Write content to a file. Logs, memory, state, and skills write immediately. All other paths require approval -- use propose() first.",
      parameters: [
        llm.ToolParam(
          name: "path",
          param_type: "string",
          description: "File path (absolute, ~/..., or relative to domain cwd)",
          required: True,
        ),
        llm.ToolParam(
          name: "content",
          param_type: "string",
          description: "File content",
          required: True,
        ),
      ],
    ),
    llm.ToolDefinition(
      name: "append_file",
      description: "Append content to a file. Same permission rules as write_file.",
      parameters: [
        llm.ToolParam(
          name: "path",
          param_type: "string",
          description: "File path (absolute, ~/..., or relative to domain cwd)",
          required: True,
        ),
        llm.ToolParam(
          name: "content",
          param_type: "string",
          description: "Content to append",
          required: True,
        ),
      ],
    ),
    llm.ToolDefinition(
      name: "list_directory",
      description: "List contents of a directory. Accepts absolute paths (/...), home-relative (~/...), or relative paths.",
      parameters: [
        llm.ToolParam(
          name: "path",
          param_type: "string",
          description: "Directory path (absolute, ~/..., or relative to domain cwd)",
          required: True,
        ),
      ],
    ),
    llm.ToolDefinition(
      name: "view_skill",
      description: "Read a skill's full instructions before using it. Returns the SKILL.md content with exact commands, argument format, and examples. Always call this before run_skill.",
      parameters: [
        llm.ToolParam(
          name: "name",
          param_type: "string",
          description: "Skill name",
          required: True,
        ),
      ],
    ),
    llm.ToolDefinition(
      name: "run_skill",
      description: "Run an installed skill as a CLI subprocess. Call view_skill first to learn the exact command syntax. Pass args as a JSON array where each element is one argument — this avoids quoting issues with spaces in values.",
      parameters: [
        llm.ToolParam(
          name: "name",
          param_type: "string",
          description: "Skill name",
          required: True,
        ),
        llm.ToolParam(
          name: "args",
          param_type: "string",
          description: "JSON array of arguments, e.g. [\"--instance\", \"HY\", \"tickets\", \"search\", \"project = HY AND status = To Do\"]",
          required: True,
        ),
      ],
    ),
    llm.ToolDefinition(
      name: "propose",
      description: "Request approval to write a file that requires permission. Posts a proposal with Approve/Reject buttons. Use this for config files, identity files, and any path outside Aura's autonomous write zones.",
      parameters: [
        llm.ToolParam(
          name: "path",
          param_type: "string",
          description: "File path to write (absolute, ~/..., or relative to domain cwd)",
          required: True,
        ),
        llm.ToolParam(
          name: "content",
          param_type: "string",
          description: "Full file content to write on approval",
          required: True,
        ),
        llm.ToolParam(
          name: "description",
          param_type: "string",
          description: "Brief description of what this change does and why",
          required: True,
        ),
      ],
    ),
    llm.ToolDefinition(
      name: "list_threads",
      description: "List all active threads in the Discord server",
      parameters: [],
    ),
    llm.ToolDefinition(
      name: "read_thread",
      description: "Read messages from a Discord thread",
      parameters: [
        llm.ToolParam(
          name: "thread_id",
          param_type: "string",
          description: "The thread/channel ID to read",
          required: True,
        ),
        llm.ToolParam(
          name: "limit",
          param_type: "string",
          description: "Max messages to fetch (default 20)",
          required: False,
        ),
      ],
    ),
    llm.ToolDefinition(
      name: "skill_manage",
      description: "Manage skills -- your procedural memory. Actions: create (new skill), edit (rewrite SKILL.md), patch (find-replace unique substring, preferred for small changes), delete (remove skill). Save after complex tasks (3+ tool calls), tricky error fixes, or non-trivial workflows the LLM had to discover through trial and error.",
      parameters: [
        llm.ToolParam(
          name: "action",
          param_type: "string",
          description: "One of: create | edit | patch | delete",
          required: True,
        ),
        llm.ToolParam(
          name: "name",
          param_type: "string",
          description: "Skill name (lowercase, hyphens, underscores, e.g. 'deploy-to-prod'). Max 64 chars.",
          required: True,
        ),
        llm.ToolParam(
          name: "content",
          param_type: "string",
          description: "Full SKILL.md content, for create and edit actions",
          required: False,
        ),
        llm.ToolParam(
          name: "old_str",
          param_type: "string",
          description: "For patch: substring to replace. Must occur exactly once in SKILL.md — widen context if not unique.",
          required: False,
        ),
        llm.ToolParam(
          name: "new_str",
          param_type: "string",
          description: "For patch: replacement text. Pass empty string to delete the matched substring.",
          required: False,
        ),
      ],
    ),
    llm.ToolDefinition(
      name: "list_skills",
      description: "List all available skills with descriptions. Check before creating a new skill to avoid duplicates, or when deciding which skill to run.",
      parameters: [],
    ),
    llm.ToolDefinition(
      name: "memory",
      description: "Keyed persistent memory. Entries are upserted by key — no need to read before writing. Use 'state' for current domain status (active tickets, blockers, PRs). Use 'memory' for durable knowledge (decisions, patterns, conventions). Use 'user' for user profile (always global). State and memory are per-domain when in a domain channel.",
      parameters: [
        llm.ToolParam(
          name: "action",
          param_type: "string",
          description: "One of: set, remove, read",
          required: True,
        ),
        llm.ToolParam(
          name: "target",
          param_type: "string",
          description: "'state' (current status), 'memory' (durable knowledge), or 'user' (user profile — always global)",
          required: True,
        ),
        llm.ToolParam(
          name: "key",
          param_type: "string",
          description: "Entry key (for set/remove). Use descriptive keys like 'pr-215', 'jira-patterns', 'timezone'.",
          required: False,
        ),
        llm.ToolParam(
          name: "content",
          param_type: "string",
          description: "Entry content (for set)",
          required: False,
        ),
        llm.ToolParam(
          name: "domain",
          param_type: "string",
          description: "Domain to read from (for cross-domain read). Omit to use current domain.",
          required: False,
        ),
      ],
    ),
    llm.ToolDefinition(
      name: "search_sessions",
      description: "Search past conversations across all channels and platforms by keyword. Returns matching message snippets with context. Use when the user references something from a past conversation or you need to recall previous discussions.",
      parameters: [
        llm.ToolParam(
          name: "query",
          param_type: "string",
          description: "Search terms",
          required: True,
        ),
        llm.ToolParam(
          name: "limit",
          param_type: "string",
          description: "Max results (default 10)",
          required: False,
        ),
      ],
    ),
    llm.ToolDefinition(
      name: "web_search",
      description: "Search the web using Brave Search. Use when you need current information, documentation, or facts not in your training data or conversation history.",
      parameters: [
        llm.ToolParam(
          name: "query",
          param_type: "string",
          description: "Search query",
          required: True,
        ),
        llm.ToolParam(
          name: "limit",
          param_type: "string",
          description: "Max results (default 5)",
          required: False,
        ),
      ],
    ),
    llm.ToolDefinition(
      name: "web_fetch",
      description: "Fetch a web page and extract its text content. Use after web_search to read a specific result, or when the user provides a URL to read.",
      parameters: [
        llm.ToolParam(
          name: "url",
          param_type: "string",
          description: "The URL to fetch",
          required: True,
        ),
      ],
    ),
    llm.ToolDefinition(
      name: "manage_schedule",
      description: "Manage scheduled tasks. Use 'list' to see all schedules. Use 'create' to add a new schedule (requires user approval). Use 'delete' to remove a schedule (requires user approval). Use 'pause' or 'resume' to toggle a schedule immediately.",
      parameters: [
        llm.ToolParam(
          name: "action",
          param_type: "string",
          description: "One of: list, create, delete, pause, resume",
          required: True,
        ),
        llm.ToolParam(
          name: "name",
          param_type: "string",
          description: "Schedule name (for create/delete/pause/resume)",
          required: False,
        ),
        llm.ToolParam(
          name: "type",
          param_type: "string",
          description: "Schedule type: 'interval' or 'cron' (for create)",
          required: False,
        ),
        llm.ToolParam(
          name: "every",
          param_type: "string",
          description: "Interval like '15m', '1h' (for create with type=interval)",
          required: False,
        ),
        llm.ToolParam(
          name: "cron",
          param_type: "string",
          description: "Cron expression like '0 9 * * *' (for create with type=cron)",
          required: False,
        ),
        llm.ToolParam(
          name: "skill",
          param_type: "string",
          description: "Skill name to invoke (for create)",
          required: False,
        ),
        llm.ToolParam(
          name: "args",
          param_type: "string",
          description: "Arguments for the skill (for create)",
          required: False,
        ),
        llm.ToolParam(
          name: "domains",
          param_type: "string",
          description: "Comma-separated domain names (for create)",
          required: False,
        ),
        llm.ToolParam(
          name: "model",
          param_type: "string",
          description: "LLM model for urgency classification (for create, default zai/glm-5-turbo)",
          required: False,
        ),
      ],
    ),
    llm.ToolDefinition(
      name: "shell",
      description: "Execute a shell command. Supports pipes, redirects, and full sh syntax. Use for: man pages, git operations, process inspection, file search, system diagnostics. Dangerous commands require user approval.",
      parameters: [
        llm.ToolParam(
          name: "command",
          param_type: "string",
          description: "Shell command to execute (e.g. 'git log --oneline -5', 'man aura', 'ps aux | grep beam')",
          required: True,
        ),
        llm.ToolParam(
          name: "timeout",
          param_type: "string",
          description: "Timeout in seconds (default 180, max 600)",
          required: False,
        ),
      ],
    ),
    llm.ToolDefinition(
      name: "browser",
      description: "Control a headless browser. Use for interactive pages (auth, forms, JS-rendered content). For read-only static HTML, prefer web_fetch. Sessions persist cookies/auth across calls within the same Discord thread. First call should be `navigate`. After navigate, a compact snapshot is returned automatically — no separate snapshot call needed unless the page changed.\n\nPages load async. After any state-changing action (navigate, click-that-navigates, press Enter on a form), call `browser(wait, ref=\"@eN\")` for a known target element or `browser(wait, seconds=3)`. Element refs (`@eN`) are only valid for the snapshot that returned them — re-snapshot after navigations. If an action times out, the page is likely still loading; retry with a higher `timeout` arg (e.g. 180). For full patterns, run `shell(command=\"agent-browser skills get core --full\")` — authoritative agent-browser playbook.",
      parameters: [
        llm.ToolParam(
          name: "action",
          param_type: "string",
          description: "navigate | snapshot | click | type | press | back | vision | console | wait | upload",
          required: True,
        ),
        llm.ToolParam(
          name: "url",
          param_type: "string",
          description: "For navigate.",
          required: False,
        ),
        llm.ToolParam(
          name: "ref",
          param_type: "string",
          description: "Element ref like @e5, for click/type/wait.",
          required: False,
        ),
        llm.ToolParam(
          name: "text",
          param_type: "string",
          description: "Text to type, for type action.",
          required: False,
        ),
        llm.ToolParam(
          name: "key",
          param_type: "string",
          description: "Key to press (Enter, Tab, Escape, ArrowDown, ...), for press.",
          required: False,
        ),
        llm.ToolParam(
          name: "question",
          param_type: "string",
          description: "What to ask the vision model, for vision action.",
          required: False,
        ),
        llm.ToolParam(
          name: "expression",
          param_type: "string",
          description: "JavaScript expression to eval, for console action. Omit to read console logs instead.",
          required: False,
        ),
        llm.ToolParam(
          name: "full",
          param_type: "string",
          description: "For snapshot: return full accessibility tree (default false = compact). Pass 'true' as a string.",
          required: False,
        ),
        llm.ToolParam(
          name: "selector",
          param_type: "string",
          description: "CSS selector for upload target (e.g. \"input[type=file]\"). If not found, the file input may not be rendered yet — snapshot/click the attach trigger first.",
          required: False,
        ),
        llm.ToolParam(
          name: "path",
          param_type: "string",
          description: "Absolute file path to upload, for upload action.",
          required: False,
        ),
        llm.ToolParam(
          name: "seconds",
          param_type: "string",
          description: "For wait action: how many seconds to sleep (e.g. \"3\"). Use either this or `ref`.",
          required: False,
        ),
        llm.ToolParam(
          name: "timeout",
          param_type: "string",
          description: "Per-call override of the default 90s action timeout, in seconds (e.g. \"180\"). Cap 600. Bump when you expect a slow op (big form submit, large upload).",
          required: False,
        ),
        llm.ToolParam(
          name: "session",
          param_type: "string",
          description: "Optional session name; defaults to current channel. Use to share auth across channels.",
          required: False,
        ),
        llm.ToolParam(
          name: "cdp_url",
          param_type: "string",
          description: "Optional CDP endpoint to attach to an already-running browser (BYO auth).",
          required: False,
        ),
      ],
    ),
    llm.ToolDefinition(
      name: "send_attachment",
      description: "Upload a local file to the current Discord channel as an attachment. Use to send screenshots (e.g. after browser(vision) or browser screenshot actions), generated reports, or any file the user needs to see. The file must exist on disk at the given path.",
      parameters: [
        llm.ToolParam(
          name: "path",
          param_type: "string",
          description: "Absolute path to the local file to upload.",
          required: True,
        ),
        llm.ToolParam(
          name: "content",
          param_type: "string",
          description: "Optional text message to accompany the attachment.",
          required: False,
        ),
        llm.ToolParam(
          name: "filename",
          param_type: "string",
          description: "Optional display name in Discord. Defaults to the basename of path.",
          required: False,
        ),
      ],
    ),
    llm.ToolDefinition(
      name: "describe_image",
      description: "Ask the vision model about a local image file. Use this for user-uploaded attachments (auto-downloaded to /tmp/aura-attachments/<msg_id>/), screenshots on disk, or any image you want described. Pass a specific question to focus the analysis. This is the right tool for follow-up vision queries on attached receipts, diagrams, or photos — DO NOT route through browser(navigate file://) + browser(vision), which is slower and browser-scoped.",
      parameters: [
        llm.ToolParam(
          name: "path",
          param_type: "string",
          description: "Absolute or relative path to the image file on disk.",
          required: True,
        ),
        llm.ToolParam(
          name: "question",
          param_type: "string",
          description: "What to ask the vision model. Defaults to a general description prompt.",
          required: False,
        ),
      ],
    ),
    llm.ToolDefinition(
      name: "flare",
      description: "Extend yourself to work on a task. Flares are long-running — treat them like persistent workspaces. Actions: ignite (start new), status (check progress), list (show all), prompt (send follow-up; auto-rekindles a parked flare), park (suspend — default after handback, flare can be resumed), rekindle (explicitly resume a parked flare with a prompt), kill (terminate — only when user asks), archive (retire — only when user asks).",
      parameters: [
        llm.ToolParam(
          name: "action",
          param_type: "string",
          description: "One of: ignite, status, list, prompt, kill, park, rekindle",
          required: True,
        ),
        llm.ToolParam(
          name: "prompt",
          param_type: "string",
          description: "For ignite: the full task prompt. For prompt: the follow-up message.",
          required: False,
        ),
        llm.ToolParam(
          name: "repo",
          param_type: "string",
          description: "For ignite: repo path relative to domain root (e.g. 'repos/cm2'). Check AGENTS.md.",
          required: False,
        ),
        llm.ToolParam(
          name: "session_name",
          param_type: "string",
          description: "For status/prompt/kill: the session name.",
          required: False,
        ),
        llm.ToolParam(
          name: "timeout_minutes",
          param_type: "string",
          description: "For ignite: max duration in minutes (default 30).",
          required: False,
        ),
        llm.ToolParam(
          name: "triggers",
          param_type: "string",
          description: "For park: JSON trigger config, e.g. '{\"type\":\"delay\",\"rekindle_at_ms\":1234567890}'",
          required: False,
        ),
      ],
    ),
  ]
}
