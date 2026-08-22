//// User-attention delivery actor for validated cognitive decisions.
////
//// The model chooses an attention action and delivery target. This actor owns
//// the mechanical effects: duplicate protection, JSONL delivery state,
//// immediate Discord sends, digest flushing, and operator dead-letter retry.

import aura/attention_queue
import aura/cognitive_decision
import aura/db
import aura/delivery/discord_compat
import aura/discord/message as discord_message
import aura/memory
import aura/operating_contracts
import aura/operational_audit
import aura/time
import aura/transport.{type Transport}
import aura/xdg
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import logging
import simplifile

pub type DeliveryTarget {
  DeliveryTarget(id: String, channel_id: String, label: String)
}

pub type Message {
  Deliver(cognitive_decision.DecisionEnvelope)
  DeliverAuthorized(
    cognitive_decision.DecisionEnvelope,
    operating_contracts.CanaryAuthorizationV1,
  )
  FlushDigest
  RetryDeadLetters(reply: Subject(Result(RetrySummary, String)))
  SuppressEvent(event_id: String, reason: String)
  DeliverHookNotify(
    event_id: String,
    source: String,
    target: String,
    text: String,
    reply: Subject(Result(String, String)),
  )
  RecordHookDelivery(
    event_id: String,
    source: String,
    target: String,
    channel_id: String,
    text: String,
    reply: Subject(Result(Nil, String)),
  )
  DrainAttention
  Tick
}

pub type Status {
  Recorded
  Queued
  Delivered
  Suppressed
  Failed
  DeadLetter
  DuplicateSuppressed
}

pub type Report {
  Report(event_id: String, status: Status, target: String, error: String)
}

pub type RetrySummary {
  RetrySummary(retryable: Int, delivered: Int, failed: Int, skipped: Int)
}

type State {
  State(
    paths: xdg.Paths,
    discord: Transport,
    targets: List(DeliveryTarget),
    digest_windows: List(String),
    history_db_subject: Option(Subject(db.DbMessage)),
    self_subject: Subject(Message),
    last_digest_window: String,
    report_to: Option(Subject(Report)),
  )
}

type LedgerEntry {
  LedgerEntry(
    event_id: String,
    status: String,
    attention_action: String,
    target: String,
    channel_id: String,
    summary: String,
    rationale: String,
    authority_required: String,
    citations: List(String),
    gaps: List(String),
    error: String,
  )
}

pub fn start(
  paths: xdg.Paths,
  discord: Transport,
  targets: List(DeliveryTarget),
  digest_windows: List(String),
) -> Result(actor.Started(Subject(Message)), actor.StartError) {
  start_with(paths, discord, targets, digest_windows, None)
}

pub fn start_with(
  paths: xdg.Paths,
  discord: Transport,
  targets: List(DeliveryTarget),
  digest_windows: List(String),
  report_to: Option(Subject(Report)),
) -> Result(actor.Started(Subject(Message)), actor.StartError) {
  builder(paths, discord, targets, digest_windows, None, report_to)
  |> actor.start
}

fn builder(
  paths: xdg.Paths,
  discord: Transport,
  targets: List(DeliveryTarget),
  digest_windows: List(String),
  history_db_subject: Option(Subject(db.DbMessage)),
  report_to: Option(Subject(Report)),
) -> actor.Builder(State, Message, Subject(Message)) {
  actor.new_with_initialiser(5000, fn(self_subject) {
    let state =
      State(
        paths: paths,
        discord: discord,
        targets: targets,
        digest_windows: digest_windows,
        history_db_subject: history_db_subject,
        self_subject: self_subject,
        last_digest_window: "",
        report_to: report_to,
      )

    reconcile_interrupted_deliveries(state)
    process.send(self_subject, DrainAttention)
    process.send_after(self_subject, 60_000, Tick)
    Ok(actor.initialised(state) |> actor.returning(self_subject))
  })
  |> actor.on_message(handle_message)
}

/// Start cognitive delivery with a DB-backed history sink for successful
/// user-facing sends.
pub fn start_with_history(
  paths: xdg.Paths,
  discord: Transport,
  targets: List(DeliveryTarget),
  digest_windows: List(String),
  history_db_subject: Subject(db.DbMessage),
  report_to: Option(Subject(Report)),
) -> Result(actor.Started(Subject(Message)), actor.StartError) {
  builder(
    paths,
    discord,
    targets,
    digest_windows,
    Some(history_db_subject),
    report_to,
  )
  |> actor.start
}

/// Start named cognitive delivery for use in a restart tree.
pub fn start_named_with_history(
  name: process.Name(Message),
  paths: xdg.Paths,
  discord: Transport,
  targets: List(DeliveryTarget),
  digest_windows: List(String),
  history_db_subject: Subject(db.DbMessage),
  report_to: Option(Subject(Report)),
) -> Result(actor.Started(Subject(Message)), actor.StartError) {
  builder(
    paths,
    discord,
    targets,
    digest_windows,
    Some(history_db_subject),
    report_to,
  )
  |> actor.named(name)
  |> actor.start
}

pub fn deliver(
  subject: Subject(Message),
  decision: cognitive_decision.DecisionEnvelope,
) -> Nil {
  process.send(subject, Deliver(decision))
}

/// Enqueue one validated decision for an authorized Codex monitor route.
pub fn deliver_authorized(
  subject: Subject(Message),
  decision: cognitive_decision.DecisionEnvelope,
  authorization: operating_contracts.CanaryAuthorizationV1,
) -> Nil {
  process.send(subject, DeliverAuthorized(decision, authorization))
}

/// Deliver a hook-layer notify (lane 2, direct): send to the channel for the
/// given target, persist to conversation history, and ledger the delivery.
/// Returns `Ok("delivered")` or `Ok("deduped")` if the event was already
/// delivered, or `Error(...)` on unknown target / send failure.
pub fn deliver_hook_notify(
  subject: Subject(Message),
  event_id: String,
  source: String,
  target: String,
  text: String,
) -> Result(String, String) {
  process.call(subject, 30_000, fn(reply) {
    DeliverHookNotify(
      event_id: event_id,
      source: source,
      target: target,
      text: text,
      reply: reply,
    )
  })
}

