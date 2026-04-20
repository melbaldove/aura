import aura/clients/skill_runner.{type SkillRunner, SkillRunner}
import aura/skill
import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/list
import gleam/otp/actor

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

pub type SkillInvocation {
  SkillInvocation(name: String, args: List(String))
}

pub opaque type FakeSkillRunner {
  FakeSkillRunner(subject: process.Subject(Msg))
}

// ---------------------------------------------------------------------------
// Internal actor types
// ---------------------------------------------------------------------------

type State {
  State(
    scripts: Dict(String, List(skill.SkillResult)),
    invocations: List(SkillInvocation),
  )
}

type Msg {
  PushScript(skill_name: String, result: skill.SkillResult)
  Pop(
    name: String,
    args: List(String),
    reply: process.Subject(Result(skill.SkillResult, String)),
  )
  GetInvocations(reply: process.Subject(List(SkillInvocation)))
}

// ---------------------------------------------------------------------------
// Actor handler
// ---------------------------------------------------------------------------

fn handle_message(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    PushScript(skill_name:, result:) -> {
      let existing =
        dict.get(state.scripts, skill_name)
        |> unwrap_or([])
      let updated =
        dict.insert(state.scripts, skill_name, list.append(existing, [result]))
      actor.continue(State(scripts: updated, invocations: state.invocations))
    }

    Pop(name:, args:, reply:) -> {
      let invocation = SkillInvocation(name: name, args: args)
      let new_invocations = [invocation, ..state.invocations]
      case dict.get(state.scripts, name) {
        Ok([next, ..rest]) -> {
          let updated = dict.insert(state.scripts, name, rest)
          process.send(reply, Ok(next))
          actor.continue(State(scripts: updated, invocations: new_invocations))
        }
        _ -> {
          process.send(reply, Error("no script for skill " <> name))
          actor.continue(State(
            scripts: state.scripts,
            invocations: new_invocations,
          ))
        }
      }
    }

    GetInvocations(reply:) -> {
      process.send(reply, list.reverse(state.invocations))
      actor.continue(state)
    }
  }
}

fn unwrap_or(r: Result(a, b), default: a) -> a {
  case r {
    Ok(v) -> v
    Error(_) -> default
  }
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Create a new fake skill runner. Returns a `#(FakeSkillRunner, SkillRunner)`
/// pair — use `FakeSkillRunner` for scripting and assertions, inject
/// `SkillRunner` into code under test.
pub fn new() -> #(FakeSkillRunner, SkillRunner) {
  let builder =
    actor.new_with_initialiser(5000, fn(subject) {
      let state = State(scripts: dict.new(), invocations: [])
      Ok(actor.initialised(state) |> actor.returning(subject))
    })
    |> actor.on_message(handle_message)

  let assert Ok(started) = actor.start(builder)
  let subj = started.data
  let fake = FakeSkillRunner(subject: subj)

  let runner =
    SkillRunner(
      invoke: fn(
        skill_info: skill.SkillInfo,
        args: List(String),
        _timeout_ms: Int,
      ) {
        process.call(subj, 1000, fn(reply) {
          Pop(name: skill_info.name, args: args, reply: reply)
        })
      },
    )

  #(fake, runner)
}

/// Push a scripted result onto the queue for `skill_name`. Results are
/// consumed FIFO — the first scripted result is returned on the first call,
/// the second on the second, etc.
pub fn script_for(
  fake: FakeSkillRunner,
  skill_name: String,
  result: skill.SkillResult,
) -> Nil {
  process.send(fake.subject, PushScript(skill_name: skill_name, result: result))
}

/// Return every recorded invocation in the order they occurred.
pub fn invocations(fake: FakeSkillRunner) -> List(SkillInvocation) {
  process.call(fake.subject, 1000, fn(reply) { GetInvocations(reply: reply) })
}
