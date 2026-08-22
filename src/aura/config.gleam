import aura/codex_reasoning
import aura/cron
import aura/env
import gleam/bit_array
import gleam/crypto
import gleam/dict
import gleam/int
import gleam/json
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

/// Compatibility marker for the retired legacy integration section.
///
/// Any configured `[[integrations]]` entry is rejected. REST connectors use
/// disabled-by-default `[[connector_configurations]]` records instead.
pub type IntegrationsConfig {
  IntegrationsConfig
}

/// One disabled-by-default REST connector configuration.
///
/// This record contains opaque references only. It cannot enable a connector.
pub type ConnectorConfiguration {
  ConnectorConfiguration(
    configuration_ref: String,
    connector_id: String,
    oauth_client_ref: String,
    credential_ref: String,
    resource_ref: String,
    oauth_scope: String,
    configuration_hash: String,
  )
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
    connector_configurations: List(ConnectorConfiguration),
  )
}

/// Per-domain configuration loaded from each domain's `config.toml`.
pub type DomainConfig {
  DomainConfig(
    domain_id: String,
    name: String,
    description: String,
    aliases: List(String),
    purpose: String,
    status: String,
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
    integrations: IntegrationsConfig,
    connector_configurations: [],
  )
}

/// Return a `DomainConfig` with all fields set to empty/zero defaults.
pub fn default_domain() -> DomainConfig {
  DomainConfig(
    domain_id: "",
    name: "",
    description: "",
    aliases: [],
    purpose: "",
    status: "active",
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
  use connector_configurations <- result.try(parse_connector_configurations(doc))
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
    connector_configurations: connector_configurations,
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

/// Parse disabled-by-default REST connector configurations.
///
/// These records select opaque references. They do not declare activation.
fn parse_connector_configurations(
  doc: dict.Dict(String, tom.Toml),
) -> Result(List(ConnectorConfiguration), String) {
  case tom.get_array(doc, ["connector_configurations"]) {
    Error(_) -> Ok([])
    Ok(entries) ->
      entries
      |> list.try_map(fn(entry) {
        case entry {
          tom.Table(fields) -> parse_connector_configuration(fields)
          tom.InlineTable(fields) -> parse_connector_configuration(fields)
          _ -> Error("[[connector_configurations]] entry must be a table")
        }
      })
      |> result.try(fn(configurations) {
        case unique_connector_configuration_refs(configurations) {
          True -> Ok(configurations)
          False -> Error("duplicate connector configuration_ref")
        }
      })
  }
}

fn parse_connector_configuration(
  fields: dict.Dict(String, tom.Toml),
) -> Result(ConnectorConfiguration, String) {
  let prefix = "[[connector_configurations]]"
  use _ <- result.try(reject_connector_configuration_secrets(fields, prefix))
  use configuration_ref <- result.try(required_string(
    fields,
    "configuration_ref",
    prefix,
  ))
  use connector_id <- result.try(required_string(fields, "connector_id", prefix))
  use oauth_client_ref <- result.try(required_string(
    fields,
    "oauth_client_ref",
    prefix,
  ))
  use credential_ref <- result.try(required_string(
    fields,
    "credential_ref",
    prefix,
  ))
  use resource_ref <- result.try(required_string(fields, "resource_ref", prefix))
  use oauth_scope <- result.try(required_string(fields, "oauth_scope", prefix))
  use _ <- result.try(require_connector_configuration_reference(
    "configuration_ref",
    "configuration:",
    configuration_ref,
  ))
  use _ <- result.try(require_connector_configuration_reference(
    "oauth_client_ref",
    "oauth-client:",
    oauth_client_ref,
  ))
  use _ <- result.try(require_connector_configuration_reference(
    "credential_ref",
    "credential:",
    credential_ref,
  ))
  use _ <- result.try(require_connector_configuration_reference(
    "resource_ref",
    "resource:",
    resource_ref,
  ))
  use _ <- result.try(validate_read_only_connector_scope(
    connector_id,
    oauth_scope,
  ))
  let configuration_hash =
    connector_configuration_hash(
      configuration_ref,
      connector_id,
      oauth_client_ref,
      credential_ref,
      resource_ref,
      oauth_scope,
    )
  Ok(ConnectorConfiguration(
    configuration_ref:,
    connector_id:,
    oauth_client_ref:,
    credential_ref:,
    resource_ref:,
    oauth_scope:,
    configuration_hash:,
  ))
}

fn reject_connector_configuration_secrets(
  fields: dict.Dict(String, tom.Toml),
  prefix: String,
) -> Result(Nil, String) {
  let forbidden = [
    "enabled",
    "oauth_client_id",
    "oauth_client_secret",
    "access_token",
    "refresh_token",
    "token",
    "discord",
    "discord_channel",
  ]
  case list.find(forbidden, fn(key) { dict.has_key(fields, key) }) {
    Ok(key) -> Error(prefix <> " must not contain " <> key)
    Error(_) -> Ok(Nil)
  }
}

fn require_connector_configuration_reference(
  name: String,
  prefix: String,
  value: String,
) -> Result(Nil, String) {
  case
    string.starts_with(value, prefix)
    && string.length(value) <= 256
    && string.trim(value) == value
    && !string.contains(value, " ")
    && !string.contains(value, "\n")
  {
    True -> Ok(Nil)
    False -> Error("invalid " <> name)
  }
}

fn validate_read_only_connector_scope(
  connector_id: String,
  oauth_scope: String,
) -> Result(Nil, String) {
  case connector_id, oauth_scope {
    "gmail", "https://www.googleapis.com/auth/gmail.readonly" -> Ok(Nil)
    "calendar", "https://www.googleapis.com/auth/calendar.readonly" -> Ok(Nil)
    "gmail", _ -> Error("unsupported connector OAuth scope")
    "calendar", _ -> Error("unsupported connector OAuth scope")
    _, _ -> Error("unsupported connector configuration")
  }
}

fn unique_connector_configuration_refs(
  configurations: List(ConnectorConfiguration),
) -> Bool {
  configurations
  |> list.map(fn(configuration) { configuration.configuration_ref })
  |> list.unique
  |> list.length
  == list.length(configurations)
}

/// Return the stable hash for fields that control one connector client.
pub fn connector_configuration_hash(
  configuration_ref: String,
  connector_id: String,
  oauth_client_ref: String,
  credential_ref: String,
  resource_ref: String,
  oauth_scope: String,
) -> String {
  json.object([
    #("configuration_ref", json.string(configuration_ref)),
    #("connector_id", json.string(connector_id)),
    #("credential_ref", json.string(credential_ref)),
    #("oauth_client_ref", json.string(oauth_client_ref)),
    #("oauth_scope", json.string(oauth_scope)),
    #("resource_ref", json.string(resource_ref)),
  ])
  |> json.to_string
  |> fn(canonical) { crypto.hash(crypto.Sha256, <<canonical:utf8>>) }
  |> bit_array.base16_encode
  |> string.lowercase
}

/// Reject the retired legacy integration section.
fn parse_integrations(
  doc: dict.Dict(String, tom.Toml),
) -> Result(IntegrationsConfig, String) {
  case tom.get_array(doc, ["integrations"]) {
    Error(_) -> Ok(IntegrationsConfig)
    Ok(_) ->
      Error(
        "[[integrations]] is retired; use disabled connector_configurations",
      )
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

/// Parse a TOML string into a `DomainConfig`. Operational domain fields and
/// legacy development and transport fields are independent and optional.
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
  use domain_id <- result.try(optional_domain_string(
    doc,
    ["domain_id"],
    "domain_id",
    "domain:" <> normalize_domain_slug(name),
  ))
  use aliases <- result.try(optional_domain_string_array(
    doc,
    ["aliases"],
    "aliases",
  ))
  use purpose <- result.try(optional_domain_string(
    doc,
    ["purpose"],
    "purpose",
    description,
  ))
  use status_raw <- result.try(optional_domain_string(
    doc,
    ["status"],
    "status",
    "active",
  ))
  use status <- result.try(parse_domain_status(status_raw))
  use cwd <- result.try(optional_domain_string(doc, ["cwd"], "cwd", ""))
  use tools <- result.try(optional_domain_string_array(doc, ["tools"], "tools"))
  use discord_channel <- result.try(optional_domain_string(
    doc,
    ["discord", "channel"],
    "discord.channel",
    "",
  ))
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
    domain_id: domain_id,
    name: name,
    description: description,
    aliases: aliases,
    purpose: purpose,
    status: status,
    cwd: cwd,
    tools: tools,
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

fn optional_domain_string(
  doc: dict.Dict(String, tom.Toml),
  path: List(String),
  label: String,
  default: String,
) -> Result(String, String) {
  case tom.get_string(doc, path) {
    Ok(value) -> Ok(value)
    Error(tom.NotFound(_)) -> Ok(default)
    Error(_) -> Error("Invalid domain field: " <> label <> " must be a string")
  }
}

fn optional_domain_string_array(
  doc: dict.Dict(String, tom.Toml),
  path: List(String),
  label: String,
) -> Result(List(String), String) {
  case tom.get_array(doc, path) {
    Error(tom.NotFound(_)) -> Ok([])
    Error(_) -> Error("Invalid domain field: " <> label <> " must be an array")
    Ok(values) ->
      values
      |> list.try_map(fn(value) {
        case value {
          tom.String(text) -> Ok(text)
          _ ->
            Error("Invalid domain field: " <> label <> " must contain strings")
        }
      })
  }
}

/// Convert a display name or alias to one stable lowercase domain slug.
pub fn normalize_domain_slug(value: String) -> String {
  value
  |> string.trim
  |> string.lowercase
  |> string.to_graphemes
  |> list.fold(#("", False), fn(state, char) {
    let #(output, previous_dash) = state
    case is_domain_slug_char(char) {
      True -> #(output <> char, False)
      False if output == "" || previous_dash -> #(output, previous_dash)
      False -> #(output <> "-", True)
    }
  })
  |> fn(state) { state.0 }
  |> remove_trailing_domain_dash
}

fn remove_trailing_domain_dash(value: String) -> String {
  case string.ends_with(value, "-") {
    True -> string.drop_end(value, 1)
    False -> value
  }
}

fn is_domain_slug_char(char: String) -> Bool {
  list.contains(
    [
      "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o",
      "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z", "0", "1", "2", "3",
      "4", "5", "6", "7", "8", "9",
    ],
    char,
  )
}

fn parse_domain_status(value: String) -> Result(String, String) {
  case value {
    "active" | "paused" | "archived" -> Ok(value)
    _ -> Error("Invalid domain status: " <> value)
  }
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
