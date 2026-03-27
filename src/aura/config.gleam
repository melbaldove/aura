import gleam/list
import gleam/result
import gleam/string
import tom

pub type DiscordConfig {
  DiscordConfig(token: String, guild: String, default_channel: String)
}

pub type ModelsConfig {
  ModelsConfig(
    brain: String,
    workstream: String,
    acp: String,
    heartbeat: String,
    monitor: String,
  )
}

pub type NotificationsConfig {
  NotificationsConfig(
    digest_windows: List(String),
    timezone: String,
    urgent_bypass: Bool,
  )
}

pub type GlobalConfig {
  GlobalConfig(
    discord: DiscordConfig,
    models: ModelsConfig,
    notifications: NotificationsConfig,
    acp_global_max_concurrent: Int,
  )
}

pub type WorkstreamConfig {
  WorkstreamConfig(
    name: String,
    description: String,
    cwd: String,
    tools: List(String),
    discord_channel: String,
    model_workstream: String,
    acp_timeout: Int,
    acp_max_concurrent: Int,
  )
}

pub fn default_global() -> GlobalConfig {
  GlobalConfig(
    discord: DiscordConfig(token: "", guild: "", default_channel: ""),
    models: ModelsConfig(
      brain: "",
      workstream: "",
      acp: "",
      heartbeat: "",
      monitor: "",
    ),
    notifications: NotificationsConfig(
      digest_windows: [],
      timezone: "",
      urgent_bypass: False,
    ),
    acp_global_max_concurrent: 0,
  )
}

pub fn default_workstream() -> WorkstreamConfig {
  WorkstreamConfig(
    name: "",
    description: "",
    cwd: "",
    tools: [],
    discord_channel: "",
    model_workstream: "",
    acp_timeout: 0,
    acp_max_concurrent: 0,
  )
}

fn extract_strings(values: List(tom.Toml)) -> List(String) {
  values
  |> list.filter_map(fn(v) {
    case v {
      tom.String(s) -> Ok(s)
      _ -> Error(Nil)
    }
  })
}

pub fn parse_global(toml_string: String) -> Result(GlobalConfig, String) {
  use doc <- result.try(
    tom.parse(toml_string)
    |> result.map_error(fn(e) { "TOML parse error: " <> string_of_parse_error(e) }),
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
  use models_workstream <- result.try(
    tom.get_string(doc, ["models", "workstream"])
    |> result.map_error(fn(_) { "Missing models.workstream" }),
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

  Ok(GlobalConfig(
    discord: DiscordConfig(
      token: token,
      guild: guild,
      default_channel: default_channel,
    ),
    models: ModelsConfig(
      brain: brain,
      workstream: models_workstream,
      acp: models_acp,
      heartbeat: heartbeat,
      monitor: monitor,
    ),
    notifications: NotificationsConfig(
      digest_windows: extract_strings(digest_windows_raw),
      timezone: timezone,
      urgent_bypass: urgent_bypass,
    ),
    acp_global_max_concurrent: global_max_concurrent,
  ))
}

pub fn parse_workstream(toml_string: String) -> Result(WorkstreamConfig, String) {
  use doc <- result.try(
    tom.parse(toml_string)
    |> result.map_error(fn(e) { "TOML parse error: " <> string_of_parse_error(e) }),
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

  use model_workstream <- result.try(
    tom.get_string(doc, ["model", "workstream"])
    |> result.map_error(fn(_) { "Missing model.workstream" }),
  )

  use acp_timeout <- result.try(
    tom.get_int(doc, ["acp", "timeout"])
    |> result.map_error(fn(_) { "Missing acp.timeout" }),
  )
  use acp_max_concurrent <- result.try(
    tom.get_int(doc, ["acp", "max_concurrent"])
    |> result.map_error(fn(_) { "Missing acp.max_concurrent" }),
  )

  Ok(WorkstreamConfig(
    name: name,
    description: description,
    cwd: cwd,
    tools: extract_strings(tools_raw),
    discord_channel: discord_channel,
    model_workstream: model_workstream,
    acp_timeout: acp_timeout,
    acp_max_concurrent: acp_max_concurrent,
  ))
}

fn string_of_parse_error(e: tom.ParseError) -> String {
  case e {
    tom.Unexpected(got, expected) ->
      "unexpected " <> got <> ", expected " <> expected
    tom.KeyAlreadyInUse(key) -> "key already in use: " <> string.join(key, ".")
  }
}
