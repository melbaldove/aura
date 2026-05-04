import aura/db
import aura/dream_effect
import aura/dream_report
import aura/llm
import aura/memory
import aura/models
import aura/structured_memory
import aura/time
import aura/xdg
import gleam/dict
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import logging
import simplifile

// ---------------------------------------------------------------------------
// Logging — uses OTP logger (process-independent, works from any spawn)
// ---------------------------------------------------------------------------

/// Log to OTP logger + domain log.jsonl (structured history).
fn dream_log(message: String, domain: String, paths: xdg.Paths) -> Nil {
  logging.log(logging.Info, message)
  let log_dir = xdg.domain_log_dir(paths, domain)
  let _ = memory.append_domain_log(log_dir, message)
  Nil
}

/// Log to OTP logger only (for messages without a domain context).
fn dream_log_global(message: String) -> Nil {
  logging.log(logging.Info, message)
}

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// Sources gathered for a domain's dream cycle.
pub type DreamSources {
  DreamSources(
    memory_content: String,
    state_content: String,
    flare_outcomes: String,
    compaction_summaries: String,
  )
}

/// Result of a single domain's dream cycle.
pub type DreamResult {
  DreamResult(
    domain: String,
    phase_reached: String,
    entries_consolidated: Int,
    entries_promoted: Int,
    reflections_generated: Int,
    entries_rendered: Int,
    entries_noop: Int,
    duration_ms: Int,
    index_entry: Option(String),
    effects: List(dream_effect.DreamEffect),
    action_candidates: List(dream_effect.ActionCandidate),
  )
}

/// Result produced by one LLM dream phase.
pub type DreamPhaseResult {
  DreamPhaseResult(
    messages: List(llm.Message),
    tool_calls: Int,
    effects: List(dream_effect.DreamEffect),
  )
}

/// Result from executing one dream memory tool call.
pub type DreamToolOutcome {
  DreamToolOutcome(
    result_text: String,
    effect: Option(dream_effect.DreamEffect),
  )
}

/// Concrete cycle timestamp context injected into dream prompts.
pub type DreamTimeContext {
  DreamTimeContext(
    started_at_ms: Int,
    started_local: String,
    started_utc: String,
  )
}

