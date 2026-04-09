import aura/discord/rest
import aura/llm
import aura/memory
import aura/models
import aura/skill
import aura/structured_memory
import aura/time
import aura/xdg
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const max_review_iterations = 8

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Check if a review should be spawned based on the turn counter.
/// Returns the new turn count (0 if review spawned, count + 1 otherwise).
/// If review_interval is 0, reviews are disabled.
pub fn maybe_spawn_review(
  review_interval: Int,
  notify_on_review: Bool,
  domain_name: String,
  channel_id: String,
  discord_token: String,
  conversation_history: List(llm.Message),
  turn_count: Int,
  paths: xdg.Paths,
  monitor_model: String,
) -> Int {
  case review_interval {
    0 -> turn_count + 1
    interval -> {
      let new_count = turn_count + 1
      case new_count >= interval {
        False -> new_count
        True -> {
          // Resolve paths based on domain
          let #(state_path, memory_path, log_dir) =
            resolve_paths(paths, domain_name)

          // Build LLM config for the monitor model
          case models.build_llm_config(monitor_model) {
            Error(e) -> {
              io.println("[review] Failed to build LLM config: " <> e)
              0
            }
            Ok(llm_config) -> {
              // Spawn state review
              process.spawn_unlinked(fn() {
                run_review(
                  "state",
                  llm_config,
                  conversation_history,
                  state_path,
                  domain_name,
                  log_dir,
                  channel_id,
                  discord_token,
                  notify_on_review,
                  paths,
                )
              })

              // Spawn memory review
              process.spawn_unlinked(fn() {
                run_review(
                  "memory",
                  llm_config,
                  conversation_history,
                  memory_path,
                  domain_name,
                  log_dir,
                  channel_id,
                  discord_token,
                  notify_on_review,
                  paths,
                )
              })

              io.println(
                "[review] Spawned state + memory review for " <> domain_name,
              )
              0
            }
          }
        }
      }
    }
  }
}

/// Build the memory tool definition for the review agent.
pub fn memory_tool_definition() -> llm.ToolDefinition {
  llm.ToolDefinition(
    name: "memory",
    description: "Save information to persistent memory. Use 'set' to create or update an entry by key. Use 'remove' to delete by key.",
    parameters: [
      llm.ToolParam(
        name: "action",
        param_type: "string",
        description: "One of: set, remove",
        required: True,
      ),
      llm.ToolParam(
        name: "target",
        param_type: "string",
        description: "'state' for current status, 'memory' for durable knowledge",
        required: True,
      ),
      llm.ToolParam(
        name: "key",
        param_type: "string",
        description: "Entry key. Use descriptive keys like 'pr-215', 'jira-patterns'.",
        required: True,
      ),
      llm.ToolParam(
        name: "content",
        param_type: "string",
        description: "Entry content (for set)",
        required: False,
      ),
    ],
  )
}

/// Build the review prompt for state or memory.
pub fn build_review_prompt(
  review_type: String,
  current_content: String,
) -> String {
  case review_type {
    "state" ->
      "Review the conversation above and consider updating the domain state.\n\n"
      <> "Current state:\n"
      <> current_content
      <> "\n\n"
      <> "Focus on: what changed? Active tickets, PRs opened/merged/closed, ACP sessions started/completed, blockers found/resolved, deployments.\n\n"
      <> "Use the memory tool with target \"state\" to update entries. Use descriptive keys like \"pr-216\", \"PROJ-123\", \"acp-session\".\n\n"
      <> "If nothing changed, say \"Nothing to save.\" and stop."
    "memory" ->
      "Review the conversation above and consider saving durable knowledge.\n\n"
      <> "Current memory:\n"
      <> current_content
      <> "\n\n"
      <> "Focus on: what was learned that will still matter later? Decisions made, patterns discovered, conventions established, codebase insights, user preferences, workflow approaches.\n\n"
      <> "Do NOT save: what was done (that's state), temporary status, trivially re-discoverable facts.\n\n"
      <> "Use the memory tool with target \"memory\" to save entries. Use descriptive keys like \"jira-patterns\", \"branch-workflow\", \"deploy-process\".\n\n"
      <> "If nothing worth saving, say \"Nothing to save.\" and stop."
    _ -> "Nothing to save."
  }
}

