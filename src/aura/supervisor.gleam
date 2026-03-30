import aura/brain
import aura/config
import aura/heartbeat_sup
import aura/memory
import aura/notification
import aura/poller
import aura/skill
import aura/validator
import aura/workstream_sup
import aura/xdg
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/otp/static_supervisor
import gleam/result
import gleam/string

/// Start the root supervision tree
pub fn start(
  global_config: config.GlobalConfig,
  paths: xdg.Paths,
) -> Result(process.Pid, String) {
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

  // 3. Start workstream actors
  use registry <- result.try(
    workstream_sup.start_all(paths, global_config, soul, all_skills),
  )
  let brain_workstreams =
    list.map(registry.entries, fn(e) {
      brain.WorkstreamInfo(name: e.name, channel_id: e.channel_id)
    })
  io.println(
    "[supervisor] Workstreams: "
    <> string.join(list.map(brain_workstreams, fn(ws) { ws.name }), ", "),
  )

  // 4. Load validation rules
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

  // 5. Start brain with registry
  use brain_subject <- result.try(
    brain.start(
      global_config,
      paths,
      brain_workstreams,
      registry.entries,
      list.map(all_skills, fn(s) { s.name }),
      global_config.acp_global_max_concurrent,
      validation_rules,
      all_skills,
    ),
  )
  io.println("[supervisor] Brain started")

  // 5. Start heartbeat checks
  let on_finding = fn(finding: notification.Finding) {
    process.send(brain_subject, brain.HeartbeatFinding(finding))
  }

  let _started_checks = heartbeat_sup.start_all(
    heartbeat_sup.default_checks(),
    all_skills,
    on_finding,
  )
  io.println("[supervisor] Heartbeat checks started")

  // 6. Start poller with auto-restart
  let discord_config = global_config.discord
  let _poller_pid =
    process.spawn_unlinked(fn() {
      poller_loop(discord_config, brain_subject, 0)
    })
  io.println("[supervisor] Poller started")

  // 7. Start OTP supervisor
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

@external(erlang, "aura_poller_ffi", "wait_for_exit")
fn wait_for_exit() -> Nil
