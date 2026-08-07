import aura/cognitive_delivery
import aura/cognitive_eval
import aura/cognitive_improve
import aura/cognitive_label
import aura/cognitive_patch
import aura/cognitive_probe
import aura/cognitive_replay
import aura/cognitive_smoke
import aura/cognitive_worker
import aura/db
import aura/dreaming
import aura/event
import aura/event_ingest
import aura/external_asks
import aura/hook_protocol
import aura/time
import aura/xdg
import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import logging
import simplifile

// ---------------------------------------------------------------------------
// FFI
// ---------------------------------------------------------------------------

@external(erlang, "aura_socket_ffi", "start_listener")
fn start_listener_ffi(
  socket_path: String,
  handler: fn(String) -> String,
) -> Result(process.Pid, String)

@external(erlang, "aura_socket_ffi", "connect_and_send")
fn connect_and_send_ffi(
  socket_path: String,
  command: String,
) -> Result(String, String)

@external(erlang, "aura_socket_ffi", "connect_and_send")
fn connect_and_send_with_timeout_ffi(
  socket_path: String,
  command: String,
  timeout_ms: Int,
) -> Result(String, String)

@external(erlang, "aura_socket_ffi", "cleanup_socket")
fn cleanup_socket_ffi(socket_path: String) -> Nil

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// Runtime context needed by the command handler. Passed at listener startup.
pub type CtlContext {
  CtlContext(
    paths: xdg.Paths,
    db_subject: process.Subject(db.DbMessage),
    event_ingest_subject: process.Subject(event_ingest.IngestMessage),
    cognitive_subject: process.Subject(cognitive_worker.Message),
    delivery_subject: option.Option(process.Subject(cognitive_delivery.Message)),
    asks_subject: option.Option(process.Subject(external_asks.Message)),
    domains: List(String),
    dream_model: String,
    dream_budget_percent: Int,
    brain_context: Int,
    started_at_ms: Int,
  )
}

// ---------------------------------------------------------------------------
// Server (runs inside the daemon)
// ---------------------------------------------------------------------------

/// Start the control socket listener. Called during supervisor startup.
pub fn start(ctx: CtlContext) -> Result(Nil, String) {
  let socket_path = xdg.state_path(ctx.paths, "aura.sock")
  case
    start_listener_ffi(socket_path, fn(command) { handle_command(command, ctx) })
  {
    Ok(_pid) -> Ok(Nil)
    Error(e) -> Error("Failed to start ctl listener: " <> e)
  }
}

pub fn build_hook_event(
  source: String,
  type_: String,
  subject: String,
  external_id: String,
  data: String,
  id: String,
  time_ms: Int,
) -> event.AuraEvent {
  event.AuraEvent(
    id: id,
    source: source,
    type_: type_,
    subject: subject,
    time_ms: time_ms,
    tags: dict.new(),
    external_id: external_id,
    data: data,
  )
}

pub fn build_external_ask(
  source: String,
  correlation_id: String,
  target: String,
  text: String,
  buttons: List(String),
  time_ms: Int,
) -> db.StoredExternalAsk {
  let buttons_json =
    json.array(buttons, json.string) |> json.to_string
  db.StoredExternalAsk(
    id: correlation_id,
    source: source,
    channel_id: target,
    message_id: "",
    text: text,
    buttons_json: buttons_json,
    status: "pending",
    decision: "",
    requested_at_ms: time_ms,
    updated_at_ms: time_ms,
  )
}

