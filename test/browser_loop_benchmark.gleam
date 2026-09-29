//// Live comparison on an isolated form. Requires AURA_BROWSER_BENCHMARK=true.

import aura/agent_loop
import aura/brain_tools
import aura/browser
import aura/browser_loop
import aura/clients/browser_runner
import aura/env
import aura/jev_client
import aura/llm
import aura/models
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import test_harness

const goal = "Replace Name with Aura, choose Blue, and click Apply. Stop when the result shows Aura blue."

pub fn main() {
  let assert Ok("true") = env.get_env("AURA_BROWSER_BENCHMARK")
  let assert Ok("openai-codex/gpt-5.6-luna") = env.get_env("TEXT_MODEL")
  let assert Ok(config) =
    models.build_llm_config_with_codex_reasoning_effort(
      "openai-codex/gpt-5.6-luna",
      "low",
    )
  let previous = set_enabled("false")
  let tools =
    brain_tools.make_built_in_tools()
    |> list.filter(fn(t) { t.name == "browser" })
  restore_enabled(previous)
  let assert True = jev_client.enabled()
  let channel = "bm-" <> unique_id()
  list.each([1, 2, 3, 4, 5], fn(pair) {
    let order = case pair % 2 {
      1 -> ["old", "jev"]
      _ -> ["jev", "old"]
    }
    list.each(order, fn(flow) {
      let trial_channel = channel <> "-" <> flow <> int.to_string(pair)
      let assert Ok(session) = browser.resolve_session("", trial_channel)
      with_cleanup([session], fn() {
        trial(pair, flow, session, trial_channel, config, tools)
      })
    })
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
  let html =
    "<label>Name<input id='name' value='old'></label><label>Color<select id='color'><option value='red'>Red</option><option value='blue'>Blue</option></select></label><button id='apply' onclick=\"document.getElementById('out').textContent=document.getElementById('name').value+' '+document.getElementById('color').value\">Apply</button><p id='out'></p>"
  command(session, "eval", [
    "document.body.innerHTML=" <> json.to_string(json.string(html)) <> ";true",
  ])
  reset()
  let start = browser_loop.monotonic_ms()
  let deadline = start + 60_000
  let production = browser_runner.production()
  let client = jev_client.production()
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
              let remaining = deadline - browser_loop.monotonic_ms()
              case remaining > 0 {
                False -> Error("Benchmark deadline")
                True -> {
                  let result =
                    production.run(
                      s,
                      cdp,
                      cmd,
                      args,
                      int.min(timeout, remaining),
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
      jev_client: jev_client.with_post(client, fn(url, key, body, timeout) {
        let _ = tick("typesafe_calls")
        client.post(url, key, body, timeout)
      }),
    )
  io.println("START " <> int.to_string(pair) <> " " <> flow)
  let output = case flow {
    "old" -> {
      let messages = [
        llm.SystemMessage(
          "Complete the browser task with the browser tool. The task page is already open in the default current session. Inspect that page first; do not navigate away. Use the default session. Verify the result before you finish.",
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
    _ -> {
      let call =
        llm.ToolCall(
          "benchmark",
          "browser",
          json.to_string(
            json.object([
              #("action", json.string("run")),
              #("goal", json.string(goal)),
              #("timeout", json.string("60")),
            ]),
          ),
        )
      let #(result, _) = brain_tools.execute_tool(ctx, call)
      brain_tools.tool_result_text(result)
    }
  }
  let elapsed = browser_loop.monotonic_ms() - start
  let commands = tick("browser_commands")
  let gpt_calls = case flow {
    "old" -> tick("gpt_calls")
    _ -> {
      case
        json.parse(
          string.replace(output, "Error: ", ""),
          decode.at(["text_calls"], decode.int),
        )
      {
        Ok(n) -> n
        Error(_) -> -1
      }
    }
  }
  let verification = case
    browser.run_ffi(
      session,
      "",
      "eval",
      [
        "(()=>{const name=document.querySelector('#name')?.value??null,color=document.querySelector('#color')?.value??null,output=document.querySelector('#out')?.textContent??null;let cookie=false,storage=false;try{cookie=document.cookie.includes('aura_jev_test=saved')}catch{}try{storage=localStorage.getItem('aura_jev_test')==='saved'}catch{}return {url:location.href,name,color,output,cookie,storage,verified:name==='Aura'&&color==='blue'&&output==='Aura blue'&&cookie&&storage}})()",
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
        #("elapsed_ms", json.int(elapsed)),
        #("verified", json.bool(verified)),
        #("verification", json.string(verification)),
        #("browser_commands", json.int(commands)),
        #(
          "browser_tool_calls",
          json.int(case flow {
            "old" -> tick("tool_calls")
            _ -> 1
          }),
        ),
        #("gpt_calls", json.int(gpt_calls)),
        #("typesafe_calls", json.int(tick("typesafe_calls"))),
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
  case deadline - browser_loop.monotonic_ms() <= 0 {
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
          let #(next, actions) = case
            stream(
              config.base_url <> "/responses",
              config.api_key,
              config.model,
              body,
              deadline - browser_loop.monotonic_ms(),
            )
          {
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
          let #(result, _) = brain_tools.execute_tool(ctx, call)
          let output = brain_tools.tool_result_text(result)
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

@external(erlang, "aura_jev_test_helpers", "with_cleanup")
fn with_cleanup(sessions: List(String), run: fn() -> Nil) -> Nil

@external(erlang, "aura_jev_test_helpers", "set_enabled")
fn set_enabled(value: String) -> Result(String, Nil)

@external(erlang, "aura_jev_test_helpers", "restore_enabled")
fn restore_enabled(value: Result(String, Nil)) -> Nil

@external(erlang, "aura_jev_test_helpers", "tick")
fn tick(key: String) -> Int

@external(erlang, "aura_jev_test_helpers", "reset")
fn reset() -> Nil

@external(erlang, "aura_browser_benchmark_helpers", "unique_id")
fn unique_id() -> String
