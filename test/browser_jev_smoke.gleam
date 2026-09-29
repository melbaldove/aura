//// Opt-in real-browser check. Default provider responses are deterministic.
//// Set AURA_JEV_SMOKE_LIVE=true to use configured live model providers.

import aura/brain_tools
import aura/browser
import aura/browser_adapter
import aura/browser_loop
import aura/clients/browser_runner
import aura/env
import aura/jev_client
import aura/jev_client_test as fixture
import aura/llm
import gleam/dict
import gleam/dynamic/decode
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/string
import gleeunit/should
import test_harness

pub fn main() {
  case env.get_env("AURA_JEV_SMOKE_LIVE") == Ok("true") {
    True -> {
      let production = jev_client.production()
      smoke(
        jev_client.with_post(production, fn(url, key, body, timeout) {
          let result = production.post(url, key, body, timeout)
          case result {
            Ok(raw) -> {
              case
                json.parse(
                  raw,
                  decode.at(["answers", "operation", "choice"], decode.string),
                )
              {
                Ok(operation) -> io.println("Live operation: " <> operation)
                Error(_) -> Nil
              }
            }
            Error(_) -> Nil
          }
          result
        }),
      )
    }
    False -> with_fake_config(fn() { smoke(jev_client.Client(scripted_post)) })
  }
}

fn smoke(client: jev_client.Client) -> Nil {
  let name =
    "jev-smoke-"
    <> int.to_string(int.absolute_value(browser_loop.monotonic_ms()))
  let session = "aura-named-" <> name
  let other = session <> "-other"
  with_cleanup([session, other], fn() {
    let runner = browser_runner.production()
    let traced_runner =
      browser_runner.BrowserRunner(
        run: fn(session, cdp, command, args, timeout) {
          let result = runner.run(session, cdp, command, args, timeout)
          case result {
            Error(reason) ->
              io.println("Test browser " <> command <> " failed: " <> reason)
            Ok(raw) ->
              case json.parse(raw, decode.at(["success"], decode.bool)) {
                Ok(False) ->
                  io.println("Test browser " <> command <> " failed: " <> raw)
                _ -> Nil
              }
          }
          result
        },
        url_has_secret: runner.url_has_secret,
      )
    let context =
      brain_tools.ToolContext(
        ..test_harness.standalone_tool_context(),
        jev_client: client,
        browser_runner: traced_runner,
      )
    tool(context, [
      #("action", "navigate"),
      #("url", "https://example.com"),
      #("session", name),
    ])
    |> string.contains("\"success\":true")
    |> should.be_true
    command(session, "eval", [
      "document.cookie='aura_jev_test=saved;path=/';localStorage.setItem('aura_jev_test','saved');true",
    ])
    let assert Ok(cdp_raw) =
      browser.run_ffi(session, "", "get", ["cdp-url"], 10_000)
    let assert Ok(cdp) =
      json.parse(cdp_raw, decode.at(["data", "cdpUrl"], decode.string))
    install_fixture(session)
    let tabs_before = command_result(session, "tab", ["list"])
    // Real dispatcher and browser runner, including the production session resolver.
    let output =
      tool(context, [
        #("action", "run"),
        #(
          "goal",
          "Replace Name with Aura, choose Blue, and click Apply. Stop when the result shows Aura blue.",
        ),
        #("session", name),
        #("timeout", "60"),
      ])
    io.println("Local run: " <> output)
    string.contains(output, "\"status\":\"done_unverified\"") |> should.be_true
    verify_text_calls(output)
    verify(session)
    command_result(session, "tab", ["list"]) |> should.equal(tabs_before)
    // A later ordinary browser call still reaches the same page and saved login markers.
    let later =
      tool(context, [
        #("action", "console"),
        #("expression", "document.querySelector('#out').textContent"),
        #("session", name),
      ])
    string.contains(later, "Aura blue") |> should.be_true
    command(other, "open", ["https://example.com"])
    let isolated =
      command_result(other, "eval", [
        "({cookie:document.cookie,local:localStorage.getItem('aura_jev_test')})",
      ])
    string.contains(isolated, "saved") |> should.be_false
    // CDP attachment uses the same target without creating a tab.
    install_fixture(session)
    let cdp_output =
      tool(context, [
        #("action", "run"),
        #(
          "goal",
          "Replace Name with Aura, choose Blue, and click Apply. Stop when the result shows Aura blue.",
        ),
        #("session", name),
        #("cdp_url", cdp),
        #("timeout", "60"),
      ])
    io.println("CDP run: " <> cdp_output)
    string.contains(cdp_output, "\"status\":\"done_unverified\"")
    |> should.be_true
    verify_text_calls(cdp_output)
    verify(session)
    guard_checks(session)
    // Token creation must also work outside secure origins.
    command(session, "open", ["about:blank"])
    install_fixture(session)
    let assert Ok(script) = browser_adapter.read_script()
    let adapter = browser_adapter.Adapter(traced_runner, session, "", script)
    let assert Ok(page) = browser_adapter.observe(adapter, 10_000)
    let assert Ok(action) =
      list.find(page.actions, fn(a) { a.label == "Apply" })
    let assert Ok(_) = browser_adapter.prepare(adapter, page, action, 10_000)
    // Only the test closes its own browser to check saved state after a restart.
    command(session, "close", [])
    command(session, "open", ["https://example.com"])
    let persisted =
      command_result(session, "eval", [
        "localStorage.getItem('aura_jev_test')==='saved' && document.cookie.includes('aura_jev_test=saved')",
      ])
    string.contains(persisted, "\"result\":true") |> should.be_true
    let input_checks = case
      env.get_env("AURA_JEV_SMOKE_NO_TEXT") == Ok("true")
    {
      True -> "select, click, zero text-model calls"
      False -> "field replacement, select, click"
    }
    io.println(
      "PASS: tool dispatcher, "
      <> input_checks
      <> ", same tab, later call, isolated session, CDP reuse, stale/covered target guards, saved cookies and local storage after restart.",
    )
  })
}

