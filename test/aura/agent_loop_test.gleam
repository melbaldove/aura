import aura/agent_loop
import aura/llm
import gleam/dict
import gleam/list
import gleam/string
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

fn initial_state() -> agent_loop.LoopState {
  agent_loop.new_state([])
}

pub fn stream_delta_accumulates_content_test() {
  let state = initial_state()
  let #(next, actions) = agent_loop.step(state, agent_loop.StreamDelta("Hel"))
  next.accumulated_content |> should.equal("Hel")
  actions |> should.equal([])
}

pub fn stream_complete_no_tools_finalizes_test() {
  let state = initial_state()
  let #(_next, actions) =
    agent_loop.step(state, agent_loop.StreamComplete("hello", "[]"))
  actions |> should.equal([agent_loop.Finalize("hello")])
}

pub fn stream_complete_with_tools_spawns_first_tool_test() {
  let state = initial_state()
  let tool_call = llm.ToolCall(id: "c1", name: "read_file", arguments: "{}")
  let json = "[{\"id\":\"c1\",\"name\":\"read_file\",\"arguments\":\"{}\"}]"
  let #(_next, actions) =
    agent_loop.step(state, agent_loop.StreamComplete("", json))
  actions |> should.equal([agent_loop.SpawnTool(tool_call)])
}

fn state_with_calls(calls: List(llm.ToolCall)) -> agent_loop.LoopState {
  agent_loop.LoopState(
    messages: [],
    iteration: 0,
    accumulated_content: "",
    accumulated_tool_calls: calls,
    pending_tool_results: dict.new(),
    traces: [],
    stream_retry_count: 0,
    capabilities: [],
    max_iterations: 80,
    max_stream_retries: 3,
  )
}

pub fn tool_result_spawns_next_pending_tool_test() {
  let calls = [
    llm.ToolCall(id: "c1", name: "a", arguments: "{}"),
    llm.ToolCall(id: "c2", name: "b", arguments: "{}"),
  ]
  let state = state_with_calls(calls)
  let #(next, actions) =
    agent_loop.step(state, agent_loop.ToolResult("c1", "ok", False))
  dict.size(next.pending_tool_results) |> should.equal(1)
  case actions {
    [agent_loop.SpawnTool(call)] -> call.id |> should.equal("c2")
    _ -> should.fail()
  }
}

pub fn tool_result_all_resolved_spawns_next_stream_test() {
  let calls = [
    llm.ToolCall(id: "c1", name: "a", arguments: "{}"),
    llm.ToolCall(id: "c2", name: "b", arguments: "{}"),
  ]
  let state = state_with_calls(calls)
  let #(next, _actions) =
    agent_loop.step(state, agent_loop.ToolResult("c1", "ok1", False))
  // c1 resolved; c2 pending → next stream only after c2
  let #(next2, actions2) =
    agent_loop.step(next, agent_loop.ToolResult("c2", "ok2", False))
  next2.iteration |> should.equal(1)
  case actions2 {
    [agent_loop.SpawnStream(messages)] ->
      list.filter(messages, fn(m) {
        case m {
          llm.ToolResultMessage(..) -> True
          _ -> False
        }
      })
      |> list.length
      |> should.equal(2)
    _ -> should.fail()
  }
}

pub fn tool_result_at_max_iterations_fails_test() {
  let calls = [llm.ToolCall(id: "c1", name: "a", arguments: "{}")]
  let state =
    agent_loop.LoopState(
      messages: [],
      iteration: 79,
      accumulated_content: "",
      accumulated_tool_calls: calls,
      pending_tool_results: dict.new(),
      traces: [],
      stream_retry_count: 0,
      capabilities: [],
      max_iterations: 80,
      max_stream_retries: 3,
    )
  let #(_next, actions) =
    agent_loop.step(state, agent_loop.ToolResult("c1", "ok", False))
  case actions {
    [agent_loop.Fail(reason)] ->
      reason |> string.contains("exceeded maximum iterations") |> should.be_true
    _ -> should.fail()
  }
}

