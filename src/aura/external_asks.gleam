//// External ask registry (ADR 038). Owns pending hook asks: durable rows in
//// SQLite, Discord button delivery, stateless resolution from brain-routed
//// interactions, TTL expiry, and blocked-waiter notification.
////
//// Unlike shell approvals (ADR 027), pending asks survive restarts: waiters
//// are external OS processes. Resolution needs no in-memory state — the DB
//// row is authoritative; the waiter map is an optimization for blocking
//// callers.

import aura/cognitive_delivery
import aura/db
import aura/discord/types as discord_types
import aura/event
import aura/hook_protocol
import aura/time
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/dynamic/decode
import logging

/// Post a Discord button message; returns the new message id.
pub type PostFn = fn(String, String, json.Json) -> Result(String, String)
/// Edit an existing Discord message via the channel messages endpoint.
pub type EditFn = fn(String, String, String, json.Json) -> Result(Nil, String)
/// Edit a Discord message via the interaction webhook (PATCH @original),
/// used right after a button click where the channel endpoint is locked.
/// Args: interaction_token, content, components.
pub type WebhookEditFn = fn(String, String, json.Json) -> Result(Nil, String)

pub type Message {
  SubmitAsk(ask: db.StoredExternalAsk, ttl_ms: Int, reply_to: Subject(String))
  ResolveAsk(correlation_id: String, choice: String, interaction_token: String)
  ExpireAsk(correlation_id: String)
  GetDecision(correlation_id: String, reply_to: Subject(String))
}

type State {
  State(
    db_subject: Subject(db.DbMessage),
    delivery: Option(Subject(cognitive_delivery.Message)),
    targets: List(cognitive_delivery.DeliveryTarget),
    post: PostFn,
    edit: EditFn,
    webhook_edit: WebhookEditFn,
    waiters: Dict(String, List(Subject(String))),
    self_subject: Subject(Message),
  )
}

pub fn start(
  db_subject: Subject(db.DbMessage),
  delivery_subject: Option(Subject(cognitive_delivery.Message)),
  targets: List(cognitive_delivery.DeliveryTarget),
  post: PostFn,
  edit: EditFn,
  webhook_edit: WebhookEditFn,
) -> Result(actor.Started(Subject(Message)), actor.StartError) {
  actor.new_with_initialiser(5000, fn(self_subject) {
    let state =
      State(
        db_subject: db_subject,
        delivery: delivery_subject,
        targets: targets,
        post: post,
        edit: edit,
        webhook_edit: webhook_edit,
        waiters: dict.new(),
        self_subject: self_subject,
      )
    Ok(actor.initialised(state) |> actor.returning(self_subject))
  })
  |> actor.on_message(handle_message)
  |> actor.start
}

/// Convenience sender for the fire-and-forget submit path (cast, no reply).
pub fn submit_ask(
  subject: Subject(Message),
  ask: db.StoredExternalAsk,
  ttl_ms: Int,
  reply_to: Subject(String),
) -> Result(Nil, String) {
  process.send(subject, SubmitAsk(ask: ask, ttl_ms: ttl_ms, reply_to: reply_to))
  Ok(Nil)
}

/// Fire-and-forget resolve from a Discord button click.
pub fn resolve_ask(
  subject: Subject(Message),
  correlation_id: String,
  choice: String,
  interaction_token: String,
) -> Nil {
  process.send(
    subject,
    ResolveAsk(
      correlation_id: correlation_id,
      choice: choice,
      interaction_token: interaction_token,
    ),
  )
}

/// Fire-and-forget expiry transition.
pub fn expire_ask(subject: Subject(Message), correlation_id: String) -> Nil {
  process.send(subject, ExpireAsk(correlation_id: correlation_id))
}

/// Synchronous (5s) decision lookup; returns the resp_* wire line.
pub fn get_decision(subject: Subject(Message), correlation_id: String) -> String {
  let reply = process.new_subject()
  process.send(
    subject,
    GetDecision(correlation_id: correlation_id, reply_to: reply),
  )
  process.receive(reply, 5_000)
  |> result.unwrap(hook_protocol.resp_error("get decision timed out"))
}
fn handle_message(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    SubmitAsk(ask: ask, ttl_ms: ttl_ms, reply_to: reply_to) ->
      handle_submit(state, ask, ttl_ms, reply_to)

    ResolveAsk(
      correlation_id: correlation_id,
      choice: choice,
      interaction_token: interaction_token,
    ) ->
      handle_resolve(state, correlation_id, choice, interaction_token)

    ExpireAsk(correlation_id: correlation_id) ->
      handle_expire(state, correlation_id)

    GetDecision(correlation_id: correlation_id, reply_to: reply_to) -> {
      let line = decision_line(state, correlation_id)
      process.send(reply_to, line)
      actor.continue(state)
    }
  }
}


