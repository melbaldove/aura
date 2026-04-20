import aura/discord/rest
import aura/vision
import gleam/bit_array
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/uri
import simplifile

pub type Action {
  Navigate
  Snapshot
  Click
  Type
  Press
  Back
  Vision
  Console
  Wait
  Upload
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
    Ok(parsed) ->
      case parsed.host {
        None -> False
        Some(host) -> !is_private_host(string.lowercase(host))
      }
  }
}

fn is_private_host(host: String) -> Bool {
  case host {
    "localhost" -> True
    "[::1]" -> True
    "::1" -> True
    "metadata.google.internal" -> True
    _ -> string.ends_with(host, ".local") || is_private_ipv4(host)
  }
}

fn is_private_ipv4(host: String) -> Bool {
  case string.split(host, ".") {
    [a, b, _, _] ->
      case int.parse(a), int.parse(b) {
        Ok(10), _ -> True
        Ok(127), _ -> True
        Ok(192), Ok(168) -> True
        Ok(172), Ok(n) if n >= 16 && n <= 31 -> True
        Ok(169), Ok(254) -> True
        _, _ -> False
      }
    _ -> False
  }
}

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
    "console" -> Ok(Console)
    "wait" -> Ok(Wait)
    "upload" -> Ok(Upload)
    "" -> Error("action is required")
    other -> Error("unknown action: " <> other)
  }
}

/// Injection point for external calls. Tests pass fakes; production wires
/// `run_fn` to `run_ffi` and `vision_fn` to the brain's vision pipeline.
pub type ExecContext {
  ExecContext(
    session: String,
    cdp_url: String,
    timeout_ms: Int,
    run_fn: fn(String, String, String, List(String), Int) ->
      Result(String, String),
    vision_fn: fn(String, String) -> Result(String, String),
    url_has_secret_fn: fn(String) -> Bool,
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
    Snapshot -> call_ffi("snapshot", snapshot_args(args), ctx)
    Click -> call_ffi("click", [get_arg(args, "ref")], ctx)
    Type -> call_ffi("type", [get_arg(args, "ref"), get_arg(args, "text")], ctx)
    Press -> call_ffi("press", [get_arg(args, "key")], ctx)
    Back -> call_ffi("back", [], ctx)
    Vision -> dispatch_vision(args, ctx)
    Console -> dispatch_console(args, ctx)
    Wait -> dispatch_wait(args, ctx)
    Upload -> dispatch_upload(args, ctx)
  }
}

fn dispatch_navigate(args: List(#(String, String)), ctx: ExecContext) -> String {
  case get_arg(args, "url") {
    "" -> error_json("url is required for navigate")
    url ->
      case ctx.url_has_secret_fn(url), is_safe_url(url) {
        True, _ ->
          error_json(
            "Blocked: URL contains what appears to be an API key or token",
          )
        _, False ->
          error_json("Blocked: URL targets a private or internal address")
        False, True -> {
          let raw = call_ffi("open", [url], ctx)
          intercept_auth_wall(raw)
        }
      }
  }
}

/// If the navigate response lands on a recognizable login/auth page,
/// replace it with an AUTH_REQUIRED signal so the LLM short-circuits.
/// Otherwise return the raw response unchanged.
fn intercept_auth_wall(raw_json: String) -> String {
  let decoder = {
    use url <- decode.optional_field("url", "", decode.string)
    use title <- decode.optional_field("title", "", decode.string)
    decode.success(#(url, title))
  }
  let full_decoder = decode.at(["data"], decoder)
  case json.parse(raw_json, full_decoder) {
    Ok(#(url, title)) ->
      case detect_auth_required(url, title) {
        True ->
          json.to_string(
            json.object([
              #("success", json.bool(False)),
              #("error", json.string("AUTH_REQUIRED")),
              #("needs_auth", json.bool(True)),
              #("url", json.string(url)),
            ]),
          )
        False -> raw_json
      }
    Error(_) -> raw_json
  }
}

fn dispatch_vision(args: List(#(String, String)), ctx: ExecContext) -> String {
  let question = case get_arg(args, "question") {
    "" -> vision.default_vision_prompt
    q -> q
  }
  let raw = call_ffi("screenshot", [], ctx)
  let path_decoder = decode.at(["data", "path"], decode.string)
  case json.parse(raw, path_decoder) {
    Error(_) -> raw
    Ok(path) ->
      case read_as_data_url(path) {
        Error(e) -> error_json("vision screenshot unreadable: " <> e)
        Ok(data_url) ->
          case ctx.vision_fn(data_url, question) {
            Error(e) -> error_json("vision model failed: " <> e)
            Ok(analysis) ->
              json.to_string(
                json.object([
                  #("success", json.bool(True)),
                  #(
                    "data",
                    json.object([
                      #("analysis", json.string(analysis)),
                      #("path", json.string(path)),
                    ]),
                  ),
                ]),
              )
          }
      }
  }
}

fn dispatch_console(args: List(#(String, String)), ctx: ExecContext) -> String {
  case get_arg(args, "expression") {
    "" -> call_ffi("console", [], ctx)
    expr -> call_ffi("eval", [expr], ctx)
  }
}

fn dispatch_upload(args: List(#(String, String)), ctx: ExecContext) -> String {
  case get_arg(args, "selector"), get_arg(args, "path") {
    "", _ -> error_json("upload requires 'selector' (e.g. input[type=file])")
    _, "" -> error_json("upload requires 'path' (absolute file path)")
    selector, path -> call_ffi("upload", [selector, path], ctx)
  }
}

fn dispatch_wait(args: List(#(String, String)), ctx: ExecContext) -> String {
  case get_arg(args, "ref"), get_arg(args, "seconds") {
    "", "" -> error_json("wait requires 'ref' or 'seconds'")
    ref, _ if ref != "" -> call_ffi("wait", [ref], ctx)
    _, seconds_str -> {
      case int.parse(seconds_str) {
        Error(_) -> error_json("seconds must be an integer")
        Ok(seconds) -> call_ffi("wait", [int.to_string(seconds * 1000)], ctx)
      }
    }
  }
}

/// Read a local image file and encode it as a base64 data URL suitable
/// for OpenAI-compatible vision APIs. Unknown extensions default to
/// image/png since screenshots are always PNG.
pub fn read_as_data_url(path: String) -> Result(String, String) {
  case simplifile.read_bits(path) {
    Error(e) ->
      Error("Failed to read " <> path <> ": " <> simplifile.describe_error(e))
    Ok(bytes) -> {
      let mime = case rest.content_type_for_filename(path) {
        "application/octet-stream" -> "image/png"
        m -> m
      }
      let encoded = bit_array.base64_encode(bytes, True)
      Ok("data:" <> mime <> ";base64," <> encoded)
    }
  }
}

fn call_ffi(action_name: String, args: List(String), ctx: ExecContext) -> String {
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
    // agent-browser's `snapshot -c` is the compact default
    "true" -> []
    _ -> ["-c"]
  }
}

fn error_json(msg: String) -> String {
  json.to_string(
    json.object([#("success", json.bool(False)), #("error", json.string(msg))]),
  )
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
/// Regex is compiled once and cached in persistent_term (see FFI).
@external(erlang, "aura_browser_ffi", "url_has_secret")
pub fn url_has_secret(url: String) -> Bool
