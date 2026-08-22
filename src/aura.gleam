import aura/codex_monitor_runtime
import aura/config
import aura/config_parser
import aura/ctl
import aura/doctor
import aura/dotenv
import aura/google_oauth_client
import aura/hook_rules
import aura/hook_run
import aura/init
import aura/supervisor
import aura/xdg
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/json
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import logging
import simplifile

pub type CliCommand {
  CliStart
  CliDoctor
  CliCtl(command: String)
  CliHookRun(rules: String, cmd: String)
  CliMonitorRunOnce
  CliMonitorAcknowledge(
    outcome_id: String,
    queue_id: String,
    lease_token: String,
    task_ref: String,
  )
  CliMonitorDefer(
    outcome_id: String,
    queue_id: String,
    lease_token: String,
    defer_until: Int,
    task_ref: String,
  )
  CliInvalid(message: String)
}

/// The process exit code for an unsafe root-supervisor failure.
pub const service_failure_exit_code = 1

pub fn main() {
  case parse_args(get_args()) {
    CliDoctor -> {
      doctor.run()
      halt(0)
    }
    CliCtl(command) -> {
      run_ctl(command)
      halt(0)
    }
    CliHookRun(rules, cmd) -> {
      run_hook(rules, cmd)
      halt(0)
    }
    CliMonitorRunOnce ->
      run_monitor_result(codex_monitor_runtime.run_once(xdg.resolve()))
    CliMonitorAcknowledge(outcome_id, queue_id, lease_token, task_ref) ->
      run_monitor_result(codex_monitor_runtime.acknowledge(
        xdg.resolve(),
        outcome_id,
        queue_id,
        lease_token,
        optional_ref(task_ref),
      ))
    CliMonitorDefer(outcome_id, queue_id, lease_token, defer_until, task_ref) ->
      run_monitor_result(codex_monitor_runtime.defer(
        xdg.resolve(),
        outcome_id,
        queue_id,
        lease_token,
        defer_until,
        optional_ref(task_ref),
      ))
    CliInvalid(message) -> {
      io.println(message)
      halt(1)
    }
    CliStart -> run_start()
  }
}