fn handle_submit(
  state: State,
  ask: db.StoredExternalAsk,
  ttl_ms: Int,
  reply_to: Subject(String),
) -> actor.Next(State, Message) {
  case db.save_external_ask(state.db_subject, ask) {
    Ok(True) -> submit(state, ask, ttl_ms, reply_to)
    Ok(False) -> attach_wait(state, ask.id, reply_to)
    Error(err) -> {
      process.send(reply_to, hook_protocol.resp_error(err))
      actor.continue(state)
    }
  }
}

fn submit(
  state: State,
  ask: db.StoredExternalAsk,
  ttl_ms: Int,
  reply_to: Subject(String),
) -> actor.Next(State, Message) {
  case db.get_external_ask(state.db_subject, ask.id) {
    Ok(None) -> {
      process.send(reply_to, hook_protocol.resp_unknown())
      actor.continue(state)
    }
    Ok(Some(_fresh)) ->
      case cognitive_delivery.resolve_target(state.targets, ask.channel_id) {
        Error(err) -> {
          let _ = mark_failed(state, ask.id, err)
          process.send(reply_to, hook_protocol.resp_error(err))
          actor.continue(state)
        }
        Ok(target) -> {
          let buttons =
            discord_types.hook_ask_buttons(
              ask.id,
              parse_button_labels(ask.buttons_json),
              False,
            )
          case state.post(target.channel_id, ask.text, buttons) {
            Error(err) -> {
              let _ = mark_failed(state, ask.id, err)
              process.send(reply_to, hook_protocol.resp_error(err))
              actor.continue(state)
            }
            Ok(message_id) -> {
              let now = time.now_ms()
              let _ = db.update_external_ask_message_id(
                state.db_subject,
                ask.id,
                message_id,
                now,
              )
              process.send_after(state.self_subject, ttl_ms, ExpireAsk(ask.id))
              audit_ask(state, ask)
              record_delivery(state, ask, target.channel_id)
              let state = attach_waiter(state, ask.id, reply_to)
              actor.continue(state)
            }
          }
        }
      }
    Error(err) -> {
      process.send(reply_to, hook_protocol.resp_error(err))
      actor.continue(state)
    }
  }
}

fn attach_wait(
  state: State,
  id: String,
  reply_to: Subject(String),
) -> actor.Next(State, Message) {
  case db.get_external_ask(state.db_subject, id) {
    Ok(None) -> {
      process.send(reply_to, hook_protocol.resp_unknown())
      actor.continue(state)
    }
    Ok(Some(row)) ->
      case row.status {
        "pending" ->
          actor.continue(attach_waiter(state, id, reply_to))
        "resolved" -> {
          process.send(
            reply_to,
            hook_protocol.resp_resolved(row.id, row.decision),
          )
          actor.continue(state)
        }
        "expired" -> {
          process.send(reply_to, hook_protocol.resp_expired(row.id))
          actor.continue(state)
        }
        _ -> {
          process.send(reply_to, hook_protocol.resp_error("ask " <> row.id <> " is " <> row.status))
          actor.continue(state)
        }
      }
    Error(err) -> {
      process.send(reply_to, hook_protocol.resp_error(err))
      actor.continue(state)
    }
  }
}

fn mark_failed(state: State, id: String, reason: String) -> Result(Bool, String) {
  let _ = db.update_external_ask_decision(
    state.db_subject,
    id,
    "failed",
    "",
    time.now_ms(),
  )
  logging.log(logging.Info, "[external_ask] " <> id <> " failed: " <> reason)
  Ok(True)
}

fn audit_ask(state: State, ask: db.StoredExternalAsk) -> Nil {
  let data =
    json.object([
      #("source", json.string(ask.source)),
      #("target", json.string(ask.channel_id)),
      #("text", json.string(ask.text)),
      #("buttons", json.string(ask.buttons_json)),
    ])
    |> json.to_string
  let ev =
    event.AuraEvent(
      id: "ask-" <> ask.id,
      source: ask.source,
      type_: "hook.ask",
      subject: ask.text,
      time_ms: time.now_ms(),
      tags: dict.new(),
      external_id: ask.id,
      data: data,
    )
  let _ = db.insert_event(state.db_subject, ev)
  Nil
}

fn record_delivery(
  state: State,
  ask: db.StoredExternalAsk,
  channel_id: String,
) -> Nil {
  case state.delivery {
    Some(delivery_subject) -> {
      let _ = cognitive_delivery.record_hook_delivery(
        delivery_subject,
        ask.id,
        ask.source,
        ask.channel_id,
        channel_id,
        ask.text,
      )
      Nil
    }
    None -> Nil
  }
}

