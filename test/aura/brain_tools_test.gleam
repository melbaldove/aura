import aura/brain_tools
import aura/db
import aura/event
import aura/llm
import aura/test_helpers
import aura/xdg
import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/string
import gleeunit/should
import simplifile
import test_harness

pub fn parse_tool_args_valid_json_test() {
  let args =
    brain_tools.parse_tool_args(
      "{\"name\":\"google\",\"args\":\"calendar today\"}",
    )
  list.length(args) |> should.equal(2)
}

pub fn parse_tool_args_concatenated_json_test() {
  let args =
    brain_tools.parse_tool_args(
      "{\"name\":\"google\",\"args\":\"a\"}{\"name\":\"jira\",\"args\":\"b\"}",
    )
  let name = case list.find(args, fn(p) { p.0 == "name" }) {
    Ok(#(_, v)) -> v
    Error(_) -> ""
  }
  name |> should.equal("google")
}

pub fn parse_tool_args_invalid_json_test() {
  let args = brain_tools.parse_tool_args("not json at all")
  let has_error = case list.find(args, fn(p) { p.0 == "_parse_error" }) {
    Ok(_) -> True
    Error(_) -> False
  }
  has_error |> should.be_true
}

pub fn parse_tool_args_empty_string_test() {
  let args = brain_tools.parse_tool_args("")
  let has_error = case list.find(args, fn(p) { p.0 == "_parse_error" }) {
    Ok(_) -> True
    Error(_) -> False
  }
  has_error |> should.be_true
}

// ---------------------------------------------------------------------------
// expand_tool_calls tests
// ---------------------------------------------------------------------------

pub fn expand_tool_calls_no_concat_test() {
  let calls = [
    llm.ToolCall(id: "1", name: "jira", arguments: "{\"action\":\"list\"}"),
  ]
  let expanded = brain_tools.expand_tool_calls(calls)
  list.length(expanded) |> should.equal(1)
  case list.first(expanded) {
    Ok(c) -> {
      c.id |> should.equal("1")
      c.name |> should.equal("jira")
      c.arguments |> should.equal("{\"action\":\"list\"}")
    }
    Error(_) -> should.fail()
  }
}

pub fn expand_tool_calls_two_concat_test() {
  let calls = [
    llm.ToolCall(
      id: "1",
      name: "jira",
      arguments: "{\"name\":\"jira\",\"args\":\"[\\\"--instance\\\", \\\"HY\\\"]\"}{\"name\":\"jira\",\"args\":\"[\\\"--instance\\\", \\\"CM\\\"]\"}",
    ),
  ]
  let expanded = brain_tools.expand_tool_calls(calls)
  list.length(expanded) |> should.equal(2)
  case expanded {
    [first, second] -> {
      first.id |> should.equal("1_0")
      second.id |> should.equal("1_1")
      first.name |> should.equal("jira")
      second.name |> should.equal("jira")
    }
    _ -> should.fail()
  }
}

pub fn expand_tool_calls_three_concat_test() {
  let calls = [
    llm.ToolCall(
      id: "1",
      name: "run_skill",
      arguments: "{\"a\":\"1\"}{\"b\":\"2\"}{\"c\":\"3\"}",
    ),
  ]
  let expanded = brain_tools.expand_tool_calls(calls)
  list.length(expanded) |> should.equal(3)
  case expanded {
    [first, second, third] -> {
      first.id |> should.equal("1_0")
      first.arguments |> should.equal("{\"a\":\"1\"}")
      second.id |> should.equal("1_1")
      second.arguments |> should.equal("{\"b\":\"2\"}")
      third.id |> should.equal("1_2")
      third.arguments |> should.equal("{\"c\":\"3\"}")
    }
    _ -> should.fail()
  }
}

pub fn expand_tool_calls_mixed_names_test() {
  let calls = [
    llm.ToolCall(
      id: "1",
      name: "unknown",
      arguments: "{\"name\":\"jira\",\"args\":\"a\"}{\"name\":\"google\",\"args\":\"b\"}",
    ),
  ]
  let expanded = brain_tools.expand_tool_calls(calls)
  list.length(expanded) |> should.equal(2)
  case expanded {
    [first, second] -> {
      first.name |> should.equal("jira")
      second.name |> should.equal("google")
    }
    _ -> should.fail()
  }
}

pub fn built_in_tools_include_flare_test() {
  let tools = brain_tools.make_built_in_tools()
  let has_flare =
    list.any(tools, fn(t) {
      case t {
        llm.ToolDefinition(name: "flare", ..) -> True
        _ -> False
      }
    })
  has_flare |> should.be_true
}

pub fn built_in_tools_no_acp_dispatch_test() {
  let tools = brain_tools.make_built_in_tools()
  let has_acp =
    list.any(tools, fn(t) {
      case t {
        llm.ToolDefinition(name: "acp_dispatch", ..) -> True
        _ -> False
      }
    })
  has_acp |> should.be_false
}

pub fn built_in_tools_include_track_test() {
  let tools = brain_tools.make_built_in_tools()
  let has_track =
    list.any(tools, fn(t) {
      case t {
        llm.ToolDefinition(name: "track", ..) -> True
        _ -> False
      }
    })
  has_track |> should.be_true
}

pub fn built_in_tools_do_not_expose_record_cognitive_feedback_test() {
  let tools = brain_tools.make_built_in_tools()
  let has_tool =
    list.any(tools, fn(t) {
      case t {
        llm.ToolDefinition(name: "record_cognitive_feedback", ..) -> True
        _ -> False
      }
    })
  has_tool |> should.be_false
}

pub fn memory_tool_description_guides_attention_feedback_test() {
  let tools = brain_tools.make_built_in_tools()
  let description = case
    list.find(tools, fn(t) {
      case t {
        llm.ToolDefinition(name: "memory", ..) -> True
        _ -> False
      }
    })
  {
    Ok(llm.ToolDefinition(description: d, ..)) -> d
    Error(_) -> ""
  }

  description |> string.contains("target='attention'") |> should.be_true
  description
  |> string.contains("proactive notifications")
  |> should.be_true
  description
  |> string.contains("event_id")
  |> should.be_true
  description
  |> string.contains("expected_attention")
  |> should.be_true
  description
  |> string.contains("no future user-facing attention")
  |> should.be_true
  description
  |> string.contains("later batch")
  |> should.be_true
  description |> string.contains("like '") |> should.be_false
  description |> string.contains("If the user says \"") |> should.be_false
  description |> string.contains("expected_attention=") |> should.be_false
}

// Regression: GLM concatenates calls for different tools without embedding a
// "name" key.  expand_tool_calls must infer the tool name from the parameter
// keys so each part targets the correct tool.
pub fn expand_tool_calls_infers_name_from_param_keys_test() {
  let tools = brain_tools.make_built_in_tools()
  let calls = [
    llm.ToolCall(
      id: "1",
      name: "web_search",
      arguments: "{\"query\":\"Extropic AI\"}{\"url\":\"https://example.com\"}",
    ),
  ]
  let expanded = brain_tools.expand_tool_calls_with_tools(calls, tools)
  list.length(expanded) |> should.equal(2)
  case expanded {
    [first, second] -> {
      first.name |> should.equal("web_search")
      // The second part has "url" — matches web_fetch, not web_search
      second.name |> should.equal("web_fetch")
    }
    _ -> should.fail()
  }
}

pub fn all_tool_params_are_string_typed_test() {
  // parse_tool_args decodes to Dict(String, String) — any non-string
  // param_type in a schema makes the LLM emit JSON numbers/booleans,
  // which fail the decode and silently reject the entire tool call.
  let tools = brain_tools.make_built_in_tools()
  let offenders =
    list.flat_map(tools, fn(t) {
      case t {
        llm.ToolDefinition(name: tool_name, parameters: params, ..) ->
          list.filter_map(params, fn(p) {
            case p.param_type {
              "string" -> Error(Nil)
              other -> Ok(tool_name <> "." <> p.name <> ":" <> other)
            }
          })
      }
    })
  offenders |> should.equal([])
}

pub fn memory_tool_has_domain_param_test() {
  let tools = brain_tools.make_built_in_tools()
  let memory_tool =
    list.find(tools, fn(t) {
      case t {
        llm.ToolDefinition(name: "memory", ..) -> True
        _ -> False
      }
    })
  case memory_tool {
    Ok(llm.ToolDefinition(parameters: params, ..)) -> {
      let has_domain = list.any(params, fn(p) { p.name == "domain" })
      has_domain |> should.be_true
    }
    _ -> should.fail()
  }
}

pub fn memory_tool_has_attention_feedback_params_test() {
  let tools = brain_tools.make_built_in_tools()
  let memory_tool =
    list.find(tools, fn(t) {
      case t {
        llm.ToolDefinition(name: "memory", ..) -> True
        _ -> False
      }
    })
  case memory_tool {
    Ok(llm.ToolDefinition(parameters: params, ..)) -> {
      list.any(params, fn(p) { p.name == "event_id" }) |> should.be_true
      list.any(params, fn(p) { p.name == "scope" }) |> should.be_true
      list.any(params, fn(p) { p.name == "expected_attention" })
      |> should.be_true
      list.any(params, fn(p) { p.name == "label" }) |> should.be_true
      list.any(params, fn(p) { p.name == "note" }) |> should.be_true
    }
    _ -> should.fail()
  }
}

fn memory_ctx(base: String) -> brain_tools.ToolContext {
  let stub = test_harness.standalone_tool_context()
  brain_tools.ToolContext(
    ..stub,
    paths: xdg.resolve_with_home(base),
    domain_name: "aura",
    message_id: "turn-feedback",
  )
}

fn run_memory_tool(ctx: brain_tools.ToolContext, args_json: String) -> String {
  let call = llm.ToolCall(id: "1", name: "memory", arguments: args_json)
  let #(result, _) = brain_tools.execute_tool(ctx, call)
  case result {
    brain_tools.TextResult(s) -> s
  }
}

pub fn memory_tool_saves_attention_preference_test() {
  let assert Ok(db_subject) = db.start(":memory:")
  let base = "/tmp/aura-attention-memory-" <> test_helpers.random_suffix()
  let _ = simplifile.delete_all([base])
  let ctx = brain_tools.ToolContext(..memory_ctx(base), db_subject: db_subject)
  let assert Ok(_) =
    simplifile.create_directory_all(xdg.cognitive_dir(ctx.paths))

  let out =
    run_memory_tool(
      ctx,
      "{\"action\":\"set\",\"target\":\"attention\",\"key\":\"package-tracker\",\"content\":\"Suppress notifications for routine package tracker alerts. These should be recorded but never surfaced or digested.\",\"scope\":\"standing\"}",
    )

  out
  |> should.equal(
    "Saved [package-tracker] to attention as a standing preference. No replay label was recorded.",
  )
  let content =
    simplifile.read(xdg.attention_memory_path(ctx.paths))
    |> should.be_ok
  content
  |> string.contains("routine package tracker alerts")
  |> should.be_true

  process.send(db_subject, db.Shutdown)
  let _ = simplifile.delete_all([base])
  Nil
}

pub fn memory_attention_tool_rejects_unscoped_plain_feedback_test() {
  let base =
    "/tmp/aura-attention-memory-requires-scope-" <> test_helpers.random_suffix()
  let _ = simplifile.delete_all([base])
  let ctx = memory_ctx(base)
  let assert Ok(_) =
    simplifile.create_directory_all(xdg.cognitive_dir(ctx.paths))

  let out =
    run_memory_tool(
      ctx,
      "{\"action\":\"set\",\"target\":\"attention\",\"key\":\"package-tracker\",\"content\":\"Suppress routine package tracker alerts.\"}",
    )

  out
  |> should.equal(
    "Error: attention memory without event evidence is only allowed for explicit standing preferences. If this corrects a concrete event or prior Aura notification, include expected_attention and the tool will resolve the recent event. If it is truly general, retry with scope=standing.",
  )
  simplifile.read(xdg.attention_memory_path(ctx.paths)) |> should.be_error

  let _ = simplifile.delete_all([base])
  Nil
}

pub fn memory_attention_tool_rejects_standing_feedback_when_recent_event_matches_test() {
  let assert Ok(db_subject) = db.start(":memory:")
  let base =
    "/tmp/aura-attention-memory-standing-overlap-"
    <> test_helpers.random_suffix()
  let _ = simplifile.delete_all([base])
  let ctx = brain_tools.ToolContext(..memory_ctx(base), db_subject: db_subject)
  let assert Ok(_) =
    simplifile.create_directory_all(xdg.cognitive_dir(ctx.paths))
  let assert Ok(True) =
    db.insert_event(
      db_subject,
      gmail_event(
        "ev-package-tracker",
        "Package tracker delivery notice",
        "notice@packageco.test",
        "thread-package-tracker",
        1_700_000_000_000,
      ),
    )

  let out =
    run_memory_tool(
      ctx,
      "{\"action\":\"set\",\"target\":\"attention\",\"key\":\"package-tracker\",\"content\":\"Suppress package tracker delivery notices.\",\"scope\":\"standing\"}",
    )

  out
  |> should.equal(
    "Error: standing attention preference overlaps a recent event (Package tracker delivery notice). Include expected_attention so the tool can resolve the event and record replay feedback, or save a standing preference only when it is not grounded in a recent event.",
  )
  simplifile.read(xdg.attention_memory_path(ctx.paths)) |> should.be_error

  process.send(db_subject, db.Shutdown)
  let _ = simplifile.delete_all([base])
  Nil
}

pub fn memory_attention_tool_rejects_standing_feedback_on_single_source_token_test() {
  let assert Ok(db_subject) = db.start(":memory:")
  let base =
    "/tmp/aura-attention-memory-source-overlap-" <> test_helpers.random_suffix()
  let _ = simplifile.delete_all([base])
  let ctx = brain_tools.ToolContext(..memory_ctx(base), db_subject: db_subject)
  let assert Ok(_) =
    simplifile.create_directory_all(xdg.cognitive_dir(ctx.paths))
  let assert Ok(True) =
    db.insert_event(
      db_subject,
      gmail_event(
        "ev-vendorco",
        "Your order has been delivered",
        "notice@vendorco.test",
        "thread-vendorco",
        1_700_000_000_000,
      ),
    )

  let out =
    run_memory_tool(
      ctx,
      "{\"action\":\"set\",\"target\":\"attention\",\"key\":\"vendorco\",\"content\":\"Suppress VendorCo notifications.\",\"scope\":\"standing\"}",
    )

  out
  |> should.equal(
    "Error: standing attention preference overlaps a recent event (Your order has been delivered). Include expected_attention so the tool can resolve the event and record replay feedback, or save a standing preference only when it is not grounded in a recent event.",
  )
  simplifile.read(xdg.attention_memory_path(ctx.paths)) |> should.be_error

  process.send(db_subject, db.Shutdown)
  let _ = simplifile.delete_all([base])
  Nil
}

pub fn memory_attention_tool_resolves_single_event_for_attention_feedback_test() {
  let assert Ok(db_subject) = db.start(":memory:")
  let base =
    "/tmp/aura-attention-memory-auto-event-" <> test_helpers.random_suffix()
  let _ = simplifile.delete_all([base])
  let ctx = brain_tools.ToolContext(..memory_ctx(base), db_subject: db_subject)
  let assert Ok(True) =
    db.insert_event(
      db_subject,
      gmail_event(
        "ev-package-tracker-auto",
        "Package tracker delivery notice",
        "notice@packageco.test",
        "thread-package-tracker-auto",
        1_700_000_000_000,
      ),
    )

  let out =
    run_memory_tool(
      ctx,
      "{\"action\":\"set\",\"target\":\"attention\",\"key\":\"package-tracker\",\"content\":\"Suppress package tracker delivery notices.\",\"expected_attention\":\"record\",\"note\":\"The user said package tracker delivery notices should not interrupt.\"}",
    )

  out
  |> string.contains("Saved [package-tracker] to attention")
  |> should.be_true
  out |> string.contains("recorded cognitive feedback") |> should.be_true
  out
  |> string.contains("event_id=ev-package-tracker-auto")
  |> should.be_true
  out |> string.contains("attention_any=[record]") |> should.be_true

  let attention =
    simplifile.read(xdg.attention_memory_path(ctx.paths))
    |> should.be_ok
  attention
  |> string.contains("Suppress package tracker delivery notices")
  |> should.be_true

  let labels = simplifile.read(xdg.labels_path(ctx.paths)) |> should.be_ok
  labels
  |> string.contains("\"event_id\":\"ev-package-tracker-auto\"")
  |> should.be_true

  process.send(db_subject, db.Shutdown)
  let _ = simplifile.delete_all([base])
  Nil
}

pub fn memory_attention_tool_rejects_ambiguous_auto_event_resolution_test() {
  let assert Ok(db_subject) = db.start(":memory:")
  let base =
    "/tmp/aura-attention-memory-auto-ambiguous-" <> test_helpers.random_suffix()
  let _ = simplifile.delete_all([base])
  let ctx = brain_tools.ToolContext(..memory_ctx(base), db_subject: db_subject)
  let assert Ok(True) =
    db.insert_event(
      db_subject,
      gmail_event(
        "ev-delivery-a",
        "Delivery notice",
        "notice@packageco.test",
        "thread-delivery-a",
        1_700_000_000_000,
      ),
    )
  let assert Ok(True) =
    db.insert_event(
      db_subject,
      gmail_event(
        "ev-delivery-b",
        "Delivery notice",
        "notice@warehouseco.test",
        "thread-delivery-b",
        1_700_000_000_001,
      ),
    )

  let out =
    run_memory_tool(
      ctx,
      "{\"action\":\"set\",\"target\":\"attention\",\"key\":\"delivery\",\"content\":\"Suppress delivery notices.\",\"expected_attention\":\"record\",\"note\":\"The user said delivery notices should not interrupt.\"}",
    )

  out
  |> string.contains("Error: attention feedback matched multiple recent events")
  |> should.be_true
  out |> string.contains("ev-delivery-a") |> should.be_true
  out |> string.contains("ev-delivery-b") |> should.be_true
  simplifile.read(xdg.attention_memory_path(ctx.paths)) |> should.be_error
  simplifile.read(xdg.labels_path(ctx.paths)) |> should.be_error

  process.send(db_subject, db.Shutdown)
  let _ = simplifile.delete_all([base])
  Nil
}

pub fn memory_attention_tool_records_label_for_event_grounded_feedback_test() {
  let assert Ok(db_subject) = db.start(":memory:")
  let base = "/tmp/aura-attention-memory-label-" <> test_helpers.random_suffix()
  let _ = simplifile.delete_all([base])
  let ctx = brain_tools.ToolContext(..memory_ctx(base), db_subject: db_subject)
  let assert Ok(True) =
    db.insert_event(
      db_subject,
      gmail_event(
        "ev-package-tracker",
        "Routine package tracker alert",
        "alerts@example.invalid",
        "thread-package-tracker",
        1_700_000_000_000,
      ),
    )

  let out =
    run_memory_tool(
      ctx,
      "{\"action\":\"set\",\"target\":\"attention\",\"key\":\"package-tracker\",\"content\":\"Suppress routine package tracker alerts.\",\"event_id\":\"ev-package-tracker\",\"expected_attention\":\"record\",\"note\":\"User said this routine package tracker alert should not interrupt.\"}",
    )

  out
  |> string.contains("Saved [package-tracker] to attention")
  |> should.be_true
  out |> string.contains("recorded cognitive feedback") |> should.be_true
  out |> string.contains("event_id=ev-package-tracker") |> should.be_true
  out |> string.contains("attention_any=[record]") |> should.be_true

  let attention =
    simplifile.read(xdg.attention_memory_path(ctx.paths))
    |> should.be_ok
  attention
  |> string.contains("Suppress routine package tracker alerts")
  |> should.be_true

  let labels = simplifile.read(xdg.labels_path(ctx.paths)) |> should.be_ok
  labels
  |> string.contains("\"event_id\":\"ev-package-tracker\"")
  |> should.be_true
  labels
  |> string.contains("\"attention_any\":[\"record\"]")
  |> should.be_true

  process.send(db_subject, db.Shutdown)
  let _ = simplifile.delete_all([base])
  Nil
}

pub fn memory_attention_tool_uses_note_when_content_is_omitted_test() {
  let assert Ok(db_subject) = db.start(":memory:")
  let base =
    "/tmp/aura-attention-memory-note-fallback-" <> test_helpers.random_suffix()
  let _ = simplifile.delete_all([base])
  let ctx = brain_tools.ToolContext(..memory_ctx(base), db_subject: db_subject)
  let assert Ok(True) =
    db.insert_event(
      db_subject,
      gmail_event(
        "ev-package-tracker-note",
        "Routine package tracker alert",
        "alerts@example.invalid",
        "thread-package-tracker-note",
        1_700_000_000_000,
      ),
    )

  let out =
    run_memory_tool(
      ctx,
      "{\"action\":\"set\",\"target\":\"attention\",\"key\":\"package-tracker\",\"event_id\":\"ev-package-tracker-note\",\"expected_attention\":\"record\",\"note\":\"Routine package tracker alerts should be recorded only and not surfaced.\"}",
    )

  out
  |> string.contains("Saved [package-tracker] to attention")
  |> should.be_true
  let attention =
    simplifile.read(xdg.attention_memory_path(ctx.paths))
    |> should.be_ok
  attention
  |> string.contains(
    "Routine package tracker alerts should be recorded only and not surfaced.",
  )
  |> should.be_true

  process.send(db_subject, db.Shutdown)
  let _ = simplifile.delete_all([base])
  Nil
}

pub fn memory_attention_tool_rejects_unknown_expected_attention_test() {
  let assert Ok(db_subject) = db.start(":memory:")
  let base =
    "/tmp/aura-attention-memory-invalid-" <> test_helpers.random_suffix()
  let _ = simplifile.delete_all([base])
  let ctx = brain_tools.ToolContext(..memory_ctx(base), db_subject: db_subject)
  let assert Ok(True) =
    db.insert_event(
      db_subject,
      gmail_event(
        "ev-package-tracker-invalid",
        "Routine package tracker alert",
        "alerts@example.invalid",
        "thread-package-tracker-invalid",
        1_700_000_000_000,
      ),
    )

  let out =
    run_memory_tool(
      ctx,
      "{\"action\":\"set\",\"target\":\"attention\",\"key\":\"package-tracker\",\"content\":\"Suppress routine package tracker alerts.\",\"event_id\":\"ev-package-tracker-invalid\",\"expected_attention\":\"later\"}",
    )

  out
  |> should.equal(
    "Error: invalid expected attention 'later'. Use record, digest, surface_now, or ask_now.",
  )
  simplifile.read(xdg.attention_memory_path(ctx.paths)) |> should.be_error
  simplifile.read(xdg.labels_path(ctx.paths)) |> should.be_error

  process.send(db_subject, db.Shutdown)
  let _ = simplifile.delete_all([base])
  Nil
}

pub fn memory_tool_allows_neutral_notification_memory_without_feedback_label_test() {
  let base =
    "/tmp/aura-memory-feedback-guard-neutral-" <> test_helpers.random_suffix()
  let _ = simplifile.delete_all([base])
  let ctx = memory_ctx(base)
  let assert Ok(_) = simplifile.create_directory_all(ctx.paths.config)

  let out =
    run_memory_tool(
      ctx,
      "{\"action\":\"set\",\"target\":\"user\",\"key\":\"notification-channels\",\"content\":\"Remember notification channel preferences for routine package tracker alerts.\"}",
    )

  out |> should.equal("Saved [notification-channels] to user.")
  let content = simplifile.read(xdg.user_path(ctx.paths)) |> should.be_ok
  content
  |> string.contains("notification channel preferences")
  |> should.be_true

  let _ = simplifile.delete_all([base])
  Nil
}

fn track_ctx(base: String) -> brain_tools.ToolContext {
  let stub = test_harness.standalone_tool_context()
  brain_tools.ToolContext(
    ..stub,
    paths: xdg.resolve_with_home(base),
    domain_name: "aura",
  )
}

fn run_track_tool(ctx: brain_tools.ToolContext, args_json: String) -> String {
  let call = llm.ToolCall(id: "1", name: "track", arguments: args_json)
  let #(result, _) = brain_tools.execute_tool(ctx, call)
  case result {
    brain_tools.TextResult(s) -> s
  }
}

pub fn track_tool_starts_concern_file_test() {
  let base = "/tmp/aura-track-tool-" <> test_helpers.random_suffix()
  let _ = simplifile.delete_all([base])
  let ctx = track_ctx(base)

  let out =
    run_track_tool(
      ctx,
      "{\"action\":\"start\",\"slug\":\"cics-342\",\"title\":\"CICS-342 Payment Reconciliation\",\"summary\":\"Payment reconciliation follow-up is active.\",\"why\":\"Blocked reconciliation can carry incorrect payment state forward.\",\"current_state\":\"Needs triage and owner confirmation.\",\"watch_signals\":\"Status changes and rollback requests.\",\"evidence\":\"Jira CICS-342\",\"authority\":\"Human approval required for production rollback.\",\"gaps\":\"Rollback runbook is not yet linked.\"}",
    )

  out
  |> string.contains("Tracking start: CICS-342 Payment Reconciliation")
  |> should.be_true
  let path = xdg.concerns_dir(ctx.paths) <> "/cics-342.md"
  let content = simplifile.read(path) |> should.be_ok
  content |> string.contains("Status: active") |> should.be_true
  content |> string.contains("Jira CICS-342") |> should.be_true

  let _ = simplifile.delete_all([base])
  Nil
}

pub fn track_tool_rejects_invalid_slug_test() {
  let base = "/tmp/aura-track-tool-invalid-" <> test_helpers.random_suffix()
  let _ = simplifile.delete_all([base])
  let ctx = track_ctx(base)

  let out =
    run_track_tool(
      ctx,
      "{\"action\":\"start\",\"slug\":\"../cics-342\",\"title\":\"Bad\"}",
    )

  out |> string.contains("Error: invalid slug") |> should.be_true
  simplifile.is_file(xdg.concerns_dir(ctx.paths) <> "/../cics-342.md")
  |> should.equal(Ok(False))

  let _ = simplifile.delete_all([base])
  Nil
}

pub fn expand_tool_calls_preserves_non_concat_test() {
  let calls = [
    llm.ToolCall(
      id: "1",
      name: "read_file",
      arguments: "{\"path\":\"foo.txt\"}",
    ),
    llm.ToolCall(
      id: "2",
      name: "jira",
      arguments: "{\"name\":\"jira\",\"args\":\"a\"}{\"name\":\"jira\",\"args\":\"b\"}",
    ),
  ]
  let expanded = brain_tools.expand_tool_calls(calls)
  list.length(expanded) |> should.equal(3)
  case expanded {
    [first, second, third] -> {
      first.id |> should.equal("1")
      first.name |> should.equal("read_file")
      second.id |> should.equal("2_0")
      third.id |> should.equal("2_1")
    }
    _ -> should.fail()
  }
}

// ---------------------------------------------------------------------------
// search_events tool tests
// ---------------------------------------------------------------------------

fn search_events_ctx(
  db_subject: process.Subject(db.DbMessage),
) -> brain_tools.ToolContext {
  let stub = test_harness.standalone_tool_context()
  brain_tools.ToolContext(..stub, db_subject: db_subject)
}

fn gmail_event(
  id: String,
  subject: String,
  from: String,
  thread: String,
  time_ms: Int,
) -> event.AuraEvent {
  event.AuraEvent(
    id: id,
    source: "gmail-work",
    type_: "message",
    subject: subject,
    time_ms: time_ms,
    tags: dict.from_list([#("from", from), #("thread", thread)]),
    external_id: id,
    data: "{}",
  )
}

fn linear_event(
  id: String,
  subject: String,
  author: String,
  status: String,
  time_ms: Int,
) -> event.AuraEvent {
  event.AuraEvent(
    id: id,
    source: "linear",
    type_: "ticket",
    subject: subject,
    time_ms: time_ms,
    tags: dict.from_list([#("author", author), #("status", status)]),
    external_id: id,
    data: "{}",
  )
}

fn run_search_events_tool(
  ctx: brain_tools.ToolContext,
  args_json: String,
) -> String {
  let call = llm.ToolCall(id: "1", name: "search_events", arguments: args_json)
  let #(result, _) = brain_tools.execute_tool(ctx, call)
  case result {
    brain_tools.TextResult(s) -> s
  }
}

pub fn search_events_tool_returns_matching_events_test() {
  let assert Ok(db_subject) = db.start(":memory:")
  let ctx = search_events_ctx(db_subject)

  let g =
    gmail_event(
      "g1",
      "Re: Q4 terms with alice",
      "alice@acme.com",
      "t-abc-123",
      1_700_000_000_000,
    )
  let l =
    linear_event(
      "l1",
      "ENG-42: alice found auth timeout",
      "alice@acme.com",
      "In Progress",
      1_700_100_000_000,
    )
  let assert Ok(True) = db.insert_event(db_subject, g)
  let assert Ok(True) = db.insert_event(db_subject, l)

  let out = run_search_events_tool(ctx, "{\"query\":\"alice\"}")
  string.contains(out, "gmail-work") |> should.be_true
  string.contains(out, "linear") |> should.be_true
  string.contains(out, "Event ID: g1") |> should.be_true
  string.contains(out, "Event ID: l1") |> should.be_true
  string.contains(out, "alice@acme.com") |> should.be_true
  string.contains(out, "t-abc-123") |> should.be_true
  string.contains(out, "In Progress") |> should.be_true

  process.send(db_subject, db.Shutdown)
}

pub fn search_events_tool_falls_back_to_loose_keywords_test() {
  let assert Ok(db_subject) = db.start(":memory:")
  let ctx = search_events_ctx(db_subject)
  let assert Ok(True) =
    db.insert_event(
      db_subject,
      gmail_event(
        "pkg-1",
        "Have you received order #123?",
        "notice@packageco.test",
        "thread-packageco",
        1_700_000_000_000,
      ),
    )

  let out = run_search_events_tool(ctx, "{\"query\":\"PackageCo delivery\"}")

  string.contains(out, "No exact phrase match") |> should.be_true
  string.contains(out, "Event ID: pkg-1") |> should.be_true
  string.contains(out, "notice@packageco.test") |> should.be_true

  process.send(db_subject, db.Shutdown)
}

pub fn search_events_tool_empty_query_returns_recent_test() {
  let assert Ok(db_subject) = db.start(":memory:")
  let ctx = search_events_ctx(db_subject)

  let e1 = gmail_event("g1", "first", "a@x.com", "t1", 1000)
  let e2 = gmail_event("g2", "second", "a@x.com", "t2", 2000)
  let e3 = gmail_event("g3", "third", "a@x.com", "t3", 3000)
  let assert Ok(True) = db.insert_event(db_subject, e1)
  let assert Ok(True) = db.insert_event(db_subject, e2)
  let assert Ok(True) = db.insert_event(db_subject, e3)

  let out = run_search_events_tool(ctx, "{\"query\":\"\"}")
  // All three subjects present
  string.contains(out, "first") |> should.be_true
  string.contains(out, "second") |> should.be_true
  string.contains(out, "third") |> should.be_true
  // Empty-query header uses the "recent" variant, not quoted query
  string.contains(out, "recent events") |> should.be_true

  process.send(db_subject, db.Shutdown)
}

pub fn search_events_tool_source_filter_test() {
  let assert Ok(db_subject) = db.start(":memory:")
  let ctx = search_events_ctx(db_subject)

  let g =
    gmail_event("g1", "ship the feature", "a@x.com", "t1", 1_700_000_000_000)
  let l =
    linear_event(
      "l1",
      "ship the feature",
      "a@x.com",
      "In Progress",
      1_700_100_000_000,
    )
  let assert Ok(True) = db.insert_event(db_subject, g)
  let assert Ok(True) = db.insert_event(db_subject, l)

  let out =
    run_search_events_tool(
      ctx,
      "{\"query\":\"ship\",\"source\":\"gmail-work\"}",
    )
  string.contains(out, "gmail-work") |> should.be_true
  string.contains(out, "linear") |> should.be_false
  string.contains(out, "In Progress") |> should.be_false

  process.send(db_subject, db.Shutdown)
}

pub fn search_events_tool_no_matches_returns_empty_message_test() {
  let assert Ok(db_subject) = db.start(":memory:")
  let ctx = search_events_ctx(db_subject)

  let g =
    gmail_event(
      "g1",
      "completely unrelated",
      "b@x.com",
      "t1",
      1_700_000_000_000,
    )
  let assert Ok(True) = db.insert_event(db_subject, g)

  let out = run_search_events_tool(ctx, "{\"query\":\"nonexistent\"}")
  out |> should.equal("No events matching \"nonexistent\".")

  process.send(db_subject, db.Shutdown)
}

pub fn search_events_tool_is_registered_test() {
  let tools = brain_tools.make_built_in_tools()
  let has =
    list.any(tools, fn(t) {
      case t {
        llm.ToolDefinition(name: "search_events", ..) -> True
        _ -> False
      }
    })
  has |> should.be_true
}