fn parse_args(args: List(String)) -> CliCommand {
  case drop_leading_dash_dash(args) {
    [] -> CliStart
    ["start"] -> CliStart
    ["doctor"] -> CliDoctor
    ["dream"] -> CliCtl("dream")
    ["status"] -> CliCtl("status")
    ["ping"] -> CliCtl("ping")
    ["cognitive-smoke", "gmail-rel42"] -> CliCtl("cognitive-smoke gmail-rel42")
    ["cognitive-eval", "fixtures"] -> CliCtl("cognitive-eval fixtures")
    ["cognitive-replay", "labels"] -> CliCtl("cognitive-replay labels")
    ["cognitive-replay", "propose-patches"] ->
      CliCtl("cognitive-replay propose-patches")
    ["cognitive-improve", "propose"] -> CliCtl("cognitive-improve propose")
    ["cognitive-test", "deliver-now"] -> CliCtl("cognitive-test deliver-now")
    ["cognitive-digest", "flush"] -> CliCtl("cognitive-digest flush")
    ["cognitive-delivery", "retry-dead-letter"] ->
      CliCtl("cognitive-delivery retry-dead-letter")
    ["cognitive-label", event_id, label] ->
      CliCtl("cognitive-label " <> event_id <> " " <> label)
    ["cognitive-label", event_id, label, expected_attention, ..note_words] ->
      CliCtl(
        "cognitive-label "
        <> event_id
        <> " "
        <> label
        <> " "
        <> expected_attention
        <> case string.join(note_words, " ") {
          "" -> ""
          note -> " " <> note
        },
      )
    ["hook", "run", "--rules", rules, "--", ..cmd] ->
      CliHookRun(rules, string.join(cmd, " "))
    ["event", ..rest] -> CliCtl("event " <> string.join(rest, " "))
    ["evidence", "submit", ..rest] ->
      CliCtl("evidence submit " <> string.join(rest, " "))
    ["tool-result", "submit", ..rest] ->
      CliCtl("tool-result submit " <> string.join(rest, " "))
    ["notify", ..rest] -> CliCtl("notify " <> string.join(rest, " "))
    ["ask", ..rest] -> CliCtl("ask " <> string.join(rest, " "))
    ["mutate", ..rest] -> CliCtl("mutate " <> string.join(rest, " "))
    ["connector-activation", ..rest] ->
      CliCtl("connector-activation " <> string.join(rest, " "))
    ["canary-preparation", ..rest] ->
      CliCtl("canary-preparation " <> string.join(rest, " "))
    ["canary-authorization", ..rest] ->
      CliCtl("canary-authorization " <> string.join(rest, " "))
    ["monitor", "capability", "prepare"] -> CliCtl("monitor capability prepare")
    ["monitor", "run-once"] -> CliMonitorRunOnce
    ["monitor", "acknowledge", outcome_id, queue_id, lease_token] ->
      CliMonitorAcknowledge(outcome_id, queue_id, lease_token, "")
    ["monitor", "acknowledge", outcome_id, queue_id, lease_token, task_ref] ->
      CliMonitorAcknowledge(outcome_id, queue_id, lease_token, task_ref)
    ["monitor", "defer", outcome_id, queue_id, lease_token, defer_until] ->
      parse_monitor_defer(outcome_id, queue_id, lease_token, defer_until, "")
    [
      "monitor",
      "defer",
      outcome_id,
      queue_id,
      lease_token,
      defer_until,
      task_ref,
    ] ->
      parse_monitor_defer(
        outcome_id,
        queue_id,
        lease_token,
        defer_until,
        task_ref,
      )
    ["monitor", "claim", ..rest] ->
      CliCtl("monitor claim " <> string.join(rest, " "))
    ["monitor", "outcome", ..rest] ->
      CliCtl("monitor outcome " <> string.join(rest, " "))
    ["monitor", ..] -> CliInvalid("Invalid monitor command")
    [
      "oauth",
      "google-client",
      "install",
      "--connector",
      connector,
      "--source",
      source,
      "--sha256",
      digest,
    ] ->
      CliCtl(
        "oauth google-client install "
        <> google_oauth_client.encode_install_command(connector, source, digest),
      )
    [
      "oauth",
      "google-client-set",
      "create",
      "--gmail",
      gmail_ref,
      "--calendar",
      calendar_ref,
    ] ->
      CliCtl(
        "oauth google-client-set create "
        <> google_oauth_client.encode_client_set_command(
          gmail_ref,
          calendar_ref,
        ),
      )
    [
      "oauth",
      "start",
      "--connector",
      connector,
      "--preparation",
      preparation,
      "--configuration",
      configuration,
      "--client",
      client,
    ]
      if connector == "gmail" || connector == "calendar"
    ->
      CliCtl(
        "oauth start "
        <> connector
        <> " "
        <> preparation
        <> " "
        <> configuration
        <> " "
        <> client,
      )
    ["oauth", "status", "--session", session] ->
      CliCtl("oauth status " <> session)
    ["oauth", "start", ..] | ["oauth", "status", ..] ->
      CliInvalid("Invalid Google OAuth command")
    ["oauth", "google-client", ..] ->
      CliInvalid("Invalid Google OAuth client command")
    ["oauth", "google-client-set", ..] ->
      CliInvalid("Invalid Google OAuth client-set command")
    [
      "connector-read",
      "run-once",
      "--authorization",
      authorization,
      "--connector",
      connector,
    ]
      if connector == "gmail" || connector == "calendar"
    -> CliCtl("connector-read run-once " <> authorization <> " " <> connector)
    ["connector-read", ..] -> CliInvalid("Invalid connector read command")
    ["domain-migrate", slug, idempotency_key] ->
      CliCtl("domain-migrate " <> slug <> " " <> idempotency_key)
    ["concern-migrate", concern_slug, domain_slug, idempotency_key] ->
      CliCtl(
        "concern-migrate "
        <> concern_slug
        <> " "
        <> domain_slug
        <> " "
        <> idempotency_key,
      )
    ["decision", ..rest] -> CliCtl("decision " <> string.join(rest, " "))
    ["asks"] -> CliCtl("asks")
    ["hooks"] -> CliCtl("hooks")
    ["oauth", "gmail", ..] ->
      CliInvalid(
        "The legacy Gmail OAuth command is retired. Gmail REST authorization is disabled until an approved read-only activation is available.",
      )
    _ -> CliStart
  }
}

fn drop_leading_dash_dash(args: List(String)) -> List(String) {
  case args {
    ["--", ..rest] -> rest
    _ -> args
  }
}

pub fn parse_args_for_test(args: List(String)) -> CliCommand {
  parse_args(args)
}

