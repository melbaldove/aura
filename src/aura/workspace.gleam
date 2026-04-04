import aura/xdg
import gleam/list
import gleam/result
import gleam/string
import simplifile

const soul_md = "# SOUL.md - Who You Are

Define your assistant's personality, tone, and boundaries here.
"

const meta_md = "# META.md - What Goes Where

- SOUL.md: Core identity rules, personality, and behavioral boundaries
- USER.md: User profile, preferences, schedule, cognitive profile
- domains/<name>/config.toml: Per-domain config (cwd, tools, discord channel)
- domains/<name>/logs/: Raw session logs
- domains/<name>/summaries/: Compressed session summaries
- domains/<name>/anchors.jsonl: Persistent context anchors for this domain
- acp/sessions/: Active agent coordination protocol sessions
- acp/completed/: Completed ACP sessions
- events.jsonl: Global event log

Golden rule: If it belongs to one domain, put it in that domain's directory.
"

const user_md = "# USER.md

Describe yourself here. Role, preferences, schedule, cognitive profile.
"

const memory_md = "# MEMORY.md - Long-Term Memory

Cross-domain insights, learned patterns, and things that don't belong to one domain.
"

const config_toml = "[discord]
token = \"\"
guild = \"\"
default_channel = \"\"

[models]
brain = \"claude-opus-4-5\"
domain = \"claude-sonnet-4-5\"
acp = \"claude-sonnet-4-5\"
heartbeat = \"claude-haiku-4-5\"
monitor = \"claude-haiku-4-5\"

[notifications]
digest_windows = [\"09:00\", \"17:00\"]
timezone = \"UTC\"
urgent_bypass = true

[acp]
global_max_concurrent = 4
"

fn domain_config_toml(name: String, description: String, channel: String) -> String {
  "name = \""
  <> name
  <> "\"\ndescription = \""
  <> description
  <> "\"\ncwd = \".\"\ntools = []\n\n[discord]\nchannel = \""
  <> channel
  <> "\"\n"
}

fn write_if_missing(path: String, content: String) -> Result(Nil, String) {
  case simplifile.is_file(path) {
    Ok(True) -> Ok(Nil)
    Ok(False) ->
      simplifile.write(path, content)
      |> result.map_error(fn(e) {
        "Failed to write " <> path <> ": " <> string.inspect(e)
      })
    Error(e) ->
      simplifile.write(path, content)
      |> result.map_error(fn(_) {
        "Failed to write " <> path <> ": " <> string.inspect(e)
      })
  }
}

fn create_dir(path: String) -> Result(Nil, String) {
  simplifile.create_directory_all(path)
  |> result.map_error(fn(e) {
    "Failed to create directory " <> path <> ": " <> string.inspect(e)
  })
}

pub fn scaffold(paths: xdg.Paths) -> Result(Nil, String) {
  // Config directories and files
  use _ <- result.try(create_dir(paths.config))
  use _ <- result.try(create_dir(paths.config <> "/domains"))

  // Data directories and files
  use _ <- result.try(create_dir(paths.data))
  use _ <- result.try(create_dir(paths.data <> "/skills"))
  use _ <- result.try(create_dir(paths.data <> "/acp"))
  use _ <- result.try(create_dir(paths.data <> "/acp/sessions"))
  use _ <- result.try(create_dir(paths.data <> "/acp/completed"))

  // State directories
  use _ <- result.try(create_dir(paths.state))

  // Config files
  use _ <- result.try(write_if_missing(paths.config <> "/SOUL.md", soul_md))
  use _ <- result.try(write_if_missing(paths.config <> "/META.md", meta_md))
  use _ <- result.try(write_if_missing(paths.config <> "/USER.md", user_md))
  use _ <- result.try(write_if_missing(paths.config <> "/config.toml", config_toml))

  // State files
  use _ <- result.try(write_if_missing(paths.state <> "/MEMORY.md", memory_md))

  // Data files
  use _ <- result.try(write_if_missing(paths.data <> "/events.jsonl", ""))

  Ok(Nil)
}

pub fn scaffold_domain(
  paths: xdg.Paths,
  name: String,
  description: String,
  channel: String,
) -> Result(Nil, String) {
  // Config dir for domain
  let domain_config_dir = paths.config <> "/domains/" <> name
  use _ <- result.try(create_dir(domain_config_dir))
  use _ <- result.try(
    write_if_missing(
      domain_config_dir <> "/config.toml",
      domain_config_toml(name, description, channel),
    ),
  )

  // Data dir for domain
  let domain_data_dir = paths.data <> "/domains/" <> name
  use _ <- result.try(create_dir(domain_data_dir))
  use _ <- result.try(create_dir(domain_data_dir <> "/logs"))
  use _ <- result.try(create_dir(domain_data_dir <> "/summaries"))
  use _ <- result.try(write_if_missing(domain_data_dir <> "/anchors.jsonl", ""))

  Ok(Nil)
}

pub fn list_domains(paths: xdg.Paths) -> Result(List(String), String) {
  let domains_dir = paths.config <> "/domains"
  use entries <- result.try(
    simplifile.read_directory(domains_dir)
    |> result.map_error(fn(e) {
      "Failed to read domains directory: " <> string.inspect(e)
    }),
  )
  let dirs =
    list.filter(entries, fn(entry) {
      case simplifile.is_directory(domains_dir <> "/" <> entry) {
        Ok(True) -> True
        _ -> False
      }
    })
  Ok(dirs)
}
