import aura/cmd
import aura/time
import gleam/erlang/process
import gleam/int
import gleam/string

pub type Command {
  Command(program: String, args: List(String))
}

// --- Pure functions ---

pub fn build_session_name(domain: String, task_id: String) -> String {
  "acp-" <> domain <> "-" <> task_id
}

pub fn build_create_command(
  session_name: String,
  shell_command: String,
) -> Command {
  Command(
    program: "tmux",
    args: ["new-session", "-d", "-s", session_name, "--", "sh", "-c", shell_command],
  )
}

pub fn build_capture_command(session_name: String) -> Command {
  Command(program: "tmux", args: ["capture-pane", "-p", "-t", session_name])
}

pub fn build_kill_command(session_name: String) -> Command {
  Command(program: "tmux", args: ["kill-session", "-t", session_name])
}

pub fn build_has_session_command(session_name: String) -> Command {
  Command(program: "tmux", args: ["has-session", "-t", session_name])
}

pub fn build_claude_command(prompt: String, cwd: String) -> String {
  "cd " <> cwd <> " && claude --dangerously-skip-permissions '" <> shell_quote_inner(prompt) <> "'"
}

fn shell_quote_inner(s: String) -> String {
  string.replace(s, "'", "'\\''")
}

// --- Effectful functions ---

pub fn run(command: Command) -> Result(String, String) {
  case cmd.run(command.program, command.args, 10_000) {
    Error(reason) -> Error(reason)
    Ok(#(0, stdout, _stderr)) -> Ok(stdout)
    Ok(#(code, _stdout, stderr)) ->
      Error("exit " <> int.to_string(code) <> ": " <> stderr)
  }
}

pub fn session_exists(session_name: String) -> Bool {
  let cmd = build_has_session_command(session_name)
  case cmd.run(cmd.program, cmd.args, 10_000) {
    Ok(#(0, _, _)) -> True
    _ -> False
  }
}

pub fn create_session(
  session_name: String,
  shell_command: String,
) -> Result(Nil, String) {
  let cmd = build_create_command(session_name, shell_command)
  case run(cmd) {
    Ok(_) -> Ok(Nil)
    Error(reason) -> Error(reason)
  }
}

pub fn capture_pane(session_name: String) -> Result(String, String) {
  let cmd = build_capture_command(session_name)
  run(cmd)
}

/// Ensure a directory is trusted by Claude Code.
/// Launches claude, sends Enter to accept the trust prompt, waits, kills session.
pub fn ensure_trusted(cwd: String) -> Result(Nil, String) {
  let session_name = "aura-trust-" <> int.to_string(time.now_ms())
  let shell_command = "cd " <> cwd <> " && claude --dangerously-skip-permissions 'echo trusted'"
  case create_session(session_name, shell_command) {
    Error(e) -> Error("Failed to create trust session: " <> e)
    Ok(Nil) -> {
      // Wait for trust prompt to appear
      process.sleep(3000)
      // Send Enter to accept
      send_keys(session_name, "Enter")
      // Wait for claude to start and respond
      process.sleep(5000)
      // Kill the session
      let _ = kill_session(session_name)
      Ok(Nil)
    }
  }
}

fn send_keys(session_name: String, keys: String) -> Nil {
  let _ = cmd.run("tmux", ["send-keys", "-t", session_name, keys], 5000)
  Nil
}

pub fn kill_session(session_name: String) -> Result(Nil, String) {
  let cmd = build_kill_command(session_name)
  case run(cmd) {
    Ok(_) -> Ok(Nil)
    Error(reason) -> Error(reason)
  }
}
