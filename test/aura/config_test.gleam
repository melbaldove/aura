import aura/config
import gleam/result
import gleeunit/should

pub fn parse_global_config_test() {
  let toml = "
[discord]
token = \"test-token\"
guild = \"aura\"
default_channel = \"aura\"

[models]
brain = \"zai/glm-5-turbo\"
workstream = \"claude/sonnet\"
acp = \"claude/opus\"
heartbeat = \"zai/glm-5-turbo\"
monitor = \"zai/glm-5-turbo\"

[notifications]
digest_windows = [\"07:35\", \"09:10\"]
timezone = \"Asia/Manila\"
urgent_bypass = true

[acp]
global_max_concurrent = 4
"

  let result = config.parse_global(toml)
  result |> should.be_ok

  let cfg = result |> result.unwrap(config.default_global())
  cfg.discord.guild |> should.equal("aura")
  cfg.models.brain |> should.equal("zai/glm-5-turbo")
  cfg.models.acp |> should.equal("claude/opus")
  cfg.notifications.timezone |> should.equal("Asia/Manila")
  cfg.acp_global_max_concurrent |> should.equal(4)
}

pub fn parse_workstream_config_test() {
  let toml = "
name = \"CM2\"
description = \"CMSquared PCHC CICS. Backend. Rust.\"
cwd = \"~/repos/cm2\"
tools = [\"jira\", \"google\", \"slack\"]

[discord]
channel = \"cm2\"

[model]
workstream = \"claude/opus\"

[acp]
timeout = 1800
max_concurrent = 2
"

  let result = config.parse_workstream(toml)
  result |> should.be_ok

  let ws = result |> result.unwrap(config.default_workstream())
  ws.name |> should.equal("CM2")
  ws.tools |> should.equal(["jira", "google", "slack"])
  ws.acp_timeout |> should.equal(1800)
}
