import aura/dreaming
import aura/llm
import aura/test_helpers
import aura/time
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import simplifile

fn temp_dir(suffix: String) -> String {
  "/tmp/aura-dreaming-" <> suffix
}

fn cleanup(base: String) -> Nil {
  let _ = simplifile.delete_all([base])
  Nil
}

// ---------------------------------------------------------------------------
// Prompt builder tests
// ---------------------------------------------------------------------------

pub fn build_consolidation_prompt_test() {
  let memory =
    "§ db-pattern\nAll DB access through actor\n\n§ fts-search\nFTS5 with porter tokenizer"
  let prompt = dreaming.build_consolidation_prompt(memory)

  // Contains key instructions
  prompt |> string.contains("Merge") |> should.be_true
  prompt |> string.contains("redundancy") |> should.be_true
  prompt |> string.contains("Compress, don't delete") |> should.be_true
  prompt |> string.contains("lose information") |> should.be_true

  // Contains the actual memory content
  prompt |> string.contains("db-pattern") |> should.be_true
  prompt |> string.contains("All DB access through actor") |> should.be_true
  prompt |> string.contains("fts-search") |> should.be_true
}

pub fn build_promotion_prompt_test() {
  let state = "§ current-focus\nDreaming system implementation"
  let flares = "### fix-bug\nFixed the off-by-one error in pagination"
  let summaries = "Discussed migration strategy and decided on SQLite"
  let prompt = dreaming.build_promotion_prompt(state, flares, summaries)

  // Contains key instructions
  prompt |> string.contains("durable knowledge") |> should.be_true
  prompt |> string.contains("transient status") |> should.be_true
  prompt |> string.contains("failures, corrections") |> should.be_true
  prompt |> string.contains("LEARNED") |> should.be_true

  // Contains all three source texts
  prompt |> string.contains("current-focus") |> should.be_true
  prompt |> string.contains("fix-bug") |> should.be_true
  prompt |> string.contains("off-by-one") |> should.be_true
  prompt |> string.contains("migration strategy") |> should.be_true
}

pub fn build_reflection_prompt_test() {
  let prompt = dreaming.build_reflection_prompt()

  // Contains pattern-related instructions
  prompt |> string.contains("recurring themes") |> should.be_true
  prompt |> string.contains("connections") |> should.be_true
  prompt |> string.contains("implicit knowledge") |> should.be_true
  prompt |> string.contains("user patterns") |> should.be_true
  prompt |> string.contains("No new patterns identified.") |> should.be_true
}

pub fn build_render_prompt_test() {
  let prompt = dreaming.build_render_prompt(4096, "**key1:** old content")

  // Contains the budget number
  prompt |> string.contains("4096") |> should.be_true

  // Contains set/remove instructions
  prompt |> string.contains("set") |> should.be_true
  prompt |> string.contains("remove") |> should.be_true

  // Contains domain-index instruction
  prompt |> string.contains("domain-index") |> should.be_true

  // Contains the previous working set
  prompt |> string.contains("old content") |> should.be_true

  // Contains stability guidance
  prompt |> string.contains("VERBATIM") |> should.be_true
}

pub fn build_render_prompt_different_budget_test() {
  let prompt = dreaming.build_render_prompt(8192, "(empty)")
  prompt |> string.contains("8192") |> should.be_true
}

// ---------------------------------------------------------------------------
// Source gathering tests
// ---------------------------------------------------------------------------

pub fn gather_file_sources_test() {
  let base = temp_dir("sources-" <> test_helpers.random_suffix())
  let _ = simplifile.create_directory_all(base)

  // Create a STATE.md with keyed entries
  let state_path = base <> "/STATE.md"
  simplifile.write(state_path, "§ focus\nBuilding dreaming system\n")
  |> should.be_ok

  // Create a MEMORY.md with keyed entries
  let memory_path = base <> "/MEMORY.md"
  simplifile.write(memory_path, "§ db-pattern\nActor serializes all writes\n")
  |> should.be_ok

  let sources = dreaming.gather_file_sources(state_path, memory_path)

  // State content is formatted via structured_memory.format_for_display
  sources.state_content |> string.contains("focus") |> should.be_true
  sources.state_content
  |> string.contains("Building dreaming system")
  |> should.be_true

  // Memory content is formatted
  sources.memory_content |> string.contains("db-pattern") |> should.be_true
  sources.memory_content
  |> string.contains("Actor serializes all writes")
  |> should.be_true

  // DB-sourced fields are empty (caller fills them)
  sources.flare_outcomes |> should.equal("")
  sources.compaction_summaries |> should.equal("")

  cleanup(base)
}

