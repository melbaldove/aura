// src/aura/browser.gleam
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/regexp
import gleam/string
import gleam/uri

pub type Action {
  Navigate
  Snapshot
  Click
  Type
  Press
  Back
  Vision
}

/// Resolve the agent-browser session name from an optional LLM-provided
/// name and the current channel_id. Returns Error if neither is available.
pub fn resolve_session(
  session_arg: String,
  channel_id: String,
) -> Result(String, String) {
  case session_arg, channel_id {
    "", "" ->
      Error(
        "session arg required when no channel_id is available "
        <> "(e.g. scheduled tasks, dreaming)",
      )
    "", ch -> Ok("aura-ch-" <> ch)
    name, _ -> Ok("aura-named-" <> name)
  }
}

const truncate_footer_reserve = 80

/// Structure-aware head-truncation for snapshots. Cuts at line boundaries
/// so accessibility tree elements are never split mid-line. Returns the
/// original text unchanged when under the threshold.
pub fn truncate_snapshot(text: String, max_chars: Int) -> String {
  case string.length(text) <= max_chars {
    True -> text
    False -> {
      let lines = string.split(text, "\n")
      let #(kept, remaining) =
        take_lines_under(lines, max_chars - truncate_footer_reserve, 0, [])
      let kept_text = string.join(list.reverse(kept), "\n")
      case remaining {
        0 -> kept_text
        n ->
          kept_text
          <> "\n[... "
          <> int.to_string(n)
          <> " more lines truncated, use browser_snapshot with full=true for full content]"
      }
    }
  }
}

/// Detect login-wall redirects by examining the final URL and page title.
/// Returns True when the navigation landed on a login/auth page.
pub fn detect_auth_required(url: String, title: String) -> Bool {
  let url_lower = string.lowercase(url)
  let title_lower = string.lowercase(title)
  let url_patterns = [
    "/signin", "/login", "/auth/", "/oauth/", "signin-oidc", "/sign-in",
    "/log-in",
  ]
  let title_patterns = ["sign in", "log in", "login", "signin"]
  list.any(url_patterns, fn(p) { string.contains(url_lower, p) })
  || list.any(title_patterns, fn(p) { string.contains(title_lower, p) })
}

fn take_lines_under(
  lines: List(String),
  budget: Int,
  used: Int,
  acc: List(String),
) -> #(List(String), Int) {
  case lines {
    [] -> #(acc, 0)
    [line, ..rest] -> {
      // +1 accounts for the newline we rejoin with
      let cost = string.length(line) + 1
      case used + cost > budget, acc {
        // Always include at least one line so the result is never empty
        True, [] -> take_lines_under(rest, budget, used + cost, [line])
        True, _ -> #(acc, list.length(lines))
        False, _ -> take_lines_under(rest, budget, used + cost, [line, ..acc])
      }
    }
  }
}

/// Return True if the URL is safe to navigate to — False if it targets
/// a private/internal IP, localhost, link-local, or cloud metadata endpoint.
pub fn is_safe_url(url: String) -> Bool {
  case uri.parse(url) {
    Error(_) -> False
    Ok(parsed) -> {
      case parsed.host {
        None -> False
        Some(host) -> host_is_safe(string.lowercase(host))
      }
    }
  }
}

fn host_is_safe(host: String) -> Bool {
  !is_private_host(host)
}

fn is_private_host(host: String) -> Bool {
  case host {
    "localhost" -> True
    "[::1]" -> True
    "::1" -> True
    "metadata.google.internal" -> True
    _ ->
      string.ends_with(host, ".local")
      || is_private_ipv4(host)
  }
}

fn is_private_ipv4(host: String) -> Bool {
  case string.split(host, ".") {
    [a, b, _, _] -> {
      let a_i = parse_octet(a)
      let b_i = parse_octet(b)
      case a_i, b_i {
        Ok(10), _ -> True
        Ok(127), _ -> True
        Ok(192), Ok(168) -> True
        Ok(172), Ok(n) if n >= 16 && n <= 31 -> True
        Ok(169), Ok(254) -> True
        _, _ -> False
      }
    }
    _ -> False
  }
}

fn parse_octet(s: String) -> Result(Int, Nil) {
  int.parse(s)
}

const secret_pattern = "(sk-ant-|sk-proj-|sk-[a-zA-Z0-9]{20,}|ghp_|ghu_|gho_|github_pat_|AKIA[0-9A-Z]{16})"