/// Handle a single command from a CLI client.
fn handle_command(command: String, ctx: CtlContext) -> String {
  let trimmed = string.trim(command)
  // Payload commands carry JSON (may contain spaces); parse them off the
  // first whitespace-delimited token before matching the flat token lists.
  case string.split_once(trimmed, " ") {
    Ok(#("event", payload)) -> handle_hook_event(ctx, string.trim(payload))
    Ok(#("notify", payload)) -> handle_hook_notify(ctx, string.trim(payload))
    Ok(#("ask", payload)) -> handle_hook_ask(ctx, string.trim(payload))
    _ ->
      case string.split(trimmed, " ") {
        ["ping"] -> "pong"

    ["dream"] -> {
      logging.log(logging.Info, "[ctl] Dream triggered via CLI")
      process.spawn_unlinked(fn() {
        dreaming.dream_all(dreaming.DreamConfig(
          model_spec: ctx.dream_model,
          paths: ctx.paths,
          db_subject: ctx.db_subject,
          domains: ctx.domains,
          budget_percent: ctx.dream_budget_percent,
          brain_context: ctx.brain_context,
        ))
      })
      "OK: dream cycle started"
    }

    ["status"] -> {
      let uptime_ms = time.now_ms() - ctx.started_at_ms
      let uptime_min = uptime_ms / 60_000
      let domain_list = string.join(ctx.domains, ", ")
      let last_dream = case
        list.find_map(ctx.domains, fn(d) {
          case db.get_last_dream_ms(ctx.db_subject, d) {
            Ok(ms) if ms > 0 -> Ok(ms)
            _ -> Error(Nil)
          }
        })
      {
        Ok(ms) -> {
          let ago_min = { time.now_ms() - ms } / 60_000
          int.to_string(ago_min) <> "m ago"
        }
        Error(_) -> "never"
      }
      "uptime: "
      <> int.to_string(uptime_min)
      <> "m | domains: "
      <> domain_list
      <> " | last dream: "
      <> last_dream
    }

    ["cognitive-smoke", "gmail-rel42"] -> {
      logging.log(logging.Info, "[ctl] Cognitive smoke triggered: gmail-rel42")
      case
        cognitive_smoke.run_gmail_rel42(cognitive_smoke.Context(
          paths: ctx.paths,
          db_subject: ctx.db_subject,
          event_ingest_subject: ctx.event_ingest_subject,
          delivery_subject: ctx.delivery_subject,
        ))
      {
        Ok(report) -> report
        Error(err) -> "ERROR: " <> err
      }
    }

    ["cognitive-eval", "fixtures"] -> {
      logging.log(logging.Info, "[ctl] Cognitive eval triggered: fixtures")
      case
        cognitive_eval.run_fixtures(cognitive_eval.Context(
          paths: ctx.paths,
          db_subject: ctx.db_subject,
          event_ingest_subject: ctx.event_ingest_subject,
          delivery_subject: ctx.delivery_subject,
        ))
      {
        Ok(report) -> report
        Error(err) -> "ERROR: " <> err
      }
    }

    ["cognitive-replay", "labels"] -> {
      logging.log(logging.Info, "[ctl] Cognitive replay triggered: labels")
      case
        cognitive_replay.run_labels(cognitive_replay.Context(
          paths: ctx.paths,
          db_subject: ctx.db_subject,
          cognitive_subject: ctx.cognitive_subject,
          delivery_subject: ctx.delivery_subject,
        ))
      {
        Ok(report) -> report
        Error(err) -> "ERROR: " <> err
      }
    }

    ["cognitive-replay", "propose-patches"] -> {
      logging.log(
        logging.Info,
        "[ctl] Cognitive replay patch proposal triggered",
      )
      case cognitive_patch.propose_from_labels(ctx.paths, ctx.db_subject) {
        Ok(report) -> {
          case report.proposal_count {
            0 -> report.markdown
            _ ->
              "OK: cognitive-replay propose-patches labels="
              <> int.to_string(report.label_count)
              <> " proposals="
              <> int.to_string(report.proposal_count)
              <> " path="
              <> report.path
          }
        }
        Error(err) -> "ERROR: cognitive replay patch proposal failed: " <> err
      }
    }

    ["cognitive-improve", "propose"] -> {
      logging.log(
        logging.Info,
        "[ctl] Cognitive improvement proposal triggered",
      )
      case
        cognitive_improve.propose(cognitive_replay.Context(
          paths: ctx.paths,
          db_subject: ctx.db_subject,
          cognitive_subject: ctx.cognitive_subject,
          delivery_subject: ctx.delivery_subject,
        ))
      {
        Ok(report) -> {
          case report.proposal_count {
            0 -> report.markdown
            _ ->
              "OK: cognitive-improve propose labels="
              <> int.to_string(report.label_count)
              <> " failed="
              <> int.to_string(report.failed_count)
              <> " skipped="
              <> int.to_string(report.skipped_count)
              <> " proposals="
              <> int.to_string(report.proposal_count)
              <> " path="
              <> report.path
          }
        }
        Error(err) -> "ERROR: cognitive improvement proposal failed: " <> err
      }
    }

    ["cognitive-test", "deliver-now"] -> {
      logging.log(logging.Info, "[ctl] Cognitive delivery probe triggered")
      case
        cognitive_probe.run_deliver_now(cognitive_probe.Context(
          paths: ctx.paths,
          db_subject: ctx.db_subject,
          event_ingest_subject: ctx.event_ingest_subject,
        ))
      {
        Ok(report) -> report
        Error(err) -> "ERROR: " <> err
      }
    }

    ["cognitive-digest", "flush"] -> {
      logging.log(logging.Info, "[ctl] Cognitive digest flush triggered")
      case ctx.delivery_subject {
        option.Some(subject) -> {
          cognitive_delivery.flush_digest(subject)
          "OK: cognitive-digest flush triggered"
        }
        option.None -> "ERROR: cognitive delivery actor unavailable"
      }
    }

    ["cognitive-delivery", "retry-dead-letter"] -> {
      logging.log(
        logging.Info,
        "[ctl] Cognitive delivery dead-letter retry triggered",
      )
      case ctx.delivery_subject {
        option.Some(subject) -> {
          case cognitive_delivery.retry_dead_letters(subject) {
            Ok(summary) ->
              "OK: cognitive-delivery retry-dead-letter "
              <> cognitive_delivery.retry_summary_to_string(summary)
            Error(err) ->
              "ERROR: cognitive delivery dead-letter retry failed: " <> err
          }
        }
        option.None -> "ERROR: cognitive delivery actor unavailable"
      }
    }

    ["cognitive-label", event_id, label] -> {
      handle_cognitive_label(ctx, event_id, label, "", "")
    }

    ["cognitive-label", event_id, label, expected_attention, ..note_words] -> {
      handle_cognitive_label(
        ctx,
        event_id,
        label,
        expected_attention,
        string.join(note_words, " "),
      )
    }

    ["decision", cid] -> handle_hook_decision(ctx, cid)
    ["asks"] -> handle_asks_list(ctx)
    ["hooks"] -> handle_hooks_list(ctx)

    _ ->
      "ERROR: unknown command '"
      <> trimmed
      <> "'. Commands: ping, dream, status, cognitive-smoke gmail-rel42, cognitive-eval fixtures, cognitive-replay labels, cognitive-replay propose-patches, cognitive-improve propose, cognitive-test deliver-now, cognitive-digest flush, cognitive-delivery retry-dead-letter, cognitive-label <event_id> <label> [expected_attention] [note], event <json>, notify <json>, ask <json>, decision <correlation_id>, asks, hooks"
      }
  }
}

fn handle_cognitive_label(
  ctx: CtlContext,
  event_id: String,
  label: String,
  expected_attention: String,
  note: String,
) -> String {
  logging.log(logging.Info, "[ctl] Cognitive label capture triggered")
  case db.get_event(ctx.db_subject, event_id) {
    Error(err) -> "ERROR: failed to load event for label: " <> err
    Ok(option.None) -> "ERROR: event not found: " <> event_id
    Ok(option.Some(_event)) -> {
      case
        cognitive_label.capture(
          ctx.paths,
          event_id,
          label,
          expected_attention,
          note,
        )
      {
        Ok(result) ->
          "OK: cognitive-label event_id="
          <> result.event_id
          <> " label="
          <> result.label
          <> " attention_any=["
          <> string.join(result.attention_any, ", ")
          <> "] path="
          <> result.path
        Error(err) -> "ERROR: cognitive label failed: " <> err
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Client (runs from the CLI)
// ---------------------------------------------------------------------------

fn hook_event_id(time_ms: Int) -> String {
  "ev-" <> int.to_string(time_ms) <> "-" <> random_suffix()
}

@external(erlang, "erlang", "unique_integer")
fn erlang_unique_integer() -> Int

fn random_suffix() -> String {
  let raw = int.to_string(erlang_unique_integer())
  string.replace(raw, "-", "")
}

fn handle_hook_event(ctx: CtlContext, payload: String) -> String {
  case hook_protocol.parse("event " <> payload) {
    Error(err) -> "ERROR: " <> err
    Ok(hook_protocol.HookEvent(
      source: source,
      type_: type_,
      subject: subject,
      external_id: external_id,
      data: data,
    )) -> {
      let now = time.now_ms()
      let id = hook_event_id(now)
      let ev =
        build_hook_event(
          source,
          type_,
          subject,
          external_id,
          data,
          id,
          now,
        )
      event_ingest.ingest(ctx.event_ingest_subject, ev)
      hook_protocol.resp_ok_event_queued(id)
    }
    Ok(_) -> "ERROR: unexpected hook command"
  }
}

fn handle_hook_notify(ctx: CtlContext, payload: String) -> String {
  case hook_protocol.parse("notify " <> payload) {
    Error(err) -> "ERROR: " <> err
    Ok(hook_protocol.HookNotify(
      source: source,
      rule: rule,
      target: target,
      text: text,
      external_id: external_id,
    )) -> {
      let now = time.now_ms()
      let event_id = hook_event_id(now)
      let prefixed = hook_protocol.apply_provenance(source, rule, text)
      let audit =
        event.AuraEvent(
          id: event_id,
          source: source,
          type_: "hook.notify",
          subject: prefixed,
          time_ms: now,
          tags: dict.new(),
          external_id: external_id,
          data: "",
        )
      case db.insert_event(ctx.db_subject, audit) {
        Ok(False) -> hook_protocol.resp_ok_deduped()
        Ok(True) ->
          case ctx.delivery_subject {
            option.None -> "ERROR: cognitive delivery actor unavailable"
            option.Some(delivery_subject) ->
              case
                cognitive_delivery.deliver_hook_notify(
                  delivery_subject,
                  event_id,
                  source,
                  target,
                  prefixed,
                )
              {
                Ok(_) -> hook_protocol.resp_delivered(event_id)
                Error(err) -> "ERROR: " <> err
              }
          }
        Error(err) -> "ERROR: " <> err
      }
    }
    Ok(_) -> "ERROR: unexpected hook command"
  }
}

fn handle_hook_ask(ctx: CtlContext, payload: String) -> String {
  case hook_protocol.parse("ask " <> payload) {
    Error(err) -> "ERROR: " <> err
    Ok(hook_protocol.HookAsk(
      source: source,
      rule: rule,
      correlation_id: correlation_id,
      target: target,
      text: text,
      buttons: buttons,
      ttl_minutes: ttl_minutes,
    )) ->
      case ctx.asks_subject {
        option.None -> "ERROR: external asks actor unavailable"
        option.Some(asks_subject) -> {
          let now = time.now_ms()
          let prefixed = hook_protocol.apply_provenance(source, rule, text)
          let ask = build_external_ask(source, correlation_id, target, prefixed, buttons, now)
          let reply = process.new_subject()
          let _ = external_asks.submit_ask(asks_subject, ask, ttl_minutes * 60_000, reply)
          case process.receive(reply, ttl_minutes * 60_000 + 10_000) {
            Ok(line) -> line
            Error(_) -> hook_protocol.resp_error("ask waiter timed out locally")
          }
        }
      }
    Ok(_) -> "ERROR: unexpected hook command"
  }
}

fn handle_hook_decision(ctx: CtlContext, correlation_id: String) -> String {
  case ctx.asks_subject {
    option.None -> "ERROR: external asks actor unavailable"
    option.Some(asks_subject) -> external_asks.get_decision(asks_subject, correlation_id)
  }
}

fn handle_asks_list(ctx: CtlContext) -> String {
  case db.list_external_asks(ctx.db_subject, 20) {
    Error(err) -> "ERROR: " <> err
    Ok(asks) -> {
      let lines =
        list.map(asks, fn(ask) {
          let now = time.now_ms()
          let age_min = { now - ask.requested_at_ms } / 60_000
          ask.id
            <> " "
            <> ask.status
            <> " "
            <> ask.source
            <> " "
            <> case ask.decision {
              "" -> "-"
              d -> d
            }
            <> " "
            <> int.to_string(age_min)
            <> "m"
        })
      case lines {
        [] -> "OK: no asks"
        _ -> string.join(lines, "\n")
      }
    }
  }
}

fn handle_hooks_list(ctx: CtlContext) -> String {
  let hooks_dir = xdg.config_path(ctx.paths, "hooks")
  let rulesets =
    simplifile.read_directory(hooks_dir)
    |> result.map(fn(entries) {
      entries
      |> list.filter(fn(entry) { string.ends_with(entry, ".toml") })
      |> list.map(fn(entry) { string.drop_start(entry, string.length(entry) - 5) })
    })
    |> result.unwrap([])
  let ruleset_names = string.join(rulesets, ", ")
  let sources =
    case db.list_event_sources(ctx.db_subject) {
      Error(_) -> []
      Ok(rows) ->
        list.map(rows, fn(row) {
          let #(source, count, last_ms) = row
          let now = time.now_ms()
          let age_min = { now - last_ms } / 60_000
          source
            <> " events="
            <> int.to_string(count)
            <> " last="
            <> int.to_string(age_min)
            <> "m"
        })
    }
  "rulesets: " <> ruleset_names <> case sources {
    [] -> ""
    _ -> "\n" <> string.join(sources, "\n")
  }
}

/// Send a command to the running Aura daemon via Unix socket.
pub fn send(paths: xdg.Paths, command: String) -> Result(String, String) {
  let socket_path = xdg.state_path(paths, "aura.sock")
  connect_and_send_ffi(socket_path, command)
}

/// Send a command with a caller-supplied read timeout (blocking asks).
pub fn send_with_timeout(
  paths: xdg.Paths,
  command: String,
  timeout_ms: Int,
) -> Result(String, String) {
  let socket_path = xdg.state_path(paths, "aura.sock")
  connect_and_send_with_timeout_ffi(socket_path, command, timeout_ms)
}

/// Remove the socket file (called on shutdown).
pub fn cleanup(paths: xdg.Paths) -> Nil {
  let socket_path = xdg.state_path(paths, "aura.sock")
  cleanup_socket_ffi(socket_path)
}