/// Build the prompt for pre-compression memory flush.
pub fn build_flush_prompt(current_content: String) -> String {
  "This conversation is about to be compressed. Older messages will be summarized and discarded.\n\n"
  <> "Save anything worth remembering before it's lost — prioritize user preferences, corrections, recurring patterns, and active work status over task-specific details.\n\n"
  <> "Current memory:\n"
  <> current_content
  <> "\n\n"
  <> "Use the memory tool to save entries. Use 'state' for current status, 'memory' for durable knowledge.\n\n"
  <> "If nothing worth saving, say \"Nothing to save.\" and stop."
}

const min_flush_messages = 6

/// Synchronous memory flush before context compression.
/// Reads current state + memory, gives the LLM one chance to persist
/// anything worth saving before messages are discarded.
/// Skips if fewer than min_flush_messages in history.
/// Never fails — logs errors and returns Nil.
pub fn flush_before_compression(
  llm_config: llm.LlmConfig,
  history: List(llm.Message),
  domain_name: String,
  paths: xdg.Paths,
) -> Nil {
  case list.length(history) < min_flush_messages {
    True -> {
      io.println(
        "[review] Flush skipped — fewer than "
        <> int.to_string(min_flush_messages)
        <> " messages",
      )
      Nil
    }
    False -> {
      let state_path = xdg.domain_state_path(paths, domain_name)
      let memory_path = xdg.domain_memory_path(paths, domain_name)

      let state_content = case
        structured_memory.format_for_display(state_path)
      {
        Ok(c) -> c
        Error(_) -> "(empty)"
      }
      let memory_content = case
        structured_memory.format_for_display(memory_path)
      {
        Ok(c) -> c
        Error(_) -> "(empty)"
      }
      let combined =
        "**State:**\n" <> state_content <> "\n\n**Memory:**\n" <> memory_content

      let flush_prompt = build_flush_prompt(combined)
      let messages = list.append(history, [llm.UserMessage(flush_prompt)])
      let tool = memory_tool_definition()

      let tool_executor = fn(call: llm.ToolCall) -> #(
        String,
        option.Option(#(String, String)),
      ) {
        execute_memory_tool(call, domain_name, paths)
      }

      case
        review_tool_loop(llm_config, messages, [tool], tool_executor, 0, [])
      {
        Ok(written) -> {
          let count = list.length(written)
          case count > 0 {
            True ->
              io.println(
                "[review] Pre-compression flush for "
                <> domain_name
                <> ": "
                <> int.to_string(count)
                <> " entries saved",
              )
            False ->
              io.println(
                "[review] Pre-compression flush for "
                <> domain_name
                <> ": nothing to save",
              )
          }
          Nil
        }
        Error(e) -> {
          io.println(
            "[review] Pre-compression flush failed for "
            <> domain_name
            <> ": "
            <> e,
          )
          Nil
        }
      }
    }
  }
}

/// Build the prompt for background skill review. MECE-aware: instructs the
/// reviewer to check existing skills before creating, avoid overlap, and
/// define clear scope boundaries.
pub fn build_skill_review_prompt(skill_index: String) -> String {
  "Review the conversation above. Was a non-trivial approach used that required trial and error? Did the user expect a different method? Was a multi-step workflow discovered that could be reused?\n\n"
  <> "Existing skills:\n"
  <> skill_index
  <> "\n\n"
  <> "Before creating a new skill:\n"
  <> "1. Check if the approach is already covered by an existing skill — if so, update it with create_skill rather than creating a duplicate.\n"
  <> "2. Check for overlap with existing skills — merge into the existing skill or split both into non-overlapping scopes with clear boundaries.\n"
  <> "3. When creating a new skill, define its scope explicitly — what it covers AND what it doesn't (boundary with adjacent skills).\n\n"
  <> "Use create_skill to create or update skills.\n\n"
  <> "If nothing worth capturing as a skill, say \"Nothing to save.\" and stop."
}

