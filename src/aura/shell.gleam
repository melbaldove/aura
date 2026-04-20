import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/regexp.{type Regexp}
import gleam/string

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// Result of scanning a command for dangerous patterns.
pub type ScanResult {
  Safe
  Flagged(pattern: String, description: String)
}

/// Result of executing a shell command.
pub type ShellResult {
  ShellResult(exit_code: Int, output: String, truncated: Bool)
}

/// Pre-compiled dangerous command patterns. Built once at startup.
pub type CompiledPatterns {
  CompiledPatterns(union: Regexp, patterns: List(#(Regexp, String, String)))
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const max_output_chars = 50_000

// ---------------------------------------------------------------------------
// Pattern definitions
// ---------------------------------------------------------------------------

/// Raw pattern definitions: (regex_string, key, description)
fn dangerous_patterns() -> List(#(String, String, String)) {
  [
    // -- Destructive --
    #("\\brm\\s+(-[^\\s]*\\s+)*/", "rm_root", "Delete in root path"),
    #("\\brm\\s+-[^\\s]*r", "rm_recursive", "Recursive delete"),
    #("\\brm\\s+--recursive\\b", "rm_recursive_long", "Recursive delete"),
    #(
      "\\bchmod\\s+(-[^\\s]*\\s+)*(777|666|o\\+[rwx]*w|a\\+[rwx]*w)\\b",
      "chmod_world_writable",
      "World-writable permissions",
    ),
    #(
      "\\bchown\\s+(-[^\\s]*)?R\\s+root",
      "chown_root",
      "Recursive chown to root",
    ),
    #("\\bmkfs\\b", "mkfs", "Format filesystem"),
    #("\\bdd\\s+.*if=", "dd", "Disk copy"),
    #(">\\s*/dev/sd", "write_block_device", "Write to block device"),
    // -- Data (case-insensitive via inline flag) --
    #(
      "(?i)\\bDROP\\s+(TABLE|DATABASE)\\b",
      "sql_drop",
      "SQL DROP TABLE/DATABASE",
    ),
    #(
      "(?i)\\bDELETE\\s+FROM\\b(?!.*\\bWHERE\\b)",
      "sql_delete_no_where",
      "SQL DELETE without WHERE",
    ),
    #("(?i)\\bTRUNCATE\\s+(TABLE)?\\s*\\w", "sql_truncate", "SQL TRUNCATE"),
    // -- System --
    #(
      "\\bsystemctl\\s+(-[^\\s]+\\s+)*(stop|restart|disable|mask)\\b",
      "systemctl",
      "Stop/restart system service",
    ),
    #("\\bkill\\s+-9\\s+-1\\b", "kill_all", "Kill all processes"),
    #("\\bpkill\\s+-9\\b", "pkill_force", "Force kill processes"),
    #(
      ":\\(\\)\\s*\\{\\s*:\\s*\\|\\s*:\\s*&\\s*\\}\\s*;\\s*:",
      "fork_bomb",
      "Fork bomb",
    ),
    // -- Remote code execution --
    #(
      "\\b(bash|sh|zsh|ksh)\\s+-[^\\s]*c(\\s+|$)",
      "shell_exec",
      "Shell command via -c flag",
    ),
    #(
      "\\b(python[23]?|perl|ruby|node)\\s+-[ec]\\s+",
      "script_exec",
      "Script execution via -e/-c flag",
    ),
    #(
      "\\b(curl|wget)\\b.*\\|\\s*(ba)?sh\\b",
      "pipe_to_shell",
      "Pipe remote content to shell",
    ),
    #(
      "\\b(bash|sh|zsh|ksh)\\s+<\\s*<\\s*\\(\\s*(curl|wget)\\b",
      "process_sub_shell",
      "Execute remote script via process substitution",
    ),
    #(
      "\\b(python[23]?|perl|ruby|node)\\s+<<",
      "heredoc_exec",
      "Script execution via heredoc",
    ),
    // -- File system --
    #(">\\s*/etc/", "overwrite_etc", "Overwrite system config"),
    #("\\btee\\b.*/etc/", "tee_etc", "Write to system config via tee"),
    #("\\bxargs\\s+.*\\brm\\b", "xargs_rm", "xargs with rm"),
    #("\\bfind\\b.*-exec\\s+(/\\S*/)?rm\\b", "find_exec_rm", "find -exec rm"),
    #("\\bfind\\b.*-delete\\b", "find_delete", "find -delete"),
    #(
      "\\bsed\\s+-[^\\s]*i.*\\s/etc/",
      "sed_inplace_etc",
      "In-place edit of system config",
    ),
    #(
      "\\b(cp|mv|install)\\b.*\\s/etc/",
      "cp_to_etc",
      "Copy/move file into /etc/",
    ),
    // -- Git history rewriting --
    #("\\bgit\\s+reset\\s+--hard\\b", "git_reset_hard", "git reset --hard"),
    #("\\bgit\\s+push\\b.*--force\\b", "git_push_force", "git force push"),
    #(
      "\\bgit\\s+push\\b.*\\s-f\\b",
      "git_push_force_short",
      "git force push (short flag)",
    ),
    #("\\bgit\\s+clean\\s+-[^\\s]*f", "git_clean_force", "git clean with force"),
    #(
      "\\bgit\\s+branch\\s+-D\\b",
      "git_branch_force_delete",
      "git branch force delete",
    ),
    // -- Aura self-protection --
    #("\\bkill\\b.*\\b(beam|epmd)\\b", "kill_beam", "Kill BEAM VM"),
    #("\\bpkill\\b.*\\b(beam|epmd)\\b", "pkill_beam", "Kill BEAM VM"),
    #("\\bkillall\\b.*\\b(beam|epmd)\\b", "killall_beam", "Kill BEAM VM"),
    #("\\brm\\b.*aura\\.db", "rm_aura_db", "Delete Aura database"),
    #(
      "\\brm\\b.*\\.config/aura",
      "rm_aura_config",
      "Delete Aura config directory",
    ),
    #(
      "\\brm\\b.*\\.local/share/aura",
      "rm_aura_data",
      "Delete Aura data directory",
    ),
    #(
      "\\brm\\b.*\\.local/state/aura",
      "rm_aura_state",
      "Delete Aura state directory",
    ),
    #(
      "\\blaunchctl\\b.*com\\.aura",
      "launchctl_aura",
      "Modify Aura launchd service",
    ),
    #(
      "\\btmux\\s+kill-ses",
      "tmux_kill_session",
      "Kill tmux session (may have active flares)",
    ),
  ]
}

