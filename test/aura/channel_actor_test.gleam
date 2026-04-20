import aura/acp/flare_manager
import aura/brain
import aura/channel_actor
import aura/conversation
import aura/db
import aura/discord
import aura/llm
import aura/time
import fakes/fake_discord
import fakes/fake_llm
import fakes/fake_review
import gleam/erlang/process
import gleam/list
import gleam/option
import gleam/string
import gleeunit/should
import poll
import test_harness

pub fn channel_actor_starts_and_accepts_messages_test() {
  let deps =
    channel_actor.TestDeps(
      channel_id: "test-channel",
      discord_token: "fake",
    )
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
    channel_actor.transition(
      with_vision,
      channel_actor.VisionError("rejected"),
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

// --- Task 10: stream deltas and reasoning ------------------------------------

pub fn stream_delta_accumulates_content_test() {
  let state = channel_actor.initial_state_for_test("ch1")
  let with_stream = channel_actor.with_fake_stream_turn(state)
  let #(new_state, _) =
    channel_actor.transition(
      with_stream,
      channel_actor.StreamDelta("hello "),
    )
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
  let sys = test_harness.fresh_system_with_allowlist(["cold-channel"])
  let now = time.now_ms()
  // Seed the DB with two prior messages for "cold-channel"
  let assert Ok(convo_id) =
    db.resolve_conversation(sys.db_subject, "discord", "cold-channel", now)
  let assert Ok(_) =
    conversation.save_exchange_to_db(
      sys.db_subject,
      convo_id,
      [llm.UserMessage("earlier question"), llm.AssistantMessage("earlier answer")],
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
    poll.poll_until(fn() { list.length(fake_llm.calls(sys.fake_llm)) > 0 }, 2000)

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
  // "cm2-thread" is both the domain channel and the allowlisted channel.
  // Brain routes it to channel_actor (possibly after creating a thread first,
  // which is fine — the channel_actor for that thread will still include fs_section).
  let sys =
    test_harness.fresh_system_with_domain_and_allowlist(
      "cm2",
      "# AGENTS",
      "cm2-thread",
      ["cm2-thread"],
    )
  fake_llm.script_text_response(sys.fake_llm, "ok")
  process.send(
    sys.brain_subject,
    brain.HandleMessage(test_harness.incoming("cm2-thread", "hi")),
  )
  let _ =
    poll.poll_until(fn() { list.length(fake_llm.calls(sys.fake_llm)) > 0 }, 2000)
  let prompts = combined_system_prompts(sys.fake_llm)
  string.contains(prompts, "## File System") |> should.be_true
  test_harness.teardown(sys)
}

pub fn system_prompt_includes_flare_context_when_in_flare_thread_test() {
  let sys = test_harness.fresh_system_with_allowlist(["flare-thread-1"])
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
    poll.poll_until(fn() { list.length(fake_llm.calls(sys.fake_llm)) > 0 }, 2000)
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
      fn() {
        list.length(fake_discord.all_sent_to(sys.fake_discord, "c")) >= 1
      },
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
  fake_llm.script_tool_call(sys.fake_llm, "read_file", "{\"path\":\"/tmp/nosuchfile\"}")
  fake_llm.script_text_response(sys.fake_llm, "reply1")
  process.send(
    sys.brain_subject,
    brain.HandleMessage(test_harness.incoming("c", "m1")),
  )
  let _ =
    poll.poll_until(
      fn() {
        list.length(fake_discord.all_sent_to(sys.fake_discord, "c")) >= 1
      },
      2000,
    )
  fake_review.skill_spawn_count(sys.fake_review)
  |> should.equal(0)

  // Turn 2: read_file tool call → iteration count: 1→2 >= 2, spawn triggered
  fake_llm.script_tool_call(sys.fake_llm, "read_file", "{\"path\":\"/tmp/nosuchfile\"}")
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
  fake_llm.script_tool_call(sys.fake_llm, "read_file", "{\"path\":\"/tmp/nosuchfile\"}")
  fake_llm.script_text_response(sys.fake_llm, "tA")
  process.send(
    sys.brain_subject,
    brain.HandleMessage(test_harness.incoming("c", "tA")),
  )
  let _ =
    poll.poll_until(
      fn() {
        list.length(fake_discord.all_sent_to(sys.fake_discord, "c")) >= 1
      },
      2000,
    )
  fake_review.skill_spawn_count(sys.fake_review) |> should.equal(0)

  // Turn B: skill_manage tool call — count resets to 0
  fake_llm.script_tool_call(sys.fake_llm, "skill_manage", "{\"action\":\"list\"}")
  fake_llm.script_text_response(sys.fake_llm, "tB")
  process.send(
    sys.brain_subject,
    brain.HandleMessage(test_harness.incoming("c", "tB")),
  )
  let _ =
    poll.poll_until(
      fn() {
        list.length(fake_discord.all_sent_to(sys.fake_discord, "c")) >= 2
      },
      2000,
    )
  fake_review.skill_spawn_count(sys.fake_review) |> should.equal(0)

  // Turn C: read_file — count: 0→1 (if no reset it would be 2→3 and spawn here)
  fake_llm.script_tool_call(sys.fake_llm, "read_file", "{\"path\":\"/tmp/nosuchfile\"}")
  fake_llm.script_text_response(sys.fake_llm, "tC")
  process.send(
    sys.brain_subject,
    brain.HandleMessage(test_harness.incoming("c", "tC")),
  )
  let _ =
    poll.poll_until(
      fn() {
        list.length(fake_discord.all_sent_to(sys.fake_discord, "c")) >= 3
      },
      2000,
    )
  // If reset didn't happen, count would be 3 and spawn_count would be 1 here.
  fake_review.skill_spawn_count(sys.fake_review) |> should.equal(0)

  // Turn D: read_file — count: 1→2
  fake_llm.script_tool_call(sys.fake_llm, "read_file", "{\"path\":\"/tmp/nosuchfile\"}")
  fake_llm.script_text_response(sys.fake_llm, "tD")
  process.send(
    sys.brain_subject,
    brain.HandleMessage(test_harness.incoming("c", "tD")),
  )
  let _ =
    poll.poll_until(
      fn() {
        list.length(fake_discord.all_sent_to(sys.fake_discord, "c")) >= 4
      },
      2000,
    )
  fake_review.skill_spawn_count(sys.fake_review) |> should.equal(0)

  // Turn E: read_file — count: 2→3, spawn fires
  fake_llm.script_tool_call(sys.fake_llm, "read_file", "{\"path\":\"/tmp/nosuchfile\"}")
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