pub fn gather_file_sources_missing_files_test() {
  let base = temp_dir("missing-" <> test_helpers.random_suffix())

  let sources =
    dreaming.gather_file_sources(
      base <> "/nonexistent/STATE.md",
      base <> "/nonexistent/MEMORY.md",
    )

  sources.state_content |> should.equal("(empty)")
  sources.memory_content |> should.equal("(empty)")
  sources.flare_outcomes |> should.equal("")
  sources.compaction_summaries |> should.equal("")
}

pub fn gather_file_sources_empty_files_test() {
  let base = temp_dir("empty-" <> test_helpers.random_suffix())
  let _ = simplifile.create_directory_all(base)

  // Create empty files
  simplifile.write(base <> "/STATE.md", "") |> should.be_ok
  simplifile.write(base <> "/MEMORY.md", "") |> should.be_ok

  let sources =
    dreaming.gather_file_sources(base <> "/STATE.md", base <> "/MEMORY.md")

  // Empty files with no entries return "(empty)" from format_for_display
  sources.state_content |> should.equal("(empty)")
  sources.memory_content |> should.equal("(empty)")

  cleanup(base)
}

// ---------------------------------------------------------------------------
// System prompt tests
// ---------------------------------------------------------------------------

pub fn build_dream_system_prompt_test() {
  let sources =
    dreaming.DreamSources(
      memory_content: "**db-pattern:** Actor serializes all writes",
      state_content: "**focus:** Building dreaming system",
      flare_outcomes: "### fix-bug\nFixed pagination",
      compaction_summaries: "Discussed SQLite migration",
    )
  let prompt = dreaming.build_dream_system_prompt("backend", sources)

  // Contains domain name
  prompt |> string.contains("backend") |> should.be_true

  // Contains dreaming context
  prompt |> string.contains("dreaming process") |> should.be_true
  prompt |> string.contains("consolidate") |> should.be_true

  // Contains all source content
  prompt |> string.contains("db-pattern") |> should.be_true
  prompt |> string.contains("Actor serializes all writes") |> should.be_true
  prompt |> string.contains("Building dreaming system") |> should.be_true
  prompt |> string.contains("fix-bug") |> should.be_true
  prompt |> string.contains("Fixed pagination") |> should.be_true
  prompt |> string.contains("SQLite migration") |> should.be_true
}

pub fn build_dream_system_prompt_empty_sources_test() {
  let sources =
    dreaming.DreamSources(
      memory_content: "(empty)",
      state_content: "(empty)",
      flare_outcomes: "(no flare outcomes since last dream)",
      compaction_summaries: "(no compaction summaries available)",
    )
  let prompt = dreaming.build_dream_system_prompt("aura", sources)

  prompt |> string.contains("aura") |> should.be_true
  prompt |> string.contains("(empty)") |> should.be_true
  prompt
  |> string.contains("(no flare outcomes since last dream)")
  |> should.be_true
  prompt
  |> string.contains("(no compaction summaries available)")
  |> should.be_true
}

// ---------------------------------------------------------------------------
// Dream cycle execution tests
// ---------------------------------------------------------------------------

pub fn retry_delays_has_three_entries_test() {
  // 3 retry delays = 4 total attempts (initial + 3 retries)
  let delays = dreaming.get_retry_delays()
  list.length(delays) |> should.equal(3)
}

pub fn retry_delays_are_increasing_test() {
  let delays = dreaming.get_retry_delays()
  case delays {
    [a, b, c] -> {
      { a < b } |> should.be_true
      { b < c } |> should.be_true
    }
    _ -> should.fail()
  }
}

pub fn extract_index_entry_found_test() {
  // Build a message list that contains an AssistantToolCallMessage
  // with a "domain-index" set call
  let messages = [
    llm.SystemMessage("system prompt"),
    llm.UserMessage("consolidate"),
    llm.AssistantMessage("consolidated text"),
    llm.UserMessage("render"),
    llm.AssistantToolCallMessage("", [
      llm.ToolCall(
        id: "call_1",
        name: "memory",
        arguments: "{\"action\":\"set\",\"target\":\"memory\",\"key\":\"db-pattern\",\"content\":\"All DB through actor\"}",
      ),
      llm.ToolCall(
        id: "call_2",
        name: "memory",
        arguments: "{\"action\":\"set\",\"target\":\"memory\",\"key\":\"domain-index\",\"content\":\"Backend domain covers DB, API, and deploy patterns.\"}",
      ),
    ]),
    llm.ToolResultMessage("call_1", "Saved [db-pattern]"),
    llm.ToolResultMessage("call_2", "Saved [domain-index]"),
  ]

  let result = dreaming.extract_index_entry(messages)
  result
  |> should.equal(Some("Backend domain covers DB, API, and deploy patterns."))
}