/// Tool definition for the skill review agent.
/// Only create_skill — the skill index is already in the prompt.
pub fn skill_tool_definitions() -> List(llm.ToolDefinition) {
  [
    llm.ToolDefinition(
      name: "create_skill",
      description: "Create or update a skill. Writes SKILL.md to the skills directory.",
      parameters: [
        llm.ToolParam(
          name: "name",
          param_type: "string",
          description: "Skill name (lowercase, hyphens, underscores). Max 64 chars.",
          required: True,
        ),
        llm.ToolParam(
          name: "content",
          param_type: "string",
          description: "Full SKILL.md content with title, description, and instructions.",
          required: True,
        ),
      ],
    ),
  ]
}

/// Check if a skill review should be spawned based on accumulated tool calls.
/// Returns the new tool call count (0 if review spawned, count + tool_calls otherwise).
/// If skill_review_interval is 0, reviews are disabled.
pub fn maybe_spawn_skill_review(
  skill_review_interval: Int,
  domain_name: String,
  channel_id: String,
  discord_token: String,
  conversation_history: List(llm.Message),
  tool_call_count: Int,
  new_tool_calls: Int,
  paths: xdg.Paths,
  monitor_model: String,
  skills_dir: String,
) -> Int {
  case skill_review_interval {
    0 -> tool_call_count + new_tool_calls
    interval -> {
      let new_count = tool_call_count + new_tool_calls
      case new_count >= interval {
        False -> new_count
        True -> {
          case models.build_llm_config(monitor_model) {
            Error(e) -> {
              io.println(
                "[review] Failed to build LLM config for skill review: " <> e,
              )
              0
            }
            Ok(llm_config) -> {
              process.spawn_unlinked(fn() {
                run_skill_review(
                  llm_config,
                  conversation_history,
                  domain_name,
                  channel_id,
                  discord_token,
                  skills_dir,
                  paths,
                )
              })
              io.println("[review] Spawned skill review for " <> domain_name)
              0
            }
          }
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Internal
// ---------------------------------------------------------------------------

fn resolve_paths(
  paths: xdg.Paths,
  domain_name: String,
) -> #(String, String, String) {
  #(
    xdg.domain_state_path(paths, domain_name),
    xdg.domain_memory_path(paths, domain_name),
    xdg.domain_log_dir(paths, domain_name),
  )
}

fn run_review(
  review_type: String,
  llm_config: llm.LlmConfig,
  conversation_history: List(llm.Message),
  target_path: String,
  domain_name: String,
  log_dir: String,
  channel_id: String,
  discord_token: String,
  notify: Bool,
  paths: xdg.Paths,
) -> Nil {
  // Read current content
  let current_content = case structured_memory.format_for_display(target_path) {
    Ok(c) -> c
    Error(e) -> {
      io.println("[review] Failed to read " <> target_path <> ": " <> e)
      "(empty — could not read current content)"
    }
  }

  // Build the review prompt
  let review_prompt = build_review_prompt(review_type, current_content)

  // Build messages: conversation history + review prompt as final user message
  let messages =
    list.append(conversation_history, [llm.UserMessage(review_prompt)])

  // Run the tool loop
  let tool = memory_tool_definition()
  let tool_executor = fn(call: llm.ToolCall) -> #(
    String,
    Option(#(String, String)),
  ) {
    execute_memory_tool(call, domain_name, paths)
  }
  case review_tool_loop(llm_config, messages, [tool], tool_executor, 0, []) {
    Ok(written) ->
      log_and_notify(
        log_dir,
        domain_name,
        review_type,
        written,
        discord_token,
        channel_id,
        notify,
      )
    Error(e) -> log_review_error(log_dir, domain_name, review_type, e)
  }
}

/// Mini tool loop: call LLM, execute tool calls via the provided executor,
/// repeat until no tool calls or max iterations. Returns list of #(key, content)
/// pairs written.
fn review_tool_loop(
  llm_config: llm.LlmConfig,
  messages: List(llm.Message),
  tools: List(llm.ToolDefinition),
  tool_executor: fn(llm.ToolCall) -> #(String, Option(#(String, String))),
  iteration: Int,
  written: List(#(String, String)),
) -> Result(List(#(String, String)), String) {
  case iteration >= max_review_iterations {
    True -> Ok(written)
    False -> {
      use response <- result.try(llm.chat_with_tools(
        llm_config,
        messages,
        tools,
      ))
      case response.tool_calls {
        [] -> {
          // No tool calls — LLM said "Nothing to save" or finished
          Ok(written)
        }
        calls -> {
          // Execute each memory tool call
          let #(new_written, result_messages) =
            list.fold(calls, #(written, []), fn(acc, call) {
              let #(acc_written, acc_results) = acc
              let #(result_text, entry) = tool_executor(call)
              let new_written = case entry {
                Some(e) -> [e, ..acc_written]
                None -> acc_written
              }
              #(new_written, [
                llm.ToolResultMessage(call.id, result_text),
                ..acc_results
              ])
            })

          // Build updated messages for next iteration
          let updated_messages =
            list.flatten([
              messages,
              [llm.AssistantToolCallMessage(response.content, calls)],
              list.reverse(result_messages),
            ])

          review_tool_loop(
            llm_config,
            updated_messages,
            tools,
            tool_executor,
            iteration + 1,
            new_written,
          )
        }
      }
    }
  }
}

/// Execute a single memory tool call. Returns #(result_text, Some(#(key, content)))
/// if an entry was written.
fn execute_memory_tool(
  call: llm.ToolCall,
  domain_name: String,
  paths: xdg.Paths,
) -> #(String, Option(#(String, String))) {
  case parse_args(call.arguments) {
    Error(_) -> #(
      "Error: failed to parse tool arguments as JSON: "
        <> string.slice(call.arguments, 0, 100),
      None,
    )
    Ok(args) -> {
      let action = get_arg(args, "action")
      let target = get_arg(args, "target")
      let key = get_arg(args, "key")
      let content = get_arg(args, "content")

      // Resolve path — review agents only write to state or memory
      let path_result = case target {
        "state" -> Ok(xdg.domain_state_path(paths, domain_name))
        "memory" -> Ok(xdg.domain_memory_path(paths, domain_name))
        unknown ->
          Error(
            "Error: unknown target '"
            <> unknown
            <> "'. Use 'state' or 'memory'.",
          )
      }

      case path_result {
        Error(e) -> #(e, None)
        Ok(path) -> execute_memory_action(action, path, key, content)
      }
    }
  }
}