/// Record a hook ask delivery that was posted by the external_asks actor:
/// append the ledger row and persist the message to channel history (system
/// invariant 9) without triggering a new Discord send.
pub fn record_hook_delivery(
  subject: Subject(Message),
  event_id: String,
  source: String,
  target: String,
  channel_id: String,
  text: String,
) -> Result(Nil, String) {
  process.call(subject, 5000, fn(reply) {
    RecordHookDelivery(
      event_id: event_id,
      source: source,
      target: target,
      channel_id: channel_id,
      text: text,
      reply: reply,
    )
  })
}

pub fn flush_digest(subject: Subject(Message)) -> Nil {
  process.send(subject, FlushDigest)
}

pub fn retry_dead_letters(
  subject: Subject(Message),
) -> Result(RetrySummary, String) {
  process.call(subject, 120_000, fn(reply) { RetryDeadLetters(reply:) })
}

pub fn retry_summary_to_string(summary: RetrySummary) -> String {
  "retried="
  <> int.to_string(summary.retryable)
  <> " delivered="
  <> int.to_string(summary.delivered)
  <> " failed="
  <> int.to_string(summary.failed)
  <> " skipped="
  <> int.to_string(summary.skipped)
}

pub fn suppress_event(
  subject: Subject(Message),
  event_id: String,
  reason: String,
) -> Nil {
  process.send(subject, SuppressEvent(event_id: event_id, reason: reason))
}

pub fn allowed_target_ids(targets: List(DeliveryTarget)) -> List(String) {
  ["none", ..list.map(targets, fn(target) { target.id })]
  |> unique_strings
}

pub fn default_target(channel_id: String) -> DeliveryTarget {
  DeliveryTarget(id: "default", channel_id: channel_id, label: "default")
}

pub fn domain_target(name: String, channel_id: String) -> DeliveryTarget {
  DeliveryTarget(
    id: "domain:" <> name,
    channel_id: channel_id,
    label: "domain " <> name,
  )
}

fn handle_message(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Deliver(decision) -> {
      deliver_decision(state, decision)
      actor.continue(state)
    }

    DeliverAuthorized(decision, authorization) -> {
      enqueue_authorized_decision(state, decision, authorization)
      actor.continue(state)
    }

    FlushDigest -> {
      flush_digest_entries(state)
      actor.continue(state)
    }

    RetryDeadLetters(reply:) -> {
      process.send(reply, retry_dead_letter_entries(state))
      actor.continue(state)
    }

    SuppressEvent(event_id:, reason:) -> {
      suppress(state, event_id, reason)
      actor.continue(state)
    }

    DeliverHookNotify(event_id:, source:, target:, text:, reply:) -> {
      let result =
        deliver_hook_notify_message(state, event_id, source, target, text)
      process.send(reply, result)
      actor.continue(state)
    }

    RecordHookDelivery(event_id:, source:, target:, channel_id:, text:, reply:) -> {
      let result =
        record_hook_delivery_message(
          state,
          event_id,
          source,
          target,
          channel_id,
          text,
        )
      process.send(reply, result)
      actor.continue(state)
    }

    DrainAttention -> {
      drain_attention_queue(state)
      actor.continue(state)
    }

    Tick -> {
      drain_attention_queue(state)
      let current = current_window()
      let current_key = current_window_key()
      let due =
        list.contains(state.digest_windows, current)
        && state.last_digest_window != current_key
      case due {
        True -> flush_digest_entries(state)
        False -> Nil
      }
      process.send_after(state.self_subject, 60_000, Tick)
      actor.continue(
        State(..state, last_digest_window: case due {
          True -> current_key
          False -> state.last_digest_window
        }),
      )
    }
  }
}

fn deliver_decision(
  state: State,
  decision: cognitive_decision.DecisionEnvelope,
) -> Nil {
  case delivery_effect_unknown(state.paths, decision.event_id) {
    Error(error) ->
      emit_ledger_failure(
        state,
        decision.event_id,
        decision.delivery.target,
        error,
      )
    Ok(True) ->
      emit_persistence_failure(
        state,
        decision.event_id,
        decision.delivery.target,
        "prior delivery effect is unknown; verify the target before retry",
      )
    Ok(False) -> deliver_decision_if_known(state, decision)
  }
}

fn deliver_decision_if_known(
  state: State,
  decision: cognitive_decision.DecisionEnvelope,
) -> Nil {
  case event_seen(state.paths, decision.event_id) {
    Ok(True) ->
      emit_report(
        state,
        Report(
          event_id: decision.event_id,
          status: DuplicateSuppressed,
          target: decision.delivery.target,
          error: "",
        ),
      )

    Error(err) -> {
      emit_ledger_failure(
        state,
        decision.event_id,
        decision.delivery.target,
        err,
      )
    }

    Ok(False) -> {
      case decision.attention.action {
        "record" -> {
          case append_decision_state(state, decision, "recorded", "", "") {
            Ok(Nil) ->
              emit_report(
                state,
                Report(
                  event_id: decision.event_id,
                  status: Recorded,
                  target: decision.delivery.target,
                  error: "",
                ),
              )
            Error(error) ->
              emit_ledger_failure(
                state,
                decision.event_id,
                decision.delivery.target,
                error,
              )
          }
        }

        "digest" -> queue_digest(state, decision)

        "surface_now" | "ask_now" -> send_immediate(state, decision)

        _ -> {
          let err = "invalid attention action: " <> decision.attention.action
          let _ = append_decision_state(state, decision, "failed", "", err)
          emit_report(
            state,
            Report(
              event_id: decision.event_id,
              status: Failed,
              target: decision.delivery.target,
              error: err,
            ),
          )
        }
      }
    }
  }
}

fn queue_digest(
  state: State,
  decision: cognitive_decision.DecisionEnvelope,
) -> Nil {
  case resolve_target(state.targets, decision.delivery.target) {
    Error(err) -> {
      emit_transition_result(
        state,
        decision,
        "dead_letter",
        "",
        err,
        DeadLetter,
      )
    }

    Ok(target) -> {
      emit_transition_result(
        state,
        decision,
        "queued",
        target.channel_id,
        "",
        Queued,
      )
    }
  }
}

