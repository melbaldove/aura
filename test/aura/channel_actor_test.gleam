import aura/acp/flare_manager
import aura/brain
import aura/channel_actor
import aura/conversation
import aura/db
import aura/discord
import aura/discord/types as discord_types
import aura/llm
import aura/time
import aura/vision
import aura/xdg
import fakes/fake_discord
import fakes/fake_llm
import fakes/fake_review
import gleam/erlang/process
import gleam/list
import gleam/option
import gleam/string
import gleeunit/should
import poll
import simplifile
import test_harness

pub fn channel_actor_starts_and_accepts_messages_test() {
  let deps =
    channel_actor.TestDeps(channel_id: "test-channel", discord_token: "fake")
  let subject = channel_actor.start_for_test(deps) |> should.be_ok

  // Sending messages should not crash the actor
  process.send(subject, channel_actor.Cancel)
  process.send(subject, channel_actor.TurnDeadline)

  // Verify the actor is still alive by sending one more and completing
  process.send(subject, channel_actor.Cancel)
}

fn fake_incoming(channel_id: String, id: String) -> discord.IncomingMessage {
  discord.IncomingMessage(
    message_id: id,
    channel_id: channel_id,
    channel_name: option.None,
    guild_id: "test-guild",
    author_id: "test-author",
    author_name: "tester",
    content: "hello",
    is_bot: False,
    attachments: [],
  )
}

pub fn incoming_when_idle_starts_turn_test() {
  let state = channel_actor.initial_state_for_test("ch1")
  let #(new_state, effects) =
    channel_actor.transition(
      state,
      channel_actor.HandleIncoming(fake_incoming("ch1", "m1")),
    )

  new_state.queue |> should.equal([])
  case new_state.turn {
    option.Some(_) -> Nil
    option.None -> should.fail()
  }
  { effects != [] } |> should.be_true
}

pub fn incoming_when_turn_in_flight_queues_test() {
  let state = channel_actor.initial_state_for_test("ch1")
  let busy_state = channel_actor.with_fake_in_flight_turn(state)
  let #(new_state, effects) =
    channel_actor.transition(
      busy_state,
      channel_actor.HandleIncoming(fake_incoming("ch1", "m2")),
    )

  list.length(new_state.queue) |> should.equal(1)
  effects |> should.equal([])
}

// --- Task 9: vision ----------------------------------------------------------

pub fn vision_complete_spawns_stream_worker_test() {
  let state = channel_actor.initial_state_for_test("ch1")
  let with_vision = channel_actor.with_fake_vision_turn(state)
  let #(_new_state, effects) =
    channel_actor.transition(
      with_vision,
      channel_actor.VisionComplete("photo.jpg", "a cat on a mat"),
    )
  let has_stream_spawn =
    list.any(effects, fn(e) {
      case e {
        channel_actor.SpawnStreamWorker(_) -> True
        _ -> False
      }
    })
  has_stream_spawn |> should.be_true
}

pub fn vision_error_still_spawns_stream_worker_test() {
  let state = channel_actor.initial_state_for_test("ch1")
  let with_vision = channel_actor.with_fake_vision_turn(state)
  let #(_, effects) =
    channel_actor.transition(with_vision, channel_actor.VisionError("rejected"))
  let has_stream_spawn =
    list.any(effects, fn(e) {
      case e {
        channel_actor.SpawnStreamWorker(_) -> True
        _ -> False
      }
    })
  has_stream_spawn |> should.be_true
}

// --- Task 10: stream deltas and reasoning ------------------------------------

pub fn stream_delta_accumulates_content_test() {
  let state = channel_actor.initial_state_for_test("ch1")
  let with_stream = channel_actor.with_fake_stream_turn(state)
  let #(new_state, _) =
    channel_actor.transition(with_stream, channel_actor.StreamDelta("hello "))
  case new_state.turn {
    option.Some(t) -> t.accumulated_content |> should.equal("hello ")
    option.None -> should.fail()
  }
}

pub fn stream_reasoning_increments_counter_test() {
  let state = channel_actor.initial_state_for_test("ch1")
  let with_stream = channel_actor.with_fake_stream_turn(state)
  let #(new_state, _) =
    channel_actor.transition(with_stream, channel_actor.StreamReasoning)
  case new_state.turn {
    option.Some(t) -> t.stream_stats.reasoning_count |> should.equal(1)
    option.None -> should.fail()
  }
}

/// Regression: should_progressive_edit previously computed last_edit_len as
/// delta_count × threshold, which grew faster than the content and prevented
/// any edit from firing. Feeding 10 deltas of 100 chars each must now produce
/// multiple DiscordEdit effects (threshold is 150, content reaches 1000).
pub fn stream_deltas_emit_progressive_edits_test() {
  let state = channel_actor.initial_state_for_test("ch1")
  let start_state = channel_actor.with_fake_stream_turn(state)
  let delta_text = string.repeat("a", 100)
  let #(final_state, total_edits) =
    list.fold(list.range(1, 10), #(start_state, 0), fn(acc, _) {
      let #(s, edits_so_far) = acc
      let #(next, effects) =
        channel_actor.transition(s, channel_actor.StreamDelta(delta_text))
      let new_edits =
        list.count(effects, fn(e) {
          case e {
            channel_actor.DiscordEdit(_, _) -> True
            _ -> False
          }
        })
      #(next, edits_so_far + new_edits)
    })
  let _ = final_state
  // 1000 chars of content / 150-char threshold → at least 6 edits in theory,
  // accept 3 as the conservative floor (matches the progressive-edits BDD).
  case total_edits >= 3 {
    True -> Nil
    False -> should.fail()
  }
}

// --- Task 11: stream complete (terminal vs tool-call) ------------------------

pub fn stream_complete_no_tools_finalizes_test() {
  let state = channel_actor.initial_state_for_test("ch1")
  let with_stream = channel_actor.with_fake_stream_turn(state)
  let #(new_state, effects) =
    channel_actor.transition(
      with_stream,
      channel_actor.StreamComplete("hello world", "[]", 100),
    )
  new_state.turn |> should.equal(option.None)
  let has_db_save =
    list.any(effects, fn(e) {
      case e {
        channel_actor.DbSaveExchange(_, _, _, _) -> True
        _ -> False
      }
    })
  has_db_save |> should.be_true
}

/// Regression: finalize_turn must persist the full turn (user message +
/// tool/new messages + final assistant message) back into state.conversation.
/// Previously `cleared` only reset turn/typing_pid and left state.conversation
/// pointing at the pre-turn history, so every turn after the first saw stale
/// context through build_llm_messages.
pub fn finalize_turn_appends_to_state_conversation_test() {
  let state = channel_actor.initial_state_for_test("ch1")
  let before = list.length(state.conversation)
  let with_stream = channel_actor.with_fake_stream_turn(state)
  let #(after_state, _) =
    channel_actor.transition(
      with_stream,
      channel_actor.StreamComplete("final answer", "[]", 100),
    )
  let has_assistant =
    list.any(after_state.conversation, fn(m) {
      case m {
        llm.AssistantMessage("final answer") -> True
        _ -> False
      }
    })
  has_assistant |> should.be_true
  { list.length(after_state.conversation) > before } |> should.be_true
}

/// Regression: the user's message must travel through the turn so that
/// finalize_turn persists it AND subsequent tool iterations keep it in the
/// LLM prompt. Previously `new_messages` was initialized empty; the user
/// message lived only in `messages_at_llm_call` for the first iteration and
/// was never saved or carried forward. Symptom: DB had assistant/tool rows
/// but no user rows after the first turn; the LLM looped on tool calls
/// because it lost the question.
pub fn user_message_persisted_through_finalize_test() {
  let incoming =
    discord.IncomingMessage(
      message_id: "m1",
      channel_id: "ch1",
      channel_name: option.None,
      guild_id: "g1",
      author_id: "u1",
      author_name: "tester",
      content: "did we update the bruno docs?",
      is_bot: False,
      attachments: [],
    )
  let state = channel_actor.initial_state_for_test("ch1")
  let #(started, _) =
    channel_actor.transition(state, channel_actor.HandleIncoming(incoming))
  let #(finalized, effects) =
    channel_actor.transition(
      started,
      channel_actor.StreamComplete("ok", "[]", 100),
    )

  let user_in_conversation =
    list.any(finalized.conversation, fn(m) {
      case m {
        llm.UserMessage("did we update the bruno docs?") -> True
        _ -> False
      }
    })
  user_in_conversation |> should.be_true

  let user_in_db_save =
    list.any(effects, fn(e) {
      case e {
        channel_actor.DbSaveExchange(messages, _, _, _) ->
          list.any(messages, fn(m) {
            case m {
              llm.UserMessage("did we update the bruno docs?") -> True
              _ -> False
            }
          })
        _ -> False
      }
    })
  user_in_db_save |> should.be_true
}

