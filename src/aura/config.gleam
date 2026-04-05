import gleam/list
import gleam/result
import gleam/string
import tom

/// Discord connection settings (token, guild ID, and fallback channel ID).
pub type DiscordConfig {
  DiscordConfig(token: String, guild: String, default_channel: String)
}

/// Model IDs used by each agent role (brain, domain, ACP, heartbeat, monitor, vision).
pub type ModelsConfig {
  ModelsConfig(
    brain: String,
    domain: String,
    acp: String,
    heartbeat: String,
    monitor: String,
    vision: String,
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

/// Top-level configuration loaded from the global `config.toml`.
pub type GlobalConfig {
  GlobalConfig(
    discord: DiscordConfig,
    models: ModelsConfig,
    notifications: NotificationsConfig,
    vision: VisionConfig,
    acp_global_max_concurrent: Int,
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
    ),
    notifications: NotificationsConfig(
      digest_windows: [],
      timezone: "",
      urgent_bypass: False,
    ),
    vision: VisionConfig(prompt: ""),
    acp_global_max_concurrent: 0,
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
  // "domain" is the canonical key; fall back to legacy "workstream" for
  // existing config files that have not been updated yet.
  use models_domain <- result.try(
    tom.get_string(doc, ["models", "domain"])
    |> result.try_recover(fn(_) { tom.get_string(doc, ["models", "workstream"]) })
    |> result.map_error(fn(_) { "Missing models.domain (or legacy models.workstream)" }),
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
    ),
    notifications: NotificationsConfig(
      digest_windows: extract_toml_strings(digest_windows_raw),
      timezone: timezone,
      urgent_bypass: urgent_bypass,
    ),
    vision: VisionConfig(prompt: vision_prompt),
    acp_global_max_concurrent: global_max_concurrent,
  ))
}

/// Parse a TOML string into a `DomainConfig`. Optional fields
/// (`model.domain` or legacy `model.workstream`, `acp.timeout`,
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

  // "domain" is the canonical key; fall back to legacy "workstream".
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
  ))
}

pub fn format_parse_error(e: tom.ParseError) -> String {
  case e {
    tom.Unexpected(got, expected) ->
      "unexpected " <> got <> ", expected " <> expected
    tom.KeyAlreadyInUse(key) -> "key already in use: " <> string.join(key, ".")
  }
}
