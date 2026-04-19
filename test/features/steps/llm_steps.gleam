import aura/llm
import dream_test/gherkin/steps.{type StepContext, type StepRegistry, get_string}
import dream_test/gherkin/world
import dream_test/matchers.{contain_string, or_fail_with, should, succeed}
import dream_test/types as dream_types  // AssertionResult used in handler return types
import fakes/fake_llm
import gleam/erlang/process
import gleam/list
import gleam/string
import test_harness.{type TestSystem}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Register all LLM step definitions onto the provided registry.
pub fn register(reg: StepRegistry) -> StepRegistry {
  reg
  |> steps.step(
    "the LLM will respond with {string}",
    given_llm_text_response,
  )
  |> steps.step(
    "the LLM will call {string} with {string}",
    given_llm_tool_call,
  )
  |> steps.step("the LLM will fail with {string}", given_llm_error)
  |> steps.step("the LLM will reason indefinitely", given_llm_reasoning_forever)
  |> steps.step(
    "the vision model will describe the image as {string}",
    given_vision_description,
  )
  |> steps.step(
    "the LLM user message contains {string}",
    then_llm_user_message_contains,
  )
  |> steps.step(
    "the LLM system prompt contains {string}",
    then_llm_system_prompt_contains,
  )
  |> steps.step(
    "the LLM last call messages contain {string}",
    then_llm_last_call_messages_contain,
  )
}

// ---------------------------------------------------------------------------
// Step handlers
// ---------------------------------------------------------------------------

fn given_llm_text_response(
  ctx: StepContext,
) -> Result(dream_types.AssertionResult, String) {
  use text <- result_try(get_string(ctx.captures, 0))
  use system <- result_try(world.get(ctx.world, "system"))
  let sys: TestSystem = system
  fake_llm.script_text_response(sys.fake_llm, text)
  Ok(succeed())
}

fn given_llm_tool_call(
  ctx: StepContext,
) -> Result(dream_types.AssertionResult, String) {
  use tool_name <- result_try(get_string(ctx.captures, 0))
  use args_json_raw <- result_try(get_string(ctx.captures, 1))
  use system <- result_try(world.get(ctx.world, "system"))
  let sys: TestSystem = system
  // dream_test's {string} capture strips outer quotes but does NOT unescape
  // backslash sequences. Gherkin uses \" inside quoted strings, so we must
  // unescape \\" -> " and \\\\ -> \\ before passing to script_tool_call.
  let args_json =
    args_json_raw
    |> string.replace(each: "\\\"", with: "\"")
    |> string.replace(each: "\\\\", with: "\\")
  fake_llm.script_tool_call(sys.fake_llm, tool_name, args_json)
  Ok(succeed())
}

fn given_llm_error(
  ctx: StepContext,
) -> Result(dream_types.AssertionResult, String) {
  use reason <- result_try(get_string(ctx.captures, 0))
  use system <- result_try(world.get(ctx.world, "system"))
  let sys: TestSystem = system
  fake_llm.script_error(sys.fake_llm, reason)
  Ok(succeed())
}

fn given_llm_reasoning_forever(
  ctx: StepContext,
) -> Result(dream_types.AssertionResult, String) {
  use system <- result_try(world.get(ctx.world, "system"))
  let sys: TestSystem = system
  fake_llm.script_reasoning_forever(sys.fake_llm)
  Ok(succeed())
}

fn given_vision_description(
  ctx: StepContext,
) -> Result(dream_types.AssertionResult, String) {
  use text <- result_try(get_string(ctx.captures, 0))
  use system <- result_try(world.get(ctx.world, "system"))
  let sys: TestSystem = system
  fake_llm.script_chat_text_response(sys.fake_llm, text)
  Ok(succeed())
}

/// Assert that any recorded `stream_with_tools` call carried a user
/// message whose content contains the given substring. Proves vision
/// enrichment reached the tool-loop prompt.
fn then_llm_user_message_contains(
  ctx: StepContext,
) -> Result(dream_types.AssertionResult, String) {
  use expected <- result_try(get_string(ctx.captures, 0))
  use system <- result_try(world.get(ctx.world, "system"))
  let sys: TestSystem = system
  let calls = fake_llm.calls(sys.fake_llm)
  let combined =
    calls
    |> list.flat_map(fn(c) {
      list.filter_map(c.messages, fn(m) {
        case m {
          llm.UserMessage(content) -> Ok(content)
          llm.UserMessageWithImage(content, _) -> Ok(content)
          _ -> Error(Nil)
        }
      })
    })
    |> string.join("\n")
  combined
  |> should
  |> contain_string(expected)
  |> or_fail_with(
    "No user message across LLM calls contained: " <> expected,
  )
}

