import aura/channel_actor
import aura/channel_supervisor
import gleam/erlang/process
import gleeunit/should

pub fn supervisor_returns_same_subject_for_same_channel_test() {
  let sup = channel_supervisor.start() |> should.be_ok
  let deps_a = channel_actor.test_deps("test-1", "fake-token")
  let sub1 =
    channel_supervisor.get_or_start(sup, "test-1", deps_a) |> should.be_ok
  let sub2 =
    channel_supervisor.get_or_start(sup, "test-1", deps_a) |> should.be_ok
  should.equal(sub1, sub2)
}

pub fn supervisor_returns_distinct_subjects_for_distinct_channels_test() {
  let sup = channel_supervisor.start() |> should.be_ok
  let sub_a =
    channel_supervisor.get_or_start(
      sup,
      "test-a",
      channel_actor.test_deps("test-a", "fake-token"),
    )
    |> should.be_ok
  let sub_b =
    channel_supervisor.get_or_start(
      sup,
      "test-b",
      channel_actor.test_deps("test-b", "fake-token"),
    )
    |> should.be_ok
  should.not_equal(sub_a, sub_b)
}

pub fn supervisor_restarts_dead_child_on_next_lookup_test() {
  let sup = channel_supervisor.start() |> should.be_ok
  let deps = channel_actor.test_deps("test-dead", "fake-token")
  let sub1 =
    channel_supervisor.get_or_start(sup, "test-dead", deps) |> should.be_ok
  let pid = process.subject_owner(sub1) |> should.be_ok

  process.kill(pid)
  process.sleep(10)

  let sub2 =
    channel_supervisor.get_or_start(sup, "test-dead", deps) |> should.be_ok
  let sub3 =
    channel_supervisor.get_or_start(sup, "test-dead", deps) |> should.be_ok

  should.not_equal(sub1, sub2)
  should.equal(sub2, sub3)
}