/// Configuration for the dream_all orchestrator.
pub type DreamConfig {
  DreamConfig(
    model_spec: String,
    paths: xdg.Paths,
    db_subject: process.Subject(db.DbMessage),
    domains: List(String),
    budget_percent: Int,
    brain_context: Int,
  )
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const max_dream_iterations = 12

const retry_delays_ms = [5000, 15_000, 30_000]

/// Per-domain timeout for parallel dream execution (10 minutes).
const domain_timeout_ms = 600_000

// ---------------------------------------------------------------------------
// Prompt builders
// ---------------------------------------------------------------------------

/// Build the prompt for the consolidation phase.
/// Instructs the LLM to review memory entries, merge overlapping entries,
/// eliminate redundancy, and find shorter formulations.
pub fn build_consolidation_prompt(current_memory: String) -> String {
  "You are consolidating memory entries for a domain. Review the current memory below and produce an improved version.

## Instructions

- Merge entries that cover overlapping topics into single, denser entries.
- Eliminate redundancy — if two entries say the same thing differently, keep the better formulation.
- Find shorter formulations without losing information. Compress, don't delete.
- Don't lose information. Every fact in the input must be preserved in the output.
- Don't store what's derivable from other entries or from the codebase itself.
- Preserve the keyed entry format: each entry starts with `§ key` on its own line, followed by content.
- Return ONLY the consolidated memory content. No commentary, no explanation.

## Current Memory

"
  <> current_memory
}

/// Build the prompt for the promotion phase.
/// Instructs the LLM to extract durable knowledge from episodic sources
/// (state, flare outcomes, compaction summaries).
pub fn build_promotion_prompt(
  state_content: String,
  flare_outcomes: String,
  compaction_summaries: String,
) -> String {
  "You are extracting durable knowledge from episodic sources. Review the sources below and identify facts worth promoting to long-term memory.

## Instructions

- Don't promote transient status (\"PR is open\", \"build is running\"). Promote what was LEARNED.
- Prioritize failures, corrections, and surprises — these are high-information signals.
- Extract patterns: if the same problem appeared twice, that's a pattern worth remembering.
- Each promoted entry should be a keyed memory entry: `§ key` followed by content.
- If nothing is worth promoting, respond with exactly: \"No new entries to promote.\"
- Return ONLY the new entries to add. No commentary.

## Current State

"
  <> state_content
  <> "

## Flare Outcomes (since last dream)

"
  <> flare_outcomes
  <> "

## Compaction Summaries

"
  <> compaction_summaries
}

/// Build the promotion prompt with concrete dream-cycle timestamp guidance.
pub fn build_promotion_prompt_with_time(
  state_content: String,
  flare_outcomes: String,
  compaction_summaries: String,
  time_context: DreamTimeContext,
) -> String {
  dream_time_section(time_context)
  <> "\n\n"
  <> build_promotion_prompt(state_content, flare_outcomes, compaction_summaries)
}

fn dream_time_section(time_context: DreamTimeContext) -> String {
  "## Dream Cycle Time

This dream cycle started at " <> time_context.started_local <> " (" <> time_context.started_utc <> ", " <> int.to_string(
    time_context.started_at_ms,
  ) <> " ms since Unix epoch).
When writing `last-dream`, reports, or dated memory, use this date unless source material provides a more specific event date.
Do not invent dates."
}

fn make_time_context(started_at_ms: Int) -> DreamTimeContext {
  DreamTimeContext(
    started_at_ms: started_at_ms,
    started_local: time.now_datetime_string() <> " local",
    started_utc: time.format_ms_utc(started_at_ms) <> " UTC",
  )
}

/// Build the prompt for the reflection phase.
/// Instructs the LLM to look for higher-level patterns across everything discussed.
pub fn build_reflection_prompt() -> String {
  "You are looking for higher-level patterns across everything discussed in this dream session.

## Instructions

- Look for recurring themes — topics or problems that keep coming up.
- Look for connections between seemingly unrelated facts.
- Look for implicit knowledge — things the user assumes but never stated explicitly.
- Look for user patterns — habits, preferences, recurring workflows.
- Each reflection should be a keyed memory entry: `§ key` followed by content.
- If nothing emerges, say \"No new patterns identified.\" and stop.
- Return ONLY the reflection entries or the no-patterns message. No commentary."
}

/// Build the prompt for the render phase.
/// Instructs the LLM to produce the final working set within the token budget.
/// Includes the previous working set so the LLM can preserve stable entries verbatim.
pub fn build_render_prompt(
  budget_tokens: Int,
  previous_working_set: String,
) -> String {
  let budget_str = int.to_string(budget_tokens)
  "You are producing the final memory working set. Use the memory tool to set and remove entries.

## Previous Working Set

"
  <> previous_working_set
  <> "

## Instructions

- Your token budget is "
  <> budget_str
  <> " tokens. The final memory must fit within this budget.
- Use the memory tool with action \"set\" to write entries and \"remove\" to delete entries.
- **Stability rule: if an entry from the previous working set is already well-formed and the underlying knowledge has NOT changed during this dream cycle, keep it VERBATIM. Do not rephrase for style. Only touch entries where new information was consolidated, promoted, or reflected.**
- When you do modify an entry, the change should reflect new information — not cosmetic rewording.
- New entries from the consolidation, promotion, and reflection phases should be set.
- Entries that are obsolete, fully subsumed by a consolidated entry, or no longer relevant should be removed.
- Maximize information density — prefer fewer, denser entries over many sparse ones.
- Every entry must earn its space. Cut entries that duplicate codebase knowledge.
- Also emit a domain index entry with key \"domain-index\" summarizing what this domain knows — a one-paragraph overview of the domain's accumulated knowledge, useful for cross-domain queries. Update the index only if domain knowledge changed.
- Emit tool calls only. No prose output."
}

// ---------------------------------------------------------------------------
// Source gathering
// ---------------------------------------------------------------------------

/// Read STATE.md and MEMORY.md for a domain via structured_memory.
/// Returns "(empty)" for missing or empty files.
/// The flare_outcomes and compaction_summaries fields are left empty — they
/// are filled by the caller from DB queries.
pub fn gather_file_sources(
  state_path: String,
  memory_path: String,
) -> DreamSources {
  let state_content = case structured_memory.format_for_display(state_path) {
    Ok(content) -> content
    Error(_) -> "(empty)"
  }
  let memory_content = case structured_memory.format_for_display(memory_path) {
    Ok(content) -> content
    Error(_) -> "(empty)"
  }
  DreamSources(
    memory_content: memory_content,
    state_content: state_content,
    flare_outcomes: "",
    compaction_summaries: "",
  )
}

/// Gather all sources for a domain's dream cycle.
/// Reads files for state and memory, queries DB for flare outcomes and
/// compaction summaries.
pub fn gather_all_sources(
  state_path: String,
  memory_path: String,
  domain: String,
  db_subject: process.Subject(db.DbMessage),
) -> DreamSources {
  let file_sources = gather_file_sources(state_path, memory_path)

  // Get the timestamp of the last dream run (0 if never dreamed)
  let since_ms = case db.get_last_dream_ms(db_subject, domain) {
    Ok(ms) -> ms
    Error(_) -> 0
  }

  // Query flare outcomes since last dream
  let flare_outcomes = case
    db.get_flare_outcomes(db_subject, domain, since_ms)
  {
    Ok(outcomes) -> format_flare_outcomes(outcomes)
    Error(_) -> "(no flare outcomes available)"
  }

  // Query compaction summaries for this domain
  let compaction_summaries = case
    db.get_compaction_summaries(db_subject, domain)
  {
    Ok(summaries) -> format_compaction_summaries(summaries)
    Error(_) -> "(no compaction summaries available)"
  }

  DreamSources(
    ..file_sources,
    flare_outcomes: flare_outcomes,
    compaction_summaries: compaction_summaries,
  )
}

/// Build the system prompt for a dream session.
/// Sets the context and includes all source material.
pub fn build_dream_system_prompt(
  domain: String,
  sources: DreamSources,
) -> String {
  "You are the dreaming process for domain \""
  <> domain
  <> "\". Your job is to consolidate and synthesize memory.

During a dream cycle, you review all accumulated knowledge — working memory, ephemeral state, agent outcomes, and conversation summaries — then consolidate, promote durable insights, and produce a compact working set.

## Domain Memory

"
  <> sources.memory_content
  <> "

## Domain State

"
  <> sources.state_content
  <> "

## Flare Outcomes

"
  <> sources.flare_outcomes
  <> "

## Compaction Summaries

"
  <> sources.compaction_summaries
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Format flare outcome tuples into a readable string.
fn format_flare_outcomes(outcomes: List(#(String, String))) -> String {
  case outcomes {
    [] -> "(no flare outcomes since last dream)"
    _ ->
      outcomes
      |> list.map(fn(pair) {
        let #(label, result_text) = pair
        "### " <> label <> "\n" <> result_text
      })
      |> string.join("\n\n")
  }
}

/// Format compaction summaries into a readable string.
fn format_compaction_summaries(summaries: List(String)) -> String {
  case summaries {
    [] -> "(no compaction summaries available)"
    _ -> string.join(summaries, "\n\n---\n\n")
  }
}

// ---------------------------------------------------------------------------
// Dream cycle execution
// ---------------------------------------------------------------------------

/// Run the full four-phase dream cycle for a single domain.
/// Phases run sequentially, each building on the shared message context:
///   1. Consolidate — merge and compress memory entries
///   2. Promote — extract durable knowledge from episodic sources
///   3. Reflect — identify higher-level patterns
///   4. Render — produce final working set via tool calls
pub fn dream_domain(
  llm_config: llm.LlmConfig,
  domain: String,
  paths: xdg.Paths,
  db_subject: process.Subject(db.DbMessage),
  budget_tokens: Int,
) -> Result(DreamResult, String) {
  let start_ms = time.now_ms()
  let time_context = make_time_context(start_ms)

  // Gather all sources for this domain
  let state_path = xdg.domain_state_path(paths, domain)
  let memory_path = xdg.domain_memory_path(paths, domain)
  let sources = gather_all_sources(state_path, memory_path, domain, db_subject)

  // Build system prompt and initial messages
  let system_prompt = build_dream_system_prompt(domain, sources)
  let initial_messages = [llm.SystemMessage(system_prompt)]

  let tool = dream_memory_tool_definition()
  let tools = [tool]

  // Phase 1: Consolidate
  dream_log("[dream] " <> domain <> " — phase 1: consolidate", domain, paths)
  use consolidate_result <- result.try(run_phase_with_retry(
    llm_config,
    initial_messages,
    tools,
    "consolidate",
    build_consolidation_prompt(sources.memory_content),
    domain,
    paths,
    db_subject,
  ))
  let messages_after_consolidate = consolidate_result.messages

  // Phase 2: Promote
  dream_log("[dream] " <> domain <> " — phase 2: promote", domain, paths)
  use promote_result <- result.try(run_phase_with_retry(
    llm_config,
    messages_after_consolidate,
    tools,
    "promote",
    build_promotion_prompt_with_time(
      sources.state_content,
      sources.flare_outcomes,
      sources.compaction_summaries,
      time_context,
    ),
    domain,
    paths,
    db_subject,
  ))
  let messages_after_promote = promote_result.messages

  // Phase 3: Reflect
  dream_log("[dream] " <> domain <> " — phase 3: reflect", domain, paths)
  use reflect_result <- result.try(run_phase_with_retry(
    llm_config,
    messages_after_promote,
    tools,
    "reflect",
    build_reflection_prompt(),
    domain,
    paths,
    db_subject,
  ))
  let messages_after_reflect = reflect_result.messages

  // Phase 4: Render
  dream_log("[dream] " <> domain <> " — phase 4: render", domain, paths)
  use render_result <- result.try(run_phase_with_retry(
    llm_config,
    messages_after_reflect,
    tools,
    "render",
    build_render_prompt(budget_tokens, sources.memory_content),
    domain,
    paths,
    db_subject,
  ))
  let final_messages = render_result.messages

  let duration_ms = time.now_ms() - start_ms
  let index_entry = extract_index_entry(final_messages)
  let effects =
    list.flatten([
      consolidate_result.effects,
      promote_result.effects,
      reflect_result.effects,
      render_result.effects,
    ])
  let summary = dream_effect.summarize_effects(effects)
  let cycle_count = current_noop_cycle_count(db_subject, domain, effects)
  let candidates =
    detect_candidates_for_result(domain, index_entry, effects, cycle_count:)

  Ok(DreamResult(
    domain: domain,
    phase_reached: "render",
    entries_consolidated: actual_write_count(consolidate_result.effects),
    entries_promoted: actual_write_count(promote_result.effects),
    reflections_generated: actual_write_count(reflect_result.effects),
    entries_rendered: actual_write_count(render_result.effects),
    entries_noop: summary.noop,
    duration_ms: duration_ms,
    index_entry: index_entry,
    effects: effects,
    action_candidates: candidates,
  ))
}

/// Memory tool definition for dreaming.
/// Focused variant — no domain param (dreaming always writes to its own domain).
pub fn dream_memory_tool_definition() -> llm.ToolDefinition {
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
        description: "Entry key. Use descriptive keys like 'db-pattern', 'deploy-process'.",
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

/// Run a single phase with retry logic (initial + 3 retries with 5s/15s/30s delays).
/// Returns the updated message list and the count of tool calls executed.
fn run_phase_with_retry(
  llm_config: llm.LlmConfig,
  messages: List(llm.Message),
  tools: List(llm.ToolDefinition),
  phase: String,
  prompt: String,
  domain: String,
  paths: xdg.Paths,
  db_subject: process.Subject(db.DbMessage),
) -> Result(DreamPhaseResult, String) {
  let executor = fn(call) {
    execute_dream_memory_tool(call, phase, domain, paths, db_subject)
  }
  run_phase_with_retry_using(
    llm_config,
    messages,
    tools,
    phase,
    prompt,
    domain,
    executor,
  )
}

/// Run a single phase with retry logic using a custom tool executor.
/// Used by the global dream pass to route writes to actual global paths.
fn run_phase_with_retry_using(
  llm_config: llm.LlmConfig,
  messages: List(llm.Message),
  tools: List(llm.ToolDefinition),
  phase: String,
  prompt: String,
  domain_label: String,
  executor: fn(llm.ToolCall) -> DreamToolOutcome,
) -> Result(DreamPhaseResult, String) {
  let phase_messages = list.append(messages, [llm.UserMessage(prompt)])

  run_phase_attempt(
    llm_config,
    phase_messages,
    tools,
    phase,
    domain_label,
    executor,
    retry_delays_ms,
  )
}

/// Recursive retry: try the LLM call, on failure sleep and retry with remaining delays.
fn run_phase_attempt(
  llm_config: llm.LlmConfig,
  messages: List(llm.Message),
  tools: List(llm.ToolDefinition),
  phase: String,
  domain_label: String,
  executor: fn(llm.ToolCall) -> DreamToolOutcome,
  remaining_delays: List(Int),
) -> Result(DreamPhaseResult, String) {
  case dream_tool_loop(llm_config, messages, tools, executor, 0, 0, []) {
    Ok(phase_result) -> Ok(phase_result)
    Error(err) -> {
      case remaining_delays {
        [] -> {
          logging.log(
            logging.Info,
            "[dream] "
              <> domain_label
              <> " — phase "
              <> phase
              <> " failed after all retries: "
              <> err,
          )
          Error("Phase " <> phase <> " failed after all retries: " <> err)
        }
        [delay, ..rest] -> {
          logging.log(
            logging.Info,
            "[dream] "
              <> domain_label
              <> " — phase "
              <> phase
              <> " failed ("
              <> err
              <> "), retrying in "
              <> int.to_string(delay)
              <> "ms",
          )
          process.sleep(delay)
          run_phase_attempt(
            llm_config,
            messages,
            tools,
            phase,
            domain_label,
            executor,
            rest,
          )
        }
      }
    }
  }
}

/// Tool loop for dreaming. Calls LLM with tools, executes any tool calls,
/// appends results, and repeats until no tool calls or max iterations.
/// Returns the updated message list and total tool call count.
pub fn dream_tool_loop(
  llm_config: llm.LlmConfig,
  messages: List(llm.Message),
  tools: List(llm.ToolDefinition),
  tool_executor: fn(llm.ToolCall) -> DreamToolOutcome,
  iteration: Int,
  tool_count: Int,
  effects: List(dream_effect.DreamEffect),
) -> Result(DreamPhaseResult, String) {
  case iteration >= max_dream_iterations {
    True ->
      Ok(DreamPhaseResult(
        messages: messages,
        tool_calls: tool_count,
        effects: list.reverse(effects),
      ))
    False -> {
      use response <- result.try(llm.chat_with_tools(
        llm_config,
        messages,
        tools,
      ))
      case response.tool_calls {
        [] -> {
          // No tool calls — append assistant text response and return
          let updated_messages = case response.content {
            "" -> messages
            content -> list.append(messages, [llm.AssistantMessage(content)])
          }
          Ok(DreamPhaseResult(
            messages: updated_messages,
            tool_calls: tool_count,
            effects: list.reverse(effects),
          ))
        }
        calls -> {
          // Execute each tool call
          let #(result_messages, new_effects) =
            execute_dream_tool_calls(calls, tool_executor, [], effects)

          let new_count = tool_count + list.length(calls)

          // Build updated messages for next iteration
          let updated_messages =
            append_dream_tool_messages(
              messages,
              response.content,
              calls,
              list.reverse(result_messages),
            )

          dream_tool_loop(
            llm_config,
            updated_messages,
            tools,
            tool_executor,
            iteration + 1,
            new_count,
            new_effects,
          )
        }
      }
    }
  }
}

/// Append one assistant tool-call message and its tool results exactly once.
pub fn append_dream_tool_messages(
  messages: List(llm.Message),
  assistant_content: String,
  calls: List(llm.ToolCall),
  result_messages: List(llm.Message),
) -> List(llm.Message) {
  list.flatten([
    messages,
    [llm.AssistantToolCallMessage(assistant_content, calls)],
    result_messages,
  ])
}

fn execute_dream_tool_calls(
  calls: List(llm.ToolCall),
  tool_executor: fn(llm.ToolCall) -> DreamToolOutcome,
  result_messages: List(llm.Message),
  effects: List(dream_effect.DreamEffect),
) -> #(List(llm.Message), List(dream_effect.DreamEffect)) {
  case calls {
    [] -> #(result_messages, effects)
    [call, ..rest] -> {
      let outcome = tool_executor(call)
      let next_effects = case outcome.effect {
        Some(effect) -> [effect, ..effects]
        None -> effects
      }
      execute_dream_tool_calls(
        rest,
        tool_executor,
        [llm.ToolResultMessage(call.id, outcome.result_text), ..result_messages],
        next_effects,
      )
    }
  }
}

/// Execute a single memory tool call for dreaming.
/// Uses set_with_archive and remove_with_archive for write-through to SQLite.
fn execute_dream_memory_tool(
  call: llm.ToolCall,
  phase: String,
  domain: String,
  paths: xdg.Paths,
  db_subject: process.Subject(db.DbMessage),
) -> DreamToolOutcome {
  case parse_dream_args(call.arguments) {
    Error(_) ->
      DreamToolOutcome(
        result_text: "Error: failed to parse tool arguments as JSON: "
          <> string.slice(call.arguments, 0, 100),
        effect: None,
      )
    Ok(args) -> {
      let action = get_dream_arg(args, "action")
      let target = get_dream_arg(args, "target")
      let key = get_dream_arg(args, "key")
      let content = get_dream_arg(args, "content")

      // Resolve path — dreaming writes to state or memory
      let path_result = case target {
        "state" -> Ok(xdg.domain_state_path(paths, domain))
        "memory" -> Ok(xdg.domain_memory_path(paths, domain))
        unknown ->
          Error(
            "Error: unknown target '"
            <> unknown
            <> "'. Use 'state' or 'memory'.",
          )
      }

      case path_result {
        Error(e) -> DreamToolOutcome(result_text: e, effect: None)
        Ok(path) ->
          execute_dream_memory_action(
            action,
            path,
            key,
            content,
            db_subject,
            domain,
            target,
            phase,
          )
      }
    }
  }
}

/// Execute a single memory tool call for the global dream pass.
/// Writes to the actual global paths (MEMORY.md, USER.md) instead of
/// domain-scoped paths, fixing the _global path mismatch.
fn execute_global_memory_tool(
  call: llm.ToolCall,
  phase: String,
  paths: xdg.Paths,
  db_subject: process.Subject(db.DbMessage),
) -> DreamToolOutcome {
  case parse_dream_args(call.arguments) {
    Error(_) ->
      DreamToolOutcome(
        result_text: "Error: failed to parse tool arguments as JSON: "
          <> string.slice(call.arguments, 0, 100),
        effect: None,
      )
    Ok(args) -> {
      let action = get_dream_arg(args, "action")
      let target = get_dream_arg(args, "target")
      let key = get_dream_arg(args, "key")
      let content = get_dream_arg(args, "content")

      // Resolve path — global pass writes to actual global files
      let path_result = case target {
        "memory" -> Ok(xdg.memory_path(paths))
        "user" -> Ok(xdg.user_path(paths))
        "state" ->
          Error(
            "Error: global dream pass has no state file. Use 'memory' or 'user'.",
          )
        unknown ->
          Error(
            "Error: unknown target '" <> unknown <> "'. Use 'memory' or 'user'.",
          )
      }

      case path_result {
        Error(e) -> DreamToolOutcome(result_text: e, effect: None)
        Ok(path) ->
          execute_dream_memory_action(
            action,
            path,
            key,
            content,
            db_subject,
            "_global",
            target,
            phase,
          )
      }
    }
  }
}

/// Execute a memory set/remove action with archive write-through.
fn execute_dream_memory_action(
  action: String,
  path: String,
  key: String,
  content: String,
  db_subject: process.Subject(db.DbMessage),
  domain: String,
  target: String,
  phase: String,
) -> DreamToolOutcome {
  case action {
    "set" -> {
      case key {
        "" ->
          DreamToolOutcome(
            result_text: "Error: key is required for set",
            effect: None,
          )
        _ ->
          case
            structured_memory.set_with_archive_checked(
              path,
              key,
              content,
              db_subject,
              domain,
              target,
            )
          {
            Ok(archive_result) -> {
              let effect =
                archive_result_to_dream_effect(
                  archive_result,
                  phase,
                  domain,
                  target,
                  key,
                  "set",
                  time.now_ms(),
                )
              DreamToolOutcome(
                result_text: archive_result_text(archive_result, key),
                effect: Some(effect),
              )
            }
            Error(e) ->
              DreamToolOutcome(result_text: "Error: " <> e, effect: None)
          }
      }
    }
    "remove" -> {
      case key {
        "" ->
          DreamToolOutcome(
            result_text: "Error: key is required for remove",
            effect: None,
          )
        _ ->
          case
            structured_memory.remove_with_archive_checked(
              path,
              key,
              db_subject,
              domain,
              target,
            )
          {
            Ok(archive_result) -> {
              let effect =
                archive_result_to_dream_effect(
                  archive_result,
                  phase,
                  domain,
                  target,
                  key,
                  "remove",
                  time.now_ms(),
                )
              DreamToolOutcome(
                result_text: archive_result_text(archive_result, key),
                effect: Some(effect),
              )
            }
            Error(e) ->
              DreamToolOutcome(result_text: "Error: " <> e, effect: None)
          }
      }
    }
    _ ->
      DreamToolOutcome(
        result_text: "Error: unknown action '"
          <> action
          <> "'. Use set or remove.",
        effect: None,
      )
  }
}

/// Convert a checked structured-memory result into a dream effect.
pub fn archive_result_to_dream_effect(
  archive_result: structured_memory.ArchiveWriteResult,
  phase: String,
  domain: String,
  target: String,
  key: String,
  action: String,
  created_at_ms: Int,
) -> dream_effect.DreamEffect {
  case archive_result {
    structured_memory.ArchiveNew(new_id, content_chars) ->
      dream_effect.DreamEffect(
        phase: phase,
        domain: domain,
        target: target,
        key: key,
        action: action,
        kind: dream_effect.EffectNew,
        previous_memory_entry_id: None,
        new_memory_entry_id: Some(new_id),
        previous_chars: None,
        content_chars: content_chars,
        created_at_ms: created_at_ms,
      )
    structured_memory.ArchiveChanged(
      previous_id,
      new_id,
      previous_chars,
      content_chars,
    ) ->
      dream_effect.DreamEffect(
        phase: phase,
        domain: domain,
        target: target,
        key: key,
        action: action,
        kind: dream_effect.EffectChanged,
        previous_memory_entry_id: Some(previous_id),
        new_memory_entry_id: Some(new_id),
        previous_chars: Some(previous_chars),
        content_chars: content_chars,
        created_at_ms: created_at_ms,
      )
    structured_memory.ArchiveNoop(previous_id, content_chars) ->
      dream_effect.DreamEffect(
        phase: phase,
        domain: domain,
        target: target,
        key: key,
        action: action,
        kind: dream_effect.EffectNoop,
        previous_memory_entry_id: previous_id,
        new_memory_entry_id: None,
        previous_chars: Some(content_chars),
        content_chars: content_chars,
        created_at_ms: created_at_ms,
      )
    structured_memory.ArchiveRemoved(previous_id) -> {
      let previous_memory_entry_id = case previous_id {
        0 -> None
        _ -> Some(previous_id)
      }
      dream_effect.DreamEffect(
        phase: phase,
        domain: domain,
        target: target,
        key: key,
        action: action,
        kind: dream_effect.EffectRemoved,
        previous_memory_entry_id: previous_memory_entry_id,
        new_memory_entry_id: None,
        previous_chars: None,
        content_chars: 0,
        created_at_ms: created_at_ms,
      )
    }
  }
}

fn archive_result_text(
  archive_result: structured_memory.ArchiveWriteResult,
  key: String,
) -> String {
  case archive_result {
    structured_memory.ArchiveNoop(_, _) -> "No change [" <> key <> "]"
    structured_memory.ArchiveRemoved(_) -> "Removed [" <> key <> "]"
    _ -> "Saved [" <> key <> "]"
  }
}

/// Extract the domain-index entry from the message history.
/// Scans for a tool call that set the key "domain-index" and returns its content.
pub fn extract_index_entry(messages: List(llm.Message)) -> Option(String) {
  list.fold(messages, None, fn(acc, msg) {
    case msg {
      llm.AssistantToolCallMessage(_, calls) -> {
        // Check each tool call for a domain-index set
        list.fold(calls, acc, fn(inner_acc, call) {
          case call.name == "memory" {
            False -> inner_acc
            True -> {
              case parse_dream_args(call.arguments) {
                Error(_) -> inner_acc
                Ok(args) -> {
                  let action = get_dream_arg(args, "action")
                  let key = get_dream_arg(args, "key")
                  let content = get_dream_arg(args, "content")
                  case action == "set" && key == "domain-index" {
                    True -> Some(content)
                    False -> inner_acc
                  }
                }
              }
            }
          }
        })
      }
      _ -> acc
    }
  })
}

/// Get the retry delays list (exposed for testing).
pub fn get_retry_delays() -> List(Int) {
  retry_delays_ms
}

// ---------------------------------------------------------------------------
// Internal helpers for argument parsing
// ---------------------------------------------------------------------------

fn parse_dream_args(json_str: String) -> Result(dict.Dict(String, String), Nil) {
  case json.parse(json_str, decode.dict(decode.string, decode.string)) {
    Ok(d) -> Ok(d)
    Error(_) -> Error(Nil)
  }
}

fn get_dream_arg(args: dict.Dict(String, String), key: String) -> String {
  case dict.get(args, key) {
    Ok(v) -> v
    Error(_) -> ""
  }
}

fn actual_write_count(effects: List(dream_effect.DreamEffect)) -> Int {
  list.count(effects, fn(effect) {
    effect.kind == dream_effect.EffectNew
    || effect.kind == dream_effect.EffectChanged
    || effect.kind == dream_effect.EffectRemoved
  })
}

fn noop_count(effects: List(dream_effect.DreamEffect)) -> Int {
  list.count(effects, fn(effect) { effect.kind == dream_effect.EffectNoop })
}

fn non_index_write_count(effects: List(dream_effect.DreamEffect)) -> Int {
  list.count(effects, fn(effect) {
    effect.key != "domain-index"
    && {
      effect.kind == dream_effect.EffectNew
      || effect.kind == dream_effect.EffectChanged
      || effect.kind == dream_effect.EffectRemoved
    }
  })
}

fn current_noop_cycle_count(
  db_subject: process.Subject(db.DbMessage),
  domain: String,
  effects: List(dream_effect.DreamEffect),
) -> Int {
  case actual_write_count(effects) == 0 && noop_count(effects) > 0 {
    False -> 1
    True -> {
      case db.get_recent_noop_dream_run_count(db_subject, domain, 2) {
        Ok(prior_count) -> prior_count + 1
        Error(e) -> {
          logging.log(
            logging.Info,
            "[dream] Failed to read prior noop dream cycles for "
              <> domain
              <> ": "
              <> e,
          )
          1
        }
      }
    }
  }
}

fn detect_candidates_for_result(
  domain: String,
  index_entry: Option(String),
  effects: List(dream_effect.DreamEffect),
  cycle_count cycle_count: Int,
) -> List(dream_effect.ActionCandidate) {
  let index_text = case index_entry {
    Some(text) -> text
    None -> ""
  }
  dream_effect.detect_action_candidates([
    dream_effect.DomainDreamObservation(
      domain: domain,
      cycle_count: cycle_count,
      actual_writes: actual_write_count(effects),
      noops: noop_count(effects),
      latest_index_mentions_external_input: dream_effect.mentions_external_input(
        index_text,
      ),
      latest_index_mentions_closure: dream_effect.mentions_closure(index_text),
      non_index_writes: non_index_write_count(effects),
    ),
  ])
}

fn persist_effects(
  db_subject: process.Subject(db.DbMessage),
  run_id: Int,
  effects: List(dream_effect.DreamEffect),
) -> Nil {
  list.each(effects, fn(effect) {
    case db.insert_dream_run_effect(db_subject, run_id, effect) {
      Ok(_) -> Nil
      Error(e) ->
        logging.log(logging.Info, "[dream] Failed to log dream effect: " <> e)
    }
  })
}

fn persist_candidates(
  db_subject: process.Subject(db.DbMessage),
  run_id: Int,
  candidates: List(dream_effect.ActionCandidate),
) -> Nil {
  let now = time.now_ms()
  list.each(candidates, fn(candidate) {
    case db.insert_dream_action_candidate(db_subject, run_id, candidate, now) {
      Ok(_) -> Nil
      Error(e) ->
        logging.log(
          logging.Info,
          "[dream] Failed to log dream action candidate: " <> e,
        )
    }
  })
}

// ---------------------------------------------------------------------------
// Map-Reduce Orchestration
// ---------------------------------------------------------------------------

/// Entry point for the full dreaming cycle, called by the scheduler.
/// Spawns one BEAM process per domain (map phase), waits for all to complete,
/// then runs the global consolidation pass (reduce phase).
pub fn dream_all(config: DreamConfig) -> Nil {
  let start_ms = time.now_ms()
  logging.log(
    logging.Info,
    "[dream] Starting dream cycle for "
      <> int.to_string(list.length(config.domains))
      <> " domains",
  )

  case models.build_llm_config(config.model_spec) {
    Error(e) -> dream_log_global("[dream] Failed to build LLM config: " <> e)
    Ok(llm_config) -> {
      let total_budget =
        models.memory_token_budget(
          config.model_spec,
          config.brain_context,
          config.budget_percent,
        )
      // Domain MEMORY.md gets ~40% of the total budget
      let domain_budget = total_budget * 40 / 100

      // Map: dream all domains in parallel
      let results =
        parallel_dream_domains(
          llm_config,
          config.domains,
          config.paths,
          config.db_subject,
          domain_budget,
        )

      // Log each domain result to the dream_runs table
      log_domain_results(results, config.db_subject)

      // Collect index entries from successful domains
      let index_entries = extract_index_entries(results)

      // Reduce: global pass
      let global_budget = total_budget * 20 / 100
      let #(global_effects, global_candidates) =
        dream_global(
          llm_config,
          config.paths,
          config.db_subject,
          global_budget,
          index_entries,
        )

      let duration_ms = time.now_ms() - start_ms
      write_cycle_report(
        config.paths,
        start_ms,
        time.now_ms(),
        config.domains,
        results,
        global_effects,
        global_candidates,
      )
      logging.log(
        logging.Info,
        "[dream] Cycle complete in " <> int.to_string(duration_ms / 1000) <> "s",
      )
    }
  }
}

fn write_cycle_report(
  paths: xdg.Paths,
  start_ms: Int,
  completed_ms: Int,
  domains: List(String),
  results: List(Result(DreamResult, String)),
  global_effects: List(dream_effect.DreamEffect),
  global_candidates: List(dream_effect.ActionCandidate),
) -> Nil {
  let effects = collect_cycle_report_effects(results, global_effects)
  let candidates = collect_cycle_report_candidates(results, global_candidates)
  let failed_count =
    count_failed_domain_results(domain_count: list.length(domains), results:)
  let report =
    dream_report.render_cycle_report(
      started_local: time.format_ms_utc(start_ms) <> " UTC",
      completed_local: time.format_ms_utc(completed_ms) <> " UTC",
      domain_count: list.length(domains),
      failed_count: failed_count,
      effects: effects,
      candidates: candidates,
    )
  let dir = xdg.dream_reports_dir(paths)
  let path = xdg.dream_report_path(paths, start_ms)
  case simplifile.create_directory_all(dir) {
    Error(e) ->
      dream_log_global(
        "[dream] Failed to create dream report directory: " <> string.inspect(e),
      )
    Ok(_) ->
      case simplifile.write(path, report) {
        Ok(_) -> dream_log_global("[dream] Report written: " <> path)
        Error(e) ->
          dream_log_global(
            "[dream] Failed to write dream report: " <> string.inspect(e),
          )
      }
  }
}

/// Count explicit failed results plus domains missing due to timeout.
pub fn count_failed_domain_results(
  domain_count domain_count: Int,
  results results: List(Result(DreamResult, String)),
) -> Int {
  let ok_count =
    list.count(results, fn(result) {
      case result {
        Ok(_) -> True
        Error(_) -> False
      }
    })
  let failed = domain_count - ok_count
  case failed < 0 {
    True -> 0
    False -> failed
  }
}

/// Collect domain and global effects for the cycle report.
pub fn collect_cycle_report_effects(
  results: List(Result(DreamResult, String)),
  global_effects: List(dream_effect.DreamEffect),
) -> List(dream_effect.DreamEffect) {
  let domain_effects =
    results
    |> list.filter_map(fn(result) {
      case result {
        Ok(dr) -> Ok(dr.effects)
        Error(_) -> Error(Nil)
      }
    })
    |> list.flatten
  list.append(domain_effects, global_effects)
}

/// Collect domain and global candidates for the cycle report.
pub fn collect_cycle_report_candidates(
  results: List(Result(DreamResult, String)),
  global_candidates: List(dream_effect.ActionCandidate),
) -> List(dream_effect.ActionCandidate) {
  let domain_candidates =
    results
    |> list.filter_map(fn(result) {
      case result {
        Ok(dr) -> Ok(dr.action_candidates)
        Error(_) -> Error(Nil)
      }
    })
    |> list.flatten
  list.append(domain_candidates, global_candidates)
}

/// Spawn one process per domain, collect results via a Subject.
fn parallel_dream_domains(
  llm_config: llm.LlmConfig,
  domains: List(String),
  paths: xdg.Paths,
  db_subject: process.Subject(db.DbMessage),
  budget_tokens: Int,
) -> List(Result(DreamResult, String)) {
  let result_subject = process.new_subject()
  let count = list.length(domains)

  // Spawn one unlinked process per domain
  list.each(domains, fn(domain) {
    process.spawn_unlinked(fn() {
      let result =
        dream_domain(llm_config, domain, paths, db_subject, budget_tokens)
      process.send(result_subject, #(domain, result))
    })
    Nil
  })

  // Wait for all results (or timeout)
  let deadline_ms = time.now_ms() + domain_timeout_ms
  collect_results(result_subject, count, [], deadline_ms)
}

/// Wait for N results with a deadline.
/// Returns all results received before the deadline. On timeout, logs a warning
/// and returns what was collected so far. The deadline_ms parameter is an
/// absolute timestamp (ms since epoch), not a relative duration.
pub fn collect_results(
  subject: process.Subject(#(String, Result(DreamResult, String))),
  remaining: Int,
  acc: List(Result(DreamResult, String)),
  deadline_ms: Int,
) -> List(Result(DreamResult, String)) {
  case remaining <= 0 {
    True -> list.reverse(acc)
    False -> {
      let now = time.now_ms()
      let remaining_ms = deadline_ms - now
      case remaining_ms <= 0 {
        True -> {
          logging.log(
            logging.Info,
            "[dream] Timeout: "
              <> int.to_string(remaining)
              <> " domains still pending",
          )
          list.reverse(acc)
        }
        False -> {
          case process.receive(subject, remaining_ms) {
            Ok(#(domain, result)) -> {
              case result {
                Ok(dr) ->
                  dream_log_global(
                    "[dream] "
                    <> domain
                    <> " completed — phase: "
                    <> dr.phase_reached
                    <> ", consolidated: "
                    <> int.to_string(dr.entries_consolidated)
                    <> ", promoted: "
                    <> int.to_string(dr.entries_promoted)
                    <> ", reflections: "
                    <> int.to_string(dr.reflections_generated)
                    <> ", render: "
                    <> int.to_string(dr.entries_rendered)
                    <> ", noops: "
                    <> int.to_string(dr.entries_noop)
                    <> ", candidates: "
                    <> int.to_string(list.length(dr.action_candidates))
                    <> " ("
                    <> int.to_string(dr.duration_ms / 1000)
                    <> "s)",
                  )
                Error(e) ->
                  dream_log_global("[dream] " <> domain <> " failed: " <> e)
              }
              collect_results(
                subject,
                remaining - 1,
                [result, ..acc],
                deadline_ms,
              )
            }
            Error(Nil) -> {
              logging.log(
                logging.Info,
                "[dream] Timeout: "
                  <> int.to_string(remaining)
                  <> " domains still pending",
              )
              list.reverse(acc)
            }
          }
        }
      }
    }
  }
}

/// Extract index entries from successful domain dream results.
/// Returns a list of "domain: index_entry" strings.
pub fn extract_index_entries(
  results: List(Result(DreamResult, String)),
) -> List(String) {
  list.filter_map(results, fn(r) {
    case r {
      Ok(dr) ->
        case dr.index_entry {
          Some(entry) -> Ok(dr.domain <> ": " <> entry)
          None -> Error(Nil)
        }
      Error(_) -> Error(Nil)
    }
  })
}

/// Log each domain dream result to the dream_runs table.
fn log_domain_results(
  results: List(Result(DreamResult, String)),
  db_subject: process.Subject(db.DbMessage),
) -> Nil {
  list.each(results, fn(r) {
    case r {
      Ok(dr) -> {
        case
          db.insert_dream_run(
            db_subject,
            dr.domain,
            time.now_ms(),
            dr.phase_reached,
            dr.entries_consolidated,
            dr.entries_promoted,
            dr.reflections_generated,
            dr.duration_ms,
            dr.entries_rendered,
            dr.entries_noop,
            list.length(dr.action_candidates),
          )
        {
          Ok(run_id) -> {
            persist_effects(db_subject, run_id, dr.effects)
            persist_candidates(db_subject, run_id, dr.action_candidates)
          }
          Error(e) ->
            logging.log(
              logging.Info,
              "[dream] Failed to log dream run for " <> dr.domain <> ": " <> e,
            )
        }
      }
      Error(_) -> Nil
    }
  })
}

/// The reduce pass — consolidates global MEMORY.md, USER.md, and domain index entries.
fn dream_global(
  llm_config: llm.LlmConfig,
  paths: xdg.Paths,
  db_subject: process.Subject(db.DbMessage),
  budget_tokens: Int,
  domain_index_entries: List(String),
) -> #(List(dream_effect.DreamEffect), List(dream_effect.ActionCandidate)) {
  let start_ms = time.now_ms()
  dream_log_global("[dream] Starting global consolidation pass")

  let global_memory_path = xdg.memory_path(paths)
  let user_path = xdg.user_path(paths)

  // Read global memory and user profile
  let memory_content = case
    structured_memory.format_for_display(global_memory_path)
  {
    Ok(content) -> content
    Error(_) -> "(empty)"
  }
  let user_content = case structured_memory.format_for_display(user_path) {
    Ok(content) -> content
    Error(_) -> "(empty)"
  }

  let index_section = case domain_index_entries {
    [] -> "(no domain index entries)"
    entries -> string.join(entries, "\n\n")
  }

  let system_prompt =
    build_global_dream_system_prompt(
      memory_content,
      user_content,
      index_section,
    )

  let initial_messages = [llm.SystemMessage(system_prompt)]
  let tool = dream_memory_tool_definition()
  let tools = [tool]

  // Phase 1: Consolidate global memory
  dream_log_global("[dream] _global — phase 1: consolidate")
  let consolidate_executor = fn(call) {
    execute_global_memory_tool(call, "consolidate", paths, db_subject)
  }
  let consolidate_result =
    run_phase_with_retry_using(
      llm_config,
      initial_messages,
      tools,
      "consolidate",
      build_consolidation_prompt(memory_content),
      "_global",
      consolidate_executor,
    )

  case consolidate_result {
    Error(e) -> {
      dream_log_global("[dream] _global — consolidation failed: " <> e)
      log_global_dream_run(
        db_subject,
        start_ms,
        "consolidate",
        0,
        0,
        0,
        0,
        0,
        [],
        [],
      )
      #([], [])
    }
    Ok(consolidate_phase) -> {
      // Phase 2: Reflect on cross-domain patterns
      dream_log_global("[dream] _global — phase 2: reflect")
      let reflect_executor = fn(call) {
        execute_global_memory_tool(call, "reflect", paths, db_subject)
      }
      let reflect_result =
        run_phase_with_retry_using(
          llm_config,
          consolidate_phase.messages,
          tools,
          "reflect",
          build_reflection_prompt(),
          "_global",
          reflect_executor,
        )

      case reflect_result {
        Error(e) -> {
          dream_log_global("[dream] _global — reflection failed: " <> e)
          log_global_dream_run(
            db_subject,
            start_ms,
            "reflect",
            actual_write_count(consolidate_phase.effects),
            0,
            0,
            0,
            noop_count(consolidate_phase.effects),
            consolidate_phase.effects,
            [],
          )
          #(consolidate_phase.effects, [])
        }
        Ok(reflect_phase) -> {
          // Phase 3: Render final global working set
          dream_log_global("[dream] _global — phase 3: render")
          let render_executor = fn(call) {
            execute_global_memory_tool(call, "render", paths, db_subject)
          }
          let render_result =
            run_phase_with_retry_using(
              llm_config,
              reflect_phase.messages,
              tools,
              "render",
              build_render_prompt(budget_tokens, memory_content),
              "_global",
              render_executor,
            )

          case render_result {
            Error(e) -> {
              dream_log_global("[dream] _global — render failed: " <> e)
              let effects =
                list.append(consolidate_phase.effects, reflect_phase.effects)
              log_global_dream_run(
                db_subject,
                start_ms,
                "render",
                actual_write_count(consolidate_phase.effects),
                0,
                actual_write_count(reflect_phase.effects),
                0,
                noop_count(effects),
                effects,
                [],
              )
              #(effects, [])
            }
            Ok(render_phase) -> {
              let duration_ms = time.now_ms() - start_ms
              logging.log(
                logging.Info,
                "[dream] _global — complete ("
                  <> int.to_string(duration_ms / 1000)
                  <> "s)",
              )
              let effects =
                list.flatten([
                  consolidate_phase.effects,
                  reflect_phase.effects,
                  render_phase.effects,
                ])
              let candidates: List(dream_effect.ActionCandidate) = []
              log_global_dream_run(
                db_subject,
                start_ms,
                "render",
                actual_write_count(consolidate_phase.effects),
                0,
                actual_write_count(reflect_phase.effects),
                actual_write_count(render_phase.effects),
                noop_count(effects),
                effects,
                candidates,
              )
              #(effects, candidates)
            }
          }
        }
      }
    }
  }
}

/// Build the system prompt for the global consolidation pass.
/// Includes global MEMORY.md, USER.md, and domain index entries.
pub fn build_global_dream_system_prompt(
  memory_content: String,
  user_content: String,
  index_section: String,
) -> String {
  "You are the global dreaming process. Your job is to consolidate cross-domain knowledge.

During the global pass, you review global memory and user profile alongside domain index summaries. Merge redundant global entries, identify cross-domain patterns, and produce a compact global working set.

## Global Memory

"
  <> memory_content
  <> "

## User Profile

"
  <> user_content
  <> "

## Domain Index Summaries

"
  <> index_section
}

/// Log a global dream run to the database.
fn log_global_dream_run(
  db_subject: process.Subject(db.DbMessage),
  start_ms: Int,
  phase_reached: String,
  entries_consolidated: Int,
  entries_promoted: Int,
  reflections_generated: Int,
  entries_rendered: Int,
  entries_noop: Int,
  effects: List(dream_effect.DreamEffect),
  candidates: List(dream_effect.ActionCandidate),
) -> Nil {
  let duration_ms = time.now_ms() - start_ms
  case
    db.insert_dream_run(
      db_subject,
      "_global",
      time.now_ms(),
      phase_reached,
      entries_consolidated,
      entries_promoted,
      reflections_generated,
      duration_ms,
      entries_rendered,
      entries_noop,
      list.length(candidates),
    )
  {
    Ok(run_id) -> {
      persist_effects(db_subject, run_id, effects)
      persist_candidates(db_subject, run_id, candidates)
    }
    Error(e) ->
      dream_log_global("[dream] Failed to log global dream run: " <> e)
  }
}
