import dream_test/gherkin/steps.{type StepContext, type StepRegistry, get_string}
import dream_test/gherkin/world
import dream_test/matchers.{succeed}
import dream_test/types as dream_types  // AssertionResult used in handler return types
import fakes/fake_llm
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
  use args_json <- result_try(get_string(ctx.captures, 1))
  use system <- result_try(world.get(ctx.world, "system"))
  let sys: TestSystem = system
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
