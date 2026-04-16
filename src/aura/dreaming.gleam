import aura/db
import aura/structured_memory
import aura/xdg
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option}
import gleam/string

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
    duration_ms: Int,
    index_entry: Option(String),
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

" <> current_memory
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

" <> state_content <> "

## Flare Outcomes (since last dream)

" <> flare_outcomes <> "

## Compaction Summaries

" <> compaction_summaries
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
pub fn build_render_prompt(budget_tokens: Int) -> String {
  let budget_str = int.to_string(budget_tokens)
  "You are producing the final memory working set. Use the memory tool to set and remove entries.

## Instructions

- Your token budget is " <> budget_str <> " tokens. The final memory must fit within this budget.
- Use the memory tool with action \"set\" to write entries and \"remove\" to delete entries.
- Maximize information density — prefer fewer, denser entries over many sparse ones.
- Every entry must earn its space. Cut entries that duplicate codebase knowledge.
- Also emit a domain index entry with key \"domain-index\" summarizing what this domain knows — a one-paragraph overview of the domain's accumulated knowledge, useful for cross-domain queries.
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
  let flare_outcomes = case db.get_flare_outcomes(db_subject, domain, since_ms) {
    Ok(outcomes) -> format_flare_outcomes(outcomes)
    Error(_) -> "(no flare outcomes available)"
  }

  // Query compaction summaries for this domain
  let compaction_summaries = case db.get_compaction_summaries(db_subject, domain) {
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
  "You are the dreaming process for domain \"" <> domain <> "\". Your job is to consolidate and synthesize memory.

During a dream cycle, you review all accumulated knowledge — working memory, ephemeral state, agent outcomes, and conversation summaries — then consolidate, promote durable insights, and produce a compact working set.

## Domain Memory

" <> sources.memory_content <> "

## Domain State

" <> sources.state_content <> "

## Flare Outcomes

" <> sources.flare_outcomes <> "

## Compaction Summaries

" <> sources.compaction_summaries
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
