//// Fake implementation of `ReviewRunner` for tests. Records every call to
//// `run` and increments a spawn counter, but never actually spawns LLM
//// processes. The `run` function always returns 0 (simulating a review
//// that was triggered and reset the counter).
////
//// Usage:
////
////   let fake = fake_review.new()
////   let runner = fake_review.as_runner(fake)
////   // inject runner into Deps ...
////   fake_review.spawn_count(fake) // -> Int

import aura/llm
import aura/review_runner.{type ReviewRunner, ReviewRunner}
import aura/xdg
import gleam/erlang/process
import gleam/list
import gleam/otp/actor

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// One recorded call to `run`.
pub type Call {
  Call(
    review_interval: Int,
    notify_on_review: Bool,
    domain_name: String,
    channel_id: String,
    discord_token: String,
    turn_count: Int,
    monitor_model: String,
  )
}

pub opaque type FakeReview {
  FakeReview(subject: process.Subject(Msg))
}

// ---------------------------------------------------------------------------
// Internal actor
// ---------------------------------------------------------------------------

type State {
  State(spawn_count: Int, calls: List(Call))
}

type Msg {
  RecordCall(call: Call, reply: process.Subject(Int))
  GetSpawnCount(reply: process.Subject(Int))
  GetCalls(reply: process.Subject(List(Call)))
}

fn handle_message(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    RecordCall(call:, reply:) -> {
      let new_count = state.spawn_count + 1
      let new_state =
        State(spawn_count: new_count, calls: list.append(state.calls, [call]))
      process.send(reply, 0)
      actor.continue(new_state)
    }
    GetSpawnCount(reply:) -> {
      process.send(reply, state.spawn_count)
      actor.continue(state)
    }
    GetCalls(reply:) -> {
      process.send(reply, state.calls)
      actor.continue(state)
    }
  }
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Create a new `FakeReview`. Use `as_runner` to get the injectable
/// `ReviewRunner`, and `spawn_count` / `calls` for assertions.
pub fn new() -> FakeReview {
  let builder =
    actor.new_with_initialiser(5000, fn(subject) {
      let state = State(spawn_count: 0, calls: [])
      Ok(actor.initialised(state) |> actor.returning(subject))
    })
    |> actor.on_message(handle_message)
  let assert Ok(started) = actor.start(builder)
  FakeReview(subject: started.data)
}

/// Return a `ReviewRunner` whose `run` function mirrors the real
/// `maybe_spawn_review` counter logic but records a spawn instead of
/// launching real LLM processes.
///
/// - If `review_interval == 0`: returns `turn_count + 1` (disabled, no record).
/// - If `new_count = turn_count + 1 >= review_interval`: records the call,
///   returns 0 (counter reset).
/// - Otherwise: returns `new_count` (counter incremented, no record).
pub fn as_runner(fake: FakeReview) -> ReviewRunner {
  let subj = fake.subject
  ReviewRunner(run: fn(
    review_interval: Int,
    notify_on_review: Bool,
    domain_name: String,
    channel_id: String,
    discord_token: String,
    _history: List(llm.Message),
    turn_count: Int,
    _paths: xdg.Paths,
    monitor_model: String,
  ) -> Int {
    case review_interval {
      0 -> turn_count + 1
      interval -> {
        let new_count = turn_count + 1
        case new_count >= interval {
          False -> new_count
          True ->
            process.call(subj, 1000, fn(reply) {
              RecordCall(
                call: Call(
                  review_interval: review_interval,
                  notify_on_review: notify_on_review,
                  domain_name: domain_name,
                  channel_id: channel_id,
                  discord_token: discord_token,
                  turn_count: turn_count,
                  monitor_model: monitor_model,
                ),
                reply: reply,
              )
            })
        }
      }
    }
  })
}

/// Return the number of times `run` was called on this fake.
pub fn spawn_count(fake: FakeReview) -> Int {
  process.call(fake.subject, 1000, fn(reply) { GetSpawnCount(reply: reply) })
}

/// Return all recorded calls in the order they occurred.
pub fn calls(fake: FakeReview) -> List(Call) {
  process.call(fake.subject, 1000, fn(reply) { GetCalls(reply: reply) })
}
