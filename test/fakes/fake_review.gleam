//// Fake implementation of `ReviewRunner` for tests. Records every call to
//// `run` / `skill_run` and increments spawn counters, but never actually
//// spawns LLM processes.
////
//// Usage:
////
////   let fake = fake_review.new()
////   let runner = fake_review.as_runner(fake)
////   // inject runner into Deps ...
////   fake_review.spawn_count(fake)       // -> Int (memory review count)
////   fake_review.skill_spawn_count(fake) // -> Int (skill review count)

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

/// One recorded call to `skill_run`.
pub type SkillCall {
  SkillCall(
    skill_review_interval: Int,
    domain_name: String,
    channel_id: String,
    discord_token: String,
    iteration_count: Int,
    new_iterations: Int,
    monitor_model: String,
    skills_dir: String,
  )
}

pub opaque type FakeReview {
  FakeReview(subject: process.Subject(Msg))
}

// ---------------------------------------------------------------------------
// Internal actor
// ---------------------------------------------------------------------------

type State {
  State(
    spawn_count: Int,
    calls: List(Call),
    skill_spawn_count: Int,
    skill_calls: List(SkillCall),
  )
}

type Msg {
  RecordCall(call: Call, reply: process.Subject(Int))
  GetSpawnCount(reply: process.Subject(Int))
  GetCalls(reply: process.Subject(List(Call)))
  RecordSkillCall(call: SkillCall, reply: process.Subject(Int))
  GetSkillSpawnCount(reply: process.Subject(Int))
  GetSkillCalls(reply: process.Subject(List(SkillCall)))
}

fn handle_message(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    RecordCall(call:, reply:) -> {
      let new_count = state.spawn_count + 1
      let new_state =
        State(
          ..state,
          spawn_count: new_count,
          calls: list.append(state.calls, [call]),
        )
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
    RecordSkillCall(call:, reply:) -> {
      let new_count = state.skill_spawn_count + 1
      let new_state =
        State(
          ..state,
          skill_spawn_count: new_count,
          skill_calls: list.append(state.skill_calls, [call]),
        )
      process.send(reply, 0)
      actor.continue(new_state)
    }
    GetSkillSpawnCount(reply:) -> {
      process.send(reply, state.skill_spawn_count)
      actor.continue(state)
    }
    GetSkillCalls(reply:) -> {
      process.send(reply, state.skill_calls)
      actor.continue(state)
    }
  }
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Create a new `FakeReview`. Use `as_runner` to get the injectable
/// `ReviewRunner`, and `spawn_count` / `calls` / `skill_spawn_count` /
/// `skill_calls` for assertions.
pub fn new() -> FakeReview {
  let builder =
    actor.new_with_initialiser(5000, fn(subject) {
      let state =
        State(spawn_count: 0, calls: [], skill_spawn_count: 0, skill_calls: [])
      Ok(actor.initialised(state) |> actor.returning(subject))
    })
    |> actor.on_message(handle_message)
  let assert Ok(started) = actor.start(builder)
  FakeReview(subject: started.data)
}

/// Return a `ReviewRunner` whose `run` / `skill_run` functions mirror the
/// real counter logic but record spawns instead of launching real LLM processes.
///
/// Memory review (`run`):
/// - If `review_interval == 0`: returns `turn_count + 1` (disabled, no record).
/// - If `new_count = turn_count + 1 >= review_interval`: records the call,
///   returns 0 (counter reset).
/// - Otherwise: returns `new_count` (counter incremented, no record).
///
/// Skill review (`skill_run`):
/// - If `skill_review_interval == 0`: returns `iteration_count + new_iterations`.
/// - If `new_count = iteration_count + new_iterations >= skill_review_interval`:
///   records the call, returns 0 (counter reset).
/// - Otherwise: returns `new_count`.
pub fn as_runner(fake: FakeReview) -> ReviewRunner {
  let subj = fake.subject
  ReviewRunner(
    run: fn(
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
    },
    skill_run: fn(
      skill_review_interval: Int,
      domain_name: String,
      channel_id: String,
      discord_token: String,
      _history: List(llm.Message),
      iteration_count: Int,
      new_iterations: Int,
      _paths: xdg.Paths,
      monitor_model: String,
      skills_dir: String,
    ) -> Int {
      case skill_review_interval {
        0 -> iteration_count + new_iterations
        interval -> {
          let new_count = iteration_count + new_iterations
          case new_count >= interval {
            False -> new_count
            True ->
              process.call(subj, 1000, fn(reply) {
                RecordSkillCall(
                  call: SkillCall(
                    skill_review_interval: skill_review_interval,
                    domain_name: domain_name,
                    channel_id: channel_id,
                    discord_token: discord_token,
                    iteration_count: iteration_count,
                    new_iterations: new_iterations,
                    monitor_model: monitor_model,
                    skills_dir: skills_dir,
                  ),
                  reply: reply,
                )
              })
          }
        }
      }
    },
  )
}

/// Return the number of times a memory review was spawned by this fake.
pub fn spawn_count(fake: FakeReview) -> Int {
  process.call(fake.subject, 1000, fn(reply) { GetSpawnCount(reply: reply) })
}

/// Return all recorded memory-review calls in the order they occurred.
pub fn calls(fake: FakeReview) -> List(Call) {
  process.call(fake.subject, 1000, fn(reply) { GetCalls(reply: reply) })
}

/// Return the number of times a skill review was spawned by this fake.
pub fn skill_spawn_count(fake: FakeReview) -> Int {
  process.call(fake.subject, 1000, fn(reply) {
    GetSkillSpawnCount(reply: reply)
  })
}

/// Return all recorded skill-review calls in the order they occurred.
pub fn skill_calls(fake: FakeReview) -> List(SkillCall) {
  process.call(fake.subject, 1000, fn(reply) { GetSkillCalls(reply: reply) })
}