pub fn extract_index_entry_not_found_test() {
  // No domain-index tool call in the messages
  let messages = [
    llm.SystemMessage("system prompt"),
    llm.UserMessage("render"),
    llm.AssistantToolCallMessage("", [
      llm.ToolCall(
        id: "call_1",
        name: "memory",
        arguments: "{\"action\":\"set\",\"target\":\"memory\",\"key\":\"db-pattern\",\"content\":\"value\"}",
      ),
    ]),
    llm.ToolResultMessage("call_1", "Saved [db-pattern]"),
  ]

  dreaming.extract_index_entry(messages) |> should.equal(None)
}

pub fn extract_index_entry_empty_messages_test() {
  dreaming.extract_index_entry([]) |> should.equal(None)
}

pub fn extract_index_entry_only_text_messages_test() {
  let messages = [
    llm.SystemMessage("system"),
    llm.UserMessage("hello"),
    llm.AssistantMessage("response"),
  ]

  dreaming.extract_index_entry(messages) |> should.equal(None)
}

pub fn extract_index_entry_uses_last_occurrence_test() {
  // If domain-index is set multiple times, the last occurrence wins
  let messages = [
    llm.AssistantToolCallMessage("", [
      llm.ToolCall(
        id: "call_1",
        name: "memory",
        arguments: "{\"action\":\"set\",\"target\":\"memory\",\"key\":\"domain-index\",\"content\":\"First version.\"}",
      ),
    ]),
    llm.ToolResultMessage("call_1", "Saved [domain-index]"),
    llm.AssistantToolCallMessage("", [
      llm.ToolCall(
        id: "call_2",
        name: "memory",
        arguments: "{\"action\":\"set\",\"target\":\"memory\",\"key\":\"domain-index\",\"content\":\"Updated version.\"}",
      ),
    ]),
    llm.ToolResultMessage("call_2", "Saved [domain-index]"),
  ]

  dreaming.extract_index_entry(messages)
  |> should.equal(Some("Updated version."))
}

pub fn extract_index_entry_ignores_remove_action_test() {
  // A remove action for domain-index should not be extracted
  let messages = [
    llm.AssistantToolCallMessage("", [
      llm.ToolCall(
        id: "call_1",
        name: "memory",
        arguments: "{\"action\":\"remove\",\"target\":\"memory\",\"key\":\"domain-index\"}",
      ),
    ]),
    llm.ToolResultMessage("call_1", "Removed [domain-index]"),
  ]

  dreaming.extract_index_entry(messages) |> should.equal(None)
}

pub fn dream_memory_tool_definition_test() {
  let tool = dreaming.dream_memory_tool_definition()

  tool.name |> should.equal("memory")

  // Has 4 parameters: action, target, key, content
  list.length(tool.parameters) |> should.equal(4)

  // action, target, key are required; content is optional
  let required_names =
    tool.parameters
    |> list.filter(fn(p) { p.required })
    |> list.map(fn(p) { p.name })
  required_names |> should.equal(["action", "target", "key"])

  let optional_names =
    tool.parameters
    |> list.filter(fn(p) { !p.required })
    |> list.map(fn(p) { p.name })
  optional_names |> should.equal(["content"])
}

// ---------------------------------------------------------------------------
// Map-Reduce Orchestration tests
// ---------------------------------------------------------------------------

pub fn extract_index_entries_from_successes_test() {
  let results = [
    Ok(dreaming.DreamResult(
      domain: "backend",
      phase_reached: "render",
      entries_consolidated: 3,
      entries_promoted: 1,
      reflections_generated: 1,
      duration_ms: 5000,
      index_entry: Some("Backend covers DB and API patterns."),
    )),
    Ok(dreaming.DreamResult(
      domain: "frontend",
      phase_reached: "render",
      entries_consolidated: 2,
      entries_promoted: 0,
      reflections_generated: 0,
      duration_ms: 3000,
      index_entry: Some("Frontend covers React and state management."),
    )),
  ]

  let entries = dreaming.extract_index_entries(results)
  list.length(entries) |> should.equal(2)

  let first = case entries {
    [a, ..] -> a
    _ -> ""
  }
  first |> string.contains("backend") |> should.be_true
  first
  |> string.contains("Backend covers DB and API patterns.")
  |> should.be_true

  let second = case entries {
    [_, b, ..] -> b
    _ -> ""
  }
  second |> string.contains("frontend") |> should.be_true
  second |> string.contains("React and state management") |> should.be_true
}

pub fn extract_index_entries_skips_failures_test() {
  let results = [
    Ok(dreaming.DreamResult(
      domain: "backend",
      phase_reached: "render",
      entries_consolidated: 3,
      entries_promoted: 1,
      reflections_generated: 1,
      duration_ms: 5000,
      index_entry: Some("Backend index."),
    )),
    Error("Phase consolidate failed after all retries"),
  ]

  let entries = dreaming.extract_index_entries(results)
  list.length(entries) |> should.equal(1)
}

