import aura/hook_rules
import gleam/option.{None, Some}
import gleam/list
import gleeunit
import gleeunit/should

fn ruleset_toml() -> String {
  "
name = \"linkedin-collector\"
source = \"linkedin\"

[[rule]]
name = \"challenge\"
match = \"CHALLENGE: (.+)\"
lane = \"ask\"
target = \"domain:one-mil-in-five\"
text = \"LinkedIn challenge: {1}. Solve it in the browser window.\"
buttons = [\"Resolved\", \"Abort\"]
ttl_minutes = 60

[[rule]]
name = \"progress\"
match = \"PROGRESS (\\\\d+)\"
lane = \"event\"
target = \"default\"
text = \"Collector progress: {1}\"
"
}

pub fn parse_rules_file_test() {
  let assert Ok(ruleset) = hook_rules.parse(ruleset_toml())
  ruleset.source |> should.equal("linkedin")
  list.length(ruleset.rules) |> should.equal(2)
}

pub fn parse_missing_lane_is_parse_error_test() {
  let toml = "
name = \"x\"
source = \"src\"
[[rule]]
name = \"r\"
match = \"ok\"
target = \"default\"
text = \"hi\"
"
  hook_rules.parse(toml) |> should.equal(Error("Missing rule.lane"))
}

pub fn invalid_lane_is_parse_error_test() {
  let toml = "
name = \"x\"
source = \"src\"
[[rule]]
name = \"r\"
match = \"ok\"
lane = \"explode\"
target = \"default\"
text = \"hi\"
"
  hook_rules.parse(toml) |> should.equal(Error("Unknown lane: explode"))
}

pub fn invalid_regex_is_parse_error_test() {
  let toml = "
name = \"x\"
source = \"src\"
[[rule]]
name = \"r\"
match = \"(\"
lane = \"event\"
target = \"default\"
text = \"hi\"
"
  let assert Error(_) = hook_rules.parse(toml)
  Nil
}

pub fn match_and_render_ask_test() {
  let assert Ok(ruleset) = hook_rules.parse(ruleset_toml())
  let assert Ok(fires) =
    hook_rules.match_line(ruleset, "CHALLENGE: unusual activity", 1_700_000_000)
  fires
  |> should.equal([
    hook_rules.FireAsk(
      rule_name: "challenge",
      target: "domain:one-mil-in-five",
      text: "LinkedIn challenge: unusual activity. Solve it in the browser window.",
      buttons: ["Resolved", "Abort"],
      ttl_minutes: 60,
      correlation_id: "linkedin-challenge-1700000000",
    ),
  ])
}

pub fn match_and_render_event_test() {
  let ruleset = {
    let assert Ok(rs) = hook_rules.parse(ruleset_toml())
    rs
  }
  let assert Ok(fires) = hook_rules.match_line(ruleset, "PROGRESS 340", 0)
  fires
  |> should.equal([
    hook_rules.FireEvent(
      rule_name: "progress",
      subject: "Collector progress: 340",
      external_id: "linkedin:progress:Collector progress: 340",
      data: "{\"line\":\"PROGRESS 340\"}",
    ),
  ])
}

pub fn no_match_test() {
  let ruleset = {
    let assert Ok(rs) = hook_rules.parse(ruleset_toml())
    rs
  }
  hook_rules.match_line(ruleset, "unrelated ping", 0)
  |> should.equal(Ok([]))
}

pub fn template_out_of_range_is_render_error_test() {
  let toml = "
name = \"x\"
source = \"src\"
[[rule]]
name = \"r\"
match = \"KEY (\\\\d+)\"
lane = \"event\"
target = \"default\"
text = \"value {9}\"
"
  let assert Ok(ruleset) = hook_rules.parse(toml)
  hook_rules.match_line(ruleset, "KEY 42", 0)
  |> should.equal(Error("template group 9 out of range"))
}

pub fn notify_uses_external_id_template_test() {
  let toml = "
name = \"x\"
source = \"src\"
[[rule]]
name = \"n\"
match = \"NOTE: (.+)\"
lane = \"notify\"
target = \"default\"
text = \"Saw: {1}\"
external_id = \"src-noted-{1}\"
"
  let assert Ok(ruleset) = hook_rules.parse(toml)
  let assert Ok(fires) = hook_rules.match_line(ruleset, "NOTE: backup done", 0)
  fires
  |> should.equal([
    hook_rules.FireNotify(
      rule_name: "n",
      target: "default",
      text: "Saw: backup done",
      external_id: "src-noted-backup done",
    ),
  ])
}