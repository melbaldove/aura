import aura/config
import aura/db
import aura/models
import aura/skill
import aura/workspace
import aura/workstream
import aura/xdg
import gleam/erlang/process
import gleam/io
import gleam/list
import gleam/result
import gleam/string
import simplifile

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

pub type WorkstreamRegistry {
  WorkstreamRegistry(entries: List(WorkstreamEntry))
}

pub type WorkstreamEntry {
  WorkstreamEntry(
    name: String,
    channel_id: String,
    subject: process.Subject(workstream.WorkstreamMessage),
  )
}

// ---------------------------------------------------------------------------
// Public functions
// ---------------------------------------------------------------------------

/// List workstream dirs, load each config, spawn actors, return registry.
pub fn start_all(
  paths: xdg.Paths,
  global_config: config.GlobalConfig,
  soul: String,
  all_skills: List(skill.SkillInfo),
  db_subject: process.Subject(db.DbMessage),
) -> Result(WorkstreamRegistry, String) {
  use names <- result.try(workspace.list_workstreams(paths))

  let entries =
    list.filter_map(names, fn(name) {
      let config_path =
        xdg.workstream_config_path(paths, name)

      case simplifile.read(config_path) {
        Error(e) -> {
          io.println(
            "[workstream_sup] Failed to read config for "
            <> name
            <> ": "
            <> string.inspect(e),
          )
          Error(Nil)
        }
        Ok(toml_content) -> {
          case config.parse_workstream(toml_content) {
            Error(e) -> {
              io.println(
                "[workstream_sup] Failed to parse config for "
                <> name
                <> ": "
                <> e,
              )
              Error(Nil)
            }
            Ok(ws_config) -> {
              // Resolve model spec: use workstream-specific or fall back to global
              let model_spec = case string.is_empty(ws_config.model_workstream) {
                True -> global_config.models.workstream
                False -> ws_config.model_workstream
              }

              case models.build_llm_config(model_spec) {
                Error(e) -> {
                  io.println(
                    "[workstream_sup] Failed to build LLM config for "
                    <> name
                    <> ": "
                    <> e,
                  )
                  Error(Nil)
                }
                Ok(llm_config) -> {
                  case
                    workstream.start(
                      name,
                      ws_config,
                      llm_config,
                      paths.data,
                      soul,
                      all_skills,
                      db_subject,
                    )
                  {
                    Error(e) -> {
                      io.println(
                        "[workstream_sup] Failed to start actor for "
                        <> name
                        <> ": "
                        <> e,
                      )
                      Error(Nil)
                    }
                    Ok(subject) -> {
                      io.println("[workstream_sup] Started workstream: " <> name)
                      Ok(WorkstreamEntry(
                        name: name,
                        channel_id: ws_config.discord_channel,
                        subject: subject,
                      ))
                    }
                  }
                }
              }
            }
          }
        }
      }
    })

  Ok(WorkstreamRegistry(entries: entries))
}

/// Look up a workstream entry by name.
pub fn find_by_name(
  registry: WorkstreamRegistry,
  name: String,
) -> Result(WorkstreamEntry, Nil) {
  list.find(registry.entries, fn(e) { e.name == name })
}

/// Look up a workstream entry by channel ID.
pub fn find_by_channel(
  registry: WorkstreamRegistry,
  channel_id: String,
) -> Result(WorkstreamEntry, Nil) {
  list.find(registry.entries, fn(e) { e.channel_id == channel_id })
}

