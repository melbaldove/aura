import aura/cron
import aura/codex_reasoning
import aura/env
import aura/integrations/gmail
import aura/oauth
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import logging
import tom

/// Discord connection settings (token, guild ID, and fallback channel ID).
pub type DiscordConfig {
  DiscordConfig(token: String, guild: String, default_channel: String)
}

/// Blather connection settings. `url` is the API base HTTP URL of the
/// Blather server (e.g. `http://10.0.0.2:18100/api`); `api_key` is a
/// `blather_<hex>` agent key. Both required if the section is present.
pub type BlatherConfig {
  BlatherConfig(url: String, api_key: String)
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
    codex_reasoning_effort: String,
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
  )
}

/// Aggregate of all parsed `[mcp.servers.*]` blocks. Empty if no blocks
/// exist.
pub type McpConfig {
  McpConfig(servers: List(McpServerConfig))
}

/// A single `[[integrations]]` entry, dispatched by its `type` field.
/// Each variant carries the runtime config type from the corresponding
/// integration module so the supervisor can call `<module>.supervised(config, ingest)`
/// without redoing the parse.
pub type IntegrationConfig {
  GmailIntegration(config: gmail.GmailConfig)
}

/// Aggregate of all parsed `[[integrations]]` blocks.
pub type IntegrationsConfig {
  IntegrationsConfig(integrations: List(IntegrationConfig))
}