fn execute_memory_action(
  action: String,
  path: String,
  key: String,
  content: String,
) -> #(String, Option(#(String, String))) {
  case action {
    "set" -> {
      case key {
        "" -> #("Error: key is required for set", None)
        _ ->
          case structured_memory.set(path, key, content) {
            Ok(_) -> #("Saved [" <> key <> "]", Some(#(key, content)))
            Error(e) -> #("Error: " <> e, None)
          }
      }
    }
    "remove" -> {
      case key {
        "" -> #("Error: key is required for remove", None)
        _ ->
          case structured_memory.remove(path, key) {
            Ok(_) -> #("Removed [" <> key <> "]", Some(#(key, "(removed)")))
            Error(e) -> #("Error: " <> e, None)
          }
      }
    }
    _ -> #("Error: unknown action '" <> action <> "'. Use set or remove.", None)
  }
}

fn run_skill_review(
  llm_config: llm.LlmConfig,
  conversation_history: List(llm.Message),
  domain_name: String,
  channel_id: String,
  discord_token: String,
  skills_dir: String,
  paths: xdg.Paths,
) -> Nil {
  let skill_index = case skill.list_with_details(skills_dir) {
    Ok(listing) -> listing
    Error(_) -> "No skills installed."
  }

  let review_prompt = build_skill_review_prompt(skill_index)
  let messages =
    list.append(conversation_history, [llm.UserMessage(review_prompt)])
  let tools = skill_tool_definitions()

  let tool_executor = fn(call: llm.ToolCall) -> #(
    String,
    Option(#(String, String)),
  ) {
    execute_skill_tool(call, skills_dir)
  }

  let log_dir = xdg.domain_log_dir(paths, domain_name)

  case review_tool_loop(llm_config, messages, tools, tool_executor, 0, []) {
    Ok(written) ->
      log_and_notify(
        log_dir,
        domain_name,
        "skill",
        written,
        discord_token,
        channel_id,
        True,
      )
    Error(e) -> log_review_error(log_dir, domain_name, "skill", e)
  }
}

