//// Gmail integration — IMAP IDLE actor for ambient email ingestion.
////
//// Holds a long-lived TLS connection to `imap.gmail.com:993`, authenticates
//// via XOAUTH2 using an OAuth refresh token loaded from disk, and forwards
//// new-message envelopes as `AuraEvent`s to `event_ingest`.
////
//// The actor runs the connect/auth/select/idle/fetch loop inline in its
//// mailbox. IDLE blocks for up to 28 minutes per cycle (below Gmail's
//// 29-minute server-side ceiling), then re-IDLEs on the same session. On
//// any error the session closes and reconnect is scheduled with exponential
//// backoff via `process.send_after`.
////
//// Only the initial `exists` count at SELECT time is used as the baseline;
//// pre-existing messages are NOT backfilled. Flag changes, expunges, and
//// non-Gmail notifications are logged and otherwise ignored.

import aura/backoff
import aura/event
import aura/event_ingest
import aura/imap
import aura/oauth
import aura/time
import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
import logging

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

pub type GmailConfig {
  GmailConfig(
    name: String,
    user_email: String,
    oauth: oauth.OAuthConfig,
    token_path: String,
  )
}

pub type Message {
  Tick(attempt: Int)
}

type State {
  State(
    config: GmailConfig,
    event_ingest: Subject(event_ingest.IngestMessage),
    self_subject: Subject(Message),
  )
}

const base_backoff_ms = 5000

const max_backoff_ms = 300_000

/// 28 min — leaves a 1-minute margin below Gmail's 29-minute IDLE ceiling.
const idle_timeout_ms = 1_680_000

const connect_timeout_ms = 10_000

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Start the Gmail integration actor.
pub fn start(
  config: GmailConfig,
  event_ingest_subject: Subject(event_ingest.IngestMessage),
) -> Result(actor.Started(Subject(Message)), actor.StartError) {
  actor.new_with_initialiser(5000, fn(self_subject) {
    let state =
      State(
        config: config,
        event_ingest: event_ingest_subject,
        self_subject: self_subject,
      )
    // Kick off the first reconnect cycle immediately.
    process.send(self_subject, Tick(0))
    Ok(actor.initialised(state) |> actor.returning(self_subject))
  })
  |> actor.on_message(handle_message)
  |> actor.start
}

/// Build a supervised child spec for the root supervisor.
pub fn supervised(
  config: GmailConfig,
  event_ingest_subject: Subject(event_ingest.IngestMessage),
) -> supervision.ChildSpecification(Subject(Message)) {
  supervision.worker(fn() { start(config, event_ingest_subject) })
}

// ---------------------------------------------------------------------------
// Exposed helpers for testing
// ---------------------------------------------------------------------------

/// Construct an AuraEvent from an IMAP envelope + GmailConfig. Pure.
/// Uses Message-ID as both `subject` (natural key) and `external_id`
/// (dedup). `data` carries the full envelope as JSON for downstream
/// tagger enrichment.
pub fn envelope_to_event(
  config: GmailConfig,
  env: imap.Envelope,
  now_ms: Int,
) -> event.AuraEvent {
  event.AuraEvent(
    id: env.message_id,
    source: config.name,
    type_: "email.received",
    subject: env.subject,
    time_ms: now_ms,
    tags: dict.new(),
    external_id: env.message_id,
    data: envelope_to_json(env),
  )
}

/// Encode an IMAP envelope as JSON for storage in AuraEvent.data. Pure.
/// Thread-id falls back to message-id in Phase 1.5 (Gmail's X-GM-THRID
/// extension would require an explicit FETCH we don't issue yet).
pub fn envelope_to_json(env: imap.Envelope) -> String {
  json.object([
    #("uid", json.int(env.uid)),
    #("message_id", json.string(env.message_id)),
    #("from", json.string(env.from)),
    #("to", json.string(env.to)),
    #("subject", json.string(env.subject)),
    #("date", json.string(env.date)),
    #("thread_id", json.string(env.message_id)),
  ])
  |> json.to_string
}

// ---------------------------------------------------------------------------
// Actor message handler
// ---------------------------------------------------------------------------

fn handle_message(state: State, msg: Message) -> actor.Next(State, Message) {
  case msg {
    Tick(attempt) -> {
      run_cycle(state, attempt)
      actor.continue(state)
    }
  }
}

// ---------------------------------------------------------------------------
// Reconnect cycle
// ---------------------------------------------------------------------------

