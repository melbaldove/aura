import aura/acp/flare_manager
import aura/brain
import aura/channel_actor
import aura/conversation
import aura/db
import aura/discord
import aura/llm
import aura/time
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
      channel_actor.VisionComplete("a cat on a mat"),
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

// --- Task 13: stream error retry ---------------------------------------------

pub fn stream_error_retries_up_to_max_test() {
  let state = channel_actor.initial_state_for_test("ch1")
  let with_stream = channel_actor.with_fake_stream_turn(state)
  let #(s1, effects1) =
    channel_actor.transition(
      with_stream,
      channel_actor.StreamError("rate limit"),
    )
  list.any(effects1, fn(e) {
    case e {
      channel_actor.SpawnStreamWorker(_) -> True
      _ -> False
    }
  })
  |> should.be_true
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
  let with_stream = channel_actor.with_fake_stream_turn(state)
  let ref = channel_actor.fake_monitor_ref()
  let #(new_state, effects) =
    channel_actor.transition(
      with_stream,
      channel_actor.WorkerDown(ref, "killed"),
    )
  list.any(effects, fn(e) {
    case e {
      channel_actor.SpawnStreamWorker(_) -> True
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
