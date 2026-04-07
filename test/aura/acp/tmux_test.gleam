import aura/acp/tmux
import gleam/list
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