fn tool(ctx: brain_tools.ToolContext, args: List(#(String, String))) -> String {
  let call =
    llm.ToolCall(
      id: "jev-smoke",
      name: "browser",
      arguments: json.to_string(
        json.object(list.map(args, fn(p) { #(p.0, json.string(p.1)) })),
      ),
    )
  let #(result, _) = brain_tools.execute_tool(ctx, call)
  brain_tools.tool_result_text(result)
}

fn command_result(
  session: String,
  command: String,
  args: List(String),
) -> String {
  let assert Ok(raw) = browser.run_ffi(session, "", command, args, 30_000)
  let assert Ok(True) = json.parse(raw, decode.at(["success"], decode.bool))
  raw
}

fn command(session: String, command: String, args: List(String)) -> Nil {
  let _ = command_result(session, command, args)
  Nil
}

fn install_fixture(session: String) -> Nil {
  let html =
    "<label>Name<input id='name' value='old'></label><label>Color<select id='color'><option value='red'>Red</option><option value='blue'>Blue</option></select></label><button id='apply' onclick=\"document.getElementById('out').textContent=document.getElementById('name').value+' '+document.getElementById('color').value\">Apply</button><p id='out'></p>"
  let html = case env.get_env("AURA_JEV_SMOKE_NO_TEXT") == Ok("true") {
    True -> string.replace(html, "value='old'", "value='Aura' readonly")
    False -> html
  }
  command(session, "eval", [
    "document.body.innerHTML=" <> json.to_string(json.string(html)) <> ";true",
  ])
}

fn verify_text_calls(output: String) -> Nil {
  case env.get_env("AURA_JEV_SMOKE_NO_TEXT") == Ok("true") {
    True -> {
      let assert Ok(0) =
        json.parse(output, decode.at(["text_calls"], decode.int))
      Nil
    }
    False -> Nil
  }
}

fn verify(session: String) -> Nil {
  let raw =
    command_result(session, "eval", [
      "document.querySelector('#name').value==='Aura' && document.querySelector('#color').value==='blue' && document.querySelector('#out').textContent==='Aura blue' && localStorage.getItem('aura_jev_test')==='saved' && document.cookie.includes('aura_jev_test=saved')",
    ])
  string.contains(raw, "\"result\":true") |> should.be_true
}

fn guard_checks(session: String) -> Nil {
  let assert Ok(script) = browser_adapter.read_script()
  let adapter =
    browser_adapter.Adapter(
      test_harness.standalone_tool_context().browser_runner,
      session,
      "",
      script,
    )
  let assert Ok(page) = browser_adapter.observe(adapter, 10_000)
  let assert Ok(action) = list.find(page.actions, fn(a) { a.label == "Apply" })
  command(session, "eval", [
    "document.querySelector('#apply').outerHTML=document.querySelector('#apply').outerHTML;true",
  ])
  browser_adapter.prepare(adapter, page, action, 10_000)
  |> should.equal(Error("stale"))
  let assert Ok(page) = browser_adapter.observe(adapter, 10_000)
  let assert Ok(action) = list.find(page.actions, fn(a) { a.label == "Apply" })
  command(session, "eval", [
    "const o=document.createElement('div');o.style='position:fixed;inset:0;z-index:999999';document.body.appendChild(o);true",
  ])
  browser_adapter.prepare(adapter, page, action, 10_000)
  |> should.equal(Error("stale"))
}

fn scripted_post(
  _url: String,
  _key: String,
  body: json.Json,
  _timeout: Int,
) -> Result(String, String) {
  let raw = json.to_string(body)
  case json.parse(raw, decode.at(["state", "page", "text"], decode.string)) {
    Error(_) -> Ok(fixture.text_response("{\"text\":\"Aura\"}"))
    Ok(text) -> {
      let target = {
        use label <- decode.field("element", decode.string)
        use value <- decode.field("current_value", decode.string)
        decode.success(#(label, value))
      }
      let elements =
        list.flat_map(
          [
            #("type_text_target", "TYPE_TEXT"),
            #("select_target", "SELECT"),
            #("click_target", "CLICK"),
          ],
          fn(head) {
            case
              json.parse(
                raw,
                decode.at(
                  ["questions", head.0, "criteria"],
                  decode.dict(decode.string, target),
                ),
              )
            {
              Ok(targets) ->
                list.map(dict.to_list(targets), fn(t) {
                  #(t.0, t.1.0, t.1.1, head.1)
                })
              Error(_) -> []
            }
          },
        )
      let choice = case string.contains(text, "Aura blue") {
        True -> #("DONE", "")
        False -> {
          case
            list.find(elements, fn(e) { e.3 == "TYPE_TEXT" && e.2 != "Aura" })
          {
            Ok(e) -> #("TYPE_TEXT", e.0)
            Error(_) ->
              case
                list.find(elements, fn(e) {
                  e.3 == "SELECT" && string.contains(e.1, "Blue")
                })
              {
                Ok(e) -> #("SELECT", e.0)
                Error(_) -> {
                  let assert Ok(e) =
                    list.find(elements, fn(e) {
                      string.ends_with(e.1, " Apply")
                    })
                  #("CLICK", e.0)
                }
              }
          }
        }
      }
      Ok(fixture.response(body, choice.0, choice.1))
    }
  }
}

@external(erlang, "aura_jev_test_helpers", "with_fake_config")
fn with_fake_config(run: fn() -> Nil) -> Nil

@external(erlang, "aura_jev_test_helpers", "with_cleanup")
fn with_cleanup(sessions: List(String), run: fn() -> Nil) -> Nil