fn run_cycle(state: State, attempt: Int) -> Nil {
  let name = state.config.name
  case oauth.load_token_set(state.config.token_path) {
    Error(err) -> {
      log_error(name, "load tokens: " <> err)
      schedule_next(state, attempt + 1)
    }
    Ok(tokens) -> {
      let now = time.now_ms()
      case oauth.ensure_fresh(state.config.oauth, tokens, now) {
        Error(err) -> {
          log_error(name, "oauth refresh: " <> err)
          schedule_next(state, attempt + 1)
        }
        Ok(fresh) -> {
          persist_if_changed(state.config.token_path, tokens, fresh)
          // run_session's idle_loop is infinite — only Error exits.
          let assert Error(reason) = run_session(state, fresh)
          log_error(name, "session ended: " <> reason)
          schedule_next(state, attempt + 1)
        }
      }
    }
  }
}

fn persist_if_changed(
  path: String,
  old: oauth.TokenSet,
  new: oauth.TokenSet,
) -> Nil {
  case new == old {
    True -> Nil
    False -> {
      case oauth.save_token_set(path, new) {
        Ok(_) -> Nil
        Error(err) -> {
          logging.log(
            logging.Warning,
            "[gmail] failed to persist refreshed tokens to " <> path <> ": " <> err,
          )
          Nil
        }
      }
    }
  }
}

fn schedule_next(state: State, next_attempt: Int) -> Nil {
  let delay = backoff.compute(next_attempt, base: base_backoff_ms, cap: max_backoff_ms)
  logging.log(
    logging.Info,
    "[gmail:" <> state.config.name <> "] reconnect in " <> int.to_string(delay) <> "ms",
  )
  let _ = process.send_after(state.self_subject, delay, Tick(next_attempt))
  Nil
}

// ---------------------------------------------------------------------------
// IMAP session
// ---------------------------------------------------------------------------

fn run_session(state: State, tokens: oauth.TokenSet) -> Result(Nil, String) {
  let name = state.config.name
  use conn <- result.try(imap.connect(
    "imap.gmail.com",
    993,
    connect_timeout_ms,
  ))
  log_info(name, "connected to imap.gmail.com:993")
  let final_result = {
    use _ <- result.try(imap.authenticate(
      conn,
      imap.XOAuth2(state.config.user_email, tokens.access_token),
    ))
    log_info(name, "authenticated via XOAUTH2")
    use mailbox <- result.try(imap.select(conn, "INBOX"))
    log_info(
      name,
      "SELECT INBOX → " <> int.to_string(mailbox.exists) <> " exists",
    )
    idle_loop(state, conn, mailbox.exists)
  }
  imap.close(conn)
  final_result
}

fn idle_loop(
  state: State,
  conn: imap.Connection,
  baseline: Int,
) -> Result(Nil, String) {
  use events <- result.try(imap.idle(conn, idle_timeout_ms))
  let new_baseline = process_events(state, conn, events, baseline)
  idle_loop(state, conn, new_baseline)
}

fn process_events(
  state: State,
  conn: imap.Connection,
  events: List(imap.IdleEvent),
  baseline: Int,
) -> Int {
  // Known Phase 1.5 limitations: fetch uses sequence numbers (not UIDs), so
  // a mid-batch expunge can race envelope fetches; UIDVALIDITY checkpointing
  // would close the gap. Acceptable for Phase 1.5 "best-effort" ingest.
  list.fold(events, baseline, fn(b, e) {
    case e {
      imap.Exists(count) -> {
        fetch_and_ingest(state, conn, b, count)
        int.max(count, b)
      }
      imap.Expunge(_) -> int.max(b - 1, 0)
      imap.Timeout -> b
    }
  })
}

fn fetch_and_ingest(
  state: State,
  conn: imap.Connection,
  from_exclusive: Int,
  to_inclusive: Int,
) -> Nil {
  list.range(from_exclusive + 1, to_inclusive)
  |> list.each(fn(seq) {
    case imap.fetch_envelope(conn, seq) {
      Ok(env) -> {
        let now = time.now_ms()
        let ae = envelope_to_event(state.config, env, now)
        event_ingest.ingest(state.event_ingest, ae)
        log_info(
          state.config.name,
          "ingested email from " <> env.from <> " subject=" <> env.subject,
        )
      }
      Error(err) -> {
        logging.log(
          logging.Warning,
          "[gmail:"
            <> state.config.name
            <> "] fetch seq="
            <> int.to_string(seq)
            <> ": "
            <> err,
        )
        Nil
      }
    }
  })
}

// ---------------------------------------------------------------------------
// Logging
// ---------------------------------------------------------------------------

fn log_info(name: String, msg: String) -> Nil {
  logging.log(logging.Info, "[gmail:" <> name <> "] " <> msg)
}

fn log_error(name: String, msg: String) -> Nil {
  logging.log(logging.Error, "[gmail:" <> name <> "] " <> msg)
}