fn parse_monitor_defer(
  outcome_id: String,
  queue_id: String,
  lease_token: String,
  raw_defer_until: String,
  task_ref: String,
) -> CliCommand {
  case int.parse(raw_defer_until) {
    Ok(defer_until) ->
      CliMonitorDefer(
        outcome_id:,
        queue_id:,
        lease_token:,
        defer_until:,
        task_ref:,
      )
    Error(_) -> CliInvalid("Invalid monitor defer time")
  }
}

fn optional_ref(value: String) {
  case value {
    "" -> None
    value -> Some(value)
  }
}

fn run_monitor_result(result: Result(String, String)) {
  case result {
    Ok("") -> halt(0)
    Ok(output) -> {
      io.println(output)
      halt(0)
    }
    Error(error) -> {
      io.println(
        json.object([
          #("ok", json.bool(False)),
          #("error", json.string(error)),
        ])
        |> json.to_string,
      )
      halt(1)
    }
  }
}

fn run_start() {
  logging.configure()
  io.println("Aura v0.1.0")
  let paths = xdg.resolve()

  // First-run detection
  case xdg.is_initialized(paths) {
    False -> {
      case init.run(paths) {
        Ok(Nil) -> Nil
        Error(e) -> {
          io.println("Setup failed: " <> e)
          halt(1)
        }
      }
    }
    True -> Nil
  }

  // Load .env
  case dotenv.load(xdg.env_path(paths)) {
    Ok(Nil) -> Nil
    Error(_) -> Nil
  }

  // Load config
  let cfg = case load_config(paths) {
    Ok(cfg) -> cfg
    Error(e) -> {
      io.println("ERROR: " <> e)
      halt(service_failure_exit_code)
      config.default_global()
    }
  }

  // Start
  case supervisor.start(cfg, paths) {
    Ok(pid) -> {
      io.println("Aura running. Press Ctrl+C to stop.")
      wait_for_supervisor_exit(pid)
      logging.log(
        logging.Error,
        "Aura root supervisor stopped; terminating for service recovery",
      )
      halt(1)
    }
    Error(e) -> {
      io.println("ERROR: " <> e)
      halt(1)
    }
  }
}

/// Wait until the root supervisor stops.
pub fn wait_for_supervisor_exit(pid: process.Pid) -> Nil {
  let monitor = process.monitor(pid)
  process.new_selector()
  |> process.select_specific_monitor(monitor, fn(_) { Nil })
  |> process.selector_receive_forever
}

fn run_ctl(command: String) {
  let paths = xdg.resolve()
  case ctl.send(paths, command) {
    Ok(response) -> {
      io.println(response)
      case string.starts_with(response, "ERROR:") {
        True -> halt(1)
        False -> Nil
      }
    }
    Error(e) -> {
      io.println("ERROR: " <> e)
      halt(1)
    }
  }
}

fn run_hook(rules: String, cmd: String) {
  logging.configure()
  let paths = xdg.resolve()
  // Bare ruleset names resolve to the canonical config dir; explicit paths win.
  let rules_path = case string.contains(rules, "/") {
    True -> rules
    False -> xdg.config_path(paths, "hooks/" <> rules <> ".toml")
  }
  let content = case simplifile.read(rules_path) {
    Ok(content) -> content
    Error(e) -> {
      io.println(
        "ERROR: cannot read rules " <> rules_path <> ": " <> string.inspect(e),
      )
      halt(1)
      ""
    }
  }
  let ruleset = case hook_rules.parse(content) {
    Ok(rs) -> rs
    Error(e) -> {
      io.println("ERROR: " <> e)
      halt(1)
      hook_rules.Ruleset(name: "broken", source: "broken", rules: [])
    }
  }
  let code = hook_run.run(paths, ruleset, cmd)
  halt(code)
}

fn load_config(paths: xdg.Paths) -> Result(config.GlobalConfig, String) {
  let path = xdg.config_path(paths, "config.toml")
  use content <- result.try(
    simplifile.read(path)
    |> result.map_error(fn(e) {
      "Cannot read config.toml: " <> string.inspect(e)
    }),
  )
  use cfg <- result.try(config.parse_global(content))
  // Resolve env var references in the discord token
  use resolved_token <- result.try(config_parser.resolve_env_string(
    cfg.discord.token,
  ))
  Ok(
    config.GlobalConfig(
      ..cfg,
      discord: config.DiscordConfig(..cfg.discord, token: resolved_token),
    ),
  )
}

@external(erlang, "aura_runtime_ffi", "halt")
fn halt(code: Int) -> Nil

@external(erlang, "aura_runtime_ffi", "get_plain_arguments")
fn get_args() -> List(String)
