import gleam/string

/// ACP session provider — determines what coding agent runs inside tmux.
pub type AcpProvider {
  ClaudeCode
  Generic(binary: String)
}

/// Build the shell command to run inside a tmux session.
pub fn build_command(
  provider: AcpProvider,
  prompt: String,
  cwd: String,
  session_name: String,
  worktree: Bool,
) -> String {
  case provider {
    ClaudeCode -> {
      let worktree_flag = case worktree {
        True -> " --worktree " <> session_name
        False -> ""
      }
      "cd "
      <> cwd
      <> " && claude --dangerously-skip-permissions"
      <> worktree_flag
      <> " '"
      <> shell_quote(prompt)
      <> "'"
    }
    Generic(binary) -> {
      "cd " <> cwd <> " && " <> binary <> " '" <> shell_quote(prompt) <> "'"
    }
  }
}

/// Parse provider from config strings.
pub fn parse_provider(provider_str: String, binary: String) -> AcpProvider {
  case provider_str {
    "generic" -> Generic(binary)
    _ -> ClaudeCode
  }
}

fn shell_quote(s: String) -> String {
  string.replace(s, "'", "'\\''")
}