/// Top-level configuration loaded from the global `config.toml`.
pub type GlobalConfig {
  GlobalConfig(
    discord: DiscordConfig,
    blather: Option(BlatherConfig),
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
    integrations: IntegrationsConfig,
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
    blather_channel: Option(String),
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
    blather: None,
    models: ModelsConfig(
      brain: "",
      domain: "",
      acp: "",
      heartbeat: "",
      monitor: "",
      vision: "",
      dream: "",
      codex_reasoning_effort: codex_reasoning.default_effort,
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
    acp_command: "codex-acp",
    brain_context: 0,
    dreaming_cron: "0 4 * * *",
    dreaming_budget_percent: 10,
    mcp: McpConfig(servers: []),
    integrations: IntegrationsConfig(integrations: []),
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
    blather_channel: None,
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
  use codex_reasoning_effort <- result.try(parse_codex_reasoning_effort(doc))

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
    |> result.unwrap("codex-acp")

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
  use integrations <- result.try(parse_integrations(doc))
  use blather <- result.try(parse_blather(doc))

  Ok(GlobalConfig(
    discord: DiscordConfig(
      token: token,
      guild: guild,
      default_channel: default_channel,
    ),
    blather: blather,
    models: ModelsConfig(
      brain: brain,
      domain: models_domain,
      acp: models_acp,
      heartbeat: heartbeat,
      monitor: monitor,
      vision: vision_model,
      dream: dream_model,
      codex_reasoning_effort: codex_reasoning_effort,
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
    integrations: integrations,
  ))
}

fn parse_codex_reasoning_effort(
  doc: dict.Dict(String, tom.Toml),
) -> Result(String, String) {
  let effort =
    tom.get_string(doc, ["models", "codex_reasoning_effort"])
    |> result.unwrap(codex_reasoning.default_effort)
    |> codex_reasoning.normalize
  case codex_reasoning.is_supported(effort) {
    True -> Ok(effort)
    False ->
      Error(
        "models.codex_reasoning_effort unsupported value: "
        <> effort
        <> ". Expected one of: "
        <> string.join(codex_reasoning.supported_efforts(), ", "),
      )
  }
}

/// Parse the optional `[blather]` section. Returns `None` if the section is
/// absent; returns an error if the section is present but missing either
/// field. Empty-string values are valid TOML but will fail at startup when
/// the transport tries to connect — fail at parse time instead.
fn parse_blather(
  doc: dict.Dict(String, tom.Toml),
) -> Result(Option(BlatherConfig), String) {
  case tom.get_table(doc, ["blather"]) {
    Error(_) -> Ok(None)
    Ok(_) -> {
      use url <- result.try(
        tom.get_string(doc, ["blather", "url"])
        |> result.map_error(fn(_) { "Missing blather.url" }),
      )
      use api_key <- result.try(
        tom.get_string(doc, ["blather", "api_key"])
        |> result.map_error(fn(_) { "Missing blather.api_key" }),
      )
      use expanded_api_key <- result.try(expand_env(api_key, "blather.api_key"))
      case url, expanded_api_key {
        "", _ -> Error("blather.url must not be empty")
        _, "" -> Error("blather.api_key must not be empty")
        _, _ -> Ok(Some(BlatherConfig(url: url, api_key: expanded_api_key)))
      }
    }
  }
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
  Ok(McpServerConfig(
    name: name,
    transport: transport,
    command: command,
    args: args,
    env: env_list,
  ))
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
            use expanded <- result.try(expand_env(s, prefix <> " env." <> key))
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

// ---------------------------------------------------------------------------
// [[integrations]] parsing
// ---------------------------------------------------------------------------

/// Parse the `[[integrations]]` array-of-tables. Missing section is valid
/// and yields an empty list. Each entry is dispatched by its `type` field
/// to a per-integration parser.
fn parse_integrations(
  doc: dict.Dict(String, tom.Toml),
) -> Result(IntegrationsConfig, String) {
  // OAuth app credentials are shared by all Gmail integrations on this
  // machine — one `[oauth.gmail]` section, many per-account blocks. The
  // per-account block can still override via its own `oauth_client_id` /
  // `oauth_client_secret` keys if ever needed, but normally doesn't.
  let gmail_oauth_defaults = parse_gmail_oauth_defaults(doc)
  case tom.get_array(doc, ["integrations"]) {
    Error(_) -> Ok(IntegrationsConfig(integrations: []))
    Ok(entries) -> {
      use integrations <- result.try(
        list.try_map(entries, fn(entry) {
          case entry {
            tom.Table(fields) -> parse_integration(fields, gmail_oauth_defaults)
            tom.InlineTable(fields) ->
              parse_integration(fields, gmail_oauth_defaults)
            _ -> Error("[[integrations]] entry must be a table")
          }
        }),
      )
      Ok(IntegrationsConfig(integrations: integrations))
    }
  }
}

fn parse_gmail_oauth_defaults(
  doc: dict.Dict(String, tom.Toml),
) -> #(String, String) {
  let cid = case tom.get_string(doc, ["oauth", "gmail", "client_id"]) {
    Ok(c) -> c
    Error(_) -> ""
  }
  let secret = case tom.get_string(doc, ["oauth", "gmail", "client_secret"]) {
    Ok(s) -> s
    Error(_) -> ""
  }
  #(cid, secret)
}

fn parse_integration(
  fields: dict.Dict(String, tom.Toml),
  gmail_oauth_defaults: #(String, String),
) -> Result(IntegrationConfig, String) {
  use type_ <- result.try(case tom.get_string(fields, ["type"]) {
    Ok(t) -> Ok(t)
    Error(_) -> Error("[[integrations]] missing type")
  })
  case type_ {
    "gmail" -> parse_gmail_integration(fields, gmail_oauth_defaults)
    other ->
      Error(
        "[[integrations]] unsupported type: "
        <> other
        <> " (phase 1.5 supports only gmail)",
      )
  }
}

fn parse_gmail_integration(
  fields: dict.Dict(String, tom.Toml),
  gmail_oauth_defaults: #(String, String),
) -> Result(IntegrationConfig, String) {
  let prefix = "[[integrations]] type=gmail"
  let #(default_cid, default_secret) = gmail_oauth_defaults

  use name <- result.try(required_string(fields, "name", prefix))
  use user_email <- result.try(required_string(fields, "user_email", prefix))
  use token_path <- result.try(required_string(fields, "token_path", prefix))

  use client_id <- result.try(resolve_oauth_field(
    fields,
    "oauth_client_id",
    default_cid,
    prefix,
  ))
  use client_secret <- result.try(resolve_oauth_field(
    fields,
    "oauth_client_secret",
    default_secret,
    prefix,
  ))
  let token_endpoint = case tom.get_string(fields, ["oauth_token_endpoint"]) {
    Ok(ep) -> ep
    Error(_) -> "https://oauth2.googleapis.com/token"
  }

  Ok(
    GmailIntegration(config: gmail.GmailConfig(
      name: name,
      user_email: user_email,
      oauth: oauth.OAuthConfig(
        client_id: client_id,
        client_secret: client_secret,
        token_endpoint: token_endpoint,
      ),
      token_path: token_path,
    )),
  )
}

/// Resolve an OAuth field: prefer per-integration value (with env-var
/// expansion), fall back to the top-level `[oauth.gmail]` default.
/// Returns Error only when both sources yield an empty string — matching
/// the old "required_string" behavior without the dead-end when env vars
/// aren't set but the user has `[oauth.gmail]` configured.
fn resolve_oauth_field(
  fields: dict.Dict(String, tom.Toml),
  key: String,
  fallback: String,
  prefix: String,
) -> Result(String, String) {
  let from_block = case tom.get_string(fields, [key]) {
    Ok(raw) ->
      case expand_env(raw, prefix <> " " <> key) {
        Ok(v) -> v
        Error(_) -> ""
      }
    Error(_) -> ""
  }
  case from_block, fallback {
    "", "" ->
      Error(
        prefix
        <> ": "
        <> key
        <> " is empty and no [oauth.gmail] fallback is configured",
      )
    "", fb -> Ok(fb)
    v, _ -> Ok(v)
  }
}

fn required_string(
  fields: dict.Dict(String, tom.Toml),
  key: String,
  prefix: String,
) -> Result(String, String) {
  case tom.get_string(fields, [key]) {
    Ok("") -> Error(prefix <> " missing " <> key)
    Ok(s) -> Ok(s)
    Error(_) -> Error(prefix <> " missing " <> key)
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
  use blather_channel <- result.try(parse_domain_blather(doc))

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
    blather_channel: blather_channel,
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

fn parse_domain_blather(
  doc: dict.Dict(String, tom.Toml),
) -> Result(Option(String), String) {
  case tom.get_table(doc, ["blather"]) {
    Error(_) -> Ok(None)
    Ok(_) -> {
      use channel <- result.try(
        tom.get_string(doc, ["blather", "channel"])
        |> result.map_error(fn(_) { "Missing blather.channel" }),
      )
      case channel {
        "" -> Error("blather.channel must not be empty")
        _ -> Ok(Some(channel))
      }
    }
  }
}

pub fn format_parse_error(e: tom.ParseError) -> String {
  case e {
    tom.Unexpected(got, expected) ->
      "unexpected " <> got <> ", expected " <> expected
    tom.KeyAlreadyInUse(key) -> "key already in use: " <> string.join(key, ".")
  }
}
