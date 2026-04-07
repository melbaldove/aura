import aura/acp/provider
import gleam/string
import gleeunit/should

pub fn claude_code_with_worktree_test() {
  let cmd =
    provider.build_command(
      provider.ClaudeCode,
      "fix the bug",
      "/home/user/repo",
      "acp-hy-t123",
      True,
    )
  cmd
  |> string.contains("claude --dangerously-skip-permissions")
  |> should.be_true
  cmd |> string.contains("--worktree acp-hy-t123") |> should.be_true
  cmd |> string.contains("cd /home/user/repo") |> should.be_true
}

pub fn claude_code_without_worktree_test() {
  let cmd =
    provider.build_command(
      provider.ClaudeCode,
      "fix the bug",
      "/home/user/repo",
      "acp-hy-t123",
      False,
    )
  cmd |> string.contains("--worktree") |> should.be_false
  cmd
  |> string.contains("claude --dangerously-skip-permissions")
  |> should.be_true
}

pub fn generic_provider_test() {
  let cmd =
    provider.build_command(
      provider.Generic("codex"),
      "fix the bug",
      "/home/user/repo",
      "acp-hy-t123",
      False,
    )
  cmd |> string.contains("codex") |> should.be_true
  cmd |> string.contains("cd /home/user/repo") |> should.be_true
  cmd |> string.contains("--worktree") |> should.be_false
}

pub fn shell_quoting_test() {
  let cmd =
    provider.build_command(
      provider.ClaudeCode,
      "it's broken",
      "/home/user/repo",
      "acp-hy-t123",
      False,
    )
  cmd |> string.contains("'\\''") |> should.be_true
}

pub fn parse_provider_claude_code_test() {
  provider.parse_provider("claude-code", "")
  |> should.equal(provider.ClaudeCode)
}

pub fn parse_provider_generic_test() {
  provider.parse_provider("generic", "codex")
  |> should.equal(provider.Generic("codex"))
}

pub fn parse_provider_default_test() {
  provider.parse_provider("", "")
  |> should.equal(provider.ClaudeCode)
}
