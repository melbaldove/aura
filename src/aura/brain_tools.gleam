import aura/acp/manager
import aura/acp/provider
import aura/acp/tmux as acp_tmux
import aura/acp/types as acp_types
import aura/db
import aura/time
import aura/discord/rest
import aura/discord/types as discord_types
import aura/llm
import aura/memory
import aura/scheduler
import aura/skill
import aura/structured_memory
import aura/tier
import aura/tools
import aura/validator
import aura/web
import aura/xdg
import gleam/dict
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

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
    acp_subject: process.Subject(manager.AcpMessage),
    domain_name: String,
    domain_cwd: String,
    acp_provider: String,
    acp_binary: String,
    acp_worktree: Bool,
    on_propose: fn(PendingProposal) -> Nil,
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
      io.println(
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
                Error(_) -> TextResult("Error: SKILL.md not found for " <> skill_name)
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
            tools.run_skill(ctx.skill_infos, skill_name, get_arg(args, "args"))
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
                    True ->
                      string.slice(content, 0, 1500) <> "\n...(truncated)"
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

              let buttons = discord_types.approve_reject_buttons(proposal_id)
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
                    Ok(Approved) -> TextResult("Approved. File written to `" <> path <> "`.")
                    Ok(Rejected) -> TextResult("Rejected by user.")
                    Ok(Expired) -> TextResult("Proposal expired (15 minute timeout).")
                    Error(_) -> TextResult("Proposal timed out waiting for approval.")
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
    "create_skill" -> {
      case require_arg(args, "name") {
        Error(e) -> TextResult(e)
        Ok(skill_name) ->
          case require_arg(args, "content") {
            Error(e) -> TextResult(e)
            Ok(content) -> {
              case skill.create(ctx.skills_dir, skill_name, content) {
                Ok(_) ->
                  TextResult(
                    "Skill created: "
                    <> skill_name
                    <> ". Available immediately via list_skills and run_skill.",
                  )
                Error(e) -> TextResult("Error: " <> e)
              }
            }
          }
      }
    }
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
            unknown -> Error("Error: unknown target '" <> unknown <> "'. Use 'state', 'memory', or 'user'.")
          }
          case path_result {
            Error(e) -> TextResult(e)
            Ok(path) -> {
              case action {
                "set" -> {
                  case key {
                    "" -> TextResult("Error: 'key' is required for set action.")
                    _ -> case structured_memory.set(path, key, content) {
                      Ok(_) -> TextResult("Saved [" <> key <> "] to " <> target <> ".")
                      Error(e) -> TextResult("Error: " <> e)
                    }
                  }
                }
                "remove" -> {
                  case key {
                    "" -> TextResult("Error: 'key' is required for remove action.")
                    _ -> case structured_memory.remove(path, key) {
                      Ok(_) -> TextResult("Removed [" <> key <> "] from " <> target <> ".")
                      Error(e) -> TextResult("Error: " <> e)
                    }
                  }
                }
                "read" -> {
                  case structured_memory.format_for_display(path) {
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
    "acp_dispatch" -> {
      case require_arg(args, "prompt") {
        Error(e) -> TextResult(e)
        Ok(prompt) -> case require_arg(args, "repo") {
          Error(e) -> TextResult(e)
          Ok(repo) -> {
            let task_id = "t" <> int.to_string(time.now_ms())
            let cwd = ctx.domain_cwd <> "/" <> repo
            let timeout_ms = case int.parse(get_arg(args, "timeout_minutes")) {
              Ok(m) -> m * 60_000
              Error(_) -> 30 * 60_000
            }
            let task_spec = acp_types.TaskSpec(
              id: task_id,
              domain: ctx.domain_name,
              prompt: prompt,
              cwd: cwd,
              timeout_ms: timeout_ms,
              acceptance_criteria: [],
              provider: provider.parse_provider(ctx.acp_provider, ctx.acp_binary),
              worktree: ctx.acp_worktree,
            )
            let thread_id = ctx.channel_id
            case manager.dispatch(ctx.acp_subject, task_spec, thread_id) {
              Ok(session_name) -> {
                let details_msg =
                  "ACP session started: " <> session_name
                  <> "\nAttach with: `tmux attach -t " <> session_name <> "`"
                  <> "\n\n**Prompt:**\n" <> prompt
                TextResult("ACP dispatched.\n" <> details_msg)
              }
              Error(e) -> TextResult("Error: " <> e)
            }
          }
        }
      }
    }
    "acp_status" -> {
      case require_arg(args, "session_name") {
        Error(e) -> TextResult(e)
        Ok(session_name) -> {
          let state_str = case manager.get_session(ctx.acp_subject, session_name) {
            Ok(session) -> {
              let elapsed_ms = time.now_ms() - session.started_at_ms
              let elapsed_min = elapsed_ms / 60_000
              " [" <> manager.session_state_to_string(session.state) <> "] (started " <> int.to_string(elapsed_min) <> "m ago)"
            }
            Error(_) -> " [unknown]"
          }
          case acp_tmux.capture_pane(session_name) {
            Ok(output) -> {
              let tail = case string.length(output) > 500 {
                True -> "...\n" <> string.slice(output, string.length(output) - 500, 500)
                False -> output
              }
              TextResult("Session: " <> session_name <> state_str <> "\n\n" <> tail)
            }
            Error(_) -> TextResult("Session not found or not running: " <> session_name)
          }
        }
      }
    }
    "acp_list" -> {
      let sessions = manager.list_sessions(ctx.acp_subject)
      case sessions {
        [] -> TextResult("No active ACP sessions.")
        _ -> {
          list.map(sessions, fn(s) {
            let elapsed_ms = time.now_ms() - s.started_at_ms
            let elapsed_min = elapsed_ms / 60_000
            s.session_name
            <> " [" <> manager.session_state_to_string(s.state) <> "]"
            <> " domain=" <> s.domain
            <> " (started " <> int.to_string(elapsed_min) <> "m ago)"
          })
          |> string.join("\n")
          |> TextResult
        }
      }
    }
    "acp_prompt" -> {
      case require_arg(args, "session_name") {
        Error(e) -> TextResult(e)
        Ok(session_name) -> case require_arg(args, "message") {
          Error(e) -> TextResult(e)
          Ok(message) -> {
            case manager.send_input(ctx.acp_subject, session_name, message) {
              Ok(_) -> TextResult("Sent to " <> session_name)
              Error(e) -> TextResult("Error: " <> e)
            }
          }
        }
      }
    }
    "acp_kill" -> {
      case require_arg(args, "session_name") {
        Error(e) -> TextResult(e)
        Ok(session_name) -> {
          case manager.kill(ctx.acp_subject, session_name) {
            Ok(_) -> TextResult("Session killed: " <> session_name)
            Error(e) -> TextResult("Error: " <> e)
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
          io.println("[brain] Redirecting unknown tool '" <> name <> "' to run_skill (matches skill name)")
          case
            tools.run_skill(ctx.skill_infos, name, get_arg(args, "args"))
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
// Tool argument helpers
// ---------------------------------------------------------------------------

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
            json.parse(
              first <> "}",
              decode.dict(decode.string, decode.string),
            )
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
      name: "create_skill",
      description: "Manage skills -- your procedural memory. Create reusable approaches for recurring task types. Save as SKILL.md with title, description, and step-by-step instructions. Use after complex tasks (3+ tool calls), tricky error fixes, or discovering non-trivial workflows.",
      parameters: [
        llm.ToolParam(
          name: "name",
          param_type: "string",
          description: "Skill name (lowercase, hyphens, underscores, e.g. 'deploy-to-prod'). Max 64 chars.",
          required: True,
        ),
        llm.ToolParam(
          name: "content",
          param_type: "string",
          description: "Full SKILL.md content with title, description, and step-by-step instructions",
          required: True,
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
      name: "acp_dispatch",
      description: "Dispatch a Claude Code session to work on a task autonomously in a tmux session. Check the domain's AGENTS.md to find which repo to use. You'll get Discord notifications on progress, alerts, and completion.",
      parameters: [
        llm.ToolParam(
          name: "prompt",
          param_type: "string",
          description: "The full task prompt for Claude Code. Be specific about what to do, which files, and acceptance criteria.",
          required: True,
        ),
        llm.ToolParam(
          name: "repo",
          param_type: "string",
          description: "Repo path relative to domain root (e.g. 'repos/cm2'). Check AGENTS.md for available repos.",
          required: True,
        ),
        llm.ToolParam(
          name: "timeout_minutes",
          param_type: "string",
          description: "Max duration in minutes (default 30)",
          required: False,
        ),
      ],
    ),
    llm.ToolDefinition(
      name: "acp_status",
      description: "Check the current output of a running ACP (Claude Code) session. Shows session state, uptime, and the last 500 characters of the tmux pane.",
      parameters: [
        llm.ToolParam(
          name: "session_name",
          param_type: "string",
          description: "The tmux session name (e.g. acp-hy-t1234567)",
          required: True,
        ),
      ],
    ),
    llm.ToolDefinition(
      name: "acp_list",
      description: "List all active ACP (Claude Code) sessions with their current state, domain, and uptime.",
      parameters: [],
    ),
    llm.ToolDefinition(
      name: "acp_prompt",
      description: "Send a follow-up instruction to a running ACP session. The message is typed into the Claude Code session as if the user typed it.",
      parameters: [
        llm.ToolParam(
          name: "session_name",
          param_type: "string",
          description: "The tmux session name (e.g. acp-hy-t1234567)",
          required: True,
        ),
        llm.ToolParam(
          name: "message",
          param_type: "string",
          description: "The instruction to send to Claude Code",
          required: True,
        ),
      ],
    ),
    llm.ToolDefinition(
      name: "acp_kill",
      description: "Kill an ACP session's tmux session. Use when closing/completing a session. Always update state and memory BEFORE killing.",
      parameters: [
        llm.ToolParam(
          name: "session_name",
          param_type: "string",
          description: "The tmux session name to kill",
          required: True,
        ),
      ],
    ),
  ]
}