pub fn stream_complete_with_tools_spawns_tool_worker_test() {
  let state = channel_actor.initial_state_for_test("ch1")
  let with_stream = channel_actor.with_fake_stream_turn(state)
  let tool_calls_json =
    "[{\"id\":\"c1\",\"name\":\"read_file\",\"arguments\":\"{}\"}]"
  let #(_, effects) =
    channel_actor.transition(
      with_stream,
      channel_actor.StreamComplete("", tool_calls_json, 100),
    )
  let has_tool_spawn =
    list.any(effects, fn(e) {
      case e {
        channel_actor.SpawnToolWorker(_) -> True
        _ -> False
      }
    })
  has_tool_spawn |> should.be_true
}

// --- Task 12: tool result sequencing -----------------------------------------

pub fn tool_result_spawns_next_pending_tool_test() {
  let state = channel_actor.initial_state_for_test("ch1")
  let with_two = channel_actor.with_fake_two_tool_calls_turn(state)
  let #(_, effects) =
    channel_actor.transition(
      with_two,
      channel_actor.ToolResult("c1", "ok", False),
    )
  list.any(effects, fn(e) {
    case e {
      channel_actor.SpawnToolWorker(_) -> True
      _ -> False
    }
  })
  |> should.be_true
}

pub fn tool_result_all_resolved_spawns_next_stream_test() {
  let state = channel_actor.initial_state_for_test("ch1")
  let with_one = channel_actor.with_fake_one_tool_call_turn(state)
  let #(_, effects) =
    channel_actor.transition(
      with_one,
      channel_actor.ToolResult("c1", "done", False),
    )
  list.any(effects, fn(e) {
    case e {
      channel_actor.SpawnStreamWorker(_) -> True
      _ -> False
    }
  })
  |> should.be_true
}

pub fn failed_cognitive_feedback_cannot_finalize_as_saved_test() {
  let state = channel_actor.initial_state_for_test("ch1")
  let with_stream = channel_actor.with_fake_stream_turn(state)
  let tool_calls_json =
    "[{\"id\":\"c1\",\"name\":\"record_cognitive_feedback\",\"arguments\":\"{\\\"event_id\\\":\\\"1\\\",\\\"label\\\":\\\"false_interrupt\\\"}\"}]"

  let #(after_tool_request, _) =
    channel_actor.transition(
      with_stream,
      channel_actor.StreamComplete("", tool_calls_json, 100),
    )
  let #(after_tool_error, _) =
    channel_actor.transition(
      after_tool_request,
      channel_actor.ToolResult("c1", "Error: event not found: 1", True),
    )
  let #(_, effects) =
    channel_actor.transition(
      after_tool_error,
      channel_actor.StreamComplete(
        "Got it — the preference is already saved in your profile.",
        "[]",
        100,
      ),
    )

  let final_text =
    list.find_map(effects, fn(effect) {
      case effect {
        channel_actor.DiscordEdit(_, content) -> Ok(content)
        _ -> Error(Nil)
      }
    })
    |> should.be_ok

  final_text
  |> string.contains("I could not record that cognitive feedback")
  |> should.be_true
  final_text
  |> string.contains("preference is already saved")
  |> should.be_false
}

pub fn cognitive_feedback_without_memory_cannot_claim_future_preference_test() {
  let state = channel_actor.initial_state_for_test("ch1")
  let with_stream = channel_actor.with_fake_stream_turn(state)
  let tool_calls_json =
    "[{\"id\":\"c1\",\"name\":\"record_cognitive_feedback\",\"arguments\":\"{\\\"event_id\\\":\\\"1\\\",\\\"label\\\":\\\"false_interrupt\\\"}\"}]"

  let #(after_tool_request, _) =
    channel_actor.transition(
      with_stream,
      channel_actor.StreamComplete("", tool_calls_json, 100),
    )
  let #(after_feedback, _) =
    channel_actor.transition(
      after_tool_request,
      channel_actor.ToolResult(
        "c1",
        "Recorded cognitive feedback: event_id=1 label=false_interrupt attention_any=[record] path=/tmp/labels.jsonl",
        False,
      ),
    )
  let #(_, effects) =
    channel_actor.transition(
      after_feedback,
      channel_actor.StreamComplete(
        "Done. Routine delivery alerts will be suppressed going forward.",
        "[]",
        100,
      ),
    )

  let final_text =
    list.find_map(effects, fn(effect) {
      case effect {
        channel_actor.DiscordEdit(_, content) -> Ok(content)
        _ -> Error(Nil)
      }
    })
    |> should.be_ok

  final_text
  |> string.contains("I recorded this as cognitive feedback")
  |> should.be_true
  final_text
  |> string.contains("have not saved a reusable preference")
  |> should.be_true
  final_text |> string.contains("will be suppressed") |> should.be_false
}

pub fn cognitive_feedback_with_memory_can_claim_future_preference_test() {
  let state = channel_actor.initial_state_for_test("ch1")
  let with_stream = channel_actor.with_fake_stream_turn(state)
  let tool_calls_json =
    "[{\"id\":\"c1\",\"name\":\"record_cognitive_feedback\",\"arguments\":\"{\\\"event_id\\\":\\\"1\\\",\\\"label\\\":\\\"false_interrupt\\\"}\"},{\"id\":\"c2\",\"name\":\"memory\",\"arguments\":\"{\\\"action\\\":\\\"set\\\",\\\"target\\\":\\\"user\\\",\\\"key\\\":\\\"email-suppressions\\\",\\\"content\\\":\\\"Suppress routine package alerts.\\\"}\"}]"

  let #(after_tool_request, _) =
    channel_actor.transition(
      with_stream,
      channel_actor.StreamComplete("", tool_calls_json, 100),
    )
  let #(after_feedback, _) =
    channel_actor.transition(
      after_tool_request,
      channel_actor.ToolResult(
        "c1",
        "Recorded cognitive feedback: event_id=1 label=false_interrupt attention_any=[record] path=/tmp/labels.jsonl",
        False,
      ),
    )
  let #(after_memory, _) =
    channel_actor.transition(
      after_feedback,
      channel_actor.ToolResult(
        "c2",
        "Saved [email-suppressions] to user.",
        False,
      ),
    )
  let #(_, effects) =
    channel_actor.transition(
      after_memory,
      channel_actor.StreamComplete(
        "Done. Routine delivery alerts will be suppressed going forward.",
        "[]",
        100,
      ),
    )

  let final_text =
    list.find_map(effects, fn(effect) {
      case effect {
        channel_actor.DiscordEdit(_, content) -> Ok(content)
        _ -> Error(Nil)
      }
    })
    |> should.be_ok

  final_text
  |> string.contains("will be suppressed going forward")
  |> should.be_true
  final_text
  |> string.contains("have not saved a reusable preference")
  |> should.be_false
}

pub fn cognitive_feedback_with_non_user_memory_cannot_claim_future_preference_test() {
  let state = channel_actor.initial_state_for_test("ch1")
  let with_stream = channel_actor.with_fake_stream_turn(state)
  let tool_calls_json =
    "[{\"id\":\"c1\",\"name\":\"record_cognitive_feedback\",\"arguments\":\"{\\\"event_id\\\":\\\"1\\\",\\\"label\\\":\\\"false_interrupt\\\"}\"},{\"id\":\"c2\",\"name\":\"memory\",\"arguments\":\"{\\\"action\\\":\\\"set\\\",\\\"target\\\":\\\"state\\\",\\\"key\\\":\\\"email-suppressions\\\",\\\"content\\\":\\\"Suppress routine package alerts.\\\"}\"}]"

  let #(after_tool_request, _) =
    channel_actor.transition(
      with_stream,
      channel_actor.StreamComplete("", tool_calls_json, 100),
    )
  let #(after_feedback, _) =
    channel_actor.transition(
      after_tool_request,
      channel_actor.ToolResult(
        "c1",
        "Recorded cognitive feedback: event_id=1 label=false_interrupt attention_any=[record] path=/tmp/labels.jsonl",
        False,
      ),
    )
  let #(after_memory, _) =
    channel_actor.transition(
      after_feedback,
      channel_actor.ToolResult(
        "c2",
        "Saved [email-suppressions] to user.",
        False,
      ),
    )
  let #(_, effects) =
    channel_actor.transition(
      after_memory,
      channel_actor.StreamComplete(
        "Done. Routine delivery alerts will be suppressed going forward.",
        "[]",
        100,
      ),
    )

  let final_text =
    list.find_map(effects, fn(effect) {
      case effect {
        channel_actor.DiscordEdit(_, content) -> Ok(content)
        _ -> Error(Nil)
      }
    })
    |> should.be_ok

  final_text
  |> string.contains("have not saved a reusable preference")
  |> should.be_true
  final_text |> string.contains("will be suppressed") |> should.be_false
}

