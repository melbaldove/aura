import aura/conversation
import aura/llm
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}

/// Reusable agent-loop engine (ADR 039). Pure decision logic for the
/// model-tool iteration: ordering, limits, retry, and capability checks.
/// Side effects (streaming, tool execution, display) are owned by the caller.
pub type LoopState {
  LoopState(
    messages: List(llm.Message),
    iteration: Int,
    accumulated_content: String,
    accumulated_tool_calls: List(llm.ToolCall),
    pending_tool_results: Dict(String, #(String, Bool)),
    traces: List(conversation.ToolTrace),
    stream_retry_count: Int,
    capabilities: List(String),
    max_iterations: Int,
    max_stream_retries: Int,
  )
}

pub type LoopEvent {
  StreamDelta(content: String)
  StreamComplete(content: String, tool_calls_json: String)
  StreamError(reason: String)
  ToolResult(call_id: String, result: String, is_error: Bool)
}

pub type LoopAction {
  SpawnStream(messages: List(llm.Message))
  SpawnTool(call: llm.ToolCall)
  RetryStream(messages: List(llm.Message), backoff_ms: Int)
  Finalize(content: String)
  Fail(reason: String)
  Continue
}

/// Create a fresh loop state for a turn over the given messages.
pub fn new_state(messages: List(llm.Message)) -> LoopState {
  LoopState(
    messages: messages,
    iteration: 0,
    accumulated_content: "",
    accumulated_tool_calls: [],
    pending_tool_results: dict.new(),
    traces: [],
    stream_retry_count: 0,
    capabilities: [],
    max_iterations: 80,
    max_stream_retries: 3,
  )
}

/// Restrict which tools this loop may execute.
pub fn with_capabilities(
  state: LoopState,
  capabilities: List(String),
) -> LoopState {
  LoopState(..state, capabilities: capabilities)
}

/// Map one loop event to the next state and the actions the caller must apply.
pub fn step(
  state: LoopState,
  event: LoopEvent,
) -> #(LoopState, List(LoopAction)) {
  case event {
    StreamDelta(content) -> #(
      LoopState(
        ..state,
        accumulated_content: state.accumulated_content <> content,
      ),
      [],
    )
    StreamComplete(content, tool_calls_json) ->
      handle_stream_complete(state, content, tool_calls_json)
    StreamError(reason) -> handle_stream_error(state, reason)
    ToolResult(call_id, result, is_error) ->
      handle_tool_result(state, call_id, result, is_error)
  }
}

fn handle_stream_complete(
  state: LoopState,
  content: String,
  tool_calls_json: String,
) -> #(LoopState, List(LoopAction)) {
  case llm.parse_flat_tool_calls_json(tool_calls_json) {
    Ok([]) -> #(state, [Finalize(content)])
    Error(_) -> #(state, [Finalize(content)])
    Ok([first_call, ..rest]) -> {
      let state =
        LoopState(
          ..state,
          accumulated_tool_calls: [first_call, ..rest],
          pending_tool_results: dict.new(),
        )
      case capability_blocked(state, first_call.name) {
        Some(error) ->
          step(state, ToolResult(first_call.id, "Error: " <> error, True))
        None -> #(state, [SpawnTool(first_call)])
      }
    }
  }
}

fn handle_stream_error(
  state: LoopState,
  reason: String,
) -> #(LoopState, List(LoopAction)) {
  case state.stream_retry_count < state.max_stream_retries {
    True -> {
      let new_retry = state.stream_retry_count + 1
      let backoff_ms = case new_retry {
        1 -> 0
        2 -> 500
        _ -> 2000
      }
      // Reset streaming state on retry so stale partial content from the
      // failed stream does not bleed into the new attempt.
      let next =
        LoopState(
          ..state,
          stream_retry_count: new_retry,
          accumulated_content: "",
          accumulated_tool_calls: [],
          pending_tool_results: dict.new(),
        )
      #(next, [RetryStream(state.messages, backoff_ms)])
    }
    False -> #(state, [Fail("stream exhausted retries: " <> reason)])
  }
}

