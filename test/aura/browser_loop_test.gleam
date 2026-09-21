import aura/brain_tools
import aura/browser_adapter
import aura/browser_loop
import aura/clients/browser_runner
import aura/jev_client
import aura/jev_client_test as fixture
import aura/llm
import aura/tool_worker
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/string
import gleeunit/should
import test_harness

pub fn page_raw() -> String {
  let page = fixture.page()
  json.to_string(
    json.object([
      #("success", json.bool(True)),
      #(
        "data",
        json.object([
          #(
            "result",
            json.object([
              #("token", json.string(page.token)),
              #("url", json.string(page.url)),
              #("title", json.string(page.title)),
              #("text", json.string(page.text)),
              #("fingerprint", json.string(page.fingerprint)),
              #(
                "actions",
                json.array(page.actions, fn(a) {
                  json.object([
                    #("id", json.string(a.id)),
                    #("kind", json.string(a.kind)),
                    #("label", json.string(a.label)),
                    #("role", json.string(a.role)),
                    #("value", json.string(a.value)),
                  ])
                }),
              ),
            ]),
          ),
        ]),
      ),
    ]),
  )
}

fn adapter(stale: Bool, fail_action: Bool) -> browser_adapter.Adapter {
  browser_adapter.Adapter(
    browser_runner.BrowserRunner(
      fn(session, cdp, command, args, timeout) {
        session |> should.equal("retained-session")
        cdp |> should.equal("retained-cdp")
        { timeout > 0 && timeout <= 1000 } |> should.be_true
        case command, args {
          "eval", [expression] -> {
            case string.contains(expression, "\"operation\":\"observe\"") {
              True -> Ok(page_raw())
              False ->
                Ok(case stale {
                  True ->
                    "{\"success\":true,\"data\":{\"result\":{\"fresh\":false}}}"
                  False ->
                    "{\"success\":true,\"data\":{\"result\":{\"fresh\":true,\"selector\":\"observed-selector\"}}}"
                })
            }
          }
          _, _ -> {
            let _ = tick("actions")
            case fail_action {
              True -> Ok("{\"success\":false,\"error\":\"secret raw failure\"}")
              False -> Ok("{\"success\":true}")
            }
          }
        }
      },
      fn(_) { False },
    ),
    "retained-session",
    "retained-cdp",
    "fixed_script",
  )
}

fn client(op: String, target: String) -> jev_client.Client {
  jev_client.Client(fn(_, _, body, _) { Ok(fixture.response(body, op, target)) })
}

fn run(op: String, target: String, stale: Bool, fail_action: Bool) -> String {
  reset()
  browser_loop.run(
    "Apply",
    1000,
    adapter(stale, fail_action),
    fixture.config(),
    browser_loop.Dependencies(client(op, target), fn() { 0 }),
  )
}

fn field(raw: String, name: String) -> String {
  let raw = case string.starts_with(raw, "Error: ") {
    True -> string.drop_start(raw, 7)
    False -> raw
  }
  let assert Ok(value) = json.parse(raw, decode.at([name], decode.string))
  value
}

pub fn stops_at_done_without_browser_input_test() {
  let raw = run("DONE", "", False, False)
  field(raw, "status") |> should.equal("done_unverified")
  tick("actions") |> should.equal(0)
  string.contains(raw, "\"verified\":false") |> should.be_true
}

pub fn stale_retries_consume_budget_without_input_test() {
  let raw = run("CLICK", "e2", True, False)
  field(raw, "status") |> should.equal("limit")
  string.contains(raw, "\"decisions\":60") |> should.be_true
  tick("actions") |> should.equal(0)
}

pub fn failed_execution_is_not_retried_test() {
  let raw = run("CLICK", "e2", False, True)
  field(raw, "status") |> should.equal("uncertain")
  tick("actions") |> should.equal(1)
  string.starts_with(raw, "Error:") |> should.be_true
  string.contains(raw, "secret raw failure") |> should.be_false
}