fn handle_resolve(
  state: State,
  correlation_id: String,
  choice: String,
  interaction_token: String,
) -> actor.Next(State, Message) {
  let updated = db.update_external_ask_decision(
    state.db_subject,
    correlation_id,
    "resolved",
    choice,
    time.now_ms(),
  )
  case updated {
    Ok(True) -> {
      let _ = edit_ask_resolved(
        state,
        correlation_id,
        choice,
        interaction_token,
      )
      let state = notify_waiters(
        state,
        correlation_id,
        hook_protocol.resp_resolved(correlation_id, choice),
      )
      actor.continue(state)
    }
    Ok(False) -> {
      logging.log(
        logging.Info,
        "late resolve for non-pending ask: " <> correlation_id,
      )
      actor.continue(state)
    }
    Error(err) -> {
      logging.log(
        logging.Info,
        "db error resolving ask " <> correlation_id <> ": " <> err,
      )
      actor.continue(state)
    }
  }
}

fn handle_expire(
  state: State,
  correlation_id: String,
) -> actor.Next(State, Message) {
  let updated = db.update_external_ask_decision(
    state.db_subject,
    correlation_id,
    "expired",
    "",
    time.now_ms(),
  )
  case updated {
    Ok(True) -> {
      let _ = edit_ask_expired(state, correlation_id)
      let state = notify_waiters(
        state,
        correlation_id,
        hook_protocol.resp_expired(correlation_id),
      )
      actor.continue(state)
    }
    Ok(False) -> {
      logging.log(
        logging.Info,
        "late expire for already-final ask: " <> correlation_id,
      )
      actor.continue(state)
    }
    Error(err) -> {
      logging.log(
        logging.Info,
        "db error expiring ask " <> correlation_id <> ": " <> err,
      )
      actor.continue(state)
    }
  }
}

/// Rebuild the ask's button row with `disabled: true` so the message shows the
/// ask was already answered.
fn disabled_buttons(row: db.StoredExternalAsk) -> json.Json {
  discord_types.hook_ask_buttons(
    row.id,
    parse_button_labels(row.buttons_json),
    True,
  )
}

/// Resolve edit: the click locked the message to the interaction, so use the
/// interaction webhook (@original) rather than the channel endpoint.
fn edit_ask_resolved(
  state: State,
  correlation_id: String,
  choice: String,
  interaction_token: String,
) -> Result(Nil, String) {
  case db.get_external_ask(state.db_subject, correlation_id) {
    Ok(Some(row)) ->
      state.webhook_edit(
        interaction_token,
        "**Resolved** — " <> choice <> " (ask " <> correlation_id <> ")",
        disabled_buttons(row),
      )
    _ -> Ok(Nil)
  }
}

/// Expire edit: no interaction is in flight, so the channel endpoint works and
/// also carries the disabled buttons.
fn edit_ask_expired(state: State, correlation_id: String) -> Result(Nil, String) {
  case db.get_external_ask(state.db_subject, correlation_id) {
    Ok(Some(row)) ->
      state.edit(
        row.channel_id,
        row.message_id,
        "**Expired** — no decision within TTL (ask " <> correlation_id <> ")",
        disabled_buttons(row),
      )
    _ -> Ok(Nil)
  }
}

fn attach_waiter(state: State, id: String, reply_to: Subject(String)) -> State {
  let existing = dict.get(state.waiters, id) |> result.unwrap([])
  State(..state, waiters: dict.insert(state.waiters, id, [reply_to, ..existing]))
}

fn notify_waiters(state: State, id: String, line: String) -> State {
  let waiters_to_notify = dict.get(state.waiters, id) |> result.unwrap([])
  list.each(waiters_to_notify, fn(w) { process.send(w, line) })
  State(..state, waiters: dict.delete(state.waiters, id))
}

fn decision_line(state: State, correlation_id: String) -> String {
  case db.get_external_ask(state.db_subject, correlation_id) {
    Ok(Some(row)) ->
      case row.status {
        "pending" -> hook_protocol.resp_pending()
        "resolved" -> hook_protocol.resp_resolved(row.id, row.decision)
        "expired" -> hook_protocol.resp_expired(row.id)
        "failed" -> hook_protocol.resp_error("ask " <> row.id <> " failed")
        _ -> hook_protocol.resp_error("ask " <> row.id <> " is " <> row.status)
      }
    _ -> hook_protocol.resp_unknown()
  }
}

fn parse_button_labels(raw: String) -> List(String) {
  case json.parse(raw, decode.list(decode.string)) {
    Ok(labels) -> labels
    Error(_) -> []
  }
}