/// Parse the LLM's `action` string into the Action type.
pub fn parse_action(s: String) -> Result(Action, String) {
  case s {
    "navigate" -> Ok(Navigate)
    "snapshot" -> Ok(Snapshot)
    "click" -> Ok(Click)
    "type" -> Ok(Type)
    "press" -> Ok(Press)
    "back" -> Ok(Back)
    "vision" -> Ok(Vision)
    "" -> Error("action is required")
    other -> Error("unknown action: " <> other)
  }
}

/// Injection point for the FFI call. Tests pass a fake `run_fn`;
/// production uses `run_ffi` defined below.
pub type ExecContext {
  ExecContext(
    session: String,
    cdp_url: String,
    timeout_ms: Int,
    run_fn: fn(String, String, String, List(String), Int) ->
      Result(String, String),
  )
}

/// Dispatch an action: validate args, run safety checks, invoke the FFI,
/// return a JSON string suitable for tool output.
pub fn execute(
  action: Action,
  args: List(#(String, String)),
  ctx: ExecContext,
) -> String {
  case action {
    Navigate -> dispatch_navigate(args, ctx)
    Snapshot -> dispatch_simple("snapshot", snapshot_args(args), ctx)
    Click -> dispatch_simple("click", ref_args(args), ctx)
    Type -> dispatch_simple("type", type_args(args), ctx)
    Press -> dispatch_simple("press", key_args(args), ctx)
    Back -> dispatch_simple("back", [], ctx)
    Vision -> dispatch_simple("screenshot", [], ctx)
    // Vision returns a screenshot; the caller (brain_tools) runs it
    // through the vision pipeline.
  }
}

fn dispatch_navigate(
  args: List(#(String, String)),
  ctx: ExecContext,
) -> String {
  case get_arg(args, "url") {
    "" -> error_json("url is required for navigate")
    url -> {
      case url_has_secret(url) {
        True ->
          error_json(
            "Blocked: URL contains what appears to be an API key or token",
          )
        False ->
          case is_safe_url(url) {
            False ->
              error_json("Blocked: URL targets a private or internal address")
            True -> call_ffi("open", [url], ctx)
          }
      }
    }
  }
}

fn dispatch_simple(
  action_name: String,
  args: List(String),
  ctx: ExecContext,
) -> String {
  call_ffi(action_name, args, ctx)
}

fn call_ffi(
  action_name: String,
  args: List(String),
  ctx: ExecContext,
) -> String {
  case ctx.run_fn(ctx.session, ctx.cdp_url, action_name, args, ctx.timeout_ms) {
    Ok(output) -> output
    Error(reason) -> error_json("agent-browser failed: " <> reason)
  }
}

fn get_arg(args: List(#(String, String)), key: String) -> String {
  case list.find(args, fn(p) { p.0 == key }) {
    Ok(#(_, v)) -> v
    Error(_) -> ""
  }
}

fn snapshot_args(args: List(#(String, String))) -> List(String) {
  case get_arg(args, "full") {
    "true" -> []
    // agent-browser's `snapshot -c` is the compact default
    _ -> ["-c"]
  }
}

fn ref_args(args: List(#(String, String))) -> List(String) {
  [get_arg(args, "ref")]
}

fn type_args(args: List(#(String, String))) -> List(String) {
  [get_arg(args, "ref"), get_arg(args, "text")]
}

fn key_args(args: List(#(String, String))) -> List(String) {
  [get_arg(args, "key")]
}

fn error_json(msg: String) -> String {
  "{\"success\": false, \"error\": \"" <> msg <> "\"}"
}

/// Production FFI binding. Use this in `ExecContext.run_fn` in production.
@external(erlang, "aura_browser_ffi", "run")
pub fn run_ffi(
  session: String,
  cdp_url: String,
  action: String,
  args: List(String),
  timeout_ms: Int,
) -> Result(String, String)

/// Detect URLs that likely contain API keys or tokens. Checks both the
/// raw URL and its URL-decoded form to catch percent-encoding tricks.
pub fn url_has_secret(url: String) -> Bool {
  case regexp.from_string(secret_pattern) {
    Error(_) -> False
    Ok(re) -> {
      let decoded = case uri.percent_decode(url) {
        Ok(d) -> d
        Error(_) -> url
      }
      regexp.check(re, url) || regexp.check(re, decoded)
    }
  }
}
