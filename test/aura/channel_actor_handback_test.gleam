/// Focused integration tests for the HandleHandback path in channel_actor.
///
/// These tests go through the full channel_actor path (brain routing →
/// channel_actor HandleHandback → start_turn → LLM call) to verify:
///   1. The handback system message is injected into the LLM call.
///   2. finalize_turn saves with author_id="aura", author_name="Aura".
import aura/acp/flare_manager
import aura/acp/monitor as acp_monitor
import aura/acp/types as acp_types
import aura/brain
import aura/channel_actor
import aura/llm
import fakes/fake_llm
import gleam/erlang/process
import gleam/list
import gleam/option
import gleam/string
import gleeunit/should
import poll
import test_harness

pub fn handback_injects_system_message_into_turn_test() {
  // Fresh system with "flare-thread-1" on the allowlist so brain routes it
  // through channel_actor.
  let sys = test_harness.fresh_system()

  // Register a flare so brain can look it up by session_name and get thread_id.
  flare_manager.register_for_test(
    sys.acp_subject,
    flare_manager.FlareRecord(
      id: "f1",
      label: "fix-build",
      status: flare_manager.Active,
      domain: "cm2",
      thread_id: "flare-thread-1",
      original_prompt: "make the build pass",
      execution_json: "{}",
      triggers_json: "[]",
      tools_json: "[]",
      workspace: "",
      session_id: "",
      session_name: "fix-build",
      handle: option.None,
      started_at_ms: 0,
      updated_at_ms: 0,
      awaiting_response: False,
    ),
  )

  // Script the LLM to reply to the handback turn.
  fake_llm.script_text_response(sys.fake_llm, "handback acknowledged")

  // Inject an AcpCompleted event with non-empty result_text. Brain's
  // handle_acp_event will look up the flare, get thread_id="flare-thread-1",
  // and send HandleHandback to the channel_actor for that thread.
  process.send(
    sys.brain_subject,
    brain.AcpEvent(acp_monitor.AcpCompleted(
      session_name: "fix-build",
      domain: "cm2",
      report: acp_types.AcpReport(
        outcome: acp_types.Clean,
        files_changed: [],
        decisions: "",
        tests: "",
        blockers: "",
        anchor: "",
      ),
      result_text: "build passed",
    )),
  )

  // Wait for the LLM call to appear (up to 3s).
  let _ = poll.poll_until(fn() { fake_llm.calls(sys.fake_llm) != [] }, 3000)

  let all_calls = fake_llm.calls(sys.fake_llm)
  { all_calls != [] } |> should.be_true

  // Collect all system messages sent across all LLM calls.
  let system_messages =
    all_calls
    |> list.flat_map(fn(c) {
      list.filter_map(c.messages, fn(m) {
        case m {
          llm.SystemMessage(s) -> Ok(s)
          _ -> Error(Nil)
        }
      })
    })
    |> string.join("\n")

  // The handback system message must be present with the correct format.
  string.contains(system_messages, "[Flare reported back: \"fix-build\"]")
  |> should.be_true

  string.contains(system_messages, "build passed")
  |> should.be_true

  test_harness.teardown(sys)
}

pub fn handback_queued_when_turn_in_flight_test() {
  // When a turn is in flight, HandleHandback must be queued.
  let state = channel_actor.initial_state_for_test("ch1")
  let busy = channel_actor.with_fake_in_flight_turn(state)
  let #(new_state, effects) =
    channel_actor.transition(
      busy,
      channel_actor.HandleHandback(
        flare_id: "f1",
        session_name: "fix-build",
        result: "done",
      ),
    )

  list.length(new_state.queue) |> should.equal(1)
  effects |> should.equal([])
}

pub fn finalize_turn_handback_uses_aura_author_test() {
  // Verify finalize_turn emits DbSaveExchange with author_id="aura" and
  // author_name="Aura" for HandbackTurn.
  let state = channel_actor.initial_state_for_test("ch1")
  let handback_state = channel_actor.with_fake_handback_turn(state, "f1")
  let #(_new_state, effects) =
    channel_actor.transition(
      handback_state,
      channel_actor.StreamComplete("handback reply", "[]", 0),
    )

  let db_save_effect =
    list.find(effects, fn(e) {
      case e {
        channel_actor.DbSaveExchange(_, _, _, _) -> True
        _ -> False
      }
    })

  case db_save_effect {
    Ok(channel_actor.DbSaveExchange(_, author_id, author_name, _)) -> {
      author_id |> should.equal("aura")
      author_name |> should.equal("Aura")
    }
    _ -> should.fail()
  }
}
