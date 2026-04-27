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
import aura/event_ingest
import aura/time
import aura/xdg
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option
import gleam/string
import logging

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

/// Handle a single command from a CLI client.
fn handle_command(command: String, ctx: CtlContext) -> String {
  let trimmed = string.trim(command)
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

    _ ->
      "ERROR: unknown command '"
      <> trimmed
      <> "'. Commands: ping, dream, status, cognitive-smoke gmail-rel42, cognitive-eval fixtures, cognitive-replay labels, cognitive-replay propose-patches, cognitive-improve propose, cognitive-test deliver-now, cognitive-digest flush, cognitive-delivery retry-dead-letter, cognitive-label <event_id> <label> [expected_attention] [note]"
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

/// Send a command to the running Aura daemon via Unix socket.
pub fn send(paths: xdg.Paths, command: String) -> Result(String, String) {
  let socket_path = xdg.state_path(paths, "aura.sock")
  connect_and_send_ffi(socket_path, command)
}

/// Remove the socket file (called on shutdown).
pub fn cleanup(paths: xdg.Paths) -> Nil {
  let socket_path = xdg.state_path(paths, "aura.sock")
  cleanup_socket_ffi(socket_path)
}
