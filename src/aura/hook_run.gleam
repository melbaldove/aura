//// `aura-hook` wrapper (ADR 038): tails a child process's output lines, tees
//// them to a per-ruleset log, matches them against hook rules, and fires the
//// resulting actions over the Aura ctl socket. IO-heavy; the pure seams
//// (`fires_to_commands`, `decision_file_path`, `is_retryable_ask_error`) are
//// unit-tested.

import aura/backoff
import aura/ctl
import aura/hook_protocol
import aura/hook_rules
import aura/mcp/jsonrpc
import aura/time
import aura/xdg
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import gleam/erlang/process
import logging
import simplifile

/// Whether a fired socket command blocks awaiting a decision.
pub type Blocking {
  Blocking
  NonBlocking
}

@external(erlang, "aura_hook_ffi", "spawn_stream")
fn spawn_stream_ffi(
  command: String,
  subject: process.Subject(Msg),
) -> Result(process.Pid, String)

type Msg {
  HookLine(String)
  HookExit(Int)
}

/// Spawn the child command via /bin/sh -c.
fn spawn_stream(command: String) -> Result(#(process.Pid, process.Subject(Msg)), String) {
  let subject = process.new_subject()
  spawn_stream_ffi(command, subject)
  |> result.map(fn(pid) { #(pid, subject) })
}

/// Convert fired rules into ctl-socket command lines. `FireEvent` becomes a
/// non-blocking `event` command; `FireNotify` a non-blocking `notify`; a
/// `FireAsk` a blocking `ask`. All payloads carry the source `hook`; notify and
/// ask additionally carry the firing rule name for provenance.
pub fn fires_to_commands(
  fires: List(hook_rules.Fire),
) -> List(#(String, Blocking)) {
  list.map(fires, fn(fire) {
    case fire {
      hook_rules.FireEvent(_rule_name, subject, external_id, data) -> #(
        "event " <> event_payload(subject, external_id, data),
        NonBlocking,
      )
      hook_rules.FireNotify(rule_name, target, text, external_id) -> #(
        "notify " <> notify_payload(rule_name, target, text, external_id),
        NonBlocking,
      )
      hook_rules.FireAsk(
        rule_name,
        target,
        text,
        buttons,
        ttl_minutes,
        correlation_id,
      ) -> #(
        "ask " <> ask_payload(rule_name, target, text, buttons, ttl_minutes, correlation_id),
        Blocking,
      )
    }
  })
}

fn event_payload(subject: String, external_id: String, data: String) -> String {
  let data_json =
    json.parse(data, decode.dynamic)
    |> result.map(jsonrpc.dynamic_to_json)
    |> result.unwrap(json.object([]))
  json.object([
    #("source", json.string("hook")),
    #("subject", json.string(subject)),
    #("external_id", json.string(external_id)),
    #("data", data_json),
  ])
  |> json.to_string
}

fn notify_payload(rule: String, target: String, text: String, external_id: String) -> String {
  json.object([
    #("source", json.string("hook")),
    #("rule", json.string(rule)),
    #("target", json.string(target)),
    #("text", json.string(text)),
    #("external_id", json.string(external_id)),
  ])
  |> json.to_string
}

fn ask_payload(
  rule: String,
  target: String,
  text: String,
  buttons: List(String),
  ttl_minutes: Int,
  correlation_id: String,
) -> String {
  json.object([
    #("source", json.string("hook")),
    #("rule", json.string(rule)),
    #("correlation_id", json.string(correlation_id)),
    #("target", json.string(target)),
    #("text", json.string(text)),
    #("buttons", json.array(buttons, json.string)),
    #("ttl_minutes", json.int(ttl_minutes)),
  ])
  |> json.to_string
}

/// Path where a resolved decision is materialized for the waiting process.
pub fn decision_file_path(paths: xdg.Paths, correlation_id: String) -> String {
  xdg.state_path(paths, "hooks/decisions/" <> correlation_id)
}

/// Whether a failed blocking ask should be retried with backoff. Socket-level
/// errors and Aura-not-running are transient; protocol errors, expiry, and a
/// resolved decision are terminal.
pub fn is_retryable_ask_error(response: String) -> Bool {
  string.starts_with(response, "ERROR: Aura is not running")
}

