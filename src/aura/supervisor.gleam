import aura/brain
import aura/config
import aura/memory
import aura/poller
import aura/skill
import aura/workstream_sup
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
  workspace_base: String,
) -> Result(process.Pid, String) {
  // 1. Load SOUL.md
  let soul = case memory.read_file(workspace_base <> "/SOUL.md") {
    Ok(content) -> content
    Error(_) -> "You are Aura, a helpful AI assistant."
  }

  // 2. Discover skills
  let all_skills = case skill.discover(workspace_base) {
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
    workstream_sup.start_all(workspace_base, global_config, soul, all_skills),
  )
  let brain_workstreams = workstream_sup.to_brain_info(registry)
  let brain_actors = list.map(registry.entries, fn(e) {
    brain.WorkstreamActor(
      name: e.name,
      channel_id: e.channel_id,
      subject: e.subject,
    )
  })
  io.println(
    "[supervisor] Workstreams: "
    <> string.join(list.map(brain_workstreams, fn(ws) { ws.name }), ", "),
  )

  // 4. Start brain with registry
  use brain_subject <- result.try(
    brain.start(global_config, workspace_base, brain_workstreams, brain_actors),
  )
  io.println("[supervisor] Brain started")

  // 5. Start poller
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

  // 6. Start OTP supervisor
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
