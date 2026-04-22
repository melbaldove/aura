//// Event ingest actor.
////
//// Sits between upstream MCP clients (or any other producer of `AuraEvent`s)
//// and the `db` actor. Responsibilities, in order:
////
////   1. Normalize — fill in `id` and `time_ms` when they are empty/zero
////      (convenience for tests and light callers; production MCP events
////      should arrive with both populated).
////   2. Tag — invoke the rule-based `event_tagger.tag/3` and merge the
////      resulting tags with any tags the caller explicitly set. Incoming
////      tags win on conflict.
////   3. Persist — call `db.insert_event`. Duplicates (by `(source,
////      external_id)`) are silently dropped; errors are logged but never
////      crash the actor.
////
//// Ingestion is fire-and-forget: callers send an `Ingest(event)` message
//// via `ingest/2` and continue immediately. There is no routing to flares
//// from here — that comes in a later phase.

import aura/db
import aura/event
import aura/event_tagger
import aura/time
import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/otp/actor
import gleam/otp/supervision
import logging

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

pub type IngestMessage {
  Ingest(event: event.AuraEvent)
}

type State {
  State(db_subject: Subject(db.DbMessage))
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Start the event ingest actor. Takes the db actor's subject as its only
/// dependency. Never fails for reasons beyond actor startup itself.
pub fn start(
  db_subject: Subject(db.DbMessage),
) -> Result(actor.Started(Subject(IngestMessage)), actor.StartError) {
  actor.new_with_initialiser(5000, fn(self_subject) {
    let state = State(db_subject: db_subject)
    Ok(actor.initialised(state) |> actor.returning(self_subject))
  })
  |> actor.on_message(handle_message)
  |> actor.start
}

/// Build a supervised child spec so the ingest actor can live under the
/// root supervisor.
pub fn supervised(
  db_subject: Subject(db.DbMessage),
) -> supervision.ChildSpecification(Subject(IngestMessage)) {
  supervision.worker(fn() { start(db_subject) })
}

/// Fire-and-forget send. The caller does not wait for the event to be
/// normalized, tagged, or persisted.
pub fn ingest(subject: Subject(IngestMessage), event: event.AuraEvent) -> Nil {
  process.send(subject, Ingest(event: event))
}

// ---------------------------------------------------------------------------
// Message handler
// ---------------------------------------------------------------------------

fn handle_message(
  state: State,
  message: IngestMessage,
) -> actor.Next(State, IngestMessage) {
  case message {
    Ingest(event: e) -> {
      let normalized = normalize(e)
      let tagged = attach_tags(normalized)
      case db.insert_event(state.db_subject, tagged) {
        Ok(True) -> Nil
        Ok(False) -> Nil
        Error(err) ->
          logging.log(
            logging.Error,
            "[event_ingest] insert_event failed for source="
              <> tagged.source
              <> " external_id="
              <> tagged.external_id
              <> ": "
              <> err,
          )
      }
      actor.continue(state)
    }
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Fill in `id` and `time_ms` when missing. Auto-filled fields are logged
/// as warnings — production callers (MCP clients) should populate both.
fn normalize(e: event.AuraEvent) -> event.AuraEvent {
  let time_ms = case e.time_ms {
    0 -> {
      let now = time.now_ms()
      logging.log(
        logging.Warning,
        "[event_ingest] event time_ms missing; filled with "
          <> int.to_string(now)
          <> " (source="
          <> e.source
          <> ")",
      )
      now
    }
    t -> t
  }

  let id = case e.id {
    "" -> {
      let generated = "ev-" <> int.to_string(time_ms) <> "-" <> random_suffix()
      logging.log(
        logging.Warning,
        "[event_ingest] event id missing; generated "
          <> generated
          <> " (source="
          <> e.source
          <> ")",
      )
      generated
    }
    existing -> existing
  }

  event.AuraEvent(..e, id: id, time_ms: time_ms)
}

/// Merge rule-based tagger output with the caller's tags. Incoming tags
/// take precedence on overlap — `dict.merge(a, b)` lets `b` win.
fn attach_tags(e: event.AuraEvent) -> event.AuraEvent {
  let rule_tags = event_tagger.tag(e.source, e.type_, e.data)
  let merged = dict.merge(rule_tags, e.tags)
  event.AuraEvent(..e, tags: merged)
}

/// Erlang's `unique_integer` returns a monotonically increasing integer
/// that is unique within a node lifetime. Good enough for test / fallback
/// event IDs without pulling in a UUID dependency.
fn random_suffix() -> String {
  let raw = int.to_string(erlang_unique_integer())
  // `unique_integer` can return negative values; strip the minus sign so
  // event IDs stay URL/filename-safe.
  case raw {
    "-" <> rest -> "n" <> rest
    other -> other
  }
}

@external(erlang, "erlang", "unique_integer")
fn erlang_unique_integer() -> Int