pub fn stream_error_retries_then_fails_test() {
  let state = agent_loop.new_state([llm.UserMessage("hi")])
  let #(state2, actions) =
    agent_loop.step(state, agent_loop.StreamError("boom"))
  state2.stream_retry_count |> should.equal(1)
  case actions {
    [agent_loop.RetryStream(messages, backoff)] -> {
      backoff |> should.equal(0)
      messages |> should.equal([llm.UserMessage("hi")])
    }
    _ -> should.fail()
  }
  // retry at count 1 → backoff 500
  let #(state3, actions3) =
    agent_loop.step(
      agent_loop.LoopState(..state2, stream_retry_count: 1),
      agent_loop.StreamError("boom"),
    )
  case actions3 {
    [agent_loop.RetryStream(_, backoff)] -> backoff |> should.equal(500)
    _ -> should.fail()
  }
  // retry at count 2 → backoff 2000
  let #(state4, actions4) =
    agent_loop.step(
      agent_loop.LoopState(..state3, stream_retry_count: 2),
      agent_loop.StreamError("boom"),
    )
  case actions4 {
    [agent_loop.RetryStream(_, backoff)] -> backoff |> should.equal(2000)
    _ -> should.fail()
  }
  // retry at count 3 → Fail
  let #(_state5, actions5) =
    agent_loop.step(
      agent_loop.LoopState(..state4, stream_retry_count: 3),
      agent_loop.StreamError("boom"),
    )
  case actions5 {
    [agent_loop.Fail(reason)] ->
      reason |> string.contains("boom") |> should.be_true
    _ -> should.fail()
  }
}

pub fn capability_blocked_tool_returns_error_immediately_test() {
  let state =
    agent_loop.with_capabilities(agent_loop.new_state([]), [
      "read_file",
      "browser",
    ])
  let #(next, actions) =
    agent_loop.step(
      state,
      agent_loop.StreamComplete(
        "",
        "[{\"id\":\"c1\",\"name\":\"shell\",\"arguments\":\"{}\"}]",
      ),
    )
  // The blocked tool records an error trace and never spawns as a tool.
  case list.find(next.traces, fn(trace) { trace.name == "shell" }) {
    Ok(trace) -> {
      trace.is_error |> should.equal(True)
      trace.result |> string.contains("capability") |> should.be_true
    }
    Error(_) -> should.fail()
  }
  // Once every call is resolved the batch continues with the next stream.
  case actions {
    [agent_loop.SpawnStream(messages)] ->
      list.filter(messages, fn(m) {
        case m {
          llm.ToolResultMessage(id, content) ->
            id == "c1" && string.contains(content, "capability")
          _ -> False
        }
      })
      |> list.length
      |> should.equal(1)
    _ -> should.fail()
  }
}

pub fn capability_check_empty_allows_all_test() {
  agent_loop.check_capability([], "shell")
  |> should.equal(Ok(Nil))
}

pub fn capability_check_allowed_test() {
  agent_loop.check_capability(["browser"], "browser")
  |> should.equal(Ok(Nil))
}

pub fn capability_check_blocked_test() {
  case agent_loop.check_capability(["browser"], "shell") {
    Error(message) ->
      message |> string.contains("capability") |> should.be_true
    Ok(_) -> should.fail()
  }
}

pub fn capability_blocked_then_allowed_batch_spawns_next_tool_test() {
  // Batch [blocked, allowed]: the blocked call records an error trace and the
  // batch continues by spawning the allowed tool.
  let state = agent_loop.with_capabilities(agent_loop.new_state([]), [
    "read_file",
  ])
  let json =
    "[{\"id\":\"c1\",\"name\":\"shell\",\"arguments\":\"{}\"},{\"id\":\"c2\",\"name\":\"read_file\",\"arguments\":\"{}\"}]"
  let #(next, actions) =
    agent_loop.step(state, agent_loop.StreamComplete("", json))
  // The blocked shell call produced an error trace.
  list.any(next.traces, fn(t) { t.name == "shell" && t.is_error })
  |> should.be_true
  // The allowed read_file call is spawned next.
  case actions {
    [agent_loop.SpawnTool(call)] -> call.name |> should.equal("read_file")
    _ -> should.fail()
  }
}
