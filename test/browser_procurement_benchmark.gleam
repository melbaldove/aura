//// Shared multi-screen benchmark driver. Compiles against pre-Jev APIs.

import aura/agent_loop
import aura/brain_tools
import aura/browser
import aura/clients/browser_runner
import aura/env
import aura/llm
import aura/models
import gleam/dict
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import simplifile
import test_harness

const goal = "Create and save a draft equipment request. Apply the in-stock and 14-inch laptop filters. Compare specifications and choose the cheapest in-stock 14-inch laptop with at least 32 GB RAM, 12 hours battery, and 3 years warranty. Request two of that laptop. Add one of the cheapest USB-C docks that supports two 4K monitors and at least 85 W charging. Use Manila office, Standard shipping, and the Engineering budget. The total must be at most $2600. Review all details and save the draft. Use visible buttons and links to change the application; do not execute JavaScript. Stop when the saved draft shows the correct items, quantities, delivery, budget, and total."

pub fn main() {
  let tools =
    brain_tools.make_built_in_tools()
    |> list.filter(fn(t) { t.name == "browser" })
  case env.get_env("AURA_BROWSER_BENCHMARK_INSPECT") {
    Ok("true") ->
      io.println(
        "SCHEMA "
        <> json.to_string(json.array(tools, llm.codex_tool_definition_to_json)),
      )
    _ -> run_trials(tools)
  }
}

fn run_trials(tools: List(llm.ToolDefinition)) {
  let assert Ok("true") = env.get_env("AURA_BROWSER_BENCHMARK")
  let assert Ok(config) =
    models.build_llm_config_with_codex_reasoning_effort(
      env.get_env("AURA_PROCUREMENT_GPT_MODEL")
        |> result.unwrap("openai-codex/gpt-5.6-luna"),
      env.get_env("AURA_PROCUREMENT_REASONING") |> result.unwrap("low"),
    )
  let assert Ok(flow) = env.get_env("AURA_PROCUREMENT_FLOW")
  let pair =
    env.get_env("AURA_PROCUREMENT_PAIR")
    |> result.unwrap("0")
    |> int.parse
    |> result.unwrap(0)
  let channel = "pc-" <> unique_id()
  let assert Ok(session) = browser.resolve_session("", channel)
  with_cleanup([session], fn() {
    trial(pair, flow, session, channel, config, tools)
  })
}