pub fn event_grounded_user_memory_requires_feedback_before_saving_test() {
  let state = channel_actor.initial_state_for_test("ch1")
  let with_stream = channel_actor.with_fake_stream_turn(state)
  let search_calls_json =
    "[{\"id\":\"c1\",\"name\":\"search_events\",\"arguments\":\"{\\\"query\\\":\\\"routine delivery\\\",\\\"limit\\\":\\\"5\\\"}\"}]"
  let memory_calls_json =
    "[{\"id\":\"c2\",\"name\":\"memory\",\"arguments\":\"{\\\"action\\\":\\\"set\\\",\\\"target\\\":\\\"user\\\",\\\"key\\\":\\\"notification-suppressions\\\",\\\"content\\\":\\\"Suppress routine delivery alerts.\\\"}\"}]"

  let #(after_search_request, _) =
    channel_actor.transition(
      with_stream,
      channel_actor.StreamComplete("", search_calls_json, 100),
    )
  let #(after_search_result, _) =
    channel_actor.transition(
      after_search_request,
      channel_actor.ToolResult(
        "c1",
        "Found 1 event:\n\n1. Event ID: <delivery-event-1>\n   [gmail] Routine delivery alert",
        False,
      ),
    )
  let #(after_memory_request, effects) =
    channel_actor.transition(
      after_search_result,
      channel_actor.StreamComplete("", memory_calls_json, 100),
    )

  list.any(effects, fn(effect) {
    case effect {
      channel_actor.SpawnToolWorker(call) -> call.name == "memory"
      _ -> False
    }
  })
  |> should.be_false
  list.any(effects, fn(effect) {
    case effect {
      channel_actor.SpawnStreamWorker(_) -> True
      _ -> False
    }
  })
  |> should.be_true

  let turn = case after_memory_request.turn {
    option.Some(turn) -> turn
    option.None -> panic as "expected tool-loop turn to continue"
  }
  let blocked_trace =
    list.find(turn.traces, fn(trace) { trace.name == "memory" })
    |> should.be_ok
  blocked_trace.is_error |> should.be_true
  blocked_trace.result
  |> string.contains("record_cognitive_feedback")
  |> should.be_true
}

pub fn event_grounded_user_memory_after_feedback_can_save_test() {
  let state = channel_actor.initial_state_for_test("ch1")
  let with_stream = channel_actor.with_fake_stream_turn(state)
  let search_calls_json =
    "[{\"id\":\"c1\",\"name\":\"search_events\",\"arguments\":\"{\\\"query\\\":\\\"routine delivery\\\",\\\"limit\\\":\\\"5\\\"}\"}]"
  let feedback_calls_json =
    "[{\"id\":\"c2\",\"name\":\"record_cognitive_feedback\",\"arguments\":\"{\\\"event_id\\\":\\\"delivery-event-1\\\",\\\"label\\\":\\\"false_interrupt\\\",\\\"expected_attention\\\":\\\"record\\\"}\"}]"
  let memory_calls_json =
    "[{\"id\":\"c3\",\"name\":\"memory\",\"arguments\":\"{\\\"action\\\":\\\"set\\\",\\\"target\\\":\\\"user\\\",\\\"key\\\":\\\"notification-suppressions\\\",\\\"content\\\":\\\"Suppress routine delivery alerts.\\\"}\"}]"

  let #(after_search_request, _) =
    channel_actor.transition(
      with_stream,
      channel_actor.StreamComplete("", search_calls_json, 100),
    )
  let #(after_search_result, _) =
    channel_actor.transition(
      after_search_request,
      channel_actor.ToolResult(
        "c1",
        "Found 1 event:\n\n1. Event ID: <delivery-event-1>\n   [gmail] Routine delivery alert",
        False,
      ),
    )
  let #(after_feedback_request, _) =
    channel_actor.transition(
      after_search_result,
      channel_actor.StreamComplete("", feedback_calls_json, 100),
    )
  let #(after_feedback_result, _) =
    channel_actor.transition(
      after_feedback_request,
      channel_actor.ToolResult(
        "c2",
        "Recorded cognitive feedback: event_id=<delivery-event-1> label=false_interrupt attention_any=[record] path=/tmp/labels.jsonl",
        False,
      ),
    )
  let #(_, effects) =
    channel_actor.transition(
      after_feedback_result,
      channel_actor.StreamComplete("", memory_calls_json, 100),
    )

  list.any(effects, fn(effect) {
    case effect {
      channel_actor.SpawnToolWorker(call) -> call.name == "memory"
      _ -> False
    }
  })
  |> should.be_true
}

pub fn event_grounded_feedback_memory_success_finalizes_without_extra_stream_test() {
  let state = channel_actor.initial_state_for_test("ch1")
  let with_stream = channel_actor.with_fake_stream_turn(state)
  let search_calls_json =
    "[{\"id\":\"c1\",\"name\":\"search_events\",\"arguments\":\"{\\\"query\\\":\\\"routine delivery\\\",\\\"limit\\\":\\\"5\\\"}\"}]"
  let feedback_calls_json =
    "[{\"id\":\"c2\",\"name\":\"record_cognitive_feedback\",\"arguments\":\"{\\\"event_id\\\":\\\"delivery-event-1\\\",\\\"label\\\":\\\"false_interrupt\\\",\\\"expected_attention\\\":\\\"record\\\"}\"}]"
  let memory_calls_json =
    "[{\"id\":\"c3\",\"name\":\"memory\",\"arguments\":\"{\\\"action\\\":\\\"set\\\",\\\"target\\\":\\\"user\\\",\\\"key\\\":\\\"notification-suppressions\\\",\\\"content\\\":\\\"Suppress routine delivery alerts.\\\"}\"}]"

  let #(after_search_request, _) =
    channel_actor.transition(
      with_stream,
      channel_actor.StreamComplete("", search_calls_json, 100),
    )
  let #(after_search_result, _) =
    channel_actor.transition(
      after_search_request,
      channel_actor.ToolResult(
        "c1",
        "Found 1 event:\n\n1. Event ID: <delivery-event-1>\n   [gmail] Routine delivery alert",
        False,
      ),
    )
  let #(after_feedback_request, _) =
    channel_actor.transition(
      after_search_result,
      channel_actor.StreamComplete("", feedback_calls_json, 100),
    )
  let #(after_feedback_result, _) =
    channel_actor.transition(
      after_feedback_request,
      channel_actor.ToolResult(
        "c2",
        "Recorded cognitive feedback: event_id=<delivery-event-1> label=false_interrupt attention_any=[record] path=/tmp/labels.jsonl",
        False,
      ),
    )
  let #(after_memory_request, _) =
    channel_actor.transition(
      after_feedback_result,
      channel_actor.StreamComplete("", memory_calls_json, 100),
    )
  let #(final_state, effects) =
    channel_actor.transition(
      after_memory_request,
      channel_actor.ToolResult(
        "c3",
        "Saved [notification-suppressions] to user.",
        False,
      ),
    )

  case final_state.turn {
    option.None -> Nil
    option.Some(_) -> should.fail()
  }
  list.any(effects, fn(effect) {
    case effect {
      channel_actor.SpawnStreamWorker(_) -> True
      _ -> False
    }
  })
  |> should.be_false
  list.any(effects, fn(effect) {
    case effect {
      channel_actor.DbSaveExchange(_, _, _, _) -> True
      _ -> False
    }
  })
  |> should.be_true
  let final_edit =
    list.find_map(effects, fn(effect) {
      case effect {
        channel_actor.DiscordEdit(_, content) -> Ok(content)
        _ -> Error(Nil)
      }
    })
    |> should.be_ok
  final_edit
  |> string.contains("Recorded the feedback and saved the reusable preference")
  |> should.be_true
}

pub fn blocked_event_grounded_memory_cannot_finalize_as_saved_test() {
  let state = channel_actor.initial_state_for_test("ch1")
  let with_stream = channel_actor.with_fake_stream_turn(state)
  let search_calls_json =
    "[{\"id\":\"c1\",\"name\":\"search_events\",\"arguments\":\"{\\\"query\\\":\\\"routine delivery\\\",\\\"limit\\\":\\\"5\\\"}\"}]"
  let memory_calls_json =
    "[{\"id\":\"c2\",\"name\":\"memory\",\"arguments\":\"{\\\"action\\\":\\\"set\\\",\\\"target\\\":\\\"user\\\",\\\"key\\\":\\\"notification-suppressions\\\",\\\"content\\\":\\\"Suppress routine delivery alerts.\\\"}\"}]"

  let #(after_search_request, _) =
    channel_actor.transition(
      with_stream,
      channel_actor.StreamComplete("", search_calls_json, 100),
    )
  let #(after_search_result, _) =
    channel_actor.transition(
      after_search_request,
      channel_actor.ToolResult(
        "c1",
        "Found 1 event:\n\n1. Event ID: <delivery-event-1>\n   [gmail] Routine delivery alert",
        False,
      ),
    )
  let #(after_memory_request, _) =
    channel_actor.transition(
      after_search_result,
      channel_actor.StreamComplete("", memory_calls_json, 100),
    )
  let #(_, effects) =
    channel_actor.transition(
      after_memory_request,
      channel_actor.StreamComplete(
        "Done. Routine delivery alerts are now suppressed.",
        "[]",
        100,
      ),
    )

  let final_text =
    list.find_map(effects, fn(effect) {
      case effect {
        channel_actor.DiscordEdit(_, content) -> Ok(content)
        _ -> Error(Nil)
      }
    })
    |> should.be_ok

  final_text
  |> string.contains("I did not save that preference")
  |> should.be_true
  final_text |> string.contains("now suppressed") |> should.be_false
}