fn emit_transition_result(
  state: State,
  decision: cognitive_decision.DecisionEnvelope,
  ledger_status: String,
  channel_id: String,
  error: String,
  report_status: Status,
) -> Nil {
  case
    append_decision_state(state, decision, ledger_status, channel_id, error)
  {
    Ok(Nil) ->
      emit_report(
        state,
        Report(
          event_id: decision.event_id,
          status: report_status,
          target: decision.delivery.target,
          error: error,
        ),
      )
    Error(ledger_error) ->
      emit_ledger_failure(
        state,
        decision.event_id,
        decision.delivery.target,
        ledger_error,
      )
  }
}

fn emit_ledger_failure(
  state: State,
  event_id: String,
  target: String,
  error: String,
) -> Nil {
  emit_persistence_failure(
    state,
    event_id,
    target,
    "delivery ledger write failed: " <> error,
  )
}

fn emit_persistence_failure(
  state: State,
  event_id: String,
  target: String,
  error: String,
) -> Nil {
  logging.log(
    logging.Error,
    "[cognitive_delivery] event_id=" <> event_id <> " " <> error,
  )
  emit_report(
    state,
    Report(event_id: event_id, status: Failed, target: target, error: error),
  )
}

fn send_immediate(
  state: State,
  decision: cognitive_decision.DecisionEnvelope,
) -> Nil {
  case state.history_db_subject {
    None ->
      emit_persistence_failure(
        state,
        decision.event_id,
        decision.delivery.target,
        "attention queue database is unavailable",
      )
    Some(db_subject) -> {
      let now = time.now_ms()
      case attention_queue.from_decision(decision, now) {
        Error(error) ->
          emit_persistence_failure(
            state,
            decision.event_id,
            decision.delivery.target,
            error,
          )
        Ok(request) ->
          case db.enqueue_attention(db_subject, request) {
            Error(error) ->
              emit_persistence_failure(
                state,
                decision.event_id,
                decision.delivery.target,
                error,
              )
            Ok(item) ->
              case item.state {
                "pending" | "deferred" -> drain_attention_queue(state)
                "delivered" | "acknowledged" ->
                  emit_report(
                    state,
                    Report(
                      event_id: decision.event_id,
                      status: DuplicateSuppressed,
                      target: decision.delivery.target,
                      error: "",
                    ),
                  )
                _ ->
                  emit_report(
                    state,
                    Report(
                      event_id: decision.event_id,
                      status: Failed,
                      target: decision.delivery.target,
                      error: "attention item is " <> item.state,
                    ),
                  )
              }
          }
      }
    }
  }
}

fn enqueue_authorized_decision(
  state: State,
  decision: cognitive_decision.DecisionEnvelope,
  authorization: operating_contracts.CanaryAuthorizationV1,
) -> Nil {
  case state.history_db_subject {
    None ->
      emit_persistence_failure(
        state,
        decision.event_id,
        authorization.attention_target,
        "attention queue database is unavailable",
      )
    Some(db_subject) ->
      case
        attention_queue.from_authorized_decision(
          decision,
          authorization,
          time.now_ms(),
        )
      {
        Error(error) ->
          emit_persistence_failure(
            state,
            decision.event_id,
            authorization.attention_target,
            error,
          )
        Ok(request) ->
          case
            db.enqueue_authorized_attention(
              db_subject,
              request,
              authorization.authorization_id,
            )
          {
            Error(error) ->
              emit_persistence_failure(
                state,
                decision.event_id,
                authorization.attention_target,
                error,
              )
            Ok(_) ->
              emit_report(
                state,
                Report(
                  event_id: decision.event_id,
                  status: Queued,
                  target: authorization.attention_target,
                  error: "",
                ),
              )
          }
      }
  }
}

fn drain_attention_queue(state: State) -> Nil {
  case state.history_db_subject {
    None -> Nil
    Some(db_subject) -> {
      let now = time.now_ms()
      let expired =
        db.expire_attention(db_subject, attention_queue.delivery_owner, now)
      case expired {
        Error(error) ->
          logging.log(
            logging.Error,
            "[attention_queue] expiry failed: " <> error,
          )
        Ok(_) -> Nil
      }
      case
        db.recover_attention(db_subject, attention_queue.delivery_owner, now)
      {
        Error(error) ->
          logging.log(
            logging.Error,
            "[attention_queue] recovery failed: " <> error,
          )
        Ok(_) ->
          case
            db.claim_attention(
              db_subject,
              attention_queue.delivery_owner,
              "cognitive_delivery",
              60_000,
              now,
            )
          {
            Error(error) ->
              logging.log(
                logging.Error,
                "[attention_queue] claim failed: " <> error,
              )
            Ok(None) -> Nil
            Ok(Some(claim)) -> {
              deliver_claimed_attention(state, db_subject, claim)
              drain_attention_queue(state)
            }
          }
      }
    }
  }
}

