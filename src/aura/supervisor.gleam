import gleam/erlang/process
import gleam/io
import gleam/otp/static_supervisor
import gleam/string

/// Start the root supervision tree
/// For Phase 1, this starts empty.
/// Discord poller, brain, workstream_sup, heartbeat_sup, and acp_sup
/// will be added in later phases.
pub fn start() -> Result(process.Pid, String) {
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