fn execute_skill_tool(
  call: llm.ToolCall,
  skills_dir: String,
) -> #(String, Option(#(String, String))) {
  case parse_args(call.arguments) {
    Error(_) -> #(
      "Error: failed to parse tool arguments as JSON: "
        <> string.slice(call.arguments, 0, 100),
      None,
    )
    Ok(args) -> {
      case call.name {
        "create_skill" -> {
          let name = get_arg(args, "name")
          let content = get_arg(args, "content")
          case name {
            "" -> #("Error: name is required", None)
            _ ->
              case content {
                "" -> #("Error: content is required", None)
                _ -> {
                  case skill.upsert(skills_dir, name, content) {
                    Ok(action) -> #(
                      "Skill " <> action <> ": " <> name,
                      Some(#(name, content)),
                    )
                    Error(e) -> #("Error: " <> e, None)
                  }
                }
              }
          }
        }
        unknown -> #("Error: unknown tool '" <> unknown <> "'", None)
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Shared log + notify
// ---------------------------------------------------------------------------

fn log_and_notify(
  log_dir: String,
  domain_name: String,
  review_type: String,
  written: List(#(String, String)),
  discord_token: String,
  channel_id: String,
  notify: Bool,
) -> Nil {
  let count = list.length(written)
  let log_entry =
    json.object([
      #("type", json.string(review_type <> "_review_completed")),
      #("domain", json.string(domain_name)),
      #("entries_written", json.int(count)),
      #("keys", json.array(list.map(written, fn(e) { e.0 }), json.string)),
      #("ts", json.int(time.now_ms())),
    ])
  case memory.append_domain_log(log_dir, json.to_string(log_entry)) {
    Ok(_) -> Nil
    Error(e) -> io.println("[review] Failed to write log: " <> e)
  }
  io.println(
    "[review] "
    <> review_type
    <> " review for "
    <> domain_name
    <> ": "
    <> int.to_string(count)
    <> " entries written",
  )

  case notify && count > 0 {
    True -> {
      let entries_text =
        list.map(written, fn(e) {
          "**" <> e.0 <> ":** " <> string.slice(e.1, 0, 100)
        })
        |> string.join("\n")
      let icon = case review_type {
        "state" -> "State updated"
        "skill" -> "Skill updated"
        _ -> "Memory saved"
      }
      let msg = "\u{1F4BE} " <> icon <> ":\n" <> entries_text
      case rest.send_message(discord_token, channel_id, msg, []) {
        Ok(_) -> Nil
        Error(e) -> io.println("[review] Discord notification failed: " <> e)
      }
    }
    False -> Nil
  }
}

fn log_review_error(
  log_dir: String,
  domain_name: String,
  review_type: String,
  error: String,
) -> Nil {
  let log_entry =
    json.object([
      #("type", json.string(review_type <> "_review_failed")),
      #("domain", json.string(domain_name)),
      #("error", json.string(error)),
      #("ts", json.int(time.now_ms())),
    ])
  case memory.append_domain_log(log_dir, json.to_string(log_entry)) {
    Ok(_) -> Nil
    Error(log_err) ->
      io.println("[review] Failed to write error log: " <> log_err)
  }
  io.println(
    "[review] "
    <> review_type
    <> " review failed for "
    <> domain_name
    <> ": "
    <> error,
  )
}

// ---------------------------------------------------------------------------
// Arg parsing (simplified -- no need for the full brain_tools parser)
// ---------------------------------------------------------------------------

fn parse_args(json_str: String) -> Result(Dict(String, String), Nil) {
  case json.parse(json_str, decode.dict(decode.string, decode.string)) {
    Ok(d) -> Ok(d)
    Error(_) -> Error(Nil)
  }
}

fn get_arg(args: Dict(String, String), key: String) -> String {
  case dict.get(args, key) {
    Ok(v) -> v
    Error(_) -> ""
  }
}