pub fn extract_index_entries_skips_none_index_test() {
  let results = [
    Ok(dreaming.DreamResult(
      domain: "backend",
      phase_reached: "reflect",
      entries_consolidated: 3,
      entries_promoted: 1,
      reflections_generated: 1,
      duration_ms: 5000,
      index_entry: None,
    )),
  ]

  let entries = dreaming.extract_index_entries(results)
  list.length(entries) |> should.equal(0)
}

pub fn extract_index_entries_empty_results_test() {
  dreaming.extract_index_entries([]) |> should.equal([])
}

pub fn build_global_dream_system_prompt_test() {
  let prompt =
    dreaming.build_global_dream_system_prompt(
      "**db-pattern:** All DB through actor",
      "**name:** Melbourne",
      "backend: Covers DB and API patterns.\n\nfrontend: Covers React.",
    )

  // Contains global dreaming context
  prompt |> string.contains("global dreaming process") |> should.be_true
  prompt |> string.contains("cross-domain") |> should.be_true

  // Contains global memory
  prompt |> string.contains("db-pattern") |> should.be_true
  prompt |> string.contains("All DB through actor") |> should.be_true

  // Contains user profile
  prompt |> string.contains("Melbourne") |> should.be_true

  // Contains domain index entries
  prompt
  |> string.contains("backend: Covers DB and API patterns.")
  |> should.be_true
  prompt |> string.contains("frontend: Covers React.") |> should.be_true
}

pub fn build_global_dream_system_prompt_empty_sources_test() {
  let prompt =
    dreaming.build_global_dream_system_prompt(
      "(empty)",
      "(empty)",
      "(no domain index entries)",
    )

  prompt |> string.contains("(empty)") |> should.be_true
  prompt |> string.contains("(no domain index entries)") |> should.be_true
}

pub fn collect_results_all_received_test() {
  // Create a subject and pre-send results to it
  let subject = process.new_subject()

  process.send(subject, #(
    "backend",
    Ok(dreaming.DreamResult(
      domain: "backend",
      phase_reached: "render",
      entries_consolidated: 3,
      entries_promoted: 1,
      reflections_generated: 1,
      duration_ms: 5000,
      index_entry: Some("Backend index."),
    )),
  ))

  process.send(subject, #(
    "frontend",
    Ok(dreaming.DreamResult(
      domain: "frontend",
      phase_reached: "render",
      entries_consolidated: 2,
      entries_promoted: 0,
      reflections_generated: 0,
      duration_ms: 3000,
      index_entry: None,
    )),
  ))

  let deadline = time.now_ms() + 1000
  let results = dreaming.collect_results(subject, 2, [], deadline)
  list.length(results) |> should.equal(2)

  // Both should be Ok
  list.all(results, fn(r) {
    case r {
      Ok(_) -> True
      Error(_) -> False
    }
  })
  |> should.be_true
}

pub fn collect_results_timeout_returns_partial_test() {
  // Create a subject and send only 1 result when expecting 2
  let subject = process.new_subject()

  process.send(subject, #(
    "backend",
    Ok(dreaming.DreamResult(
      domain: "backend",
      phase_reached: "render",
      entries_consolidated: 1,
      entries_promoted: 0,
      reflections_generated: 0,
      duration_ms: 1000,
      index_entry: None,
    )),
  ))

  // Expect 2 but only 1 was sent — should timeout and return what we have
  let deadline = time.now_ms() + 100
  let results = dreaming.collect_results(subject, 2, [], deadline)
  list.length(results) |> should.equal(1)
}

pub fn collect_results_zero_remaining_test() {
  // When remaining is 0, should return empty immediately
  let subject = process.new_subject()
  let deadline = time.now_ms() + 1000
  let results = dreaming.collect_results(subject, 0, [], deadline)
  list.length(results) |> should.equal(0)
}

pub fn collect_results_includes_errors_test() {
  let subject = process.new_subject()

  process.send(subject, #("backend", Error("LLM call failed")))
  process.send(subject, #(
    "frontend",
    Ok(dreaming.DreamResult(
      domain: "frontend",
      phase_reached: "render",
      entries_consolidated: 2,
      entries_promoted: 0,
      reflections_generated: 0,
      duration_ms: 3000,
      index_entry: None,
    )),
  ))

  let deadline = time.now_ms() + 1000
  let results = dreaming.collect_results(subject, 2, [], deadline)
  list.length(results) |> should.equal(2)

  // One should be Error, one Ok
  let error_count =
    list.count(results, fn(r) {
      case r {
        Error(_) -> True
        _ -> False
      }
    })
  error_count |> should.equal(1)
}
