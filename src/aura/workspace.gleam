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
- workstreams/<name>/config.toml: Per-workstream config (cwd, tools, discord channel)
- workstreams/<name>/logs/: Raw session logs
- workstreams/<name>/summaries/: Compressed session summaries
- workstreams/<name>/anchors.jsonl: Persistent context anchors for this workstream
- acp/sessions/: Active agent coordination protocol sessions
- acp/completed/: Completed ACP sessions
- events.jsonl: Global event log

Golden rule: If it belongs to one workstream, put it in that workstream's directory.
"

const user_md = "# USER.md

Describe yourself here. Role, preferences, schedule, cognitive profile.
"

const memory_md = "# MEMORY.md - Long-Term Memory

Cross-workstream insights, learned patterns, and things that don't belong to one workstream.
"

const config_toml = "[discord]
token = \"\"
guild = \"\"
default_channel = \"\"

[models]
brain = \"claude-opus-4-5\"
workstream = \"claude-sonnet-4-5\"
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

fn workstream_config_toml(name: String, description: String, channel: String) -> String {
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

pub fn scaffold(base: String) -> Result(Nil, String) {
  use _ <- result.try(create_dir(base))
  use _ <- result.try(create_dir(base <> "/workstreams"))
  use _ <- result.try(create_dir(base <> "/skills"))
  use _ <- result.try(create_dir(base <> "/acp"))
  use _ <- result.try(create_dir(base <> "/acp/sessions"))
  use _ <- result.try(create_dir(base <> "/acp/completed"))
  use _ <- result.try(write_if_missing(base <> "/SOUL.md", soul_md))
  use _ <- result.try(write_if_missing(base <> "/META.md", meta_md))
  use _ <- result.try(write_if_missing(base <> "/USER.md", user_md))
  use _ <- result.try(write_if_missing(base <> "/MEMORY.md", memory_md))
  use _ <- result.try(write_if_missing(base <> "/config.toml", config_toml))
  use _ <- result.try(write_if_missing(base <> "/events.jsonl", ""))
  Ok(Nil)
}

pub fn scaffold_workstream(
  base: String,
  name: String,
  description: String,
  channel: String,
) -> Result(Nil, String) {
  let ws_path = base <> "/workstreams/" <> name
  use _ <- result.try(create_dir(ws_path))
  use _ <- result.try(create_dir(ws_path <> "/logs"))
  use _ <- result.try(create_dir(ws_path <> "/summaries"))
  use _ <- result.try(
    write_if_missing(
      ws_path <> "/config.toml",
      workstream_config_toml(name, description, channel),
    ),
  )
  use _ <- result.try(write_if_missing(ws_path <> "/anchors.jsonl", ""))
  Ok(Nil)
}

pub fn list_workstreams(base: String) -> Result(List(String), String) {
  let ws_dir = base <> "/workstreams"
  use entries <- result.try(
    simplifile.read_directory(ws_dir)
    |> result.map_error(fn(e) {
      "Failed to read workstreams directory: " <> string.inspect(e)
    }),
  )
  let dirs =
    list.filter(entries, fn(entry) {
      case simplifile.is_directory(ws_dir <> "/" <> entry) {
        Ok(True) -> True
        _ -> False
      }
    })
  Ok(dirs)
}