pub fn no_progress_returns_control_test() {
  let raw = run("CLICK", "e2", False, False)
  field(raw, "status") |> should.equal("blocked")
  tick("actions") |> should.equal(3)
}

pub fn waits_stop_at_action_budget_test() {
  let raw = run("WAIT", "", False, False)
  field(raw, "status") |> should.equal("limit")
  tick("actions") |> should.equal(30)
}

pub fn elapsed_deadline_stops_before_input_test() {
  reset()
  let raw =
    browser_loop.run(
      "Apply",
      2,
      adapter(False, False),
      fixture.config(),
      browser_loop.Dependencies(client("CLICK", "e2"), fn() { tick("clock") }),
    )
  field(raw, "status") |> should.equal("timeout")
  tick("actions") |> should.equal(0)
}

pub fn provider_error_does_not_mutate_browser_test() {
  reset()
  let raw =
    browser_loop.run(
      "Apply",
      1000,
      adapter(False, False),
      fixture.config(),
      browser_loop.Dependencies(
        jev_client.Client(fn(_, _, _, _) { Error("Provider unavailable") }),
        fn() { 0 },
      ),
    )
  field(raw, "status") |> should.equal("error")
  tick("actions") |> should.equal(0)
}

pub fn auth_wall_stops_before_model_request_test() {
  let base = adapter(False, False)
  let runner =
    browser_runner.BrowserRunner(
      fn(_, _, _, _, _) {
        Ok(
          page_raw()
          |> string.replace("https://example.com/", "https://example.com/login"),
        )
      },
      fn(_) { False },
    )
  let raw =
    browser_loop.run(
      "Apply",
      1000,
      browser_adapter.Adapter(..base, runner: runner),
      fixture.config(),
      browser_loop.Dependencies(
        jev_client.Client(fn(_, _, _, _) {
          panic as "Auth wall must stop before model request"
        }),
        fn() { 0 },
      ),
    )
  field(raw, "status") |> should.equal("auth_required")
}

pub fn private_page_stops_before_model_request_test() {
  let base = adapter(False, False)
  let runner =
    browser_runner.BrowserRunner(
      fn(_, _, _, _, _) {
        Ok(
          page_raw()
          |> string.replace("https://example.com/", "http://127.0.0.1/"),
        )
      },
      fn(_) { False },
    )
  let raw =
    browser_loop.run(
      "Apply",
      1000,
      browser_adapter.Adapter(..base, runner: runner),
      fixture.config(),
      browser_loop.Dependencies(
        jev_client.Client(fn(_, _, _, _) {
          panic as "Private page must not reach provider"
        }),
        fn() { 0 },
      ),
    )
  field(raw, "status") |> should.equal("blocked")
}

pub fn stale_page_after_text_generation_never_receives_input_test() {
  reset()
  let base = adapter(False, False)
  let runner =
    browser_runner.BrowserRunner(
      fn(s, c, command, args, timeout) {
        case args {
          [expression] if command == "eval" -> {
            case string.contains(expression, "\"operation\":\"prepare\"") {
              True ->
                Ok("{\"success\":true,\"data\":{\"result\":{\"fresh\":false}}}")
              False -> base.runner.run(s, c, command, args, timeout)
            }
          }
          _ -> base.runner.run(s, c, command, args, timeout)
        }
      },
      fn(_) { False },
    )
  let client =
    jev_client.Client(fn(url, _, body, _) {
      case string.ends_with(url, "chat/completions") {
        True -> Ok(fixture.text_response("{\"text\":\"new value\"}"))
        False -> Ok(fixture.response(body, "TYPE_TEXT", "e1"))
      }
    })
  let raw =
    browser_loop.run(
      "Apply",
      1000,
      browser_adapter.Adapter(..base, runner: runner),
      fixture.config(),
      browser_loop.Dependencies(client, fn() { 0 }),
    )
  field(raw, "status") |> should.equal("limit")
  string.contains(raw, "\"text_calls\":60") |> should.be_true
  tick("actions") |> should.equal(0)
}

