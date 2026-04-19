import features/steps/common_steps
import gleeunit/should

pub fn duration_ms_passthrough_test() {
  common_steps.duration_to_ms(500, "ms")
  |> should.equal(500)
}

pub fn duration_milliseconds_plural_test() {
  common_steps.duration_to_ms(100, "milliseconds")
  |> should.equal(100)
}

pub fn duration_seconds_test() {
  common_steps.duration_to_ms(3, "seconds")
  |> should.equal(3000)
}

pub fn duration_second_singular_test() {
  common_steps.duration_to_ms(1, "second")
  |> should.equal(1000)
}

pub fn duration_minutes_test() {
  common_steps.duration_to_ms(2, "minutes")
  |> should.equal(120_000)
}

pub fn duration_minute_singular_test() {
  common_steps.duration_to_ms(1, "minute")
  |> should.equal(60_000)
}

pub fn duration_fallthrough_test() {
  common_steps.duration_to_ms(42, "turns")
  |> should.equal(42)
}