fn deliver_claimed_attention(
  state: State,
  db_subject: Subject(db.DbMessage),
  claim: attention_queue.Claim,
) -> Nil {
  let item = claim.item
  case resolve_target(state.targets, item.delivery_target) {
    Error(error) -> {
      let now = time.now_ms()
      case
        db.reschedule_attention(
          db_subject,
          claim.lease_token,
          error,
          now + 60_000,
          now,
        )
      {
        Error(persistence_error) ->
          emit_persistence_failure(
            state,
            item.decision_id,
            item.delivery_target,
            "reschedule failed: " <> persistence_error,
          )
        Ok(Nil) ->
          emit_report(
            state,
            Report(
              event_id: item.decision_id,
              status: Failed,
              target: item.delivery_target,
              error:,
            ),
          )
      }
    }
    Ok(target) -> {
      let now = time.now_ms()
      case
        db.renew_attention_lease(db_subject, claim.lease_token, 60_000, now)
      {
        Error(error) ->
          emit_persistence_failure(
            state,
            item.decision_id,
            item.delivery_target,
            error,
          )
        Ok(Nil) ->
          case db.begin_attention_delivery(db_subject, claim.lease_token, now) {
            Error(error) ->
              emit_persistence_failure(
                state,
                item.decision_id,
                item.delivery_target,
                error,
              )
            Ok(Nil) -> {
              let content = format_attention_item(item)
              case
                discord_compat.deliver(
                  state.discord,
                  target.channel_id,
                  content,
                )
              {
                discord_compat.Complete(visible_content:, receipts:) ->
                  case
                    db.complete_attention_delivery(
                      db_subject,
                      claim.lease_token,
                      target.channel_id,
                      visible_content,
                      receipts,
                      time.now_ms(),
                    )
                  {
                    Error(error) ->
                      emit_persistence_failure(
                        state,
                        item.decision_id,
                        item.delivery_target,
                        "queue outcome failed after send: " <> error,
                      )
                    Ok(Nil) -> {
                      append_attention_ledger(
                        state,
                        item,
                        "delivered",
                        target.channel_id,
                        "",
                      )
                      emit_report(
                        state,
                        Report(
                          event_id: item.decision_id,
                          status: Delivered,
                          target: item.delivery_target,
                          error: "",
                        ),
                      )
                    }
                  }
                discord_compat.EffectUnknown(
                  visible_content:,
                  receipts:,
                  error:,
                ) ->
                  case
                    db.mark_attention_effect_unknown(
                      db_subject,
                      claim.lease_token,
                      target.channel_id,
                      visible_content,
                      receipts,
                      error,
                      time.now_ms(),
                    )
                  {
                    Error(persistence_error) ->
                      emit_persistence_failure(
                        state,
                        item.decision_id,
                        item.delivery_target,
                        "effect_unknown persistence failed: "
                          <> persistence_error,
                      )
                    Ok(Nil) -> {
                      append_attention_ledger(
                        state,
                        item,
                        "effect_unknown",
                        target.channel_id,
                        error,
                      )
                      emit_report(
                        state,
                        Report(
                          event_id: item.decision_id,
                          status: Failed,
                          target: item.delivery_target,
                          error: "effect_unknown: " <> error,
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

fn deliver_hook_notify_message(
  state: State,
  event_id: String,
  source: String,
  target: String,
  text: String,
) -> Result(String, String) {
  use effect_unknown <- result.try(delivery_effect_unknown(
    state.paths,
    event_id,
  ))
  case effect_unknown {
    True ->
      Error("prior delivery effect is unknown; verify the target before retry")
    False ->
      case event_seen(state.paths, event_id) {
        Ok(True) -> Ok("deduped")
        Error(err) -> Error(err)
        Ok(False) ->
          deliver_unseen_hook_notify(state, event_id, source, target, text)
      }
  }
}

fn deliver_unseen_hook_notify(
  state: State,
  event_id: String,
  source: String,
  target: String,
  text: String,
) -> Result(String, String) {
  case resolve_target(state.targets, target) {
    Error(err) -> {
      use _ <- result.try(append_hook_ledger(
        state,
        event_id,
        source,
        "surface_now",
        target,
        "",
        text,
        "dead_letter",
        err,
      ))
      Error(err)
    }
    Ok(resolved) ->
      case
        append_hook_ledger(
          state,
          event_id,
          source,
          "surface_now",
          target,
          resolved.channel_id,
          text,
          "sending",
          "",
        )
      {
        Error(error) -> Error("delivery ledger write failed: " <> error)
        Ok(Nil) ->
          case send_discord_chunks(state.discord, resolved.channel_id, text) {
            Error(error) -> {
              let #(ledger_status, _) = send_failure_transition(error)
              use _ <- result.try(append_hook_ledger(
                state,
                event_id,
                source,
                "surface_now",
                target,
                resolved.channel_id,
                text,
                ledger_status,
                error,
              ))
              Error(error)
            }
            Ok(_) -> {
              use _ <- result.try(persist_front_surface_message(
                state,
                event_id,
                resolved.channel_id,
                text,
              ))
              use _ <- result.try(append_hook_ledger(
                state,
                event_id,
                source,
                "surface_now",
                target,
                resolved.channel_id,
                text,
                "delivered",
                "",
              ))
              emit_report(
                state,
                Report(
                  event_id: event_id,
                  status: Delivered,
                  target: target,
                  error: "",
                ),
              )
              Ok("delivered")
            }
          }
      }
  }
}

fn record_hook_delivery_message(
  state: State,
  event_id: String,
  source: String,
  target: String,
  channel_id: String,
  text: String,
) -> Result(Nil, String) {
  case event_seen(state.paths, event_id) {
    Error(error) -> Error(error)
    Ok(True) -> Ok(Nil)
    Ok(False) -> {
      use _ <- result.try(persist_front_surface_message(
        state,
        event_id,
        channel_id,
        text,
      ))
      append_hook_ledger(
        state,
        event_id,
        source,
        "ask_now",
        target,
        channel_id,
        text,
        "delivered",
        "",
      )
    }
  }
}

fn append_hook_ledger(
  state: State,
  event_id: String,
  source: String,
  attention_action: String,
  target: String,
  channel_id: String,
  text: String,
  status: String,
  error: String,
) -> Result(Nil, String) {
  let now = time.now_ms()
  use _ <- result.try(append_ledger(
    state.paths,
    json.object([
      #("timestamp_ms", json.int(now)),
      #("event_id", json.string(event_id)),
      #("status", json.string(status)),
      #("attention_action", json.string(attention_action)),
      #("target", json.string(target)),
      #("channel_id", json.string(channel_id)),
      #("summary", json.string(text)),
      #("rationale", json.string("hook-declared: " <> source)),
      #("authority_required", json.string("")),
      #("citations", json.array([], json.string)),
      #("gaps", json.array([], json.string)),
      #("error", json.string(error)),
    ]),
  ))
  append_delivery_transition_audit(state, event_id, status, now)
}

/// Resolve a hook notify/ask target id against the given targets list.
pub fn resolve_target(
  targets: List(DeliveryTarget),
  target_id: String,
) -> Result(DeliveryTarget, String) {
  case target_id {
    "none" -> Error("delivery target none has no channel")
    _ ->
      case list.find(targets, fn(target) { target.id == target_id }) {
        Ok(target) -> Ok(target)
        Error(_) -> Error("unknown delivery target: " <> target_id)
      }
  }
}

fn send_discord_chunks(
  discord: Transport,
  channel_id: String,
  content: String,
) -> Result(Nil, String) {
  send_discord_chunk_list(
    discord,
    channel_id,
    discord_message.split_to_discord_messages(content),
    False,
  )
}

fn send_discord_chunk_list(
  discord: Transport,
  channel_id: String,
  chunks: List(String),
  sent_any: Bool,
) -> Result(Nil, String) {
  case chunks {
    [] -> Ok(Nil)
    [chunk, ..rest] -> {
      case discord.send_message(channel_id, chunk) {
        Ok(_) -> send_discord_chunk_list(discord, channel_id, rest, True)
        Error(error) ->
          case sent_any {
            True -> Error("effect_unknown: partial Discord delivery: " <> error)
            False -> Error(error)
          }
      }
    }
  }
}

fn send_failure_transition(error: String) -> #(String, Status) {
  case string.starts_with(error, "effect_unknown:") {
    True -> #("effect_unknown", Failed)
    False -> #("dead_letter", DeadLetter)
  }
}

fn suppress(state: State, event_id: String, reason: String) -> Nil {
  case event_seen(state.paths, event_id) {
    Ok(True) -> Nil
    _ -> {
      let _ =
        append_ledger(
          state.paths,
          json.object([
            #("timestamp_ms", json.int(time.now_ms())),
            #("event_id", json.string(event_id)),
            #("status", json.string("suppressed")),
            #("attention_action", json.string("")),
            #("target", json.string("none")),
            #("channel_id", json.string("")),
            #("summary", json.string("")),
            #("rationale", json.string(reason)),
            #("authority_required", json.string("")),
            #("citations", json.array([], json.string)),
            #("gaps", json.array([], json.string)),
            #("error", json.string("")),
          ]),
        )
      emit_report(
        state,
        Report(
          event_id: event_id,
          status: Suppressed,
          target: "none",
          error: "",
        ),
      )
    }
  }
}

fn flush_digest_entries(state: State) -> Nil {
  case pending_digest_entries(state.paths) {
    Error(err) ->
      logging.log(
        logging.Error,
        "[cognitive_delivery] digest read failed: " <> err,
      )

    Ok(entries) -> {
      let targets =
        entries
        |> list.map(fn(entry) { entry.target })
        |> unique_strings

      list.each(targets, fn(target) {
        let items = list.filter(entries, fn(entry) { entry.target == target })
        send_digest_group(state, target, items)
      })
    }
  }
}

fn send_digest_group(
  state: State,
  target_id: String,
  entries: List(LedgerEntry),
) -> Nil {
  case entries {
    [] -> Nil
    [first, ..] -> {
      let channel_id = first.channel_id
      case channel_id {
        "" -> {
          let err = "queued digest entry has no channel_id"
          list.each(entries, fn(entry) {
            emit_entry_transition_result(
              state,
              entry,
              entry.channel_id,
              "dead_letter",
              err,
              DeadLetter,
            )
          })
        }

        _ -> {
          let content = format_digest(entries)
          case begin_entries_delivery(state, entries, channel_id) {
            Error(error) ->
              list.each(entries, fn(entry) {
                emit_ledger_failure(state, entry.event_id, target_id, error)
              })
            Ok(Nil) ->
              case send_discord_chunks(state.discord, channel_id, content) {
                Ok(_) -> {
                  case
                    persist_front_surface_message(
                      state,
                      first.event_id,
                      channel_id,
                      content,
                    )
                  {
                    Error(error) ->
                      list.each(entries, fn(entry) {
                        let _ =
                          emit_entry_transition_result(
                            state,
                            entry,
                            channel_id,
                            "effect_unknown",
                            "history write failed after send: " <> error,
                            Failed,
                          )
                        Nil
                      })
                    Ok(Nil) ->
                      list.each(entries, fn(entry) {
                        let _ =
                          emit_entry_transition_result(
                            state,
                            entry,
                            channel_id,
                            "delivered",
                            "",
                            Delivered,
                          )
                        Nil
                      })
                  }
                }

                Error(err) ->
                  list.each(entries, fn(entry) {
                    let #(ledger_status, report_status) =
                      send_failure_transition(err)
                    let _ =
                      emit_entry_transition_result(
                        state,
                        entry,
                        channel_id,
                        ledger_status,
                        err,
                        report_status,
                      )
                    Nil
                  })
              }
          }
        }
      }
    }
  }
}

fn retry_dead_letter_entries(state: State) -> Result(RetrySummary, String) {
  use entries <- result.try(retryable_dead_letter_entries(state.paths))
  let summary =
    RetrySummary(
      retryable: list.length(entries),
      delivered: 0,
      failed: 0,
      skipped: 0,
    )

  let summary = retry_digest_dead_letters(entries, state, summary)
  Ok(retry_immediate_dead_letters(entries, state, summary))
}

fn retry_digest_dead_letters(
  entries: List(LedgerEntry),
  state: State,
  summary: RetrySummary,
) -> RetrySummary {
  let digest_entries =
    entries
    |> list.filter(fn(entry) { entry.attention_action == "digest" })
  let target_ids =
    digest_entries
    |> list.map(fn(entry) { entry.target })
    |> unique_strings

  list.fold(target_ids, summary, fn(acc, target_id) {
    let target_entries =
      digest_entries
      |> list.filter(fn(entry) { entry.target == target_id })
    retry_digest_group(state, target_id, target_entries, acc)
  })
}

fn retry_digest_group(
  state: State,
  target_id: String,
  entries: List(LedgerEntry),
  summary: RetrySummary,
) -> RetrySummary {
  case entries {
    [] -> summary
    _ -> {
      case resolve_target(state.targets, target_id) {
        Error(err) -> {
          list.each(entries, fn(entry) {
            let _ =
              emit_entry_transition_result(
                state,
                entry,
                "",
                "dead_letter",
                err,
                DeadLetter,
              )
          })
          RetrySummary(..summary, failed: summary.failed + list.length(entries))
        }

        Ok(target) -> {
          let content = format_digest(entries)
          case begin_entries_delivery(state, entries, target.channel_id) {
            Error(error) -> {
              list.each(entries, fn(entry) {
                emit_ledger_failure(state, entry.event_id, target_id, error)
              })
              RetrySummary(
                ..summary,
                failed: summary.failed + list.length(entries),
              )
            }
            Ok(Nil) ->
              retry_marked_digest_group(
                state,
                target.channel_id,
                entries,
                content,
                summary,
              )
          }
        }
      }
    }
  }
}

fn retry_marked_digest_group(
  state: State,
  channel_id: String,
  entries: List(LedgerEntry),
  content: String,
  summary: RetrySummary,
) -> RetrySummary {
  let history_event_id = case entries {
    [first, ..] -> first.event_id
    [] -> ""
  }
  case send_discord_chunks(state.discord, channel_id, content) {
    Ok(_) ->
      case
        persist_front_surface_message(
          state,
          history_event_id,
          channel_id,
          content,
        )
      {
        Error(error) -> {
          list.each(entries, fn(entry) {
            let _ =
              emit_entry_transition_result(
                state,
                entry,
                channel_id,
                "effect_unknown",
                "history write failed after send: " <> error,
                Failed,
              )
            Nil
          })
          RetrySummary(..summary, failed: summary.failed + list.length(entries))
        }
        Ok(Nil) ->
          list.fold(entries, summary, fn(acc, entry) {
            case
              emit_entry_transition_result(
                state,
                entry,
                channel_id,
                "delivered",
                "",
                Delivered,
              )
            {
              True -> RetrySummary(..acc, delivered: acc.delivered + 1)
              False -> RetrySummary(..acc, failed: acc.failed + 1)
            }
          })
      }

    Error(err) -> {
      let #(ledger_status, report_status) = send_failure_transition(err)
      list.each(entries, fn(entry) {
        let _ =
          emit_entry_transition_result(
            state,
            entry,
            channel_id,
            ledger_status,
            err,
            report_status,
          )
      })
      RetrySummary(..summary, failed: summary.failed + list.length(entries))
    }
  }
}

fn retry_immediate_dead_letters(
  entries: List(LedgerEntry),
  state: State,
  summary: RetrySummary,
) -> RetrySummary {
  entries
  |> list.filter(fn(entry) {
    entry.attention_action == "surface_now"
    || entry.attention_action == "ask_now"
  })
  |> list.fold(summary, fn(acc, entry) {
    retry_immediate_entry(state, entry, acc)
  })
}

fn retry_immediate_entry(
  state: State,
  entry: LedgerEntry,
  summary: RetrySummary,
) -> RetrySummary {
  case state.history_db_subject {
    None -> RetrySummary(..summary, failed: summary.failed + 1)
    Some(db_subject) -> {
      let now = time.now_ms()
      let domain_id = case string.starts_with(entry.target, "domain:") {
        True -> string.replace(entry.target, "domain:", "")
        False -> "global"
      }
      let request =
        attention_queue.EnqueueRequest(
          queue_id: "attention:" <> entry.event_id,
          decision_id: entry.event_id,
          domain_id:,
          concern_id: None,
          event_refs: [entry.event_id],
          action: entry.attention_action,
          summary: entry.summary,
          rationale: entry.rationale,
          why_now: None,
          deferral_cost: None,
          why_not_digest: None,
          authority_request: case entry.authority_required {
            "" | "none" -> None
            value -> Some(value)
          },
          citations: entry.citations,
          delivery_owner: attention_queue.delivery_owner,
          delivery_target: entry.target,
          delivery_key: "cognitive:" <> entry.event_id,
          available_at: now,
          expires_at: None,
        )
      case db.enqueue_attention(db_subject, request) {
        Error(_) -> RetrySummary(..summary, failed: summary.failed + 1)
        Ok(item) -> {
          drain_attention_queue(state)
          case db.get_attention(db_subject, item.queue_id) {
            Ok(finished) if finished.state == "delivered" ->
              RetrySummary(..summary, delivered: summary.delivered + 1)
            _ -> RetrySummary(..summary, failed: summary.failed + 1)
          }
        }
      }
    }
  }
}

fn persist_front_surface_message(
  state: State,
  event_id: String,
  channel_id: String,
  content: String,
) -> Result(Nil, String) {
  case state.history_db_subject {
    None -> Ok(Nil)
    Some(db_subject) -> {
      let now = time.now_ms()
      case
        db.append_delivery_message_with_audit(
          db_subject,
          channel_id,
          event_id,
          content,
          now,
        )
      {
        Ok(Nil) -> Ok(Nil)
        Error(err) -> Error("channel " <> channel_id <> ": " <> err)
      }
    }
  }
}

pub fn format_immediate(decision: cognitive_decision.DecisionEnvelope) -> String {
  let header = case decision.attention.action {
    "ask_now" -> "**Aura needs a decision**"
    _ -> "**Aura noticed something attention-worthy**"
  }

  header
  <> "\n\n"
  <> decision.summary
  <> "\n\nRationale: "
  <> decision.attention.rationale
  <> "\nWhy now: "
  <> decision.attention.why_now
  <> "\nDeferral cost: "
  <> decision.attention.deferral_cost
  <> "\nWhy digest is insufficient: "
  <> decision.attention.why_not_digest
  <> "\nAuthority: "
  <> decision.authority.required
  <> authority_reason(decision.authority)
  <> gaps_block(decision.gaps)
  <> "\nCitations: "
  <> string.join(decision.citations, ", ")
  <> "\nEvent: "
  <> decision.event_id
}

fn format_attention_item(item: operating_contracts.AttentionQueueItem) -> String {
  let header = case item.action {
    "ask_now" -> "**Aura needs a decision**"
    _ -> "**Aura noticed something attention-worthy**"
  }
  header
  <> "\n\n"
  <> item.summary
  <> "\n\nRationale: "
  <> item.rationale
  <> optional_line("Why now", item.why_now)
  <> optional_line("Deferral cost", item.deferral_cost)
  <> optional_line("Why digest is insufficient", item.why_not_digest)
  <> optional_line("Authority", item.authority_request)
  <> "\nCitations: "
  <> string.join(item.citations, ", ")
  <> "\nEvent: "
  <> item.decision_id
}

fn optional_line(label: String, value: Option(String)) -> String {
  case value {
    None -> ""
    Some(text) -> "\n" <> label <> ": " <> text
  }
}

fn append_attention_ledger(
  state: State,
  item: operating_contracts.AttentionQueueItem,
  status: String,
  channel_id: String,
  error: String,
) -> Nil {
  let write =
    append_ledger(
      state.paths,
      json.object([
        #("timestamp_ms", json.int(time.now_ms())),
        #("event_id", json.string(item.decision_id)),
        #("status", json.string(status)),
        #("attention_action", json.string(item.action)),
        #("target", json.string(item.delivery_target)),
        #("channel_id", json.string(channel_id)),
        #("summary", json.string(item.summary)),
        #("rationale", json.string(item.rationale)),
        #(
          "authority_required",
          json.string(item.authority_request |> option.unwrap("none")),
        ),
        #("citations", json.array(item.citations, json.string)),
        #("gaps", json.array([], json.string)),
        #("error", json.string(error)),
      ]),
    )
  case write {
    Ok(Nil) -> Nil
    Error(problem) ->
      logging.log(
        logging.Error,
        "[attention_queue] compatibility ledger failed for "
          <> item.queue_id
          <> ": "
          <> problem,
      )
  }
}

fn format_digest(entries: List(LedgerEntry)) -> String {
  let lines =
    entries
    |> list.map(fn(entry) {
      "- "
      <> entry.summary
      <> " ["
      <> entry.event_id
      <> "]"
      <> "\n  Rationale: "
      <> entry.rationale
      <> case entry.authority_required {
        "none" | "" -> ""
        other -> "\n  Authority: " <> other
      }
    })

  "**Aura digest**\n\n" <> string.join(lines, "\n")
}

fn authority_reason(authority: cognitive_decision.AuthorityDecision) -> String {
  case authority.reason {
    "" -> ""
    reason -> " (" <> reason <> ")"
  }
}

fn gaps_block(gaps: List(String)) -> String {
  case gaps {
    [] -> ""
    _ -> "\nGaps: " <> string.join(gaps, "; ")
  }
}

fn append_decision_state(
  state: State,
  decision: cognitive_decision.DecisionEnvelope,
  status: String,
  channel_id: String,
  error: String,
) -> Result(Nil, String) {
  let now = time.now_ms()
  use _ <- result.try(append_ledger(
    state.paths,
    json.object([
      #("timestamp_ms", json.int(now)),
      #("event_id", json.string(decision.event_id)),
      #("status", json.string(status)),
      #("attention_action", json.string(decision.attention.action)),
      #("target", json.string(decision.delivery.target)),
      #("channel_id", json.string(channel_id)),
      #("summary", json.string(decision.summary)),
      #("rationale", json.string(decision.attention.rationale)),
      #("authority_required", json.string(decision.authority.required)),
      #("citations", json.array(decision.citations, json.string)),
      #("gaps", json.array(decision.gaps, json.string)),
      #("error", json.string(error)),
    ]),
  ))
  append_delivery_transition_audit(state, decision.event_id, status, now)
}

fn append_entry_state_with_channel(
  state: State,
  entry: LedgerEntry,
  status: String,
  channel_id: String,
  error: String,
) -> Result(Nil, String) {
  let now = time.now_ms()
  use _ <- result.try(append_ledger(
    state.paths,
    json.object([
      #("timestamp_ms", json.int(now)),
      #("event_id", json.string(entry.event_id)),
      #("status", json.string(status)),
      #("attention_action", json.string(entry.attention_action)),
      #("target", json.string(entry.target)),
      #("channel_id", json.string(channel_id)),
      #("summary", json.string(entry.summary)),
      #("rationale", json.string(entry.rationale)),
      #("authority_required", json.string(entry.authority_required)),
      #("citations", json.array(entry.citations, json.string)),
      #("gaps", json.array(entry.gaps, json.string)),
      #("error", json.string(error)),
    ]),
  ))
  append_delivery_transition_audit(state, entry.event_id, status, now)
}

fn append_delivery_transition_audit(
  state: State,
  event_id: String,
  status: String,
  occurred_at: Int,
) -> Result(Nil, String) {
  case state.history_db_subject {
    None -> Ok(Nil)
    Some(db_subject) ->
      db.append_operational_audit(
        db_subject,
        operational_audit.Record(
          schema_version: 1,
          audit_id: "",
          record_type: case status {
            "sending" -> "external_effect_intent"
            "delivered" -> "external_effect_outcome"
            _ -> "state_transition"
          },
          actor: "aura",
          source: "cognitive_delivery",
          action: "delivery." <> status,
          target_type: "delivery",
          target_id: event_id,
          before_version: None,
          after_version: None,
          idempotency_key: None,
          evidence_refs: [event_id],
          proof_refs: [],
          authority_ref: None,
          result: case status {
            "failed" | "dead_letter" | "effect_unknown" -> "failed"
            "sending" -> "pending"
            _ -> "succeeded"
          },
          error_code: None,
          occurred_at:,
        ),
      )
  }
}

fn emit_entry_transition_result(
  state: State,
  entry: LedgerEntry,
  channel_id: String,
  ledger_status: String,
  error: String,
  report_status: Status,
) -> Bool {
  case
    append_entry_state_with_channel(
      state,
      entry,
      ledger_status,
      channel_id,
      error,
    )
  {
    Ok(Nil) -> {
      emit_report(
        state,
        Report(
          event_id: entry.event_id,
          status: report_status,
          target: entry.target,
          error: error,
        ),
      )
      True
    }
    Error(ledger_error) -> {
      emit_ledger_failure(state, entry.event_id, entry.target, ledger_error)
      False
    }
  }
}

fn begin_entries_delivery(
  state: State,
  entries: List(LedgerEntry),
  channel_id: String,
) -> Result(Nil, String) {
  list.try_each(entries, fn(entry) {
    append_entry_state_with_channel(state, entry, "sending", channel_id, "")
  })
}

fn append_ledger(paths: xdg.Paths, value: json.Json) -> Result(Nil, String) {
  use _ <- result.try(
    simplifile.create_directory_all(xdg.cognitive_dir(paths))
    |> result.map_error(fn(e) {
      "failed to create cognitive directory "
      <> xdg.cognitive_dir(paths)
      <> ": "
      <> string.inspect(e)
    }),
  )
  memory.append_jsonl(xdg.deliveries_path(paths), value)
}

fn event_seen(paths: xdg.Paths, event_id: String) -> Result(Bool, String) {
  case simplifile.is_file(xdg.deliveries_path(paths)) {
    Ok(False) -> Ok(False)
    Ok(True) -> {
      use content <- result.try(
        simplifile.read(xdg.deliveries_path(paths))
        |> result.map_error(fn(e) { string.inspect(e) }),
      )
      Ok(string.contains(content, "\"event_id\":\"" <> event_id <> "\""))
    }
    Error(err) -> Error(string.inspect(err))
  }
}

fn delivery_effect_unknown(
  paths: xdg.Paths,
  event_id: String,
) -> Result(Bool, String) {
  use entries <- result.try(read_ledger_entries(paths))
  case
    entries
    |> latest_entries
    |> list.find(fn(entry) { entry.event_id == event_id })
  {
    Ok(entry) ->
      Ok(entry.status == "sending" || entry.status == "effect_unknown")
    Error(_) -> Ok(False)
  }
}

fn reconcile_interrupted_deliveries(state: State) -> Nil {
  case read_ledger_entries(state.paths) {
    Error(error) ->
      logging.log(
        logging.Error,
        "[cognitive_delivery] failed to inspect interrupted deliveries: "
          <> error,
      )
    Ok(entries) ->
      entries
      |> latest_entries
      |> list.filter(fn(entry) {
        entry.status == "sending" || entry.status == "effect_unknown"
      })
      |> list.each(fn(entry) {
        let error =
          "delivery was interrupted; effect is unknown; verify the target before retry"
        case entry.status {
          "sending" ->
            case
              append_entry_state_with_channel(
                state,
                entry,
                "effect_unknown",
                entry.channel_id,
                error,
              )
            {
              Ok(Nil) ->
                emit_report(
                  state,
                  Report(
                    event_id: entry.event_id,
                    status: Failed,
                    target: entry.target,
                    error: error,
                  ),
                )
              Error(ledger_error) ->
                emit_ledger_failure(
                  state,
                  entry.event_id,
                  entry.target,
                  ledger_error,
                )
            }
          _ ->
            emit_report(
              state,
              Report(
                event_id: entry.event_id,
                status: Failed,
                target: entry.target,
                error: error,
              ),
            )
        }
      })
  }
}

fn pending_digest_entries(paths: xdg.Paths) -> Result(List(LedgerEntry), String) {
  use entries <- result.try(read_ledger_entries(paths))
  let terminal_ids =
    entries
    |> list.filter(fn(entry) { entry.status != "queued" })
    |> list.map(fn(entry) { entry.event_id })

  entries
  |> list.filter(fn(entry) {
    entry.status == "queued" && !list.contains(terminal_ids, entry.event_id)
  })
  |> Ok
}

fn retryable_dead_letter_entries(
  paths: xdg.Paths,
) -> Result(List(LedgerEntry), String) {
  use entries <- result.try(read_ledger_entries(paths))

  entries
  |> latest_entries
  |> list.filter(is_retryable_dead_letter)
  |> Ok
}

fn latest_entries(entries: List(LedgerEntry)) -> List(LedgerEntry) {
  collect_latest(list.reverse(entries), [], [])
}

fn collect_latest(
  entries: List(LedgerEntry),
  seen_ids: List(String),
  acc: List(LedgerEntry),
) -> List(LedgerEntry) {
  case entries {
    [] -> acc
    [entry, ..rest] -> {
      case list.contains(seen_ids, entry.event_id) {
        True -> collect_latest(rest, seen_ids, acc)
        False ->
          collect_latest(rest, [entry.event_id, ..seen_ids], [entry, ..acc])
      }
    }
  }
}

fn is_retryable_dead_letter(entry: LedgerEntry) -> Bool {
  let retryable_status =
    entry.status == "dead_letter" || entry.status == "failed"
  let retryable_attention =
    entry.attention_action == "digest"
    || entry.attention_action == "surface_now"
    || entry.attention_action == "ask_now"

  retryable_status && retryable_attention
}

fn read_ledger_entries(paths: xdg.Paths) -> Result(List(LedgerEntry), String) {
  case simplifile.is_file(xdg.deliveries_path(paths)) {
    Ok(False) -> Ok([])
    Ok(True) -> {
      use content <- result.try(
        simplifile.read(xdg.deliveries_path(paths))
        |> result.map_error(fn(e) { string.inspect(e) }),
      )

      content
      |> string.split("\n")
      |> list.filter(fn(line) { string.trim(line) != "" })
      |> list.try_map(parse_ledger_line)
    }
    Error(err) -> Error(string.inspect(err))
  }
}

fn parse_ledger_line(line: String) -> Result(LedgerEntry, String) {
  json.parse(line, ledger_decoder())
  |> result.map_error(fn(e) { string.inspect(e) })
}

fn ledger_decoder() {
  use event_id <- decode.field("event_id", decode.string)
  use status <- decode.field("status", decode.string)
  use attention_action <- decode.optional_field(
    "attention_action",
    "",
    decode.string,
  )
  use target <- decode.optional_field("target", "", decode.string)
  use channel_id <- decode.optional_field("channel_id", "", decode.string)
  use summary <- decode.optional_field("summary", "", decode.string)
  use rationale <- decode.optional_field("rationale", "", decode.string)
  use authority_required <- decode.optional_field(
    "authority_required",
    "",
    decode.string,
  )
  use citations <- decode.optional_field(
    "citations",
    [],
    decode.list(decode.string),
  )
  use gaps <- decode.optional_field("gaps", [], decode.list(decode.string))
  use error <- decode.optional_field("error", "", decode.string)
  decode.success(LedgerEntry(
    event_id: event_id,
    status: status,
    attention_action: attention_action,
    target: target,
    channel_id: channel_id,
    summary: summary,
    rationale: rationale,
    authority_required: authority_required,
    citations: citations,
    gaps: gaps,
    error: error,
  ))
}

fn current_window() -> String {
  time.now_datetime_string()
  |> string.slice(11, 5)
}

fn current_window_key() -> String {
  time.now_datetime_string()
  |> string.slice(0, 16)
}

fn unique_strings(values: List(String)) -> List(String) {
  unique_strings_loop(values, [])
}

fn unique_strings_loop(values: List(String), acc: List(String)) -> List(String) {
  case values {
    [] -> list.reverse(acc)
    [value, ..rest] -> {
      case list.contains(acc, value) {
        True -> unique_strings_loop(rest, acc)
        False -> unique_strings_loop(rest, [value, ..acc])
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
    "[cognitive_delivery] event_id="
    <> report.event_id
    <> " status="
    <> status_to_string(report.status)
    <> " target="
    <> report.target
    <> " error="
    <> report.error

  case report.status {
    Failed | DeadLetter -> logging.log(logging.Error, msg)
    _ -> logging.log(logging.Info, msg)
  }
}

pub fn status_to_string(status: Status) -> String {
  case status {
    Recorded -> "recorded"
    Queued -> "queued"
    Delivered -> "delivered"
    Suppressed -> "suppressed"
    Failed -> "failed"
    DeadLetter -> "dead_letter"
    DuplicateSuppressed -> "duplicate_suppressed"
  }
}
