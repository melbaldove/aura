import aura/tier
import gleeunit/should

pub fn tier1_paths_test() {
  tier.for_path("domains/cm2/logs/2026-03-30.jsonl") |> should.equal(tier.Autonomous)
  tier.for_path("domains/cm2/anchors.jsonl") |> should.equal(tier.Autonomous)
  tier.for_path("events.jsonl") |> should.equal(tier.Autonomous)
  tier.for_path("MEMORY.md") |> should.equal(tier.Autonomous)
}

pub fn tier2_paths_test() {
  tier.for_path("domains/cm2/config.toml") |> should.equal(tier.NeedsApproval)
  tier.for_path("config.toml") |> should.equal(tier.NeedsApproval)
  tier.for_path("USER.md") |> should.equal(tier.NeedsApproval)
}

pub fn tier3_paths_test() {
  tier.for_path("SOUL.md") |> should.equal(tier.NeedsApprovalWithPreview)
  tier.for_path("META.md") |> should.equal(tier.NeedsApprovalWithPreview)
}

pub fn unknown_path_test() {
  tier.for_path("random/file.txt") |> should.equal(tier.NeedsApproval)
}

pub fn can_write_test() {
  tier.can_write_without_approval("domains/cm2/logs/today.jsonl") |> should.be_true
  tier.can_write_without_approval("SOUL.md") |> should.be_false
  tier.can_write_without_approval("config.toml") |> should.be_false
}
