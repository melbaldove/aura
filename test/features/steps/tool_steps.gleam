import aura/skill
import dream_test/gherkin/steps.{type StepContext, type StepRegistry, get_string}
import dream_test/gherkin/world
import dream_test/matchers.{succeed}
import dream_test/types as dream_types
import fakes/fake_skill_runner.{SkillInvocation}
import gleam/int
import gleam/list
import test_harness.{type TestSystem}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Register all tool step definitions onto the provided registry.
pub fn register(reg: StepRegistry) -> StepRegistry {
  reg
  |> steps.step(
    "skill {string} will return stdout {string}",
    given_skill_stdout,
  )
  |> steps.step(
    "skill {string} will fail with stderr {string}",
    given_skill_failure,
  )
  |> steps.step("skill {string} was invoked", then_skill_invoked)
}

// ---------------------------------------------------------------------------
// Step handlers
// ---------------------------------------------------------------------------

fn given_skill_stdout(
  ctx: StepContext,
) -> Result(dream_types.AssertionResult, String) {
  use name <- result_try(get_string(ctx.captures, 0))
  use text <- result_try(get_string(ctx.captures, 1))
  use system <- result_try(world.get(ctx.world, "system"))
  let sys: TestSystem = system
  fake_skill_runner.script_for(
    sys.fake_skill_runner,
    name,
    skill.SkillResult(exit_code: 0, stdout: text, stderr: ""),
  )
  Ok(succeed())
}

fn given_skill_failure(
  ctx: StepContext,
) -> Result(dream_types.AssertionResult, String) {
  use name <- result_try(get_string(ctx.captures, 0))
  use text <- result_try(get_string(ctx.captures, 1))
  use system <- result_try(world.get(ctx.world, "system"))
  let sys: TestSystem = system
  fake_skill_runner.script_for(
    sys.fake_skill_runner,
    name,
    skill.SkillResult(exit_code: 1, stdout: "", stderr: text),
  )
  Ok(succeed())
}

fn then_skill_invoked(
  ctx: StepContext,
) -> Result(dream_types.AssertionResult, String) {
  use name <- result_try(get_string(ctx.captures, 0))
  use system <- result_try(world.get(ctx.world, "system"))
  let sys: TestSystem = system
  let invocations = fake_skill_runner.invocations(sys.fake_skill_runner)
  let matches =
    list.any(invocations, fn(inv) {
      case inv {
        SkillInvocation(n, _) if n == name -> True
        _ -> False
      }
    })
  case matches {
    True -> Ok(succeed())
    False ->
      Error(
        "expected skill '"
        <> name
        <> "' to be invoked, got "
        <> int.to_string(list.length(invocations))
        <> " other invocations",
      )
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