// --- Task 13: stream error retry ---------------------------------------------

pub fn stream_error_retries_up_to_max_test() {
  let state = channel_actor.initial_state_for_test("ch1")
  let with_stream = channel_actor.with_fake_stream_turn(state)
  let #(s1, effects1) =
    channel_actor.transition(
      with_stream,
      channel_actor.StreamError("rate limit"),
    )
  // StreamError now emits ScheduleRetry (non-blocking), not SpawnStreamWorker
  list.any(effects1, fn(e) {
    case e {
      channel_actor.ScheduleRetry(_, _) -> True
      _ -> False
    }
  })
  |> should.be_true
  // No immediate SpawnStreamWorker on StreamError
  list.any(effects1, fn(e) {
    case e {
      channel_actor.SpawnStreamWorker(_) -> True
      _ -> False
    }
  })
  |> should.be_false
  case s1.turn {
    option.Some(t) -> t.stream_retry_count |> should.equal(1)
    option.None -> should.fail()
  }
}

pub fn stream_error_exhausts_retries_fails_turn_test() {
  let state = channel_actor.initial_state_for_test("ch1")
  let with_stream_3 = channel_actor.with_fake_stream_turn_at_retry(state, 3)
  let #(new_state, effects) =
    channel_actor.transition(
      with_stream_3,
      channel_actor.StreamError("timeout"),
    )
  new_state.turn |> should.equal(option.None)
  list.any(effects, fn(e) {
    case e {
      channel_actor.DiscordSend(_) -> True
      _ -> False
    }
  })
  |> should.be_true
}

// --- Task 14: cancel + deadline ----------------------------------------------

pub fn cancel_kills_worker_and_fails_turn_test() {
  let state = channel_actor.initial_state_for_test("ch1")
  let with_stream = channel_actor.with_fake_stream_turn(state)
  let #(new_state, effects) =
    channel_actor.transition(with_stream, channel_actor.Cancel)
  new_state.turn |> should.equal(option.None)
  list.any(effects, fn(e) {
    case e {
      channel_actor.KillWorker(_) -> True
      _ -> False
    }
  })
  |> should.be_true
}

pub fn cancel_idle_is_noop_test() {
  let state = channel_actor.initial_state_for_test("ch1")
  let #(new_state, effects) =
    channel_actor.transition(state, channel_actor.Cancel)
  new_state |> should.equal(state)
  effects |> should.equal([])
}

pub fn turn_deadline_fails_turn_test() {
  let state = channel_actor.initial_state_for_test("ch1")
  let with_stream = channel_actor.with_fake_stream_turn(state)
  let #(new_state, _) =
    channel_actor.transition(with_stream, channel_actor.TurnDeadline)
  new_state.turn |> should.equal(option.None)
}

// --- Task 15: worker down translation ----------------------------------------

pub fn worker_down_stream_translates_to_stream_error_test() {
  let state = channel_actor.initial_state_for_test("ch1")
  let ref = channel_actor.fake_monitor_ref()
  let with_monitor = channel_actor.with_fake_stream_turn_monitored(state, ref)
  let #(new_state, effects) =
    channel_actor.transition(
      with_monitor,
      channel_actor.WorkerDown(ref, "killed"),
    )
  // WorkerDown with matching ref translates to StreamError → ScheduleRetry
  list.any(effects, fn(e) {
    case e {
      channel_actor.ScheduleRetry(_, _) -> True
      _ -> False
    }
  })
  |> should.be_true
  let _ = new_state
}

// --- Task 1: cold actor loads history from DB --------------------------------

pub fn cold_actor_loads_history_from_db_test() {
  let sys = test_harness.fresh_system()
  let now = time.now_ms()
  // Seed the DB with two prior messages for "cold-channel"
  let assert Ok(convo_id) =
    db.resolve_conversation(sys.db_subject, "discord", "cold-channel", now)
  let assert Ok(_) =
    conversation.save_exchange_to_db(
      sys.db_subject,
      convo_id,
      [
        llm.UserMessage("earlier question"),
        llm.AssistantMessage("earlier answer"),
      ],
      "u1",
      "tester",
      now - 1000,
    )

  // Script the LLM to return a response
  fake_llm.script_text_response(sys.fake_llm, "ok")

  // Send a new message to the same channel — this will start a fresh channel_actor
  let msg =
    discord.IncomingMessage(
      message_id: "new-msg",
      channel_id: "cold-channel",
      channel_name: option.None,
      guild_id: "test-guild",
      author_id: "u1",
      author_name: "tester",
      content: "follow up",
      is_bot: False,
      attachments: [],
    )
  process.send(sys.brain_subject, brain.HandleMessage(msg))

  // Poll until the LLM call is recorded
  let _ =
    poll.poll_until(
      fn() { list.length(fake_llm.calls(sys.fake_llm)) > 0 },
      2000,
    )

  // Inspect the LLM call and assert history was hydrated
  let last_call = case list.last(fake_llm.calls(sys.fake_llm)) {
    Ok(c) -> c
    Error(_) -> panic as "no LLM call recorded"
  }
  let joined =
    list.filter_map(last_call.messages, fn(m) {
      case m {
        llm.UserMessage(c) -> Ok(c)
        llm.AssistantMessage(c) -> Ok(c)
        _ -> Error(Nil)
      }
    })
    |> string.join("\n")
  string.contains(joined, "earlier question") |> should.be_true
  test_harness.teardown(sys)
}

// --- Task 3: system prompt fs_section ----------------------------------------

fn combined_system_prompts(fake: fake_llm.FakeLLM) -> String {
  fake_llm.calls(fake)
  |> list.flat_map(fn(c) {
    list.filter_map(c.messages, fn(m) {
      case m {
        llm.SystemMessage(content) -> Ok(content)
        _ -> Error(Nil)
      }
    })
  })
  |> string.join("\n")
}

pub fn system_prompt_includes_fs_section_test() {
  // "cm2-thread" is the domain channel. All channels route through channel_actor.
  let sys =
    test_harness.fresh_system_with_domain("cm2", "# AGENTS", "cm2-thread")
  fake_llm.script_text_response(sys.fake_llm, "ok")
  process.send(
    sys.brain_subject,
    brain.HandleMessage(test_harness.incoming("cm2-thread", "hi")),
  )
  let _ =
    poll.poll_until(
      fn() { list.length(fake_llm.calls(sys.fake_llm)) > 0 },
      2000,
    )
  let prompts = combined_system_prompts(sys.fake_llm)
  string.contains(prompts, "## File System") |> should.be_true
  test_harness.teardown(sys)
}

pub fn system_prompt_includes_flare_context_when_in_flare_thread_test() {
  let sys = test_harness.fresh_system()
  // Register a flare session keyed on thread_id = "flare-thread-1"
  let now = time.now_ms()
  flare_manager.register_for_test(
    sys.acp_subject,
    flare_manager.FlareRecord(
      id: "f-test-1",
      label: "fix-build",
      status: flare_manager.Active,
      domain: "cm2",
      thread_id: "flare-thread-1",
      original_prompt: "make the build pass",
      execution_json: "",
      triggers_json: "",
      tools_json: "",
      workspace: "",
      session_id: "sess-1",
      session_name: "fix-build-session",
      handle: option.None,
      started_at_ms: now,
      updated_at_ms: now,
      awaiting_response: False,
    ),
  )
  fake_llm.script_text_response(sys.fake_llm, "ok")
  process.send(
    sys.brain_subject,
    brain.HandleMessage(test_harness.incoming("flare-thread-1", "status?")),
  )
  let _ =
    poll.poll_until(
      fn() { list.length(fake_llm.calls(sys.fake_llm)) > 0 },
      2000,
    )
  let prompts = combined_system_prompts(sys.fake_llm)
  string.contains(prompts, "## Active Flare") |> should.be_true
  string.contains(prompts, "fix-build") |> should.be_true
  test_harness.teardown(sys)
}

// --- Task 4: post-response memory review -----------------------------------------

pub fn memory_review_spawns_after_threshold_test() {
  // fresh_system with review_interval=2 so we need only 2 turns to trigger
  let sys = test_harness.fresh_system_with_review_interval(2)

  // Turn 1: count goes to 1, no spawn yet (count < interval)
  fake_llm.script_text_response(sys.fake_llm, "reply1")
  process.send(
    sys.brain_subject,
    brain.HandleMessage(test_harness.incoming("c", "m1")),
  )
  let _ =
    poll.poll_until(
      fn() { list.length(fake_discord.all_sent_to(sys.fake_discord, "c")) >= 1 },
      2000,
    )
  fake_review.spawn_count(sys.fake_review)
  |> should.equal(0)

  // Turn 2: count hits interval, spawn triggered
  fake_llm.script_text_response(sys.fake_llm, "reply2")
  process.send(
    sys.brain_subject,
    brain.HandleMessage(test_harness.incoming("c", "m2")),
  )
  let _ =
    poll.poll_until(
      fn() { fake_review.spawn_count(sys.fake_review) >= 1 },
      2000,
    )
  fake_review.spawn_count(sys.fake_review)
  |> should.equal(1)

  test_harness.teardown(sys)
}

