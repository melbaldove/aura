import aura/validator
import gleam/list
import gleeunit/should

pub fn match_exact_path_test() {
  validator.path_matches("SOUL.md", "SOUL.md") |> should.be_true
  validator.path_matches("USER.md", "SOUL.md") |> should.be_false
}

pub fn match_glob_path_test() {
  validator.path_matches("domains/cm2/log.jsonl", "domains/*/log.jsonl")
  |> should.be_true
  validator.path_matches(
    "domains/cm2/logs/2026-03-30.jsonl",
    "domains/*/logs/*.jsonl",
  )
  |> should.be_true
  validator.path_matches("config.toml", "*.toml") |> should.be_true
  validator.path_matches("SOUL.md", "*.toml") |> should.be_false
}

pub fn validate_must_contain_test() {
  let rule =
    validator.Rule(
      path: "SOUL.md",
      rule_type: validator.MustContain("# SOUL"),
      message: "header required",
    )
  validator.check_rule(rule, "# SOUL\nYou are Aura.") |> should.be_ok
  validator.check_rule(rule, "No header here.") |> should.be_error
}

pub fn validate_valid_toml_test() {
  let rule =
    validator.Rule(
      path: "config.toml",
      rule_type: validator.ValidToml,
      message: "must be valid TOML",
    )
  validator.check_rule(rule, "name = \"test\"\n[section]\nkey = \"value\"")
  |> should.be_ok
  validator.check_rule(rule, "invalid [[[toml") |> should.be_error
}

pub fn validate_valid_jsonl_test() {
  let rule =
    validator.Rule(
      path: "log.jsonl",
      rule_type: validator.ValidJsonl,
      message: "must be valid JSONL",
    )
  validator.check_rule(rule, "{\"key\": \"value\"}") |> should.be_ok
  validator.check_rule(rule, "not json at all") |> should.be_error
}

pub fn validate_no_patterns_test() {
  let rule =
    validator.Rule(
      path: "SOUL.md",
      rule_type: validator.NoPatterns(["heartbeat", "cron"]),
      message: "no ops",
    )
  validator.check_rule(rule, "You are direct and concise.") |> should.be_ok
  validator.check_rule(rule, "Check heartbeat every 5 minutes.")
  |> should.be_error
}

pub fn validate_max_size_test() {
  let rule =
    validator.Rule(
      path: "SOUL.md",
      rule_type: validator.MaxSizeKb(1),
      message: "max 1KB",
    )
  validator.check_rule(rule, "short content") |> should.be_ok
}

pub fn validate_all_matching_test() {
  let rules = [
    validator.Rule(
      path: "SOUL.md",
      rule_type: validator.MustContain("# SOUL"),
      message: "header",
    ),
    validator.Rule(
      path: "SOUL.md",
      rule_type: validator.NoPatterns(["heartbeat"]),
      message: "no ops",
    ),
    validator.Rule(
      path: "*.toml",
      rule_type: validator.ValidToml,
      message: "valid toml",
    ),
  ]
  validator.validate("SOUL.md", "# SOUL\nPersonality.", rules) |> should.be_ok
  validator.validate("SOUL.md", "# SOUL\nheartbeat stuff.", rules)
  |> should.be_error
}

pub fn parse_rules_test() {
  let toml =
    "
[[rules]]
path = \"SOUL.md\"
type = \"must_contain\"
value = \"# SOUL\"
message = \"Must have header\"

[[rules]]
path = \"*.toml\"
type = \"valid_toml\"
message = \"Must be valid TOML\"
"
  let rules = validator.parse_rules(toml) |> should.be_ok
  list.length(rules) |> should.equal(2)
}
