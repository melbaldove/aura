import aura/config
import aura/config_parser
import gleam/list
import gleam/result
import gleam/string
import gleeunit/should

pub fn resolve_env_var_test() {
  set_env("TEST_AURA_TOKEN", "secret123")

  config_parser.resolve_env_string("${TEST_AURA_TOKEN}")
  |> should.equal(Ok("secret123"))

  config_parser.resolve_env_string("plain-string")
  |> should.equal(Ok("plain-string"))

  config_parser.resolve_env_string("${NONEXISTENT_VAR}")
  |> should.be_error
}

fn base_global_toml() -> String {
  "
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
}

pub fn parse_empty_mcp_returns_empty_servers_test() {
  let result = config.parse_global(base_global_toml())
  result |> should.be_ok
  let cfg = result |> result.unwrap(config.default_global())
  cfg.mcp.servers |> should.equal([])
}

pub fn parse_single_stdio_server_test() {
  let toml =
    base_global_toml()
    <> "
[mcp.servers.gmail-work]
transport = \"stdio\"
command = \"gmail-mcp\"
args = [\"--accept-insecure\"]
"
  let result = config.parse_global(toml)
  result |> should.be_ok
  let cfg = result |> result.unwrap(config.default_global())
  cfg.mcp.servers |> list.length |> should.equal(1)
  let assert [server] = cfg.mcp.servers
  server.name |> should.equal("gmail-work")
  server.transport |> should.equal(config.StdioTransport)
  server.command |> should.equal("gmail-mcp")
  server.args |> should.equal(["--accept-insecure"])
}

pub fn parse_multiple_servers_test() {
  let toml =
    base_global_toml()
    <> "
[mcp.servers.gmail]
transport = \"stdio\"
command = \"gmail-mcp\"

[mcp.servers.linear]
transport = \"stdio\"
command = \"linear-mcp\"
"
  let result = config.parse_global(toml)
  result |> should.be_ok
  let cfg = result |> result.unwrap(config.default_global())
  cfg.mcp.servers |> list.length |> should.equal(2)
  let names =
    cfg.mcp.servers
    |> list.map(fn(s) { s.name })
    |> list.sort(string.compare)
  names |> should.equal(["gmail", "linear"])
}

pub fn parse_server_with_env_expansion_test() {
  set_env("TEST_GMAIL_TOKEN", "gmail-xyz")
  let toml =
    base_global_toml()
    <> "
[mcp.servers.gmail]
transport = \"stdio\"
command = \"gmail-mcp\"

[mcp.servers.gmail.env]
GMAIL_TOKEN = \"${TEST_GMAIL_TOKEN}\"
"
  let result = config.parse_global(toml)
  result |> should.be_ok
  let cfg = result |> result.unwrap(config.default_global())
  let assert [server] = cfg.mcp.servers
  server.env |> should.equal([#("GMAIL_TOKEN", "gmail-xyz")])
}

pub fn parse_server_without_transport_defaults_to_stdio_test() {
  let toml =
    base_global_toml()
    <> "
[mcp.servers.gmail]
command = \"gmail-mcp\"
"
  let result = config.parse_global(toml)
  result |> should.be_ok
  let cfg = result |> result.unwrap(config.default_global())
  let assert [server] = cfg.mcp.servers
  server.transport |> should.equal(config.StdioTransport)
}

pub fn parse_server_with_unsupported_transport_returns_error_test() {
  let toml =
    base_global_toml()
    <> "
[mcp.servers.gmail]
transport = \"sse\"
command = \"gmail-mcp\"
"
  let result = config.parse_global(toml)
  case result {
    Ok(_) -> should.fail()
    Error(msg) -> {
      string.contains(msg, "unsupported transport") |> should.be_true
      string.contains(msg, "sse") |> should.be_true
    }
  }
}

pub fn parse_server_missing_command_returns_error_test() {
  let toml =
    base_global_toml()
    <> "
[mcp.servers.gmail]
transport = \"stdio\"
"
  let result = config.parse_global(toml)
  case result {
    Ok(_) -> should.fail()
    Error(msg) -> {
      string.contains(msg, "command") |> should.be_true
      string.contains(msg, "gmail") |> should.be_true
    }
  }
}

fn set_env(key: String, value: String) -> Nil {
  set_env_ffi(key, value)
  Nil
}

@external(erlang, "aura_test_ffi", "set_env")
fn set_env_ffi(key: String, value: String) -> Bool
