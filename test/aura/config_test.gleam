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
domain = \"claude/sonnet\"
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
  cfg.models.domain |> should.equal("claude/sonnet")
  cfg.models.acp |> should.equal("claude/opus")
  cfg.notifications.timezone |> should.equal("Asia/Manila")
  cfg.acp_global_max_concurrent |> should.equal(4)
}

pub fn parse_domain_config_test() {
  let toml = "
name = \"CM2\"
description = \"CMSquared PCHC CICS. Backend. Rust.\"
cwd = \"~/repos/cm2\"
tools = [\"jira\", \"google\", \"slack\"]

[discord]
channel = \"cm2\"

[model]
domain = \"claude/opus\"

[acp]
timeout = 1800
max_concurrent = 2
"

  let result = config.parse_domain(toml)
  result |> should.be_ok

  let ws = result |> result.unwrap(config.default_domain())
  ws.name |> should.equal("CM2")
  ws.tools |> should.equal(["jira", "google", "slack"])
  ws.acp_timeout |> should.equal(1800)
}

pub fn parse_global_config_with_vision_test() {
  let toml = "
[discord]
token = \"test-token\"
guild = \"aura\"
default_channel = \"aura\"

[models]
brain = \"zai/glm-5.1\"
domain = \"zai/glm-5.1\"
acp = \"claude/opus\"
heartbeat = \"zai/glm-5-turbo\"
monitor = \"zai/glm-5-turbo\"
vision = \"zai/glm-5v-turbo\"

[vision]
prompt = \"Describe this image concisely.\"

[notifications]
digest_windows = [\"07:35\"]
timezone = \"Asia/Manila\"
urgent_bypass = true

[acp]
global_max_concurrent = 4
"
  let result = config.parse_global(toml)
  result |> should.be_ok
  let cfg = result |> result.unwrap(config.default_global())
  cfg.models.vision |> should.equal("zai/glm-5v-turbo")
  cfg.vision.prompt |> should.equal("Describe this image concisely.")
}

// This test uses the legacy "workstream" key to verify backwards compatibility
pub fn parse_global_config_without_vision_test() {
  let toml = "
[discord]
token = \"test-token\"
guild = \"aura\"
default_channel = \"aura\"

[models]
brain = \"zai/glm-5.1\"
workstream = \"zai/glm-5.1\"
acp = \"claude/opus\"
heartbeat = \"zai/glm-5-turbo\"
monitor = \"zai/glm-5-turbo\"

[notifications]
digest_windows = [\"07:35\"]
timezone = \"Asia/Manila\"
urgent_bypass = true

[acp]
global_max_concurrent = 4
"
  let result = config.parse_global(toml)
  result |> should.be_ok
  let cfg = result |> result.unwrap(config.default_global())
  cfg.models.vision |> should.equal("")
  cfg.vision.prompt |> should.equal("")
}

pub fn parse_domain_config_with_vision_test() {
  let toml = "
name = \"local-accounts\"
description = \"Local accounting\"
cwd = \".\"
tools = [\"discord\"]

[discord]
channel = \"local-accounts\"

[models]
vision = \"zai/glm-5v-turbo\"

[vision]
prompt = \"Describe this receipt. Focus on amounts and dates.\"
"
  let result = config.parse_domain(toml)
  result |> should.be_ok
  let cfg = result |> result.unwrap(config.default_domain())
  cfg.vision_model |> should.equal("zai/glm-5v-turbo")
  cfg.vision_prompt |> should.equal("Describe this receipt. Focus on amounts and dates.")
}

pub fn parse_domain_config_without_vision_test() {
  let toml = "
name = \"CM2\"
description = \"CMSquared\"
cwd = \".\"
tools = [\"discord\"]

[discord]
channel = \"cm2\"
"
  let result = config.parse_domain(toml)
  result |> should.be_ok
  let cfg = result |> result.unwrap(config.default_domain())
  cfg.vision_model |> should.equal("")
  cfg.vision_prompt |> should.equal("")
}

pub fn parse_domain_config_with_acp_test() {
  let toml = "
name = \"test\"
description = \"Test\"
cwd = \".\"
tools = [\"discord\"]

[discord]
channel = \"test\"

[acp]
provider = \"generic\"
binary = \"codex\"
worktree = false
"
  let result = config.parse_domain(toml)
  result |> should.be_ok
  let cfg = result |> result.unwrap(config.default_domain())
  cfg.acp_provider |> should.equal("generic")
  cfg.acp_binary |> should.equal("codex")
  cfg.acp_worktree |> should.equal(False)
}

pub fn parse_domain_config_acp_defaults_test() {
  let toml = "
name = \"test\"
description = \"Test\"
cwd = \".\"
tools = [\"discord\"]

[discord]
channel = \"test\"
"
  let result = config.parse_domain(toml)
  result |> should.be_ok
  let cfg = result |> result.unwrap(config.default_domain())
  cfg.acp_provider |> should.equal("claude-code")
  cfg.acp_worktree |> should.equal(True)
}

pub fn parse_global_skill_review_interval_test() {
  let toml = "
[discord]
token = \"test-token\"
guild = \"aura\"
default_channel = \"aura\"

[models]
brain = \"zai/glm-5-turbo\"
domain = \"claude/sonnet\"
acp = \"claude/opus\"
heartbeat = \"zai/glm-5-turbo\"
monitor = \"zai/glm-5-turbo\"

[notifications]
digest_windows = [\"07:35\"]
timezone = \"Asia/Manila\"
urgent_bypass = true

[acp]
global_max_concurrent = 4

[memory]
skill_review_interval = 50
"

  let result = config.parse_global(toml)
  result |> should.be_ok

  let cfg = result |> result.unwrap(config.default_global())
  cfg.memory.skill_review_interval |> should.equal(50)
}

pub fn parse_global_skill_review_interval_default_test() {
  let toml = "
[discord]
token = \"test-token\"
guild = \"aura\"
default_channel = \"aura\"

[models]
brain = \"zai/glm-5-turbo\"
domain = \"claude/sonnet\"
acp = \"claude/opus\"
heartbeat = \"zai/glm-5-turbo\"
monitor = \"zai/glm-5-turbo\"

[notifications]
digest_windows = [\"07:35\"]
timezone = \"Asia/Manila\"
urgent_bypass = true

[acp]
global_max_concurrent = 4
"

  let result = config.parse_global(toml)
  result |> should.be_ok

  let cfg = result |> result.unwrap(config.default_global())
  cfg.memory.skill_review_interval |> should.equal(30)
}
