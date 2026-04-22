import gleam/int

/// Exponential backoff with cap.
///
/// `compute(0, base: 1000, cap: 60_000)` = 1000
/// `compute(1, base: 1000, cap: 60_000)` = 2000
/// `compute(2, base: 1000, cap: 60_000)` = 4000
/// ... doubles each step until capped at `cap`.
///
/// Negative attempts clamp to 0. Attempts above 20 clamp to 20 to avoid
/// integer blowup in the shift — the cap will apply well before then.
pub fn compute(attempt: Int, base base: Int, cap cap: Int) -> Int {
  let shift = int.clamp(attempt, min: 0, max: 20)
  int.min(base * int.bitwise_shift_left(1, shift), cap)
}