/// Run the child command, tee its output to the ruleset log, match lines, and
/// fire actions. Returns the child's exit code.
pub fn run(
  paths: xdg.Paths,
  rules: hook_rules.Ruleset,
  command: String,
) -> Int {
  let log_path = xdg.state_path(paths, "hooks/" <> rules.name <> ".log")
  let _ = simplifile.create_directory_all(xdg.state_path(paths, "hooks"))
  let _ = simplifile.create_directory_all(xdg.state_path(paths, "hooks/decisions"))

  case spawn_stream(command) {
    Error(err) -> {
      logging.log(logging.Error, "[hook] failed to spawn: " <> err)
      1
    }
    Ok(#(_pid, subject)) -> tail_loop(paths, subject, rules, log_path)
  }
}

fn tail_loop(
  paths: xdg.Paths,
  subject: process.Subject(Msg),
  rules: hook_rules.Ruleset,
  log_path: String,
) -> Int {
  case process.receive(subject, 10_000) {
    Error(_) -> tail_loop(paths, subject, rules, log_path)
    Ok(message) ->
      case message {
        HookLine(line) -> {
          append_log(log_path, line)
          let _ = hook_rules.match_line(rules, line, time.now_ms())
          |> result.map(fn(fires) { fire_all(paths, fires) })
          tail_loop(paths, subject, rules, log_path)
        }
        HookExit(code) -> code
      }
  }
}

fn append_log(log_path: String, line: String) -> Nil {
  case simplifile.append(log_path, line <> "\n") {
    Ok(_) -> Nil
    Error(e) -> logging.log(logging.Error, "[hook] log write failed: " <> string.inspect(e))
  }
}

fn fire_all(
  paths: xdg.Paths,
  fires: List(hook_rules.Fire),
) -> Nil {
  let commands = fires_to_commands(fires)
  list.each(commands, fn(command) {
    let _ = process.spawn_unlinked(fn() { fire_command(paths, command) })
    Nil
  })
}

fn fire_command(
  paths: xdg.Paths,
  command: #(String, Blocking),
) -> Nil {
  let #(line, blocking) = command
  case blocking {
    Blocking -> fire_blocking(paths, line)
    NonBlocking -> fire_non_blocking(paths, line)
  }
}

fn fire_blocking(paths: xdg.Paths, line: String) -> Nil {
  case hook_protocol.parse(line) {
    Ok(hook_protocol.HookAsk(
      ttl_minutes: ttl_minutes,
      correlation_id: correlation_id,
      ..
    )) ->
      ask_with_retry(paths, line, correlation_id, ttl_minutes * 60_000)
    Ok(_) -> fire_non_blocking(paths, line)
    Error(_) -> logging.log(logging.Warning, "[hook] unparseable ask line")
  }
}

fn fire_non_blocking(paths: xdg.Paths, line: String) -> Nil {
  case ctl.send(paths, line) {
    Ok(response) ->
      case string.starts_with(response, "ERROR:") {
        True -> logging.log(logging.Warning, "[hook] " <> response)
        False -> Nil
      }
    Error(err) -> logging.log(logging.Warning, "[hook] " <> err)
  }
}

/// Fire a blocking ask, retrying on transient socket failures until the TTL.
/// On a resolved decision, materialize the choice into the decision file so
/// the waiting process can poll it.
fn ask_with_retry(
  paths: xdg.Paths,
  line: String,
  correlation_id: String,
  ttl_ms: Int,
) -> Nil {
  let deadline = time.now_ms() + ttl_ms
  let attempt = 0
  poll_ask(paths, line, correlation_id, ttl_ms, deadline, attempt)
}

fn poll_ask(
  paths: xdg.Paths,
  line: String,
  correlation_id: String,
  ttl_ms: Int,
  deadline: Int,
  attempt: Int,
) -> Nil {
  case ctl.send_with_timeout(paths, line, ttl_ms + 60_000) {
    Ok(response) ->
      case response {
        "RESOLVED" <> _ -> {
          let choice = string.replace(response, "RESOLVED " <> correlation_id <> " ", "")
          let _ = simplifile.write(decision_file_path(paths, correlation_id), choice)
          Nil
        }
        "EXPIRED" <> _ -> Nil
        other ->
          case is_retryable_ask_error(other) {
            True -> retry_ask(paths, line, correlation_id, ttl_ms, deadline, attempt)
            False -> Nil
          }
      }
    Error(_) -> retry_ask(paths, line, correlation_id, ttl_ms, deadline, attempt)
  }
}

fn retry_ask(
  paths: xdg.Paths,
  line: String,
  correlation_id: String,
  ttl_ms: Int,
  deadline: Int,
  attempt: Int,
) -> Nil {
  let delay = backoff.compute(attempt, base: 5_000, cap: 30_000)
  case time.now_ms() + delay < deadline {
    True -> {
      process.sleep(delay)
      poll_ask(paths, line, correlation_id, ttl_ms, deadline, attempt + 1)
    }
    False -> Nil
  }
}
