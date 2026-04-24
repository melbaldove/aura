//// Async log-only cognitive context worker.
////
//// The worker consumes persisted event IDs, loads each event from the DB, builds
//// deterministic evidence context, and emits a compact log/report. It does not
//// make attention, work, authority, or concern decisions. Those belong to the
//// model-backed decision loop once text policies and replay evaluation exist.

import aura/cognitive_event
import aura/db
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision
import gleam/string
import logging

pub type Message {
  BuildContextForEvent(id: String)
}

pub type Status {
  ContextReady
  MissingEvent
  DbError
}

pub type Report {
  Report(
    event_id: String,
    status: Status,
    evidence_count: Int,
    resource_ref_count: Int,
    raw_ref_count: Int,
    errors: List(String),
  )
}

type State {
  State(db_subject: Subject(db.DbMessage), report_to: Option(Subject(Report)))
}

/// Start the production worker.
pub fn start(
  db_subject: Subject(db.DbMessage),
) -> Result(actor.Started(Subject(Message)), actor.StartError) {
  start_with(db_subject, None)
}

/// Start a worker with injected reporting for behavior tests.
pub fn start_with(
  db_subject: Subject(db.DbMessage),
  report_to: Option(Subject(Report)),
) -> Result(actor.Started(Subject(Message)), actor.StartError) {
  actor.new_with_initialiser(5000, fn(self_subject) {
    let state = State(db_subject: db_subject, report_to: report_to)
    Ok(actor.initialised(state) |> actor.returning(self_subject))
  })
  |> actor.on_message(handle_message)
  |> actor.start
}

/// Supervised child spec for the production worker.
pub fn supervised(
  db_subject: Subject(db.DbMessage),
) -> supervision.ChildSpecification(Subject(Message)) {
  supervision.worker(fn() { start(db_subject) })
}

/// Fire-and-forget context build request.
pub fn build_context(subject: Subject(Message), id: String) -> Nil {
  process.send(subject, BuildContextForEvent(id: id))
}

fn handle_message(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    BuildContextForEvent(id:) -> {
      build_event_context(state, id)
      actor.continue(state)
    }
  }
}

fn build_event_context(state: State, id: String) -> Nil {
  case db.get_event(state.db_subject, id) {
    Error(err) -> {
      let report =
        Report(
          event_id: id,
          status: DbError,
          evidence_count: 0,
          resource_ref_count: 0,
          raw_ref_count: 0,
          errors: [err],
        )
      emit_report(state, report)
    }
    Ok(None) -> {
      let report =
        Report(
          event_id: id,
          status: MissingEvent,
          evidence_count: 0,
          resource_ref_count: 0,
          raw_ref_count: 0,
          errors: ["event not found"],
        )
      emit_report(state, report)
    }
    Ok(Some(e)) -> {
      let observation = cognitive_event.from_event(e)
      let evidence = cognitive_event.extract_evidence(observation)
      let report =
        Report(
          event_id: id,
          status: ContextReady,
          evidence_count: list.length(evidence.atoms),
          resource_ref_count: list.length(evidence.resource_refs),
          raw_ref_count: list.length(evidence.raw_refs),
          errors: [],
        )
      emit_report(state, report)
    }
  }
}

fn emit_report(state: State, report: Report) -> Nil {
  case state.report_to {
    Some(subject) -> process.send(subject, report)
    None -> Nil
  }

  let msg =
    "[cognitive] event_id="
    <> report.event_id
    <> " status="
    <> status_to_string(report.status)
    <> " evidence_count="
    <> int.to_string(report.evidence_count)
    <> " resource_refs="
    <> int.to_string(report.resource_ref_count)
    <> " raw_refs="
    <> int.to_string(report.raw_ref_count)
    <> " errors="
    <> string.join(report.errors, "; ")

  case report.status {
    ContextReady -> logging.log(logging.Info, msg)
    MissingEvent -> logging.log(logging.Warning, msg)
    DbError -> logging.log(logging.Error, msg)
  }
}

pub fn status_to_string(status: Status) -> String {
  case status {
    ContextReady -> "context_ready"
    MissingEvent -> "missing_event"
    DbError -> "db_error"
  }
}
