import aura/cron
import aura/env
import gleam/dict
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import logging
import tom

/// Discord connection settings (token, guild ID, and fallback channel ID).
pub type DiscordConfig {
  DiscordConfig(token: String, guild: String, default_channel: String)
}

/// Model IDs used by each agent role (brain, domain, ACP, heartbeat, monitor, vision, dream).
pub type ModelsConfig {
  ModelsConfig(
    brain: String,
    domain: String,
    acp: String,
    heartbeat: String,
    monitor: String,
    vision: String,
    dream: String,
  )
}

/// Vision model configuration (prompt for image description).
pub type VisionConfig {
  VisionConfig(prompt: String)
}

/// Controls when and how digest notifications are delivered.
/// `digest_windows` are time-of-day windows (e.g. "09:00-10:00").
/// `urgent_bypass` allows urgent findings to skip the digest schedule.
pub type NotificationsConfig {
  NotificationsConfig(
    digest_windows: List(String),
    timezone: String,
    urgent_bypass: Bool,
  )
}

/// Controls automatic post-response memory review.
pub type MemoryConfig {
  MemoryConfig(
    review_interval: Int,
    notify_on_review: Bool,
    skill_review_interval: Int,
  )
}

/// Transport used to talk to an MCP server. Phase 1 only supports stdio.
pub type McpTransport {
  StdioTransport
}

