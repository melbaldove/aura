import aura/acp/provider
import aura/acp/types
import gleeunit/should

pub fn task_spec_test() {
  let spec =
    types.TaskSpec(
      id: "acp-cm2-cics967",
      domain: "cm2",
      prompt: "Fix bug",
      cwd: "~/repos/cm2",
      timeout_ms: 1_800_000,
      acceptance_criteria: ["Tests pass"],
      provider: provider.ClaudeCode,
      worktree: True,
    )
  spec.id |> should.equal("acp-cm2-cics967")
}

pub fn session_status_test() {
  types.status_to_string(types.Running) |> should.equal("running")
  types.status_to_string(types.Stuck) |> should.equal("stuck")
  types.status_to_string(types.Complete) |> should.equal("complete")
}

pub fn outcome_test() {
  types.outcome_to_string(types.Clean) |> should.equal("clean")
  types.outcome_to_string(types.Failed) |> should.equal("failed")
}