// --- Task 5: post-response skill review -----------------------------------------

pub fn skill_review_spawns_after_threshold_test() {
  // fresh_system with skill_review_interval=2.
  // Skill review counter only increments on turns with non-skill_manage tool traces.
  // Use read_file tool calls (each turn: tool call → final text response).
  let #(sys, _) = test_harness.fresh_system_with_skill_review_interval(2)

  // Turn 1: read_file tool call → iteration count: 0→1, no spawn yet
  fake_llm.script_tool_call(
    sys.fake_llm,
    "read_file",
    "{\"path\":\"/tmp/nosuchfile\"}",
  )
  fake_llm.script_text_response(sys.fake_llm, "reply1")
  process.send(
    sys.brain_subject,
    brain.HandleMessage(test_harness.incoming("c", "m1")),
  )
  let _ =
    poll.poll_until(
      fn() { list.length(fake_discord.all_sent_to(sys.fake_discord, "c")) >= 1 },
      2000,
    )
  fake_review.skill_spawn_count(sys.fake_review)
  |> should.equal(0)

  // Turn 2: read_file tool call → iteration count: 1→2 >= 2, spawn triggered
  fake_llm.script_tool_call(
    sys.fake_llm,
    "read_file",
    "{\"path\":\"/tmp/nosuchfile\"}",
  )
  fake_llm.script_text_response(sys.fake_llm, "reply2")
  process.send(
    sys.brain_subject,
    brain.HandleMessage(test_harness.incoming("c", "m2")),
  )
  let _ =
    poll.poll_until(
      fn() { fake_review.skill_spawn_count(sys.fake_review) >= 1 },
      2000,
    )
  fake_review.skill_spawn_count(sys.fake_review)
  |> should.equal(1)

  test_harness.teardown(sys)
}

pub fn skill_manage_tool_call_resets_skill_review_counter_test() {
  // Pure transition test: verify that a turn with a skill_manage trace resets
  // the skill review counter to 0, while a turn with a non-skill_manage trace
  // increments it. Uses a fake state with review_counts seeded directly.
  //
  // Scenario (skill_review_interval=3 via fake_review):
  //   turn A (trace: read_file):      count: 0→1, no spawn
  //   turn B (trace: skill_manage):   count: 1→0 (reset), no spawn
  //   turn C (trace: read_file):      count: 0→1, no spawn
  //   turn D (trace: read_file):      count: 1→2, no spawn
  //   turn E (trace: read_file):      count: 2→3, SPAWN (returns 0)

  // Turn A: read_file tool call (non-skill_manage) → counter: 0→1.
  // Turn B: skill_manage → reset to 0.
  // Turns C, D, E: read_file → counter: 0→1→2→3 → SPAWN.
  // If reset didn't work, C would bring the counter to 3 and spawn too early.
  let #(sys, _) = test_harness.fresh_system_with_skill_review_interval(3)

  // Turn A: LLM calls read_file (non-skill_manage) — count: 0→1
  fake_llm.script_tool_call(
    sys.fake_llm,
    "read_file",
    "{\"path\":\"/tmp/nosuchfile\"}",
  )
  fake_llm.script_text_response(sys.fake_llm, "tA")
  process.send(
    sys.brain_subject,
    brain.HandleMessage(test_harness.incoming("c", "tA")),
  )
  let _ =
    poll.poll_until(
      fn() { list.length(fake_discord.all_sent_to(sys.fake_discord, "c")) >= 1 },
      2000,
    )
  fake_review.skill_spawn_count(sys.fake_review) |> should.equal(0)

  // Turn B: skill_manage tool call — count resets to 0
  fake_llm.script_tool_call(
    sys.fake_llm,
    "skill_manage",
    "{\"action\":\"list\"}",
  )
  fake_llm.script_text_response(sys.fake_llm, "tB")
  process.send(
    sys.brain_subject,
    brain.HandleMessage(test_harness.incoming("c", "tB")),
  )
  let _ =
    poll.poll_until(
      fn() { list.length(fake_discord.all_sent_to(sys.fake_discord, "c")) >= 2 },
      2000,
    )
  fake_review.skill_spawn_count(sys.fake_review) |> should.equal(0)

  // Turn C: read_file — count: 0→1 (if no reset it would be 2→3 and spawn here)
  fake_llm.script_tool_call(
    sys.fake_llm,
    "read_file",
    "{\"path\":\"/tmp/nosuchfile\"}",
  )
  fake_llm.script_text_response(sys.fake_llm, "tC")
  process.send(
    sys.brain_subject,
    brain.HandleMessage(test_harness.incoming("c", "tC")),
  )
  let _ =
    poll.poll_until(
      fn() { list.length(fake_discord.all_sent_to(sys.fake_discord, "c")) >= 3 },
      2000,
    )
  // If reset didn't happen, count would be 3 and spawn_count would be 1 here.
  fake_review.skill_spawn_count(sys.fake_review) |> should.equal(0)

  // Turn D: read_file — count: 1→2
  fake_llm.script_tool_call(
    sys.fake_llm,
    "read_file",
    "{\"path\":\"/tmp/nosuchfile\"}",
  )
  fake_llm.script_text_response(sys.fake_llm, "tD")
  process.send(
    sys.brain_subject,
    brain.HandleMessage(test_harness.incoming("c", "tD")),
  )
  let _ =
    poll.poll_until(
      fn() { list.length(fake_discord.all_sent_to(sys.fake_discord, "c")) >= 4 },
      2000,
    )
  fake_review.skill_spawn_count(sys.fake_review) |> should.equal(0)

  // Turn E: read_file — count: 2→3, spawn fires
  fake_llm.script_tool_call(
    sys.fake_llm,
    "read_file",
    "{\"path\":\"/tmp/nosuchfile\"}",
  )
  fake_llm.script_text_response(sys.fake_llm, "tE")
  process.send(
    sys.brain_subject,
    brain.HandleMessage(test_harness.incoming("c", "tE")),
  )
  let _ =
    poll.poll_until(
      fn() { fake_review.skill_spawn_count(sys.fake_review) >= 1 },
      2000,
    )
  fake_review.skill_spawn_count(sys.fake_review) |> should.equal(1)

  test_harness.teardown(sys)
}

// --- Task 8: in-actor compression --------------------------------------------

/// Build a conversation with (min_tail_messages + extra) messages where the
/// early tool results have long content so `prune_tool_outputs` will clear them.
/// We need more than min_tail_messages so that some fall before the prune boundary.
fn large_tool_output_conversation() -> List(llm.Message) {
  // Build 25 pairs of AssistantToolCallMessage + ToolResultMessage.
  // That's well over min_tail_messages (20), so the first several results
  // will be eligible for pruning.
  let large_content = string.repeat("x", 300)
  // 300 chars > prune_min_chars (200)
  // Generate 25 pairs without list.range
  let ids = [
    "c1", "c2", "c3", "c4", "c5", "c6", "c7", "c8", "c9", "c10", "c11", "c12",
    "c13", "c14", "c15", "c16", "c17", "c18", "c19", "c20", "c21", "c22", "c23",
    "c24", "c25",
  ]
  list.flat_map(ids, fn(id) {
    [
      llm.AssistantToolCallMessage("", [
        llm.ToolCall(id: id, name: "read_file", arguments: "{}"),
      ]),
      llm.ToolResultMessage(id, large_content),
    ]
  })
}

pub fn prune_tool_outputs_effect_clears_large_outputs_test() {
  // Build a state with an oversized conversation.
  let state =
    channel_actor.initial_state_for_test("prune-ch")
    |> fn(s) {
      channel_actor.ChannelState(
        ..s,
        conversation: large_tool_output_conversation(),
      )
    }

  // Execute the PruneToolOutputs effect directly.
  let new_state =
    channel_actor.execute_effect(state, channel_actor.PruneToolOutputs)

  // At least some tool results should be replaced by the pruned placeholder.
  let pruned_count =
    list.count(new_state.conversation, fn(msg) {
      case msg {
        llm.ToolResultMessage(_, content) ->
          content == "[Output cleared to save context]"
        _ -> False
      }
    })
  { pruned_count > 0 }
  |> should.be_true
}

pub fn update_compressor_tokens_effect_sets_last_prompt_tokens_test() {
  let state = channel_actor.initial_state_for_test("tok-ch")
  // Initially last_prompt_tokens should be 0.
  state.compressor_state.last_prompt_tokens |> should.equal(0)

  let new_state =
    channel_actor.execute_effect(
      state,
      channel_actor.UpdateCompressorTokens(5000),
    )
  new_state.compressor_state.last_prompt_tokens |> should.equal(5000)
}

