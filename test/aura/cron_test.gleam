import aura/cron.{Any, CronExpr, Exact, Step}
import gleeunit/should

// --- Parse tests ---

pub fn parse_all_stars_test() {
  cron.parse("* * * * *")
  |> should.be_ok
  |> should.equal(CronExpr(
    minute: Any,
    hour: Any,
    day_of_month: Any,
    month: Any,
    day_of_week: Any,
  ))
}

pub fn parse_specific_values_test() {
  cron.parse("30 9 1 * *")
  |> should.be_ok
  |> should.equal(CronExpr(
    minute: Exact(30),
    hour: Exact(9),
    day_of_month: Exact(1),
    month: Any,
    day_of_week: Any,
  ))
}

pub fn parse_step_test() {
  cron.parse("*/5 * * * *")
  |> should.be_ok
  |> should.equal(CronExpr(
    minute: Step(5),
    hour: Any,
    day_of_month: Any,
    month: Any,
    day_of_week: Any,
  ))
}

pub fn parse_too_few_fields_test() {
  cron.parse("* * *")
  |> should.be_error
}

pub fn parse_non_numeric_test() {
  cron.parse("abc * * * *")
  |> should.be_error
}

// --- Matches tests ---

pub fn matches_all_stars_test() {
  let assert Ok(expr) = cron.parse("* * * * *")
  cron.matches(expr, minute: 23, hour: 14, day: 7, month: 3, weekday: 2)
  |> should.be_true
}

pub fn matches_specific_minute_hour_test() {
  let assert Ok(expr) = cron.parse("30 9 * * *")

  // 9:30 matches
  cron.matches(expr, minute: 30, hour: 9, day: 1, month: 1, weekday: 0)
  |> should.be_true

  // 9:31 doesn't match
  cron.matches(expr, minute: 31, hour: 9, day: 1, month: 1, weekday: 0)
  |> should.be_false

  // 10:30 doesn't match
  cron.matches(expr, minute: 30, hour: 10, day: 1, month: 1, weekday: 0)
  |> should.be_false
}

pub fn matches_step_5_test() {
  let assert Ok(expr) = cron.parse("*/5 * * * *")

  // 0, 5, 10 match
  cron.matches(expr, minute: 0, hour: 0, day: 1, month: 1, weekday: 0)
  |> should.be_true
  cron.matches(expr, minute: 5, hour: 0, day: 1, month: 1, weekday: 0)
  |> should.be_true
  cron.matches(expr, minute: 10, hour: 0, day: 1, month: 1, weekday: 0)
  |> should.be_true

  // 3 doesn't match
  cron.matches(expr, minute: 3, hour: 0, day: 1, month: 1, weekday: 0)
  |> should.be_false
}

pub fn matches_step_15_test() {
  let assert Ok(expr) = cron.parse("*/15 * * * *")

  // 0, 15, 30, 45 match
  cron.matches(expr, minute: 0, hour: 0, day: 1, month: 1, weekday: 0)
  |> should.be_true
  cron.matches(expr, minute: 15, hour: 0, day: 1, month: 1, weekday: 0)
  |> should.be_true
  cron.matches(expr, minute: 30, hour: 0, day: 1, month: 1, weekday: 0)
  |> should.be_true
  cron.matches(expr, minute: 45, hour: 0, day: 1, month: 1, weekday: 0)
  |> should.be_true

  // 7 doesn't match
  cron.matches(expr, minute: 7, hour: 0, day: 1, month: 1, weekday: 0)
  |> should.be_false
}

pub fn matches_day_of_month_test() {
  let assert Ok(expr) = cron.parse("0 9 1 * *")

  // 1st matches
  cron.matches(expr, minute: 0, hour: 9, day: 1, month: 1, weekday: 0)
  |> should.be_true

  // 15th doesn't match
  cron.matches(expr, minute: 0, hour: 9, day: 15, month: 1, weekday: 0)
  |> should.be_false
}

pub fn matches_day_of_week_test() {
  let assert Ok(expr) = cron.parse("0 9 * * 1")

  // Monday (1) matches
  cron.matches(expr, minute: 0, hour: 9, day: 1, month: 1, weekday: 1)
  |> should.be_true

  // Tuesday (2) doesn't match
  cron.matches(expr, minute: 0, hour: 9, day: 1, month: 1, weekday: 2)
  |> should.be_false
}

pub fn matches_month_test() {
  let assert Ok(expr) = cron.parse("0 0 1 6 *")

  // June matches
  cron.matches(expr, minute: 0, hour: 0, day: 1, month: 6, weekday: 0)
  |> should.be_true

  // July doesn't match
  cron.matches(expr, minute: 0, hour: 0, day: 1, month: 7, weekday: 0)
  |> should.be_false
}
