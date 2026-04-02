import aura/brain
import aura/config
import aura/db
import aura/db_migration
import aura/discord/rest
import aura/heartbeat_sup
import aura/memory
import aura/notification
import aura/poller
import aura/skill
import aura/validator
import aura/workspace
import aura/xdg
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import simplifile
import gleam/otp/static_supervisor
import gleam/result
import gleam/string

/// Start the root supervision tree
pub fn start(
  global_config: config.GlobalConfig,
  paths: xdg.Paths,
) -> Result(process.Pid, String) {
  // 0. Migrate workstreams/ → domains/ if needed
  migrate_directories(paths)

  // 1. Load SOUL.md
  let soul = case memory.read_file(xdg.soul_path(paths)) {
    Ok(content) -> content
    Error(_) -> "You are Aura, a helpful AI assistant."
  }

  // 2. Discover skills
  let all_skills = case skill.discover(xdg.skills_dir(paths)) {
    Ok(skills) -> skills
    Error(_) -> []
  }
  io.println(
    "[supervisor] Discovered "
    <> int.to_string(list.length(all_skills))
    <> " skills",
  )

  // 3. Start database
  use db_subject <- result.try(
    db.start(xdg.db_path(paths))
    |> result.map_error(fn(e) { "Failed to start database: " <> e })
  )
  io.println("[supervisor] Database started")

  // Migrate JSONL files if they exist
  case db_migration.migrate_jsonl(db_subject, paths.data) {
    Ok(0) -> io.println("[supervisor] No JSONL files to migrate")
    Ok(n) ->
      io.println(
        "[supervisor] Migrated " <> int.to_string(n) <> " messages from JSONL",
      )
    Error(e) -> io.println("[supervisor] JSONL migration error: " <> e)
  }

  // 4. Resolve Discord channel name → ID mapping
  let channel_map = case rest.list_channels(global_config.discord.token, global_config.discord.guild) {
    Ok(channels) -> channels
    Error(e) -> {
      io.println("[supervisor] Failed to list Discord channels: " <> e)
      []
    }
  }

  // 5. Load domain configs (no actors — brain handles all channels directly)
  let brain_domains = case workspace.list_domains(paths) {
    Ok(names) -> {
      list.filter_map(names, fn(name) {
        let config_path = xdg.domain_config_path(paths, name)
        // Ensure AGENTS.md exists for this domain
        let agents_path = xdg.domain_config_dir(paths, name) <> "/AGENTS.md"
        case simplifile.is_file(agents_path) {
          Ok(True) -> Nil
          _ -> {
            let _ = simplifile.write(agents_path, "# " <> name <> "\n\nDomain-specific instructions go here.\n")
            Nil
          }
        }
        case simplifile.read(config_path) {
          Ok(toml_content) -> {
            case config.parse_domain(toml_content) {
              Ok(cfg) -> {
                // Resolve channel name → ID. If the config value is already numeric, use it directly.
                let channel_id = case list.find(channel_map, fn(c) { c.0 == cfg.discord_channel }) {
                  Ok(#(_, id)) -> id
                  Error(_) -> cfg.discord_channel
                }
                Ok(brain.DomainInfo(name: name, channel_id: channel_id))
              }
              Error(e) -> {
                io.println("[supervisor] Failed to parse domain " <> name <> ": " <> e)
                Error(Nil)
              }
            }
          }
          Error(_) -> {
            io.println("[supervisor] Failed to read config for domain " <> name)
            Error(Nil)
          }
        }
      })
    }
    Error(_) -> []
  }
  io.println(
    "[supervisor] Domains: "
    <> string.join(list.map(brain_domains, fn(d) { d.name }), ", "),
  )

  // 5. Load validation rules
  let validation_rules = case memory.read_file(xdg.config_path(paths, "validations.toml")) {
    Ok(content) -> {
      case validator.parse_rules(content) {
        Ok(rules) -> {
          io.println("[supervisor] Loaded " <> int.to_string(list.length(rules)) <> " validation rules")
          rules
        }
        Error(e) -> {
          io.println("[supervisor] Failed to parse validation rules: " <> e)
          []
        }
      }
    }
    Error(_) -> {
      io.println("[supervisor] No validations.toml found, using no validation rules")
      []
    }
  }

  // 6. Start brain
  use brain_subject <- result.try(
    brain.start(brain.BrainConfig(
      global: global_config,
      paths: paths,
      soul: soul,
      domains: brain_domains,
      skill_infos: all_skills,
      validation_rules: validation_rules,
      db_subject: db_subject,
    )),
  )
  io.println("[supervisor] Brain started")

  // 7. Start heartbeat checks
  let on_finding = fn(finding: notification.Finding) {
    process.send(brain_subject, brain.HeartbeatFinding(finding))
  }

  let _started_checks = heartbeat_sup.start_all(
    heartbeat_sup.default_checks(),
    all_skills,
    on_finding,
  )
  io.println("[supervisor] Heartbeat checks started")

  // 8. Start poller with auto-restart
  let discord_config = global_config.discord
  let _poller_pid =
    process.spawn_unlinked(fn() {
      poller_loop(discord_config, brain_subject, 0)
    })
  io.println("[supervisor] Poller started")

  // 9. Start OTP supervisor
  // (poller_loop is defined below)
  let result =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.restart_tolerance(intensity: 3, period: 5)
    |> static_supervisor.start

  case result {
    Ok(started) -> {
      io.println("Aura supervisor started")
      Ok(started.pid)
    }
    Error(e) -> Error("Failed to start supervisor: " <> string.inspect(e))
  }
}

/// Poller loop with auto-restart and backoff.
/// Traps exits so gateway actor crashes are caught instead of propagated.
fn poller_loop(
  discord_config: config.DiscordConfig,
  brain_subject: process.Subject(brain.BrainMessage),
  retry_count: Int,
) -> Nil {
  // Trap exits so linked gateway actor crash doesn't kill us
  process.trap_exits(True)

  io.println("[poller-loop] Starting poller (attempt " <> int.to_string(retry_count + 1) <> ")")
  case poller.start(discord_config, brain_subject) {
    Ok(Nil) -> {
      // Poller connected — wait for the gateway to die
      // (we'll receive an exit message since we're trapping exits)
      io.println("[poller-loop] Gateway connected, monitoring...")
      wait_for_exit()
      io.println("[poller-loop] Gateway exited, restarting in 5s...")
      process.sleep(5000)
      poller_loop(discord_config, brain_subject, 0)
    }
    Error(e) -> {
      let delay = case retry_count {
        0 -> 1000
        1 -> 5000
        2 -> 15000
        _ -> 30000
      }
      io.println("[poller-loop] Poller error: " <> e <> ", retrying in " <> int.to_string(delay) <> "ms")
      process.sleep(delay)
      poller_loop(discord_config, brain_subject, retry_count + 1)
    }
  }
}

fn migrate_directories(paths: xdg.Paths) -> Nil {
  migrate_dir(paths.config <> "/workstreams", paths.config <> "/domains", "config")
  migrate_dir(paths.data <> "/workstreams", paths.data <> "/domains", "data")
}

fn migrate_dir(from: String, to: String, label: String) -> Nil {
  case simplifile.rename(from, to) {
    Ok(_) -> io.println("[supervisor] Migrated " <> label <> "/workstreams → " <> label <> "/domains")
    Error(_) -> Nil
  }
}

@external(erlang, "aura_poller_ffi", "wait_for_exit")
fn wait_for_exit() -> Nil