pub fn update_compressor_tokens_zero_is_noop_test() {
  let state = channel_actor.initial_state_for_test("tok-ch2")
  // Set a non-zero initial value.
  let state_with_tokens =
    channel_actor.ChannelState(
      ..state,
      compressor_state: conversation.CompressorState(
        ..state.compressor_state,
        last_prompt_tokens: 1000,
      ),
    )
  // UpdateCompressorTokens(0) should NOT reset to 0.
  let new_state =
    channel_actor.execute_effect(
      state_with_tokens,
      channel_actor.UpdateCompressorTokens(0),
    )
  new_state.compressor_state.last_prompt_tokens |> should.equal(1000)
}

pub fn compression_complete_replaces_conversation_test() {
  let state = channel_actor.initial_state_for_test("comp-ch")
  let old_history = [
    llm.UserMessage("old msg"),
    llm.AssistantMessage("old reply"),
  ]
  let state_with_history =
    channel_actor.ChannelState(..state, conversation: old_history)

  let new_history = [
    llm.SystemMessage("[CONTEXT COMPACTION] summary"),
    llm.UserMessage("recent"),
  ]
  let new_comp_state =
    conversation.CompressorState(
      previous_summary: option.Some("summary"),
      last_prompt_tokens: 9000,
      compression_count: 1,
      cooldown_until: 0,
    )
  let snapshot_len = list.length(old_history)
  let #(new_state, effects) =
    channel_actor.transition(
      state_with_history,
      channel_actor.CompressionComplete(
        new_history,
        new_comp_state,
        snapshot_len,
      ),
    )
  new_state.conversation |> should.equal(new_history)
  new_state.compressor_state |> should.equal(new_comp_state)
  effects |> should.equal([])
}

pub fn compression_complete_merges_delta_when_new_messages_arrived_test() {
  // If more messages arrived since the snapshot was taken, the delta is
  // appended to the compressed history.
  let state = channel_actor.initial_state_for_test("comp-delta-ch")
  let original_history = [
    llm.UserMessage("m1"),
    llm.AssistantMessage("r1"),
    llm.UserMessage("m2"),
    llm.AssistantMessage("r2"),
  ]
  let state_with_history =
    channel_actor.ChannelState(..state, conversation: original_history)

  // Snapshot was taken when only 2 messages existed.
  let snapshot_len = 2
  let compressed = [llm.SystemMessage("[CONTEXT COMPACTION] compressed")]
  let new_comp_state = conversation.new_compressor_state()
  let #(new_state, _effects) =
    channel_actor.transition(
      state_with_history,
      channel_actor.CompressionComplete(
        compressed,
        new_comp_state,
        snapshot_len,
      ),
    )
  // Expected: compressed + the 2 messages that arrived after the snapshot.
  let expected =
    list.append(compressed, list.drop(original_history, snapshot_len))
  new_state.conversation |> should.equal(expected)
}

pub fn finalize_turn_emits_update_compressor_tokens_test() {
  // StreamComplete with a non-zero prompt_tokens should produce
  // UpdateCompressorTokens in the effects.
  let state = channel_actor.initial_state_for_test("ct-ch")
  let with_stream = channel_actor.with_fake_stream_turn(state)
  let #(_, effects) =
    channel_actor.transition(
      with_stream,
      channel_actor.StreamComplete("hello", "[]", 7777),
    )
  let has_update =
    list.any(effects, fn(e) {
      case e {
        channel_actor.UpdateCompressorTokens(7777) -> True
        _ -> False
      }
    })
  has_update |> should.be_true
}

pub fn finalize_turn_emits_prune_when_over_threshold_test() {
  // Set a very small brain_context so that even a short conversation triggers
  // pruning but NOT full compression. With brain_context=1000:
  //   - pruning threshold:    tokens > 500   (50% of 1000)
  //   - full compression:     tokens > 700   (70% of 1000)
  // Use prompt_tokens=600 to land in the "prune only" zone.
  let state = channel_actor.initial_state_for_test("prune-thresh-ch")
  let state_small_ctx =
    channel_actor.ChannelState(
      ..state,
      brain_context: 1000,
      conversation: large_tool_output_conversation(),
    )
  let with_stream = channel_actor.with_fake_stream_turn(state_small_ctx)
  let #(_, effects) =
    channel_actor.transition(
      with_stream,
      channel_actor.StreamComplete("reply", "[]", 600),
    )
  // With prompt_tokens=600 > 500 but <= 700: pruning fires, not full compression.
  let has_prune =
    list.any(effects, fn(e) {
      case e {
        channel_actor.PruneToolOutputs -> True
        _ -> False
      }
    })
  has_prune |> should.be_true
}

// --- Task 8a: base prompt in channel_actor -----------------------------------

/// Domain AGENTS.md content must appear in the channel_actor system prompt.
/// This exercises build_base_system_prompt's domain_prompt section.
pub fn system_prompt_includes_domain_agents_md_content_test() {
  let sys =
    test_harness.fresh_system_with_domain(
      "local-test",
      "You are the local-test assistant. Tone: terse.",
      "local-test-channel",
    )
  fake_llm.script_text_response(sys.fake_llm, "ok")
  process.send(
    sys.brain_subject,
    brain.HandleMessage(test_harness.incoming("local-test-channel", "hi")),
  )
  let _ = poll.poll_until(fn() { fake_llm.calls(sys.fake_llm) != [] }, 2000)
  let prompts = combined_system_prompts(sys.fake_llm)
  string.contains(prompts, "You are the local-test assistant")
  |> should.be_true
  test_harness.teardown(sys)
}

/// USER.md content written to disk before the turn must appear in the
/// channel_actor system prompt. This exercises build_base_system_prompt's
/// memory read (format_for_display re-read on every turn).
pub fn system_prompt_includes_user_memory_content_test() {
  let sys = test_harness.fresh_system()
  // Write directly to USER.md before sending the message.
  let user_file_path = xdg.user_path(sys.paths)
  // Ensure parent directory exists (user_path returns config/USER.md).
  let user_dir =
    string.slice(user_file_path, 0, string.length(user_file_path) - 8)
  let _ = simplifile.create_directory_all(user_dir)
  let _ = simplifile.write(user_file_path, "§ favorite-color\norange\n")

  fake_llm.script_text_response(sys.fake_llm, "ok")
  process.send(
    sys.brain_subject,
    brain.HandleMessage(test_harness.incoming("ch-mem-test", "hi")),
  )
  let _ = poll.poll_until(fn() { fake_llm.calls(sys.fake_llm) != [] }, 2000)
  let prompts = combined_system_prompts(sys.fake_llm)
  string.contains(prompts, "favorite-color")
  |> should.be_true

  // Cleanup
  let _ = simplifile.delete(user_file_path)
  test_harness.teardown(sys)
}

/// Regression: guild_id, scheduler_subject, and ACP fields were stubbed as
/// empty defaults in build_initial_state; now threaded from Deps.
/// Passes a Deps with guild_id="g99" and asserts it flows into tool_ctx.
pub fn deps_guild_id_threads_into_tool_ctx_test() {
  let assert Ok(db_subject) = db.start(":memory:")
  let deps =
    channel_actor.test_deps("ch-guild-test", "tok")
    |> fn(d) {
      channel_actor.Deps(..d, guild_id: "g99", db_subject: db_subject)
    }
  // Build a real ChannelState using the production build_initial_state path
  // to verify that guild_id is threaded through to tool_ctx.guild_id.
  let state = channel_actor.initial_state_from_deps_for_test(deps)
  state.tool_ctx.guild_id |> should.equal("g99")
  state.tool_ctx.acp_provider |> should.equal("claude-code")
  state.tool_ctx.acp_worktree |> should.be_true
}

/// Regression: finalize_turn was using format_progress (which appends " ...")
/// for the final Discord edit. The final edit must NOT end with " ...".
pub fn finalize_turn_final_discord_edit_has_no_trailing_ellipsis_test() {
  let state = channel_actor.initial_state_for_test("ch1")
  let with_stream = channel_actor.with_fake_stream_turn(state)
  let content = "Here is the final answer"
  let #(_, effects) =
    channel_actor.transition(
      with_stream,
      channel_actor.StreamComplete(content, "[]", 100),
    )
  let discord_edits =
    list.filter_map(effects, fn(e) {
      case e {
        channel_actor.DiscordEdit(_, body) -> Ok(body)
        _ -> Error(Nil)
      }
    })
  // There must be at least one DiscordEdit
  case discord_edits {
    [] -> should.fail()
    _ -> Nil
  }
  // None of the final DiscordEdit bodies should end with " ..."
  list.all(discord_edits, fn(body) { !string.ends_with(body, " ...") })
  |> should.be_true
}

// --- non-blocking stream retry backoff -----------------------------------

