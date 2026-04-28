import aura/blather/thread_channel
import gleam/option
import gleeunit/should

pub fn make_combines_parent_and_thread_ids_test() {
  thread_channel.make("ch-1", "msg-2")
  |> should.equal("ch-1#thread:msg-2")
}

pub fn parse_thread_channel_returns_parent_and_thread_test() {
  thread_channel.parse("ch-1#thread:msg-2")
  |> should.equal(option.Some(#("ch-1", "msg-2")))
}

pub fn parse_normal_channel_returns_none_test() {
  thread_channel.parse("ch-1")
  |> should.equal(option.None)
}

pub fn parent_returns_parent_for_thread_channel_test() {
  thread_channel.parent("ch-1#thread:msg-2")
  |> should.equal(Ok("ch-1"))
}

pub fn parent_errors_for_normal_channel_test() {
  thread_channel.parent("ch-1")
  |> should.be_error
}
