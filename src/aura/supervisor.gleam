import aura/brain
import aura/config
import aura/poller
import gleam/erlang/process
import gleam/io
import gleam/otp/static_supervisor
import gleam/result
import gleam/string

/// Start the root supervision tree
pub fn start(
  global_config: config.GlobalConfig,
  workspace_base: String,
  workstreams: List(brain.WorkstreamInfo),
) -> Result(process.Pid, String) {
  use brain_subject <- result.try(brain.start(global_config, workspace_base, workstreams))

  // Start poller in a linked process (so supervisor crash restarts it)
  let _poller_pid =
    process.spawn(fn() {
      case poller.start(global_config.discord, brain_subject) {
        Ok(Nil) -> {
          // Keep process alive - gateway runs in stratus actor
          process.sleep_forever()
        }
        Error(e) -> {
          io.println("[supervisor] Poller failed: " <> e)
          panic as "poller start failed"
        }
      }
    })

  let result =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.restart_tolerance(intensity: 3, period: 5)
    |> static_supervisor.start

  case result {
    Ok(started) -> {
      io.println("Aura supervisor started")
      Ok(started.pid)
    }
    Error(e) -> {
      Error("Failed to start supervisor: " <> string.inspect(e))
    }
  }
}