/// Assert that the system prompt in the latest LLM `stream_with_tools` call
/// contains the given substring. Proves domain context assembly injected the
/// AGENTS.md content into the prompt.
///
/// Polls for up to 2000ms since the brain processes messages asynchronously —
/// the LLM call may not have been recorded by the time this step runs.
fn then_llm_system_prompt_contains(
  ctx: StepContext,
) -> Result(dream_types.AssertionResult, String) {
  use expected <- result_try(get_string(ctx.captures, 0))
  use system <- result_try(world.get(ctx.world, "system"))
  let sys: TestSystem = system
  let combined = poll_for_system_prompt(sys.fake_llm, expected, 0, 2000)
  combined
  |> should
  |> contain_string(expected)
  |> or_fail_with(
    "No system message across LLM calls contained: " <> expected,
  )
}

/// Poll every 10ms until a system message containing `expected` appears in the
/// recorded LLM calls, or until `timeout_ms` elapses. Returns the combined
/// system message content (possibly not containing `expected` on timeout).
fn poll_for_system_prompt(
  fake: fake_llm.FakeLLM,
  expected: String,
  elapsed: Int,
  timeout_ms: Int,
) -> String {
  let calls = fake_llm.calls(fake)
  let combined =
    calls
    |> list.flat_map(fn(c) {
      list.filter_map(c.messages, fn(m) {
        case m {
          llm.SystemMessage(content) -> Ok(content)
          _ -> Error(Nil)
        }
      })
    })
    |> string.join("\n")
  case string.contains(combined, expected) || elapsed >= timeout_ms {
    True -> combined
    False -> {
      let _ = process.sleep(10)
      poll_for_system_prompt(fake, expected, elapsed + 10, timeout_ms)
    }
  }
}

/// Assert that the most-recent `stream_with_tools` call carried at least one
/// message (of any role) whose content contains the given substring.  Used to
/// verify that tool errors surfaced as `ToolResultMessage` entries in the next
/// LLM iteration.  Polls for up to 2000ms to allow async brain processing.
fn then_llm_last_call_messages_contain(
  ctx: StepContext,
) -> Result(dream_types.AssertionResult, String) {
  use expected <- result_try(get_string(ctx.captures, 0))
  use system <- result_try(world.get(ctx.world, "system"))
  let sys: TestSystem = system
  let combined = poll_for_any_message(sys.fake_llm, expected, 0, 2000)
  combined
  |> should
  |> contain_string(expected)
  |> or_fail_with(
    "No message in last LLM call contained: " <> expected,
  )
}

/// Poll every 10ms until any message in the latest LLM call contains
/// `expected`, or until `timeout_ms` elapses.
fn poll_for_any_message(
  fake: fake_llm.FakeLLM,
  expected: String,
  elapsed: Int,
  timeout_ms: Int,
) -> String {
  let calls = fake_llm.calls(fake)
  let last_call_messages = case list.last(calls) {
    Ok(c) -> c.messages
    Error(_) -> []
  }
  let combined =
    last_call_messages
    |> list.filter_map(fn(m) {
      case m {
        llm.UserMessage(content) -> Ok(content)
        llm.UserMessageWithImage(content, _) -> Ok(content)
        llm.AssistantMessage(content) -> Ok(content)
        llm.AssistantToolCallMessage(content, _) -> Ok(content)
        llm.SystemMessage(content) -> Ok(content)
        llm.ToolResultMessage(_, content) -> Ok(content)
      }
    })
    |> string.join("\n")
  case string.contains(combined, expected) || elapsed >= timeout_ms {
    True -> combined
    False -> {
      let _ = process.sleep(10)
      poll_for_any_message(fake, expected, elapsed + 10, timeout_ms)
    }
  }
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Thread a `Result` through a step body using `use` syntax.
fn result_try(
  r: Result(a, String),
  f: fn(a) -> Result(dream_types.AssertionResult, String),
) -> Result(dream_types.AssertionResult, String) {
  case r {
    Ok(v) -> f(v)
    Error(e) -> Error(e)
  }
}