fn handle_tool_result(
  state: LoopState,
  call_id: String,
  result: String,
  is_error: Bool,
) -> #(LoopState, List(LoopAction)) {
  let new_pending =
    dict.insert(state.pending_tool_results, call_id, #(result, is_error))
  let trace =
    conversation.ToolTrace(
      name: find_tool_name(state.accumulated_tool_calls, call_id),
      args: find_tool_args(state.accumulated_tool_calls, call_id),
      result: result,
      is_error: is_error,
    )
  let new_traces = list.append(state.traces, [trace])
  let next_state =
    LoopState(..state, pending_tool_results: new_pending, traces: new_traces)
  case all_tool_calls_resolved(state.accumulated_tool_calls, new_pending) {
    False ->
      case find_next_unresolved(state.accumulated_tool_calls, new_pending) {
        Some(next_call) ->
          case capability_blocked(next_state, next_call.name) {
            Some(error) ->
              step(
                next_state,
                ToolResult(next_call.id, "Error: " <> error, True),
              )
            None -> #(next_state, [SpawnTool(next_call)])
          }
        None -> #(next_state, [Fail("tool_result inconsistency")])
      }
    True ->
      // Guard against runaway tool loops.
      case next_state.iteration + 1 >= next_state.max_iterations {
        True -> #(next_state, [Fail("Tool loop exceeded maximum iterations")])
        False -> {
          let tool_result_messages =
            list.map(next_state.accumulated_tool_calls, fn(call) {
              case dict.get(new_pending, call.id) {
                Ok(#(text, _)) -> llm.ToolResultMessage(call.id, text)
                Error(_) -> llm.ToolResultMessage(call.id, "")
              }
            })
          let new_messages =
            list.flatten([
              next_state.messages,
              [
                llm.AssistantToolCallMessage(
                  next_state.accumulated_content,
                  next_state.accumulated_tool_calls,
                ),
              ],
              tool_result_messages,
            ])
          let iterated =
            LoopState(
              ..next_state,
              iteration: next_state.iteration + 1,
              accumulated_content: "",
              accumulated_tool_calls: [],
              pending_tool_results: dict.new(),
              messages: new_messages,
              stream_retry_count: 0,
            )
          #(iterated, [SpawnStream(new_messages)])
        }
      }
  }
}

/// True when every accumulated tool call has a result recorded in `pending`.
fn all_tool_calls_resolved(
  calls: List(llm.ToolCall),
  pending: Dict(String, #(String, Bool)),
) -> Bool {
  list.all(calls, fn(c) { dict.has_key(pending, c.id) })
}

/// Find the first tool call that hasn't been resolved in `pending`.
fn find_next_unresolved(
  calls: List(llm.ToolCall),
  pending: Dict(String, #(String, Bool)),
) -> Option(llm.ToolCall) {
  list.find(calls, fn(c) { !dict.has_key(pending, c.id) })
  |> option.from_result
}

/// Look up the tool name by call id in the accumulated tool calls.
fn find_tool_name(calls: List(llm.ToolCall), id: String) -> String {
  case list.find(calls, fn(c) { c.id == id }) {
    Ok(c) -> c.name
    Error(_) -> "unknown"
  }
}

/// Look up the original tool-call arguments by call id.
fn find_tool_args(calls: List(llm.ToolCall), id: String) -> String {
  case list.find(calls, fn(c) { c.id == id }) {
    Ok(c) -> c.arguments
    Error(_) -> ""
  }
}

/// Public capability gate. `allowed` is the flare's tool allow-list; an empty
/// list grants all tools (the brain grants an explicit manifest per flare).
pub fn check_capability(
  allowed: List(String),
  tool_name: String,
) -> Result(Nil, String) {
  case allowed {
    [] -> Ok(Nil)
    names ->
      case list.contains(names, tool_name) {
        True -> Ok(Nil)
        False ->
          Error(
            "tool '"
            <> tool_name
            <> "' is outside this flare's capability manifest",
          )
      }
  }
}

/// Blocked-tool message when `tool_name` is outside the capability allow-list.
/// An empty allow-list permits every tool.
fn capability_blocked(state: LoopState, tool_name: String) -> Option(String) {
  case check_capability(state.capabilities, tool_name) {
    Ok(Nil) -> None
    Error(message) -> Some(message)
  }
}