fn trial(
  pair: Int,
  flow: String,
  session: String,
  channel: String,
  config: llm.LlmConfig,
  tools: List(llm.ToolDefinition),
) {
  command(session, "open", ["https://example.com"])
  let assert True =
    command(session, "eval", ["location.href==='https://example.com/'"])
    |> string.contains("\"result\":true")
  command(session, "eval", [
    "document.cookie='aura_jev_test=saved;path=/';localStorage.setItem('aura_jev_test','saved');true",
  ])
  let assert Ok(fixture) =
    simplifile.read("test/fixtures/browser_procurement.js")
  command(session, "eval", [fixture])
  reset()
  let timeout_seconds =
    env.get_env("AURA_PROCUREMENT_TIMEOUT_SECONDS")
    |> result.unwrap("180")
    |> int.parse
    |> result.unwrap(180)
  let assert True = timeout_seconds > 0 && timeout_seconds <= 600
  let start = monotonic_ms()
  let deadline = start + timeout_seconds * 1000
  let production = browser_runner.production()
  let ctx =
    brain_tools.ToolContext(
      ..test_harness.standalone_tool_context(),
      channel_id: channel,
      browser_runner: browser_runner.BrowserRunner(
        run: fn(s, cdp, cmd, args, timeout) {
          case s == session && cdp == "" {
            False -> Error("Benchmark must use its isolated default session")
            True -> {
              let _ = tick("browser_commands")
              let remaining = deadline - monotonic_ms()
              case remaining > 0 {
                False -> Error("Benchmark deadline")
                True -> {
                  let started = monotonic_ms()
                  let result =
                    production.run(
                      s,
                      cdp,
                      cmd,
                      args,
                      int.min(timeout, remaining),
                    )
                  io.println(
                    "BROWSER_TIMING "
                    <> cmd
                    <> " "
                    <> int.to_string(monotonic_ms() - started),
                  )
                  case result {
                    Error(reason) -> io.println("BROWSER_ERROR " <> reason)
                    _ -> Nil
                  }
                  result
                }
              }
            }
          }
        },
        url_has_secret: production.url_has_secret,
      ),
    )
  io.println("START " <> int.to_string(pair) <> " " <> flow)
  let output = case flow {
    "preflight" -> {
      list.each(
        [
          "Laptops",
          "Only in-stock laptops",
          "Only 14-inch laptops",
          "Compare laptops",
          "Choose Orion 14",
          "Add laptop",
          "Increase Orion 14 quantity",
          "Docks",
          "Compare docks",
          "Choose Harbor Dock",
          "Add dock",
          "Configure request",
          "Manila office",
          "Standard shipping",
          "Engineering",
          "Review request",
          "Save draft",
        ],
        fn(label) { click_label(ctx, label) },
      )
      "Preflight complete"
    }
    "jev" -> {
      let #(r, _) =
        brain_tools.execute_tool(
          ctx,
          llm.ToolCall(
            "procurement",
            "browser",
            json.to_string(
              json.object([
                #("action", json.string("run")),
                #("goal", json.string(goal)),
                #("timeout", json.string(int.to_string(timeout_seconds))),
              ]),
            ),
          ),
        )
      brain_tools.tool_result_text(r)
    }
    "old" -> {
      let messages = [
        llm.SystemMessage(
          "Complete the task using the browser tool on the current application. Use snapshot to inspect each changed screen and obtain fresh refs. Interact only through visible buttons and links using click. Use the default session. The task page is already open; do not navigate away, execute JavaScript, or use keyboard input. Verify the saved result before finishing.",
        ),
        llm.UserMessage(goal),
      ]
      let state =
        agent_loop.new_state(messages)
        |> agent_loop.with_capabilities(["browser"])
      drive(
        state,
        [agent_loop.SpawnStream(messages)],
        ctx,
        config,
        tools,
        deadline,
      )
    }
    _ -> "Error: Unknown flow"
  }
  let elapsed = monotonic_ms() - start
  let commands = tick("browser_commands")
  let gpt_calls = case flow {
    "jev" ->
      json.parse(
        string.replace(output, "Error: ", ""),
        decode.at(["text_calls"], decode.int),
      )
      |> result.unwrap(-1)
    _ -> tick("gpt_calls")
  }
  let verification = case
    browser.run_ffi(
      session,
      "",
      "eval",
      [
        "(()=>{const s=window.getProcurementState?.();let cookie=false,storage=false,persisted=false;try{cookie=document.cookie.includes('aura_jev_test=saved');storage=localStorage.getItem('aura_jev_test')==='saved';persisted=JSON.parse(localStorage.getItem('procurement_draft')||'null')?.saved===true}catch{}return {state:s??null,cookie,storage,persisted,verified:!!s&&s.saved&&s.view==='saved'&&s.filters.stock&&s.filters.size&&s.laptop==='orion'&&s.dock==='harbor'&&s.laptopQty===2&&s.dockQty===1&&s.office==='Manila'&&s.shipping==='standard'&&s.budget==='Engineering'&&s.total===2547&&cookie&&storage&&persisted}})()",
      ],
      30_000,
    )
  {
    Ok(raw) -> raw
    Error(reason) ->
      json.to_string(
        json.object([
          #("success", json.bool(False)),
          #("error", json.string(reason)),
        ]),
      )
  }
  let verified =
    json.parse(
      verification,
      decode.at(["data", "result", "verified"], decode.bool),
    )
    |> result.unwrap(False)
  io.println(
    "RESULT "
    <> json.to_string(
      json.object([
        #("pair", json.int(pair)),
        #("flow", json.string(flow)),
        #("gpt_model", json.string(config.model)),
        #("reasoning", json.string(config.codex_reasoning_effort)),
        #("timeout_seconds", json.int(timeout_seconds)),
        #("elapsed_ms", json.int(elapsed)),
        #("verified", json.bool(verified)),
        #("verification", json.string(verification)),
        #("browser_commands", json.int(commands)),
        #(
          "browser_tool_calls",
          json.int(case flow {
            "old" -> tick("tool_calls")
            "preflight" -> commands
            _ -> 1
          }),
        ),
        #("gpt_calls", json.int(gpt_calls)),
        #(
          "typesafe_calls",
          json.int(case flow {
            "jev" ->
              json.parse(
                string.replace(output, "Error: ", ""),
                decode.at(["decisions"], decode.int),
              )
              |> result.unwrap(-1)
            _ -> 0
          }),
        ),
        #("stream_retries", json.int(tick("stream_retries"))),
        #("output", json.string(output)),
      ]),
    ),
  )
}

