//// Async cognitive decision worker.
////
//// The worker consumes persisted event IDs, loads each event from the DB, builds
//// deterministic evidence context, loads text policies/concerns, asks the
//// configured model for one decision envelope, validates it, and appends the
//// decision to a JSONL log. Ingestion remains fire-and-forget.

import aura/clients/llm_client
import aura/cognitive_context
import aura/cognitive_decision
import aura/cognitive_delivery
import aura/cognitive_event
import aura/db
import aura/llm
import aura/memory
import aura/time
import aura/xdg
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
import gleam/string
import logging
import simplifile

pub type Message {
  BuildContextForEvent(id: String)
}

pub type Status {
  DecisionReady
  MissingEvent
  DbError
  ContextError
  ModelError
  InvalidDecision
  DecisionLogError
}

const model_max_attempts = 3

const model_retry_delay_ms = 1000

pub type Report {
  Report(
    event_id: String,
    status: Status,
    evidence_count: Int,
    resource_ref_count: Int,
    raw_ref_count: Int,
    citation_count: Int,
    attention_action: String,
    work_action: String,
    authority_required: String,
    errors: List(String),
  )
}

type State {
  State(
    db_subject: Subject(db.DbMessage),
    paths: xdg.Paths,
    llm_config: llm.LlmConfig,
    chat_text: fn(llm.LlmConfig, List(llm.Message), Option(Float)) ->
      Result(String, String),
    report_to: Option(Subject(Report)),
    delivery_subject: Option(Subject(cognitive_delivery.Message)),
    delivery_targets: List(String),
    digest_windows: List(String),
  )
}

/// Start the production worker.
pub fn start(
  db_subject: Subject(db.DbMessage),
  paths: xdg.Paths,
  llm_config: llm.LlmConfig,
) -> Result(actor.Started(Subject(Message)), actor.StartError) {
  start_with(
    db_subject,
    paths,
    llm_config,
    llm_client.production().chat_text,
    None,
  )
}

/// Start a worker with injected reporting for behavior tests.
pub fn start_with(
  db_subject: Subject(db.DbMessage),
  paths: xdg.Paths,
  llm_config: llm.LlmConfig,
  chat_text: fn(llm.LlmConfig, List(llm.Message), Option(Float)) ->
    Result(String, String),
  report_to: Option(Subject(Report)),
) -> Result(actor.Started(Subject(Message)), actor.StartError) {
  start_with_options(
    db_subject,
    paths,
    llm_config,
    chat_text,
    report_to,
    None,
    [
      "none",
      "default",
    ],
    [],
  )
}

/// Start a production worker connected to the cognitive delivery actor.
pub fn start_with_delivery(
  db_subject: Subject(db.DbMessage),
  paths: xdg.Paths,
  llm_config: llm.LlmConfig,
  delivery_subject: Subject(cognitive_delivery.Message),
  delivery_targets: List(String),
  digest_windows: List(String),
) -> Result(actor.Started(Subject(Message)), actor.StartError) {
  start_with_options(
    db_subject,
    paths,
    llm_config,
    llm_client.production().chat_text,
    None,
    Some(delivery_subject),
    delivery_targets,
    digest_windows,
  )
}

/// Start a worker with injected model, reporting, and delivery for behavior tests.
pub fn start_with_delivery_and_report(
  db_subject: Subject(db.DbMessage),
  paths: xdg.Paths,
  llm_config: llm.LlmConfig,
  chat_text: fn(llm.LlmConfig, List(llm.Message), Option(Float)) ->
    Result(String, String),
  report_to: Option(Subject(Report)),
  delivery_subject: Subject(cognitive_delivery.Message),
  delivery_targets: List(String),
  digest_windows: List(String),
) -> Result(actor.Started(Subject(Message)), actor.StartError) {
  start_with_options(
    db_subject,
    paths,
    llm_config,
    chat_text,
    report_to,
    Some(delivery_subject),
    delivery_targets,
    digest_windows,
  )
}

fn start_with_options(
  db_subject: Subject(db.DbMessage),
  paths: xdg.Paths,
  llm_config: llm.LlmConfig,
  chat_text: fn(llm.LlmConfig, List(llm.Message), Option(Float)) ->
    Result(String, String),
  report_to: Option(Subject(Report)),
  delivery_subject: Option(Subject(cognitive_delivery.Message)),
  delivery_targets: List(String),
  digest_windows: List(String),
) -> Result(actor.Started(Subject(Message)), actor.StartError) {
  actor.new_with_initialiser(5000, fn(self_subject) {
    let state =
      State(
        db_subject: db_subject,
        paths: paths,
        llm_config: llm_config,
        chat_text: chat_text,
        report_to: report_to,
        delivery_subject: delivery_subject,
        delivery_targets: delivery_targets,
        digest_windows: digest_windows,
      )
    Ok(actor.initialised(state) |> actor.returning(self_subject))
  })
  |> actor.on_message(handle_message)
  |> actor.start
}

/// Supervised child spec for the production worker.
pub fn supervised(
  db_subject: Subject(db.DbMessage),
  paths: xdg.Paths,
  llm_config: llm.LlmConfig,
) -> supervision.ChildSpecification(Subject(Message)) {
  supervision.worker(fn() { start(db_subject, paths, llm_config) })
}

/// Fire-and-forget cognitive decision request.
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
          citation_count: 0,
          attention_action: "",
          work_action: "",
          authority_required: "",
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
          citation_count: 0,
          attention_action: "",
          work_action: "",
          authority_required: "",
          errors: ["event not found"],
        )
      emit_report(state, report)
    }
    Ok(Some(e)) -> {
      let observation = cognitive_event.from_event(e)
      let evidence = cognitive_event.extract_evidence(observation)
      decide_for_event(state, id, observation, evidence)
    }
  }
}

