import aura/dreaming
import aura/test_helpers
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
  let memory = "§ db-pattern\nAll DB access through actor\n\n§ fts-search\nFTS5 with porter tokenizer"
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
  let prompt = dreaming.build_render_prompt(4096)

  // Contains the budget number
  prompt |> string.contains("4096") |> should.be_true

  // Contains set/remove instructions
  prompt |> string.contains("set") |> should.be_true
  prompt |> string.contains("remove") |> should.be_true

  // Contains domain-index instruction
  prompt |> string.contains("domain-index") |> should.be_true
}

pub fn build_render_prompt_different_budget_test() {
  let prompt = dreaming.build_render_prompt(8192)
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
  sources.state_content |> string.contains("Building dreaming system") |> should.be_true

  // Memory content is formatted
  sources.memory_content |> string.contains("db-pattern") |> should.be_true
  sources.memory_content |> string.contains("Actor serializes all writes") |> should.be_true

  // DB-sourced fields are empty (caller fills them)
  sources.flare_outcomes |> should.equal("")
  sources.compaction_summaries |> should.equal("")

  cleanup(base)
}

pub fn gather_file_sources_missing_files_test() {
  let base = temp_dir("missing-" <> test_helpers.random_suffix())

  let sources = dreaming.gather_file_sources(
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

  let sources = dreaming.gather_file_sources(
    base <> "/STATE.md",
    base <> "/MEMORY.md",
  )

  // Empty files with no entries return "(empty)" from format_for_display
  sources.state_content |> should.equal("(empty)")
  sources.memory_content |> should.equal("(empty)")

  cleanup(base)
}

// ---------------------------------------------------------------------------
// System prompt tests
// ---------------------------------------------------------------------------

pub fn build_dream_system_prompt_test() {
  let sources = dreaming.DreamSources(
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
  let sources = dreaming.DreamSources(
    memory_content: "(empty)",
    state_content: "(empty)",
    flare_outcomes: "(no flare outcomes since last dream)",
    compaction_summaries: "(no compaction summaries available)",
  )
  let prompt = dreaming.build_dream_system_prompt("aura", sources)

  prompt |> string.contains("aura") |> should.be_true
  prompt |> string.contains("(empty)") |> should.be_true
  prompt |> string.contains("(no flare outcomes since last dream)") |> should.be_true
  prompt |> string.contains("(no compaction summaries available)") |> should.be_true
}
