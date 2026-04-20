import aura/llm
import aura/review
import aura/xdg

/// Dependency-injected wrapper around `review.maybe_spawn_review`.
/// Production uses the real implementation; tests substitute a fake that
/// records invocations and returns 0 without spawning real LLM processes.
pub type ReviewRunner {
  ReviewRunner(
    run: fn(
      Int,
      Bool,
      String,
      String,
      String,
      List(llm.Message),
      Int,
      xdg.Paths,
      String,
    ) ->
      Int,
  )
}

/// Production default — delegates directly to `review.maybe_spawn_review`.
pub fn default() -> ReviewRunner {
  ReviewRunner(run: review.maybe_spawn_review)
}