// ---------------------------------------------------------------------------
// Pattern compilation
// ---------------------------------------------------------------------------

/// Compile all dangerous patterns at startup. Call once, store in BrainState.
pub fn compile_patterns() -> CompiledPatterns {
  let raw = dangerous_patterns()
  let opts = regexp.Options(case_insensitive: False, multi_line: False)

  let compiled =
    list.filter_map(raw, fn(entry) {
      let #(pattern, key, description) = entry
      case regexp.compile(pattern, opts) {
        Ok(re) -> Ok(#(re, key, description))
        Error(_) -> Error(Nil)
      }
    })

  let union_str =
    list.map(raw, fn(entry) { "(?:" <> entry.0 <> ")" })
    |> string.join("|")

  let union = case regexp.compile(union_str, opts) {
    Ok(re) -> re
    // Fallback: if union fails, use first pattern (should never happen)
    Error(_) -> {
      let assert Ok(re) = regexp.from_string("(?!)")
      re
    }
  }

  CompiledPatterns(union: union, patterns: compiled)
}

// ---------------------------------------------------------------------------
// Scanning
// ---------------------------------------------------------------------------

/// Scan a command for dangerous patterns. Returns Safe or Flagged.
pub fn scan(command: String, patterns: CompiledPatterns) -> ScanResult {
  let normalized = normalize(command)

  // Fast path: single regex check against union of all patterns
  case regexp.check(patterns.union, normalized) {
    False -> {
      // No structural pattern match — check content-level threats
      case check_content_threats(normalized) {
        None -> Safe
        Some(#(key, desc)) -> Flagged(pattern: key, description: desc)
      }
    }
    True -> {
      // Union matched — walk individual patterns to attribute which one
      case find_matching_pattern(normalized, patterns.patterns) {
        Some(#(key, desc)) -> Flagged(pattern: key, description: desc)
        None -> Safe
      }
    }
  }
}

fn find_matching_pattern(
  command: String,
  patterns: List(#(Regexp, String, String)),
) -> Option(#(String, String)) {
  case patterns {
    [] -> None
    [#(re, key, desc), ..rest] -> {
      case regexp.check(re, command) {
        True -> Some(#(key, desc))
        False -> find_matching_pattern(command, rest)
      }
    }
  }
}

/// Content-level threat detection (beyond regex patterns).
fn check_content_threats(command: String) -> Option(#(String, String)) {
  case check_homograph(command) {
    Some(desc) -> Some(#("homograph", desc))
    None -> None
  }
}

/// Detect mixed-script characters in URLs (homograph attacks).
/// Flags URLs containing characters from multiple Unicode scripts.
fn check_homograph(command: String) -> Option(String) {
  let has_url =
    string.contains(command, "http://") || string.contains(command, "https://")
  let has_curl_wget =
    string.contains(command, "curl") || string.contains(command, "wget")
  case has_url && has_curl_wget {
    False -> None
    True -> {
      let has_non_ascii =
        string.to_graphemes(command)
        |> list.any(fn(g) { string.byte_size(g) > 1 })
      case has_non_ascii {
        True ->
          Some(
            "Non-ASCII characters in URL command — possible homograph attack",
          )
        False -> None
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Normalization
// ---------------------------------------------------------------------------

/// Normalize a command for security scanning.
/// Strips ANSI escapes, null bytes, and applies NFKC normalization.
pub fn normalize(command: String) -> String {
  normalize_ffi(command)
}

@external(erlang, "aura_shell_ffi", "normalize_command")
fn normalize_ffi(command: String) -> String

// ---------------------------------------------------------------------------
// Execution
// ---------------------------------------------------------------------------

/// Execute a shell command with timeout and cwd.
pub fn execute(
  command: String,
  timeout_ms: Int,
  cwd: String,
) -> Result(ShellResult, String) {
  case run_shell_ffi(command, timeout_ms, cwd) {
    Ok(#(exit_code, raw_output)) -> {
      // Strip ANSI from output
      let clean = normalize_ffi(raw_output)
      let #(output, truncated) = truncate_output(clean, max_output_chars)
      Ok(ShellResult(exit_code: exit_code, output: output, truncated: truncated))
    }
    Error(e) -> Error(e)
  }
}

@external(erlang, "aura_shell_ffi", "run_shell")
fn run_shell_ffi(
  command: String,
  timeout_ms: Int,
  cwd: String,
) -> Result(#(Int, String), String)

// ---------------------------------------------------------------------------
// Output truncation
// ---------------------------------------------------------------------------

/// Truncate output to max_chars, keeping 40% head and 60% tail.
/// Returns (output, was_truncated).
pub fn truncate_output(output: String, max_chars: Int) -> #(String, Bool) {
  let len = string.length(output)
  case len > max_chars {
    False -> #(output, False)
    True -> {
      let head_chars = max_chars * 2 / 5
      let tail_chars = max_chars - head_chars
      let head = string.slice(output, 0, head_chars)
      let tail = string.slice(output, len - tail_chars, tail_chars)
      let notice =
        "\n\n--- [truncated "
        <> int.to_string(len)
        <> " chars to "
        <> int.to_string(max_chars)
        <> "] ---\n\n"
      #(head <> notice <> tail, True)
    }
  }
}
