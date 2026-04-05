import aura/acp/tmux
import gleam/list
import gleam/string
import gleeunit/should

pub fn build_session_name_test() {
  tmux.build_session_name("cm2", "cics967")
  |> should.equal("acp-cm2-cics967")
}

pub fn build_create_command_test() {
  let cmd = tmux.build_create_command("acp-cm2-cics967", "claude -p 'fix bug'")
  cmd.program |> should.equal("tmux")
  list.first(cmd.args) |> should.equal(Ok("new-session"))
}

pub fn build_capture_command_test() {
  let cmd = tmux.build_capture_command("acp-cm2-cics967")
  cmd.program |> should.equal("tmux")
  list.first(cmd.args) |> should.equal(Ok("capture-pane"))
}

pub fn build_kill_command_test() {
  let cmd = tmux.build_kill_command("acp-cm2-cics967")
  cmd.program |> should.equal("tmux")
  list.first(cmd.args) |> should.equal(Ok("kill-session"))
}

pub fn build_has_session_command_test() {
  let cmd = tmux.build_has_session_command("acp-cm2-cics967")
  cmd.program |> should.equal("tmux")
  list.first(cmd.args) |> should.equal(Ok("has-session"))
}

pub fn build_claude_command_test() {
  let cmd = tmux.build_claude_command("fix the bug", "~/repos/cm2")
  cmd |> string.contains("cd ~/repos/cm2") |> should.be_true
  cmd |> string.contains("claude -p --dangerously-skip-permissions") |> should.be_true
}

pub fn build_claude_command_escapes_single_quotes_test() {
  let cmd = tmux.build_claude_command("it's broken", "/tmp")
  cmd |> string.contains("'\\''") |> should.be_true
}