fn decide_for_event(
  state: State,
  id: String,
  observation: cognitive_event.Observation,
  evidence: cognitive_event.EvidenceBundle,
) -> Nil {
  let evidence_count = list.length(evidence.atoms)
  let resource_ref_count = list.length(evidence.resource_refs)
  let raw_ref_count = list.length(evidence.raw_refs)

  case
    cognitive_context.build_with_delivery_targets_and_digest_windows(
      state.paths,
      observation,
      evidence,
      state.delivery_targets,
      state.digest_windows,
    )
  {
    Error(err) ->
      emit_report(
        state,
        base_report(
          id,
          ContextError,
          evidence_count,
          resource_ref_count,
          raw_ref_count,
          [err],
        ),
      )

    Ok(context) -> {
      let messages = cognitive_decision.build_messages(context)
      case chat_text_with_retries(state, messages, model_max_attempts) {
        Error(err) ->
          emit_report(
            state,
            base_report(
              id,
              ModelError,
              evidence_count,
              resource_ref_count,
              raw_ref_count,
              [err],
            ),
          )

        Ok(raw_response) -> {
          case cognitive_decision.decode_response(raw_response) {
            Error(err) ->
              emit_report(
                state,
                base_report(
                  id,
                  InvalidDecision,
                  evidence_count,
                  resource_ref_count,
                  raw_ref_count,
                  [err],
                ),
              )

            Ok(decision) -> {
              case cognitive_decision.validate(decision, context) {
                Error(errors) ->
                  emit_report(
                    state,
                    base_report(
                      id,
                      InvalidDecision,
                      evidence_count,
                      resource_ref_count,
                      raw_ref_count,
                      errors,
                    ),
                  )

                Ok(validated) -> {
                  case append_decision(state.paths, validated, raw_response) {
                    Error(err) ->
                      emit_report(
                        state,
                        Report(
                          event_id: id,
                          status: DecisionLogError,
                          evidence_count: evidence_count,
                          resource_ref_count: resource_ref_count,
                          raw_ref_count: raw_ref_count,
                          citation_count: list.length(validated.citations),
                          attention_action: validated.attention.action,
                          work_action: validated.work.action,
                          authority_required: validated.authority.required,
                          errors: [err],
                        ),
                      )

                    Ok(_) -> {
                      emit_delivery(state, validated)
                      emit_report(
                        state,
                        Report(
                          event_id: id,
                          status: DecisionReady,
                          evidence_count: evidence_count,
                          resource_ref_count: resource_ref_count,
                          raw_ref_count: raw_ref_count,
                          citation_count: list.length(validated.citations),
                          attention_action: validated.attention.action,
                          work_action: validated.work.action,
                          authority_required: validated.authority.required,
                          errors: [],
                        ),
                      )
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}

fn chat_text_with_retries(
  state: State,
  messages: List(llm.Message),
  attempts_remaining: Int,
) -> Result(String, String) {
  case state.chat_text(state.llm_config, messages, Some(0.0)) {
    Ok(raw_response) -> Ok(raw_response)
    Error(err) -> {
      case attempts_remaining > 1 {
        True -> {
          logging.log(
            logging.Warning,
            "[cognitive] model call failed, retrying: " <> err,
          )
          process.sleep(model_retry_delay_ms)
          chat_text_with_retries(state, messages, attempts_remaining - 1)
        }
        False -> Error(err)
      }
    }
  }
}

fn emit_delivery(
  state: State,
  decision: cognitive_decision.DecisionEnvelope,
) -> Nil {
  case state.delivery_subject {
    Some(subject) -> cognitive_delivery.deliver(subject, decision)
    None -> Nil
  }
}

fn append_decision(
  paths: xdg.Paths,
  decision: cognitive_decision.DecisionEnvelope,
  raw_response: String,
) -> Result(Nil, String) {
  use _ <- result.try(
    simplifile.create_directory_all(xdg.cognitive_dir(paths))
    |> result.map_error(fn(e) {
      "Failed to create cognitive directory "
      <> xdg.cognitive_dir(paths)
      <> ": "
      <> string.inspect(e)
    }),
  )
  memory.append_jsonl(
    xdg.decisions_path(paths),
    cognitive_decision.to_json(decision, raw_response, time.now_ms()),
  )
}

fn base_report(
  event_id: String,
  status: Status,
  evidence_count: Int,
  resource_ref_count: Int,
  raw_ref_count: Int,
  errors: List(String),
) -> Report {
  Report(
    event_id: event_id,
    status: status,
    evidence_count: evidence_count,
    resource_ref_count: resource_ref_count,
    raw_ref_count: raw_ref_count,
    citation_count: 0,
    attention_action: "",
    work_action: "",
    authority_required: "",
    errors: errors,
  )
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
    <> " citations="
    <> int.to_string(report.citation_count)
    <> " attention="
    <> report.attention_action
    <> " work="
    <> report.work_action
    <> " authority="
    <> report.authority_required
    <> " errors="
    <> string.join(report.errors, "; ")

  case report.status {
    DecisionReady -> logging.log(logging.Info, msg)
    MissingEvent -> logging.log(logging.Warning, msg)
    DbError | ContextError | ModelError | InvalidDecision | DecisionLogError ->
      logging.log(logging.Error, msg)
  }
}

pub fn status_to_string(status: Status) -> String {
  case status {
    DecisionReady -> "decision_ready"
    MissingEvent -> "missing_event"
    DbError -> "db_error"
    ContextError -> "context_error"
    ModelError -> "model_error"
    InvalidDecision -> "invalid_decision"
    DecisionLogError -> "decision_log_error"
  }
}