/// Regression: StreamError with retry_count=2 (third attempt triggers 500ms
/// backoff) must emit ScheduleRetry(_, 500), not SpawnStreamWorker directly.
pub fn stream_error_retry_count_2_emits_schedule_retry_500ms_test() {
  let state = channel_actor.initial_state_for_test("ch1")
  // retry_count=2 means the NEXT retry (3rd attempt) uses 500ms backoff.
  // The backoff is: retry 1→0ms, retry 2→500ms, retry 3+→2000ms.
  // With current retry_count=1, new_retry=2, backoff=500ms.
  let with_stream = channel_actor.with_fake_stream_turn_at_retry(state, 1)
  let #(_, effects) =
    channel_actor.transition(
      with_stream,
      channel_actor.StreamError("rate limit"),
    )
  // Must contain ScheduleRetry with 500ms delay
  list.any(effects, fn(e) {
    case e {
      channel_actor.ScheduleRetry(_, 500) -> True
      _ -> False
    }
  })
  |> should.be_true
  // Must NOT contain a direct SpawnStreamWorker
  list.any(effects, fn(e) {
    case e {
      channel_actor.SpawnStreamWorker(_) -> True
      _ -> False
    }
  })
  |> should.be_false
}

/// RetryStream message spawns a stream worker directly (backoff already elapsed).
pub fn retry_stream_message_spawns_stream_worker_test() {
  let state = channel_actor.initial_state_for_test("ch1")
  let with_stream = channel_actor.with_fake_stream_turn(state)
  let #(_, effects) =
    channel_actor.transition(with_stream, channel_actor.RetryStream)
  list.any(effects, fn(e) {
    case e {
      channel_actor.SpawnStreamWorker(_) -> True
      _ -> False
    }
  })
  |> should.be_true
}

/// RetryStream when idle is a no-op.
pub fn retry_stream_when_idle_is_noop_test() {
  let state = channel_actor.initial_state_for_test("ch1")
  let #(new_state, effects) =
    channel_actor.transition(state, channel_actor.RetryStream)
  effects |> should.equal([])
  new_state.turn |> should.equal(option.None)
}

// --- WorkerDown ref-check + demonitor on worker swap -------------------

/// Regression: WorkerDown with a ref that does NOT match turn.worker_monitor
/// must be silently ignored (stale DOWN from superseded worker).
pub fn worker_down_stale_ref_is_ignored_test() {
  let state = channel_actor.initial_state_for_test("ch1")
  let current_ref = channel_actor.fake_monitor_ref()
  let stale_ref = channel_actor.fake_monitor_ref()
  // Turn monitors `current_ref`; incoming DOWN carries `stale_ref`.
  let with_stream =
    channel_actor.with_fake_stream_turn_monitored(state, current_ref)
  let #(new_state, effects) =
    channel_actor.transition(
      with_stream,
      channel_actor.WorkerDown(stale_ref, "crashed"),
    )
  // Stale DOWN must produce no effects and leave the turn intact.
  effects |> should.equal([])
  case new_state.turn {
    option.Some(_) -> Nil
    option.None -> should.fail()
  }
}

/// Regression: WorkerDown with a ref that MATCHES turn.worker_monitor must
/// dispatch to the correct handler (StreamError for StreamWorker).
pub fn worker_down_matching_ref_dispatches_stream_error_test() {
  let state = channel_actor.initial_state_for_test("ch1")
  let ref = channel_actor.fake_monitor_ref()
  let with_stream = channel_actor.with_fake_stream_turn_monitored(state, ref)
  let #(new_state, effects) =
    channel_actor.transition(
      with_stream,
      channel_actor.WorkerDown(ref, "crashed"),
    )
  // Matching ref + "crashed" → StreamError → ScheduleRetry (retry_count was 0)
  list.any(effects, fn(e) {
    case e {
      channel_actor.ScheduleRetry(_, _) -> True
      _ -> False
    }
  })
  |> should.be_true
  // Turn should still be active (retry scheduled, not failed)
  case new_state.turn {
    option.Some(_) -> Nil
    option.None -> should.fail()
  }
}

// --- mutex concurrent compressions via in_flight flag ------------------

/// Regression: when compression_in_flight is True, finalize_turn must NOT
/// emit SpawnCompression even when needs_full_compression would return True.
pub fn finalize_turn_skips_compression_when_in_flight_test() {
  let state = channel_actor.initial_state_for_test("comp-mutex-ch")
  // Set compression_in_flight = True and a conversation large enough that
  // needs_full_compression would normally trigger.
  // We use a tiny brain_context (1) to force the threshold to be breached.
  let state_with_flag =
    channel_actor.ChannelState(
      ..state,
      compression_in_flight: True,
      brain_context: 1,
      compressor_state: conversation.CompressorState(
        ..state.compressor_state,
        last_prompt_tokens: 9999,
      ),
    )
  let with_stream = channel_actor.with_fake_stream_turn(state_with_flag)
  let #(_, effects) =
    channel_actor.transition(
      with_stream,
      channel_actor.StreamComplete("done", "[]", 9999),
    )
  // No SpawnCompression should be emitted while in_flight is True
  list.any(effects, fn(e) {
    case e {
      channel_actor.SpawnCompression(_, _) -> True
      _ -> False
    }
  })
  |> should.be_false
}

/// Regression: CompressionComplete must reset compression_in_flight to False.
pub fn compression_complete_clears_in_flight_flag_test() {
  let state = channel_actor.initial_state_for_test("comp-flag-ch")
  let state_with_flag =
    channel_actor.ChannelState(..state, compression_in_flight: True)
  let new_comp_state = conversation.new_compressor_state()
  let #(new_state, _) =
    channel_actor.transition(
      state_with_flag,
      channel_actor.CompressionComplete([], new_comp_state, 0),
    )
  new_state.compression_in_flight |> should.be_false
}

/// Regression: WorkerDown for the compression monitor must reset
/// compression_in_flight to False so compression is never silently disabled
/// for the lifetime of the channel_actor after a worker crash.
pub fn compression_worker_crash_resets_in_flight_test() {
  let state = channel_actor.initial_state_for_test("comp-crash-ch")
  let comp_ref = channel_actor.fake_monitor_ref()
  let state_with_flag =
    channel_actor.ChannelState(
      ..state,
      compression_in_flight: True,
      compression_monitor: option.Some(comp_ref),
    )
  // Simulate a non-normal WorkerDown for the compression monitor
  let #(new_state, effects) =
    channel_actor.transition(
      state_with_flag,
      channel_actor.WorkerDown(comp_ref, "killed"),
    )
  // compression_in_flight must be reset to False
  new_state.compression_in_flight |> should.be_false
  // compression_monitor must be cleared
  new_state.compression_monitor |> should.equal(option.None)
  // No effects should be emitted (the failure is logged, not propagated)
  effects |> should.equal([])
}

/// WorkerDown with "normal" reason for the compression monitor must only
/// clear compression_monitor, not reset compression_in_flight (normal exit
/// means CompressionComplete was already sent).
pub fn compression_worker_normal_exit_clears_monitor_test() {
  let state = channel_actor.initial_state_for_test("comp-normal-ch")
  let comp_ref = channel_actor.fake_monitor_ref()
  let state_with_flag =
    channel_actor.ChannelState(
      ..state,
      compression_in_flight: True,
      compression_monitor: option.Some(comp_ref),
    )
  let #(new_state, effects) =
    channel_actor.transition(
      state_with_flag,
      channel_actor.WorkerDown(comp_ref, "normal"),
    )
  // Normal exit: monitor cleared but in_flight unchanged (CompressionComplete will arrive)
  new_state.compression_monitor |> should.equal(option.None)
  effects |> should.equal([])
}

// --- preserve author_name on UserTurn ------------------------------------

/// Regression: finalize_turn was hardcoding author_name="" for UserTurn. Now
/// it reads author_name from turn.kind. Verify that DbSaveExchange carries
/// the author_name that was set when the turn was started.
pub fn finalize_turn_preserves_author_name_test() {
  let state = channel_actor.initial_state_for_test("ch-author")
  let incoming =
    discord.IncomingMessage(
      message_id: "m-alice",
      channel_id: "ch-author",
      channel_name: option.None,
      guild_id: "g1",
      author_id: "u-alice",
      author_name: "Alice",
      content: "hello",
      is_bot: False,
      attachments: [],
    )
  // Start the turn — this populates author_name in UserTurn
  let #(started, _) =
    channel_actor.transition(state, channel_actor.HandleIncoming(incoming))
  // Finalize the turn
  let #(_finalized, effects) =
    channel_actor.transition(
      started,
      channel_actor.StreamComplete("reply", "[]", 100),
    )
  // DbSaveExchange must carry author_name: "Alice"
  let author_name_in_db =
    list.find_map(effects, fn(e) {
      case e {
        channel_actor.DbSaveExchange(_, _, name, _) -> Ok(name)
        _ -> Error(Nil)
      }
    })
  case author_name_in_db {
    Ok(name) -> name |> should.equal("Alice")
    Error(_) -> should.fail()
  }
}

// --- max 80 tool iterations guard --------------------------------------

