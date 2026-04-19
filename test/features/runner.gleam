/// BDD feature runner — discovers all `.feature` files under `test/features/`,
/// registers all step modules, excludes `@slow` and `@wip` scenarios, and runs
/// with a BDD results reporter.
///
/// Invoke with:
///   gleam run -m features/runner
import dream_test/gherkin/discover
import dream_test/gherkin/steps
import dream_test/reporters/bdd
import dream_test/reporters/progress
import dream_test/runner
import features/steps/common_steps
import features/steps/llm_steps
import features/steps/tool_steps
import gleam/list

pub fn main() {
  let registry =
    steps.new()
    |> common_steps.register
    |> llm_steps.register
    |> tool_steps.register

  let suite =
    discover.features("test/features/**/*.feature")
    |> discover.with_registry(registry)
    |> discover.to_suite("aura e2e features")

  runner.new([suite])
  |> runner.filter_tests(exclude_slow_and_wip)
  |> runner.progress_reporter(progress.new())
  |> runner.results_reporters([bdd.new()])
  |> runner.exit_on_failure()
  |> runner.run()
}

fn exclude_slow_and_wip(info: runner.TestInfo) -> Bool {
  !list.contains(info.tags, "slow") && !list.contains(info.tags, "wip")
}