/// One `[mcp.servers.<name>]` block parsed from the global config.
/// `name` is the dict key from the TOML table, not a parsed field.
/// `env` values and other fields have `${VAR}` references pre-expanded.
pub type McpServerConfig {
  McpServerConfig(
    name: String,
    transport: McpTransport,
    command: String,
    args: List(String),
    env: List(#(String, String)),
    subscribe: List(String),
  )
}

/// Aggregate of all parsed `[mcp.servers.*]` blocks. Empty if no blocks
/// exist.
pub type McpConfig {
  McpConfig(servers: List(McpServerConfig))
}

/// Top-level configuration loaded from the global `config.toml`.
pub type GlobalConfig {
  GlobalConfig(
    discord: DiscordConfig,
    models: ModelsConfig,
    notifications: NotificationsConfig,
    vision: VisionConfig,
    memory: MemoryConfig,
    acp_global_max_concurrent: Int,
    acp_server_url: String,
    acp_agent_name: String,
    acp_transport: String,
    acp_command: String,
    brain_context: Int,
    dreaming_cron: String,
    dreaming_budget_percent: Int,
    mcp: McpConfig,
  )
}

/// Per-domain configuration loaded from each domain's `config.toml`.
pub type DomainConfig {
  DomainConfig(
    name: String,
    description: String,
    cwd: String,
    tools: List(String),
    discord_channel: String,
    model_domain: String,
    acp_timeout: Int,
    acp_max_concurrent: Int,
    vision_model: String,
    vision_prompt: String,
    acp_provider: String,
    acp_binary: String,
    acp_worktree: Bool,
    acp_server_url: String,
    acp_agent_name: String,
  )
}

/// Return a `GlobalConfig` with all fields set to empty/zero defaults.
pub fn default_global() -> GlobalConfig {
  GlobalConfig(
    discord: DiscordConfig(token: "", guild: "", default_channel: ""),
    models: ModelsConfig(
      brain: "",
      domain: "",
      acp: "",
      heartbeat: "",
      monitor: "",
      vision: "",
      dream: "",
    ),
    notifications: NotificationsConfig(
      digest_windows: [],
      timezone: "",
      urgent_bypass: False,
    ),
    vision: VisionConfig(prompt: ""),
    memory: MemoryConfig(
      review_interval: 10,
      notify_on_review: True,
      skill_review_interval: 10,
    ),
    acp_global_max_concurrent: 0,
    acp_server_url: "",
    acp_agent_name: "claude-code",
    acp_transport: "stdio",
    acp_command: "claude-agent-acp",
    brain_context: 0,
    dreaming_cron: "0 4 * * *",
    dreaming_budget_percent: 10,
    mcp: McpConfig(servers: []),
  )
}

/// Return a `DomainConfig` with all fields set to empty/zero defaults.
pub fn default_domain() -> DomainConfig {
  DomainConfig(
    name: "",
    description: "",
    cwd: "",
    tools: [],
    discord_channel: "",
    model_domain: "",
    acp_timeout: 0,
    acp_max_concurrent: 0,
    vision_model: "",
    vision_prompt: "",
    acp_provider: "claude-code",
    acp_binary: "",
    acp_worktree: True,
    acp_server_url: "",
    acp_agent_name: "",
  )
}

pub fn extract_toml_strings(values: List(tom.Toml)) -> List(String) {
  values
  |> list.filter_map(fn(v) {
    case v {
      tom.String(s) -> Ok(s)
      _ -> Error(Nil)
    }
  })
}

/// Parse a TOML string into a `GlobalConfig`. Returns an error message if any
/// required key is absent or the TOML is malformed.
pub fn parse_global(toml_string: String) -> Result(GlobalConfig, String) {
  use doc <- result.try(
    tom.parse(toml_string)
    |> result.map_error(fn(e) { "TOML parse error: " <> format_parse_error(e) }),
  )

  use token <- result.try(
    tom.get_string(doc, ["discord", "token"])
    |> result.map_error(fn(_) { "Missing discord.token" }),
  )
  use guild <- result.try(
    tom.get_string(doc, ["discord", "guild"])
    |> result.map_error(fn(_) { "Missing discord.guild" }),
  )
  use default_channel <- result.try(
    tom.get_string(doc, ["discord", "default_channel"])
    |> result.map_error(fn(_) { "Missing discord.default_channel" }),
  )

  use brain <- result.try(
    tom.get_string(doc, ["models", "brain"])
    |> result.map_error(fn(_) { "Missing models.brain" }),
  )
  use models_domain <- result.try(
    tom.get_string(doc, ["models", "domain"])
    |> result.try_recover(fn(_) {
      tom.get_string(doc, ["models", "workstream"])
    })
    |> result.map_error(fn(_) { "Missing models.domain" }),
  )
  use models_acp <- result.try(
    tom.get_string(doc, ["models", "acp"])
    |> result.map_error(fn(_) { "Missing models.acp" }),
  )
  use heartbeat <- result.try(
    tom.get_string(doc, ["models", "heartbeat"])
    |> result.map_error(fn(_) { "Missing models.heartbeat" }),
  )
  use monitor <- result.try(
    tom.get_string(doc, ["models", "monitor"])
    |> result.map_error(fn(_) { "Missing models.monitor" }),
  )

  use digest_windows_raw <- result.try(
    tom.get_array(doc, ["notifications", "digest_windows"])
    |> result.map_error(fn(_) { "Missing notifications.digest_windows" }),
  )
  use timezone <- result.try(
    tom.get_string(doc, ["notifications", "timezone"])
    |> result.map_error(fn(_) { "Missing notifications.timezone" }),
  )
  use urgent_bypass <- result.try(
    tom.get_bool(doc, ["notifications", "urgent_bypass"])
    |> result.map_error(fn(_) { "Missing notifications.urgent_bypass" }),
  )

  use global_max_concurrent <- result.try(
    tom.get_int(doc, ["acp", "global_max_concurrent"])
    |> result.map_error(fn(_) { "Missing acp.global_max_concurrent" }),
  )

  let vision_model =
    tom.get_string(doc, ["models", "vision"])
    |> result.unwrap("")

  let vision_prompt =
    tom.get_string(doc, ["vision", "prompt"])
    |> result.unwrap("")

  let review_interval =
    tom.get_int(doc, ["memory", "review_interval"])
    |> result.unwrap(10)

  let notify_on_review =
    tom.get_bool(doc, ["memory", "notify_on_review"])
    |> result.unwrap(True)

  let skill_review_interval =
    tom.get_int(doc, ["memory", "skill_review_interval"])
    |> result.unwrap(30)

  let brain_context =
    tom.get_int(doc, ["models", "brain_context"])
    |> result.unwrap(0)

  let acp_server_url =
    tom.get_string(doc, ["acp", "server_url"])
    |> result.unwrap("")

  let acp_agent_name =
    tom.get_string(doc, ["acp", "agent_name"])
    |> result.unwrap("claude-code")

  let acp_transport =
    tom.get_string(doc, ["acp", "transport"])
    |> result.unwrap("stdio")

  let acp_command =
    tom.get_string(doc, ["acp", "command"])
    |> result.unwrap("claude-agent-acp")

  let dream_model =
    tom.get_string(doc, ["models", "dream"])
    |> result.unwrap(brain)

  let dreaming_cron = case tom.get_string(doc, ["dreaming", "cron"]) {
    Ok(c) -> {
      case cron.parse(c) {
        Ok(_) -> c
        Error(_) -> {
          logging.log(
            logging.Warning,
            "[config] Invalid dreaming.cron '" <> c <> "', using default",
          )
          "0 4 * * *"
        }
      }
    }
    Error(_) -> "0 4 * * *"
  }

  let dreaming_budget_percent = case
    tom.get_int(doc, ["dreaming", "budget_percent"])
  {
    Ok(p) -> int.clamp(p, min: 1, max: 50)
    Error(_) -> 10
  }

  use mcp <- result.try(parse_mcp(doc))

  Ok(GlobalConfig(
    discord: DiscordConfig(
      token: token,
      guild: guild,
      default_channel: default_channel,
    ),
    models: ModelsConfig(
      brain: brain,
      domain: models_domain,
      acp: models_acp,
      heartbeat: heartbeat,
      monitor: monitor,
      vision: vision_model,
      dream: dream_model,
    ),
    notifications: NotificationsConfig(
      digest_windows: extract_toml_strings(digest_windows_raw),
      timezone: timezone,
      urgent_bypass: urgent_bypass,
    ),
    vision: VisionConfig(prompt: vision_prompt),
    memory: MemoryConfig(
      review_interval: review_interval,
      notify_on_review: notify_on_review,
      skill_review_interval: skill_review_interval,
    ),
    acp_global_max_concurrent: global_max_concurrent,
    acp_server_url: acp_server_url,
    acp_agent_name: acp_agent_name,
    acp_transport: acp_transport,
    acp_command: acp_command,
    brain_context: brain_context,
    dreaming_cron: dreaming_cron,
    dreaming_budget_percent: dreaming_budget_percent,
    mcp: mcp,
  ))
}

/// Parse the `[mcp.servers.*]` section. Missing section is valid and yields
/// an empty server list.
fn parse_mcp(doc: dict.Dict(String, tom.Toml)) -> Result(McpConfig, String) {
  case tom.get_table(doc, ["mcp", "servers"]) {
    Error(_) -> Ok(McpConfig(servers: []))
    Ok(servers_table) -> {
      let entries = dict.to_list(servers_table)
      use servers <- result.try(
        list.try_map(entries, fn(entry) {
          let #(name, value) = entry
          case value {
            tom.Table(fields) -> parse_mcp_server(name, fields)
            tom.InlineTable(fields) -> parse_mcp_server(name, fields)
            _ ->
              Error(
                "[mcp.servers." <> name <> "] expected table, got non-table",
              )
          }
        }),
      )
      Ok(McpConfig(servers: servers))
    }
  }
}

fn parse_mcp_server(
  name: String,
  fields: dict.Dict(String, tom.Toml),
) -> Result(McpServerConfig, String) {
  let prefix = "[mcp.servers." <> name <> "]"

  use transport <- result.try(parse_mcp_transport(prefix, fields))

  use command_raw <- result.try(case tom.get_string(fields, ["command"]) {
    Ok(c) -> Ok(c)
    Error(_) -> Error(prefix <> " missing command")
  })
  use command <- result.try(expand_env(command_raw, prefix <> " command"))
  use _ <- result.try(case command {
    "" -> Error(prefix <> " missing command")
    _ -> Ok(Nil)
  })
  use args <- result.try(parse_mcp_string_list(
    fields,
    "args",
    prefix <> " args",
    allow_missing: True,
  ))
  use env_list <- result.try(parse_mcp_env(fields, prefix))
  use subscribe <- result.try(parse_mcp_string_list(
    fields,
    "subscribe",
    prefix <> " subscribe",
    allow_missing: False,
  ))
  case subscribe {
    [] -> Error(prefix <> " subscribe must be a non-empty list")
    _ ->
      Ok(McpServerConfig(
        name: name,
        transport: transport,
        command: command,
        args: args,
        env: env_list,
        subscribe: subscribe,
      ))
  }
}

fn parse_mcp_transport(
  prefix: String,
  fields: dict.Dict(String, tom.Toml),
) -> Result(McpTransport, String) {
  case tom.get_string(fields, ["transport"]) {
    Error(_) -> Ok(StdioTransport)
    Ok("stdio") -> Ok(StdioTransport)
    Ok(other) ->
      Error(
        prefix
        <> " unsupported transport: "
        <> other
        <> " (phase 1 supports only stdio)",
      )
  }
}

fn parse_mcp_string_list(
  fields: dict.Dict(String, tom.Toml),
  key: String,
  context: String,
  allow_missing allow_missing: Bool,
) -> Result(List(String), String) {
  case tom.get_array(fields, [key]) {
    Error(_) ->
      case allow_missing {
        True -> Ok([])
        False -> Error(context <> " must be a non-empty list")
      }
    Ok(values) -> {
      list.try_map(values, fn(v) {
        case v {
          tom.String(s) -> expand_env(s, context)
          _ -> Error(context <> " entries must be strings")
        }
      })
    }
  }
}

fn parse_mcp_env(
  fields: dict.Dict(String, tom.Toml),
  prefix: String,
) -> Result(List(#(String, String)), String) {
  case tom.get_table(fields, ["env"]) {
    Error(_) -> Ok([])
    Ok(env_table) -> {
      list.try_map(dict.to_list(env_table), fn(entry) {
        let #(key, value) = entry
        case value {
          tom.String(s) -> {
            use expanded <- result.try(expand_env(
              s,
              prefix <> " env." <> key,
            ))
            Ok(#(key, expanded))
          }
          _ -> Error(prefix <> " env." <> key <> " must be a string")
        }
      })
    }
  }
}

/// Expand a single `${VAR}` reference. Non-matching values pass through
/// unchanged. A missing env var substitutes empty string and logs a
/// warning so startup isn't blocked by a typo.
fn expand_env(value: String, context: String) -> Result(String, String) {
  case string.starts_with(value, "${") && string.ends_with(value, "}") {
    False -> Ok(value)
    True -> {
      let var_name =
        value
        |> string.drop_start(2)
        |> string.drop_end(1)
      case env.get_env(var_name) {
        Ok(v) -> Ok(v)
        Error(_) -> {
          logging.log(
            logging.Warning,
            "[config] "
              <> context
              <> ": env var "
              <> var_name
              <> " not set, using empty string",
          )
          Ok("")
        }
      }
    }
  }
}

/// Parse a TOML string into a `DomainConfig`. Optional fields
/// Optional fields (`model.domain`, `acp.timeout`,
/// `acp.max_concurrent`) fall back to sensible defaults when absent.
pub fn parse_domain(toml_string: String) -> Result(DomainConfig, String) {
  use doc <- result.try(
    tom.parse(toml_string)
    |> result.map_error(fn(e) { "TOML parse error: " <> format_parse_error(e) }),
  )

  use name <- result.try(
    tom.get_string(doc, ["name"])
    |> result.map_error(fn(_) { "Missing name" }),
  )
  use description <- result.try(
    tom.get_string(doc, ["description"])
    |> result.map_error(fn(_) { "Missing description" }),
  )
  use cwd <- result.try(
    tom.get_string(doc, ["cwd"])
    |> result.map_error(fn(_) { "Missing cwd" }),
  )
  use tools_raw <- result.try(
    tom.get_array(doc, ["tools"])
    |> result.map_error(fn(_) { "Missing tools" }),
  )

  use discord_channel <- result.try(
    tom.get_string(doc, ["discord", "channel"])
    |> result.map_error(fn(_) { "Missing discord.channel" }),
  )

  let model_domain =
    tom.get_string(doc, ["model", "domain"])
    |> result.try_recover(fn(_) { tom.get_string(doc, ["model", "workstream"]) })
    |> result.unwrap("")

  let acp_timeout =
    tom.get_int(doc, ["acp", "timeout"])
    |> result.unwrap(1800)

  let acp_max_concurrent =
    tom.get_int(doc, ["acp", "max_concurrent"])
    |> result.unwrap(2)

  let vision_model =
    tom.get_string(doc, ["models", "vision"])
    |> result.unwrap("")

  let vision_prompt =
    tom.get_string(doc, ["vision", "prompt"])
    |> result.unwrap("")

  let acp_provider =
    tom.get_string(doc, ["acp", "provider"])
    |> result.unwrap("claude-code")

  let acp_binary =
    tom.get_string(doc, ["acp", "binary"])
    |> result.unwrap("")

  let acp_worktree =
    tom.get_bool(doc, ["acp", "worktree"])
    |> result.unwrap(True)

  let acp_server_url =
    tom.get_string(doc, ["acp", "server_url"])
    |> result.unwrap("")

  let acp_agent_name =
    tom.get_string(doc, ["acp", "agent_name"])
    |> result.unwrap("")

  Ok(DomainConfig(
    name: name,
    description: description,
    cwd: cwd,
    tools: extract_toml_strings(tools_raw),
    discord_channel: discord_channel,
    model_domain: model_domain,
    acp_timeout: acp_timeout,
    acp_max_concurrent: acp_max_concurrent,
    vision_model: vision_model,
    vision_prompt: vision_prompt,
    acp_provider: acp_provider,
    acp_binary: acp_binary,
    acp_worktree: acp_worktree,
    acp_server_url: acp_server_url,
    acp_agent_name: acp_agent_name,
  ))
}

pub fn format_parse_error(e: tom.ParseError) -> String {
  case e {
    tom.Unexpected(got, expected) ->
      "unexpected " <> got <> ", expected " <> expected
    tom.KeyAlreadyInUse(key) -> "key already in use: " <> string.join(key, ".")
  }
}