/// Regression: ToolResult that resolves all tool calls when turn.iteration
/// is already 79 (so iteration + 1 = 80 >= max_tool_iterations) must fail
/// the turn, not spawn another stream worker.
pub fn tool_result_at_max_iterations_fails_turn_test() {
  let state = channel_actor.initial_state_for_test("ch-iter")
  // iteration = 79: next would be 80 which hits the limit
  let with_turn =
    channel_actor.with_fake_one_tool_call_turn_at_iteration(state, 79)
  let #(new_state, effects) =
    channel_actor.transition(
      with_turn,
      channel_actor.ToolResult("c1", "done", False),
    )
  // Turn must be cleared (fail_turn_internal clears it)
  new_state.turn |> should.equal(option.None)
  // Must NOT contain a SpawnStreamWorker
  list.any(effects, fn(e) {
    case e {
      channel_actor.SpawnStreamWorker(_) -> True
      _ -> False
    }
  })
  |> should.be_false
  // Must contain a DiscordSend with an error message
  list.any(effects, fn(e) {
    case e {
      channel_actor.DiscordSend(_) -> True
      _ -> False
    }
  })
  |> should.be_true
}

/// Regression: ToolResult that resolves all tool calls when turn.iteration
/// is 78 (so iteration + 1 = 79 < 80) must still spawn a stream worker.
pub fn tool_result_below_max_iterations_spawns_stream_test() {
  let state = channel_actor.initial_state_for_test("ch-iter2")
  let with_turn =
    channel_actor.with_fake_one_tool_call_turn_at_iteration(state, 78)
  let #(_new_state, effects) =
    channel_actor.transition(
      with_turn,
      channel_actor.ToolResult("c1", "done", False),
    )
  list.any(effects, fn(e) {
    case e {
      channel_actor.SpawnStreamWorker(_) -> True
      _ -> False
    }
  })
  |> should.be_true
}

// --- image prefix format + position -------------------

/// Regression: enrich_messages_with_description must PREPEND
/// "[Image <filename>: <desc>]\n\n" BEFORE the original content, not append after.
pub fn enrich_messages_prepend_with_filename_test() {
  let messages = [llm.UserMessage("hi")]
  let result =
    channel_actor.enrich_messages_with_description(
      messages,
      "photo.png",
      "a cat",
    )
  case result {
    [llm.UserMessage(content)] ->
      content
      |> should.equal("[Image photo.png: a cat]\n\nhi")
    _ -> should.fail()
  }
}

// --- vision prompt from config (not hardcoded) -------------------------

/// Regression: start_turn for a message with an image attachment must use the
/// configured resolved_vision_config.prompt rather than the old hardcoded string.
/// Construct a state with a known prompt and verify SpawnVisionWorker carries it.
pub fn vision_spawn_uses_configured_prompt_test() {
  let state = channel_actor.initial_state_for_test("ch-vision-prompt")
  let custom_prompt = "Summarise this chart for data analysis."
  let state_with_vision =
    channel_actor.ChannelState(
      ..state,
      resolved_vision_config: vision.ResolvedVisionConfig(
        model_spec: "fake-model",
        prompt: custom_prompt,
      ),
    )
  let msg =
    discord.IncomingMessage(
      message_id: "m-img",
      channel_id: "ch-vision-prompt",
      channel_name: option.None,
      guild_id: "g1",
      author_id: "u1",
      author_name: "tester",
      content: "check this chart",
      is_bot: False,
      attachments: [
        discord_types.Attachment(
          url: "https://example.com/chart.png",
          filename: "chart.png",
          content_type: "image/png",
        ),
      ],
    )
  let #(_new_state, effects) =
    channel_actor.transition(
      state_with_vision,
      channel_actor.HandleIncoming(msg),
    )
  let vision_spawn_question =
    list.find_map(effects, fn(e) {
      case e {
        channel_actor.SpawnVisionWorker(_path, question, _filename) ->
          Ok(question)
        _ -> Error(Nil)
      }
    })
  case vision_spawn_question {
    Ok(q) -> q |> should.equal(custom_prompt)
    Error(_) -> should.fail()
  }
}

// --- StopTyping before DiscordEdit in finalize_turn -------------------

/// Regression: finalize_turn was appending StopTyping after DiscordEdit.
/// Now StopTyping must appear before DiscordEdit in the effect list so the
/// typing indicator is cleared before the final message is edited.
pub fn finalize_turn_stop_typing_before_discord_edit_test() {
  let state = channel_actor.initial_state_for_test("ch-typing")
  let incoming =
    discord.IncomingMessage(
      message_id: "m-typing",
      channel_id: "ch-typing",
      channel_name: option.None,
      guild_id: "g1",
      author_id: "u1",
      author_name: "tester",
      content: "hello",
      is_bot: False,
      attachments: [],
    )
  // Start a turn so there is an active turn in state
  let #(started, _) =
    channel_actor.transition(state, channel_actor.HandleIncoming(incoming))
  // Inject a fake typing pid into the state
  let fake_pid = process.self()
  let state_with_typing =
    channel_actor.ChannelState(..started, typing_pid: option.Some(fake_pid))
  // Finalize the turn
  let #(_finalized, effects) =
    channel_actor.transition(
      state_with_typing,
      channel_actor.StreamComplete("reply", "[]", 100),
    )
  // Find the position of StopTyping and DiscordEdit in the effect list
  let indexed = list.index_map(effects, fn(e, i) { #(i, e) })
  let stop_typing_pos =
    list.find_map(indexed, fn(pair) {
      case pair.1 {
        channel_actor.StopTyping(_) -> Ok(pair.0)
        _ -> Error(Nil)
      }
    })
  let discord_edit_pos =
    list.find_map(indexed, fn(pair) {
      case pair.1 {
        channel_actor.DiscordEdit(_, _) -> Ok(pair.0)
        _ -> Error(Nil)
      }
    })
  case stop_typing_pos, discord_edit_pos {
    Ok(stop_i), Ok(edit_i) -> {
      // StopTyping must come BEFORE DiscordEdit
      { stop_i < edit_i } |> should.be_true()
    }
    _, _ -> should.fail()
  }
}

// --- reset accumulated_content on StreamError retry -------------------

/// Regression: StreamError retry preserved the stale accumulated_content from
/// the failed stream. Now the retry turn must start clean with
/// accumulated_content == "" so the new stream is not contaminated.
pub fn stream_error_retry_resets_accumulated_content_test() {
  let state = channel_actor.initial_state_for_test("ch-retry")
  let incoming =
    discord.IncomingMessage(
      message_id: "m-retry",
      channel_id: "ch-retry",
      channel_name: option.None,
      guild_id: "g1",
      author_id: "u1",
      author_name: "tester",
      content: "hello",
      is_bot: False,
      attachments: [],
    )
  // Start a turn
  let #(started, _) =
    channel_actor.transition(state, channel_actor.HandleIncoming(incoming))
  // Send a StreamDelta to accumulate some content
  let #(with_delta, _) =
    channel_actor.transition(
      started,
      channel_actor.StreamDelta("partial content"),
    )
  // Trigger a StreamError (retry_count < max_stream_retries=3, so retries)
  let #(after_error, _effects) =
    channel_actor.transition(
      with_delta,
      channel_actor.StreamError("network blip"),
    )
  // The turn must still be active (it retried, not failed)
  case after_error.turn {
    option.Some(turn) -> {
      // accumulated_content must be reset to "" by the retry
      turn.accumulated_content |> should.equal("")
    }
    option.None -> should.fail()
  }
}

// --- record stream_stats start_ms on worker spawn ---------------------

/// Regression: execute_spawn_stream_worker was not setting start_ms /
/// last_heartbeat_ms, leaving them 0 for the whole turn. Now both are set to
/// time.now_ms() in execute_spawn_stream_worker (the effect interpreter).
///
/// We test the pure state-update step directly via apply_stream_start_ms_for_test
/// because execute_spawn_stream_worker calls build_base_system_prompt which
/// requires a live flare_manager actor that the stub acp_subject doesn't provide.
pub fn spawn_stream_worker_records_start_ms_test() {
  let state = channel_actor.initial_state_for_test("ch-start-ms")
  // Put a fake stream turn in flight with start_ms = 0 (initial value)
  let state_with_turn = channel_actor.with_fake_stream_turn(state)
  case state_with_turn.turn {
    option.Some(initial_turn) -> {
      initial_turn.stream_stats.start_ms |> should.equal(0)
      initial_turn.stream_stats.last_heartbeat_ms |> should.equal(0)
    }
    option.None -> should.fail()
  }
  // Apply the start_ms update (mirrors what execute_spawn_stream_worker does)
  let now_ms = time.now_ms()
  let after_update =
    channel_actor.apply_stream_start_ms_for_test(state_with_turn, now_ms)
  case after_update.turn {
    option.Some(turn) -> {
      // start_ms must equal the supplied now_ms
      turn.stream_stats.start_ms |> should.equal(now_ms)
      // last_heartbeat_ms must also equal now_ms
      turn.stream_stats.last_heartbeat_ms |> should.equal(now_ms)
      // and now_ms itself must be > 0 (sanity check that time.now_ms() works)
      { now_ms > 0 } |> should.be_true()
    }
    option.None -> should.fail()
  }
}
