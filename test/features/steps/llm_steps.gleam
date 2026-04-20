import aura/llm
import dream_test/gherkin/steps.{type StepContext, type StepRegistry, get_int, get_string}
import dream_test/gherkin/world
import dream_test/matchers.{contain_string, or_fail_with, should, succeed}
import dream_test/types as dream_types  // AssertionResult used in handler return types
import fakes/fake_llm
import gleam/list
import gleam/string
import poll
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
  // Workaround: dream_test's .feature parser mangles {string} captures
  // that contain many backslash-escaped quotes. Specialized steps that
  // take plain scalar values and build JSON server-side sidestep the
  // issue. UPSTREAM_CANDIDATE: fix or document escape handling in dream_test.
  |> steps.step(
    "the LLM will call run_skill with name {string} and args {string}",
    given_llm_run_skill_tool_call,
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
  |> steps.step(
    "the LLM will stream {int} deltas of {int} characters each",
    given_llm_stream_deltas,
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

fn given_llm_run_skill_tool_call(
  ctx: StepContext,
) -> Result(dream_types.AssertionResult, String) {
  use name <- result_try(get_string(ctx.captures, 0))
  use args <- result_try(get_string(ctx.captures, 1))
  use system <- result_try(world.get(ctx.world, "system"))
  let sys: TestSystem = system
  let args_json =
    "{\"name\":\""
    <> name
    <> "\",\"args\":\""
    <> args
    <> "\"}"
  fake_llm.script_tool_call(sys.fake_llm, "run_skill", args_json)
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

/// Script `delta_count` Delta events, each of `char_count` repeated "a"
/// characters, followed by a Complete carrying the full accumulated content.
/// This drives enough streamed content to trigger multiple progressive edits
/// in brain's `collect_stream_loop` (which fires every 150 chars).
fn given_llm_stream_deltas(
  ctx: StepContext,
) -> Result(dream_types.AssertionResult, String) {
  use delta_count <- result_try(get_int(ctx.captures, 0))
  use char_count <- result_try(get_int(ctx.captures, 1))
  use system <- result_try(world.get(ctx.world, "system"))
  let sys: TestSystem = system
  let delta_text = string.repeat("a", char_count)
  let deltas = list.repeat(fake_llm.Delta(text: delta_text), delta_count)
  let full_content = string.repeat(delta_text, delta_count)
  let events =
    list.append(deltas, [
      fake_llm.Complete(
        content: full_content,
        tool_calls_json: "[]",
        prompt_tokens: 0,
      ),
    ])
  fake_llm.script(sys.fake_llm, events)
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
  let check = fn() {
    string.contains(combined_system_prompts(sys.fake_llm), expected)
  }
  let _ = poll.poll_until(check, 2000)
  combined_system_prompts(sys.fake_llm)
  |> should
  |> contain_string(expected)
  |> or_fail_with(
    "No system message across LLM calls contained: " <> expected,
  )
}

fn combined_system_prompts(fake: fake_llm.FakeLLM) -> String {
  fake_llm.calls(fake)
  |> list.flat_map(fn(c) {
    list.filter_map(c.messages, fn(m) {
      case m {
        llm.SystemMessage(content) -> Ok(content)
        _ -> Error(Nil)
      }
    })
  })
  |> string.join("\n")
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
  let check = fn() {
    string.contains(last_call_combined(sys.fake_llm), expected)
  }
  let _ = poll.poll_until(check, 2000)
  last_call_combined(sys.fake_llm)
  |> should
  |> contain_string(expected)
  |> or_fail_with(
    "No message in last LLM call contained: " <> expected,
  )
}

fn last_call_combined(fake: fake_llm.FakeLLM) -> String {
  let last_call_messages = case list.last(fake_llm.calls(fake)) {
    Ok(c) -> c.messages
    Error(_) -> []
  }
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
