//// Async log-only cognitive interpretation worker.
////
//// The worker consumes persisted event IDs, loads each event from the DB, builds
//// deterministic evidence, runs an injected interpreter, validates the output,
//// and emits a compact log/report. It never mutates concerns, memory, state, or
//// flares.

import aura/cognitive_event
import aura/cognitive_interpretation as ci
import aura/cognitive_validator
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
  InterpretEventId(id: String)
}

pub type Status {
  Valid
  Invalid
  MissingEvent
  DbError
}

pub type Report {
  Report(
    event_id: String,
    status: Status,
    evidence_count: Int,
    attention_action: String,
    work_action: String,
    gap_count: Int,
    errors: List(String),
  )
}

pub type Interpreter =
  fn(cognitive_event.Observation, cognitive_event.EvidenceBundle) ->
    ci.CognitiveInterpretation

type State {
  State(
    db_subject: Subject(db.DbMessage),
    interpreter: Interpreter,
    report_to: Option(Subject(Report)),
  )
}

/// Start the production worker with the conservative record-only interpreter.
pub fn start(
  db_subject: Subject(db.DbMessage),
) -> Result(actor.Started(Subject(Message)), actor.StartError) {
  start_with(db_subject, ci.record_only, None)
}

/// Start a worker with injected interpretation/reporting for behavior tests.
pub fn start_with(
  db_subject: Subject(db.DbMessage),
  interpreter: Interpreter,
  report_to: Option(Subject(Report)),
) -> Result(actor.Started(Subject(Message)), actor.StartError) {
  actor.new_with_initialiser(5000, fn(self_subject) {
    let state =
      State(
        db_subject: db_subject,
        interpreter: interpreter,
        report_to: report_to,
      )
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

/// Fire-and-forget interpretation request.
pub fn interpret_event(subject: Subject(Message), id: String) -> Nil {
  process.send(subject, InterpretEventId(id: id))
}

fn handle_message(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    InterpretEventId(id:) -> {
      interpret(state, id)
      actor.continue(state)
    }
  }
}

fn interpret(state: State, id: String) -> Nil {
  case db.get_event(state.db_subject, id) {
    Error(err) -> {
      let report =
        Report(
          event_id: id,
          status: DbError,
          evidence_count: 0,
          attention_action: "",
          work_action: "",
          gap_count: 0,
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
          attention_action: "",
          work_action: "",
          gap_count: 0,
          errors: ["event not found"],
        )
      emit_report(state, report)
    }
    Ok(Some(e)) -> {
      let observation = cognitive_event.from_event(e)
      let evidence = cognitive_event.extract_evidence(observation)
      let interpretation = state.interpreter(observation, evidence)
      case cognitive_validator.validate(interpretation, evidence) {
        Ok(valid) -> {
          let report =
            Report(
              event_id: id,
              status: Valid,
              evidence_count: list.length(evidence.atoms),
              attention_action: ci.attention_action_to_string(
                valid.attention_judgment.action,
              ),
              work_action: ci.work_action_to_string(
                valid.work_disposition.action,
              ),
              gap_count: list.length(valid.gap_events),
              errors: [],
            )
          emit_report(state, report)
        }
        Error(errors) -> {
          let report =
            Report(
              event_id: id,
              status: Invalid,
              evidence_count: list.length(evidence.atoms),
              attention_action: ci.attention_action_to_string(
                interpretation.attention_judgment.action,
              ),
              work_action: ci.work_action_to_string(
                interpretation.work_disposition.action,
              ),
              gap_count: list.length(interpretation.gap_events),
              errors: errors,
            )
          emit_report(state, report)
        }
      }
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
    <> " attention="
    <> report.attention_action
    <> " work="
    <> report.work_action
    <> " gaps="
    <> int.to_string(report.gap_count)
    <> " errors="
    <> string.join(report.errors, "; ")

  case report.status {
    Valid -> logging.log(logging.Info, msg)
    Invalid | MissingEvent -> logging.log(logging.Warning, msg)
    DbError -> logging.log(logging.Error, msg)
  }
}

pub fn status_to_string(status: Status) -> String {
  case status {
    Valid -> "valid"
    Invalid -> "invalid"
    MissingEvent -> "missing_event"
    DbError -> "db_error"
  }
}
