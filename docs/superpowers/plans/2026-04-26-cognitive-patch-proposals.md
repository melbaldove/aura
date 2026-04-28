# Cognitive Patch Proposals Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn captured cognitive correction labels into reviewable markdown patch proposal reports for text policies and concern files.

**Architecture:** Add a small offline proposal module that reads existing label JSONL, groups labels by known adjustment surface, enriches each case with event subject/source when available, and writes a markdown report under the cognitive data directory. The command proposes ordinary text edits only; it never mutates `policies/*.md` or `concerns/*.md`.

**Tech Stack:** Gleam, append/read JSONL files, SQLite through the existing `db` actor, `gleeunit` behavior tests, XDG paths.

---

### Task 1: Proposal Report Generation

**Files:**
- Create: `src/aura/cognitive_patch.gleam`
- Test: `test/aura/cognitive_patch_test.gleam`

- [ ] **Step 1: Write failing tests**

Add tests that create temp XDG paths, append label JSONL, optionally insert events into an in-memory DB, and assert that proposal generation:

```gleam
pub fn propose_from_missing_labels_returns_noop_report_test() {
  let assert Ok(db_subject) = db.start(":memory:")
  let #(base, paths) = temp_paths("cognitive-patch-empty")

  let result =
    cognitive_patch.propose_from_labels_at(paths, db_subject, 1234)
    |> should.be_ok

  result.proposal_count |> should.equal(0)
  result.label_count |> should.equal(0)
  result.path |> should.equal("")
  result.markdown
  |> should.equal("OK: no cognitive labels found; no patch proposals generated.")

  process.send(db_subject, db.Shutdown)
  let _ = simplifile.delete_all([base])
  Nil
}

pub fn propose_from_labels_groups_by_patch_target_test() {
  let assert Ok(db_subject) = db.start(":memory:")
  let #(base, paths) = temp_paths("cognitive-patch-grouped")
  let assert Ok(True) = db.insert_event(db_subject, sample_event("ev-noisy"))
  let _ = simplifile.create_directory_all(xdg.cognitive_dir(paths))
  let _ = memory.append_jsonl(xdg.labels_path(paths), label_json("ev-noisy", "false_interrupt", ["record", "digest"], "Too noisy."))

  let result =
    cognitive_patch.propose_from_labels_at(paths, db_subject, 1234)
    |> should.be_ok

  result.proposal_count |> should.equal(1)
  result.label_count |> should.equal(1)
  result.path
  |> should.equal(xdg.cognitive_dir(paths) <> "/patch-proposals/1234.md")
  result.markdown |> string.contains("## `policies/attention.md`") |> should.be_true
  result.markdown |> string.contains("ev-noisy") |> should.be_true
  result.markdown |> string.contains("Too noisy.") |> should.be_true
  result.markdown |> string.contains("Expected attention: record, digest") |> should.be_true

  process.send(db_subject, db.Shutdown)
  let _ = simplifile.delete_all([base])
  Nil
}
```

- [ ] **Step 2: Verify tests fail**

Run:

```bash
nix develop --command gleam test
```

Expected: compile failure because `aura/cognitive_patch` does not exist.

- [ ] **Step 3: Implement minimal module**

Implement:

```gleam
pub type ProposalReport {
  ProposalReport(path: String, label_count: Int, proposal_count: Int, markdown: String)
}

pub fn propose_from_labels(paths: xdg.Paths, db_subject: process.Subject(db.DbMessage)) -> Result(ProposalReport, String)

pub fn propose_from_labels_at(paths: xdg.Paths, db_subject: process.Subject(db.DbMessage), timestamp_ms: Int) -> Result(ProposalReport, String)
```

The module must call `cognitive_replay.load_labels`, map known correction labels to allowed text targets, render markdown with event IDs, labels, expected attention, event subject/source, notes, and a patch brief, and write non-empty reports to `~/.local/share/aura/cognitive/patch-proposals/<timestamp_ms>.md`.

- [ ] **Step 4: Verify tests pass**

Run:

```bash
nix develop --command gleam test
```

Expected: all tests pass.

### Task 2: CLI And Daemon Wiring

**Files:**
- Modify: `src/aura.gleam`
- Modify: `src/aura/ctl.gleam`
- Test: `test/aura/cli_test.gleam`

- [ ] **Step 1: Write failing CLI parse test**

Add:

```gleam
pub fn parse_cognitive_replay_propose_patches_test() {
  aura.parse_args_for_test(["cognitive-replay", "propose-patches"])
  |> should.equal(aura.CliCtl("cognitive-replay propose-patches"))
}
```

- [ ] **Step 2: Verify test fails**

Run:

```bash
nix develop --command gleam test
```

Expected: parse test fails because the command currently falls through to `CliStart`.

- [ ] **Step 3: Wire command**

Add CLI parsing and `ctl` handling:

```gleam
["cognitive-replay", "propose-patches"] ->
  CliCtl("cognitive-replay propose-patches")
```

and in the daemon command handler call `cognitive_patch.propose_from_labels(ctx.paths, ctx.db_subject)`, returning:

```text
OK: cognitive-replay propose-patches labels=<n> proposals=<n> path=<path>
```

For no labels, return the report markdown text directly.

- [ ] **Step 4: Verify command wiring passes**

Run:

```bash
nix develop --command gleam test
```

Expected: all tests pass.

### Task 3: Documentation

**Files:**
- Modify: `README.md`
- Modify: `AGENTS.md`
- Modify: `docs/architecture/cognitive-capacity-first-slice-plan.md`
- Modify: `docs/architecture/cognitive-capacity.md`

- [ ] **Step 1: Document the new command**

Record that `cognitive-replay propose-patches` reads correction labels and writes markdown proposal reports without applying policy changes.

- [ ] **Step 2: Verify docs and formatting**

Run:

```bash
git diff --check
nix develop --command gleam test
```

Expected: no whitespace errors and all tests pass.

### Task 4: Commit And Deploy

**Files:**
- All files above.

- [ ] **Step 1: Review final diff**

Run:

```bash
git status --short
git diff --stat
```

- [ ] **Step 2: Commit**

Run:

```bash
git add src/aura/cognitive_patch.gleam src/aura.gleam src/aura/ctl.gleam test/aura/cognitive_patch_test.gleam test/aura/cli_test.gleam README.md AGENTS.md docs/architecture/cognitive-capacity-first-slice-plan.md docs/architecture/cognitive-capacity.md docs/superpowers/plans/2026-04-26-cognitive-patch-proposals.md
git commit -m "feat: propose cognitive policy patches"
```

- [ ] **Step 3: Deploy**

Before deployment, tail `/tmp/aura.log` on Eisenhower for active work. If safe, run:

```bash
bash scripts/deploy.sh
```

Expected: Aura restarts and the log shows normal startup.
