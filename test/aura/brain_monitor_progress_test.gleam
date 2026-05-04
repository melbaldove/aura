import aura/acp/flare_manager
import aura/acp/monitor as acp_monitor
import aura/brain
import aura/time
import fakes/fake_discord
import fakes/fake_llm
import gleam/erlang/process
import gleam/list
import gleam/option
import gleam/string
import gleeunit/should
import poll
import test_harness

const thread_id = "flare-thread"

const session_name = "acp-cm2-f-test"

fn register_active_flare(sys: test_harness.TestSystem) -> Nil {
  let now = time.now_ms()
  flare_manager.register_for_test(
    sys.acp_subject,
    flare_manager.FlareRecord(
      id: "f-test",
      label: "scope report work",
      status: flare_manager.Active,
      domain: "cm2",
      thread_id: thread_id,
      original_prompt: "scope report work",
      execution_json: "",
      triggers_json: "",
      tools_json: "",
      workspace: "",
      session_id: "session-id",
      session_name: session_name,
      handle: option.None,
      started_at_ms: now,
      updated_at_ms: now,
      awaiting_response: True,
    ),
  )
}

fn progress(summary: String) -> brain.BrainMessage {
  brain.AcpEvent(acp_monitor.AcpProgress(
    session_name,
    "cm2",
    "Report scoping",
    "Working",
    summary,
    False,
  ))
}

fn summary(current: String) -> String {
  "Status: Working\nDone: found report generators\nCurrent: "
  <> current
  <> "\nNeeds input: none\nNext: continue mapping"
}

fn sent_contains(sys: test_harness.TestSystem, needle: String) -> Bool {
  fake_discord.all_sent_to(sys.fake_discord, thread_id)
  |> list.any(fn(message) { string.contains(message, needle) })
}

pub fn acp_progress_edits_existing_monitor_when_thread_is_quiet_test() {
  let sys = test_harness.fresh_system()
  register_active_flare(sys)

  process.send(sys.brain_subject, progress(summary("reading samples")))
  poll.poll_until(
    fn() {
      list.length(fake_discord.all_sent_to(sys.fake_discord, thread_id)) == 1
    },
    2000,
  )
  |> should.be_true

  process.send(sys.brain_subject, progress(summary("tracing dispatch")))
  let _ =
    fake_discord.assert_latest_contains(
      sys.fake_discord,
      thread_id,
      "tracing dispatch",
      2000,
    )

  fake_discord.all_sent_to(sys.fake_discord, thread_id)
  |> list.length
  |> should.equal(1)

  test_harness.teardown(sys)
}

pub fn acp_progress_resurfaces_after_user_chatter_then_waits_for_more_chatter_test() {
  let sys = test_harness.fresh_system()
  register_active_flare(sys)

  process.send(sys.brain_subject, progress(summary("reading samples")))
  poll.poll_until(
    fn() {
      list.length(fake_discord.all_sent_to(sys.fake_discord, thread_id)) == 1
    },
    2000,
  )
  |> should.be_true

  fake_llm.script_text_response(sys.fake_llm, "chat reply")
  process.send(
    sys.brain_subject,
    brain.HandleMessage(test_harness.incoming(thread_id, "still here")),
  )
  let _ =
    fake_discord.assert_latest_contains(
      sys.fake_discord,
      thread_id,
      "chat reply",
      3000,
    )

  process.send(sys.brain_subject, progress(summary("tracing queue dispatch")))
  poll.poll_until(
    fn() { sent_contains(sys, "Progress: tracing queue dispatch") },
    2000,
  )
  |> should.be_true

  let sent_after_resurface =
    fake_discord.all_sent_to(sys.fake_discord, thread_id) |> list.length

  process.send(sys.brain_subject, progress(summary("finalizing mapping")))
  let _ =
    fake_discord.assert_latest_contains(
      sys.fake_discord,
      thread_id,
      "finalizing mapping",
      2000,
    )

  fake_discord.all_sent_to(sys.fake_discord, thread_id)
  |> list.length
  |> should.equal(sent_after_resurface)

  test_harness.teardown(sys)
}
