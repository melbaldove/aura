import aura/tier
import gleeunit/should

pub fn tier1_domain_logs_test() {
  tier.for_path("/home/user/.local/share/aura/domains/cm2/logs/2026-03-30.jsonl")
  |> should.equal(tier.Autonomous)
}

pub fn tier1_domain_log_jsonl_test() {
  tier.for_path("/home/user/.local/share/aura/domains/cm2/log.jsonl")
  |> should.equal(tier.Autonomous)
}

pub fn tier1_events_test() {
  tier.for_path("/home/user/.local/share/aura/events.jsonl")
  |> should.equal(tier.Autonomous)
}

pub fn tier1_domain_memory_test() {
  tier.for_path("/home/user/.local/share/aura/domains/hy/MEMORY.md")
  |> should.equal(tier.Autonomous)
}

pub fn tier1_domain_state_test() {
  tier.for_path("/home/user/.local/state/aura/domains/cm2/STATE.md")
  |> should.equal(tier.Autonomous)
}

pub fn tier1_global_memory_test() {
  tier.for_path("/home/user/.local/state/aura/MEMORY.md")
  |> should.equal(tier.Autonomous)
}

pub fn tier1_skills_test() {
  tier.for_path("/home/user/.local/share/aura/skills/jira/SKILL.md")
  |> should.equal(tier.Autonomous)
}

pub fn tier2_config_toml_test() {
  tier.for_path("/home/user/.config/aura/domains/cm2/config.toml")
  |> should.equal(tier.NeedsApproval)
}

pub fn tier2_global_config_test() {
  tier.for_path("/home/user/.config/aura/config.toml")
  |> should.equal(tier.NeedsApproval)
}

pub fn tier2_user_md_test() {
  tier.for_path("/home/user/.config/aura/USER.md")
  |> should.equal(tier.NeedsApproval)
}

pub fn tier2_catchall_test() {
  tier.for_path("/etc/hosts")
  |> should.equal(tier.NeedsApproval)
}

pub fn tier2_random_path_test() {
  tier.for_path("/home/user/random/file.txt")
  |> should.equal(tier.NeedsApproval)
}

pub fn tier3_soul_test() {
  tier.for_path("/home/user/.config/aura/SOUL.md")
  |> should.equal(tier.NeedsApprovalWithPreview)
}

pub fn can_write_autonomous_test() {
  tier.can_write_without_approval(
    "/home/user/.local/share/aura/domains/cm2/logs/today.jsonl",
  )
  |> should.be_true
}

pub fn can_write_soul_test() {
  tier.can_write_without_approval("/home/user/.config/aura/SOUL.md")
  |> should.be_false
}

pub fn can_write_config_test() {
  tier.can_write_without_approval("/home/user/.config/aura/config.toml")
  |> should.be_false
}