fn drive(
  state: agent_loop.LoopState,
  actions: List(agent_loop.LoopAction),
  ctx: brain_tools.ToolContext,
  config: llm.LlmConfig,
  tools: List(llm.ToolDefinition),
  deadline: Int,
) -> String {
  case deadline - monotonic_ms() <= 0 {
    True -> "Error: Benchmark deadline"
    False -> {
      case actions {
        [agent_loop.Finalize(content), ..] -> content
        [agent_loop.Fail(reason), ..] -> "Error: " <> reason
        [agent_loop.RetryStream(messages, backoff), ..] -> {
          let _ = tick("stream_retries")
          process.sleep(backoff)
          drive(
            state,
            [agent_loop.SpawnStream(messages)],
            ctx,
            config,
            tools,
            deadline,
          )
        }
        [agent_loop.SpawnStream(messages), ..] -> {
          let _ = tick("gpt_calls")
          let body =
            llm.build_codex_responses_body_with_reasoning_effort(
              config.model,
              messages,
              tools,
              True,
              config.codex_reasoning_effort,
            )
            |> json.to_string
          let model_started = monotonic_ms()
          let response =
            stream(
              config.base_url <> "/responses",
              config.api_key,
              config.model,
              body,
              deadline - monotonic_ms(),
            )
          io.println(
            "MODEL_TIMING " <> int.to_string(monotonic_ms() - model_started),
          )
          let #(next, actions) = case response {
            Ok(#(content, calls)) -> {
              let #(next, _) =
                agent_loop.step(state, agent_loop.StreamDelta(content))
              agent_loop.step(next, agent_loop.StreamComplete(content, calls))
            }
            Error(reason) ->
              agent_loop.step(state, agent_loop.StreamError(reason))
          }
          drive(next, actions, ctx, config, tools, deadline)
        }
        [agent_loop.SpawnTool(call), ..] -> {
          let _ = tick("tool_calls")
          io.println("OLD_TOOL " <> call.arguments)
          let output = execute(ctx, call)
          io.println("OLD_RESULT " <> output)
          let #(next, actions) =
            agent_loop.step(
              state,
              agent_loop.ToolResult(
                call.id,
                output,
                string.starts_with(output, "Error:"),
              ),
            )
          drive(next, actions, ctx, config, tools, deadline)
        }
        _ -> "Error: Unexpected loop state"
      }
    }
  }
}

fn command(session: String, cmd: String, args: List(String)) -> String {
  let assert Ok(raw) = browser.run_ffi(session, "", cmd, args, 30_000)
  let assert Ok(True) = json.parse(raw, decode.at(["success"], decode.bool))
  raw
}

@external(erlang, "aura_browser_benchmark_helpers", "codex_stream")
fn stream(
  url: String,
  auth: String,
  model: String,
  body: String,
  timeout: Int,
) -> Result(#(String, String), String)

@external(erlang, "aura_browser_benchmark_helpers", "with_cleanup")
fn with_cleanup(sessions: List(String), run: fn() -> Nil) -> Nil

@external(erlang, "aura_browser_benchmark_helpers", "tick")
fn tick(key: String) -> Int

@external(erlang, "aura_browser_benchmark_helpers", "reset")
fn reset() -> Nil

@external(erlang, "aura_browser_benchmark_helpers", "unique_id")
fn unique_id() -> String

@external(erlang, "aura_browser_benchmark_helpers", "monotonic_ms")
fn monotonic_ms() -> Int

fn execute(ctx: brain_tools.ToolContext, call: llm.ToolCall) -> String {
  let action =
    json.parse(call.arguments, decode.at(["action"], decode.string))
    |> result.unwrap("")
  case
    call.name == "browser"
    && list.contains(["snapshot", "click", "wait"], action)
  {
    False ->
      "Error: This benchmark permits only browser snapshot, click, and wait through visible controls."
    True -> {
      let #(r, _) = brain_tools.execute_tool(ctx, call)
      brain_tools.tool_result_text(r)
    }
  }
}

fn click_label(ctx: brain_tools.ToolContext, label: String) {
  let raw =
    execute(
      ctx,
      llm.ToolCall(
        "snapshot",
        "browser",
        "{\"action\":\"snapshot\",\"full\":\"true\"}",
      ),
    )
  let assert Ok(refs) =
    json.parse(
      raw,
      decode.at(
        ["data", "refs"],
        decode.dict(decode.string, decode.at(["name"], decode.string)),
      ),
    )
  let assert Ok(pair) = dict.to_list(refs) |> list.find(fn(p) { p.1 == label })
  let call =
    llm.ToolCall(
      "click",
      "browser",
      json.to_string(
        json.object([
          #("action", json.string("click")),
          #("ref", json.string("@" <> pair.0)),
        ]),
      ),
    )
  let raw = execute(ctx, call)
  let assert Ok(True) = json.parse(raw, decode.at(["success"], decode.bool))
  io.println("PREFLIGHT_CLICK " <> label)
}
