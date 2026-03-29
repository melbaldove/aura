import aura/brain
import aura/config
import aura/heartbeat_sup
import aura/memory
import aura/notification
import aura/poller
import aura/skill
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

  // 4. Start brain with registry
  use brain_subject <- result.try(
    brain.start(global_config, paths, brain_workstreams, registry.entries, global_config.acp_global_max_concurrent),
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

  // 6. Start poller
  let _poller_pid =
    process.spawn(fn() {
      case poller.start(global_config.discord, brain_subject) {
        Ok(Nil) -> process.sleep_forever()
        Error(e) -> {
          io.println("[supervisor] Poller failed: " <> e)
          panic as "poller start failed"
        }
      }
    })
  io.println("[supervisor] Poller started")

  // 7. Start OTP supervisor
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