pub fn executed_action_remains_counted_when_observation_fails_test() {
  reset()
  let base = adapter(False, False)
  let runner =
    browser_runner.BrowserRunner(
      fn(s, c, command, args, timeout) {
        case args {
          [expression] if command == "eval" -> {
            case
              string.contains(expression, "\"operation\":\"observe\"")
              && tick("observations") > 0
            {
              True -> Error("Observation failed")
              False -> base.runner.run(s, c, command, args, timeout)
            }
          }
          _ -> base.runner.run(s, c, command, args, timeout)
        }
      },
      fn(_) { False },
    )
  let raw =
    browser_loop.run(
      "Apply",
      1000,
      browser_adapter.Adapter(..base, runner: runner),
      fixture.config(),
      browser_loop.Dependencies(client("CLICK", "e2"), fn() { 0 }),
    )
  field(raw, "status") |> should.equal("error")
  string.contains(raw, "\"actions\":1") |> should.be_true
  tick("actions") |> should.equal(1)
}

pub fn disabled_action_is_hidden_and_rejected_test() {
  let old = set_enabled("false")
  let assert Ok(tool) =
    brain_tools.make_built_in_tools()
    |> list.find(fn(t) { t.name == "browser" })
  list.any(tool.parameters, fn(p) { p.name == "goal" }) |> should.be_false
  string.contains(tool.description, "Jev") |> should.be_false
  let raw =
    browser_loop.execute(
      "Apply",
      "retained-session",
      "",
      1000,
      adapter(False, False).runner,
    )
  string.contains(raw, "disabled") |> should.be_true
  restore_enabled(old)
}

pub fn enabled_action_is_in_tool_schema_test() {
  let old = set_enabled("true")
  let assert Ok(tool) =
    brain_tools.make_built_in_tools()
    |> list.find(fn(t) { t.name == "browser" })
  list.any(tool.parameters, fn(p) { p.name == "goal" }) |> should.be_true
  restore_enabled(old)
}

pub fn killed_worker_issues_no_followup_browser_action_test() {
  with_fake_config(fn() {
    let reached = process.new_subject()
    let acted = process.new_subject()
    let parent = process.new_subject()
    let base = adapter(False, False)
    let runner =
      browser_runner.BrowserRunner(
        fn(_, _, command, args, timeout) {
          case command {
            "eval" ->
              base.runner.run(
                "retained-session",
                "retained-cdp",
                command,
                args,
                timeout,
              )
            _ -> {
              process.send(acted, command)
              Ok("{\"success\":true}")
            }
          }
        },
        fn(_) { False },
      )
    let ctx =
      brain_tools.ToolContext(
        ..test_harness.standalone_tool_context(),
        browser_runner: runner,
        jev_client: jev_client.Client(fn(_, _, body, _) {
          process.send(reached, Nil)
          process.sleep(100)
          Ok(fixture.response(body, "CLICK", "e2"))
        }),
      )
    let worker =
      tool_worker.spawn(
        ctx,
        llm.ToolCall(
          "cancel",
          "browser",
          "{\"action\":\"run\",\"goal\":\"Apply\",\"timeout\":\"1\"}",
        ),
        parent,
      )
    process.receive(reached, 1000) |> should.equal(Ok(Nil))
    process.unlink(worker)
    process.kill(worker)
    process.receive(acted, 200) |> should.be_error
    process.receive(parent, 0) |> should.be_error
  })
}

@external(erlang, "aura_jev_test_helpers", "with_fake_config")
fn with_fake_config(run: fn() -> Nil) -> Nil

@external(erlang, "aura_jev_test_helpers", "tick")
fn tick(key: String) -> Int

@external(erlang, "aura_jev_test_helpers", "reset")
fn reset() -> Nil

@external(erlang, "aura_jev_test_helpers", "set_enabled")
fn set_enabled(value: String) -> Result(String, Nil)

@external(erlang, "aura_jev_test_helpers", "restore_enabled")
fn restore_enabled(value: Result(String, Nil)) -> Nil
