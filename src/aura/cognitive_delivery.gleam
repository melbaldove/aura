//// User-attention delivery actor for validated cognitive decisions.
////
//// The model chooses an attention action and delivery target. This actor owns
//// the mechanical effects: duplicate protection, JSONL delivery state,
//// immediate Discord sends, digest flushing, and operator dead-letter retry.

import aura/clients/discord_client.{type DiscordClient}
import aura/cognitive_decision
import aura/discord/message as discord_message
import aura/memory
import aura/time
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
  FlushDigest
  RetryDeadLetters(reply: Subject(Result(RetrySummary, String)))
  SuppressEvent(event_id: String, reason: String)
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
    discord: DiscordClient,
    targets: List(DeliveryTarget),
    digest_windows: List(String),
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
  discord: DiscordClient,
  targets: List(DeliveryTarget),
  digest_windows: List(String),
) -> Result(actor.Started(Subject(Message)), actor.StartError) {
  start_with(paths, discord, targets, digest_windows, None)
}

pub fn start_with(
  paths: xdg.Paths,
  discord: DiscordClient,
  targets: List(DeliveryTarget),
  digest_windows: List(String),
  report_to: Option(Subject(Report)),
) -> Result(actor.Started(Subject(Message)), actor.StartError) {
  actor.new_with_initialiser(5000, fn(self_subject) {
    let state =
      State(
        paths: paths,
        discord: discord,
        targets: targets,
        digest_windows: digest_windows,
        self_subject: self_subject,
        last_digest_window: "",
        report_to: report_to,
      )

    process.send_after(self_subject, 60_000, Tick)
    Ok(actor.initialised(state) |> actor.returning(self_subject))
  })
  |> actor.on_message(handle_message)
  |> actor.start
}

pub fn deliver(
  subject: Subject(Message),
  decision: cognitive_decision.DecisionEnvelope,
) -> Nil {
  process.send(subject, Deliver(decision))
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

    Tick -> {
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

    Ok(False) -> {
      case decision.attention.action {
        "record" -> {
          let _ = append_decision_state(state, decision, "recorded", "", "")
          emit_report(
            state,
            Report(
              event_id: decision.event_id,
              status: Recorded,
              target: decision.delivery.target,
              error: "",
            ),
          )
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
  case resolve_target(state, decision.delivery.target) {
    Error(err) -> {
      let _ = append_decision_state(state, decision, "dead_letter", "", err)
      emit_report(
        state,
        Report(
          event_id: decision.event_id,
          status: DeadLetter,
          target: decision.delivery.target,
          error: err,
        ),
      )
    }

    Ok(target) -> {
      let _ =
        append_decision_state(state, decision, "queued", target.channel_id, "")
      emit_report(
        state,
        Report(
          event_id: decision.event_id,
          status: Queued,
          target: decision.delivery.target,
          error: "",
        ),
      )
    }
  }
}

fn send_immediate(
  state: State,
  decision: cognitive_decision.DecisionEnvelope,
) -> Nil {
  case resolve_target(state, decision.delivery.target) {
    Error(err) -> {
      let _ = append_decision_state(state, decision, "dead_letter", "", err)
      emit_report(
        state,
        Report(
          event_id: decision.event_id,
          status: DeadLetter,
          target: decision.delivery.target,
          error: err,
        ),
      )
    }

    Ok(target) -> {
      let content =
        decision
        |> format_immediate
        |> discord_message.clip_to_discord_limit
      case state.discord.send_message(target.channel_id, content) {
        Ok(_) -> {
          let _ =
            append_decision_state(
              state,
              decision,
              "delivered",
              target.channel_id,
              "",
            )
          emit_report(
            state,
            Report(
              event_id: decision.event_id,
              status: Delivered,
              target: decision.delivery.target,
              error: "",
            ),
          )
        }
        Error(err) -> {
          let _ =
            append_decision_state(
              state,
              decision,
              "dead_letter",
              target.channel_id,
              err,
            )
          emit_report(
            state,
            Report(
              event_id: decision.event_id,
              status: DeadLetter,
              target: decision.delivery.target,
              error: err,
            ),
          )
        }
      }
    }
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
            let _ = append_entry_state(state.paths, entry, "dead_letter", err)
            emit_report(
              state,
              Report(
                event_id: entry.event_id,
                status: DeadLetter,
                target: target_id,
                error: err,
              ),
            )
          })
        }

        _ -> {
          let content =
            entries
            |> format_digest
            |> discord_message.clip_to_discord_limit
          case state.discord.send_message(channel_id, content) {
            Ok(_) ->
              list.each(entries, fn(entry) {
                let _ = append_entry_state(state.paths, entry, "delivered", "")
                emit_report(
                  state,
                  Report(
                    event_id: entry.event_id,
                    status: Delivered,
                    target: target_id,
                    error: "",
                  ),
                )
              })

            Error(err) ->
              list.each(entries, fn(entry) {
                let _ =
                  append_entry_state(state.paths, entry, "dead_letter", err)
                emit_report(
                  state,
                  Report(
                    event_id: entry.event_id,
                    status: DeadLetter,
                    target: target_id,
                    error: err,
                  ),
                )
              })
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
      case resolve_target(state, target_id) {
        Error(err) -> {
          list.each(entries, fn(entry) {
            let _ =
              append_entry_state_with_channel(
                state.paths,
                entry,
                "dead_letter",
                "",
                err,
              )
            emit_report(
              state,
              Report(
                event_id: entry.event_id,
                status: DeadLetter,
                target: target_id,
                error: err,
              ),
            )
          })
          RetrySummary(..summary, failed: summary.failed + list.length(entries))
        }

        Ok(target) -> {
          let content =
            entries
            |> format_digest
            |> discord_message.clip_to_discord_limit
          case state.discord.send_message(target.channel_id, content) {
            Ok(_) -> {
              list.each(entries, fn(entry) {
                let _ =
                  append_entry_state_with_channel(
                    state.paths,
                    entry,
                    "delivered",
                    target.channel_id,
                    "",
                  )
                emit_report(
                  state,
                  Report(
                    event_id: entry.event_id,
                    status: Delivered,
                    target: target_id,
                    error: "",
                  ),
                )
              })
              RetrySummary(
                ..summary,
                delivered: summary.delivered + list.length(entries),
              )
            }

            Error(err) -> {
              list.each(entries, fn(entry) {
                let _ =
                  append_entry_state_with_channel(
                    state.paths,
                    entry,
                    "dead_letter",
                    target.channel_id,
                    err,
                  )
                emit_report(
                  state,
                  Report(
                    event_id: entry.event_id,
                    status: DeadLetter,
                    target: target_id,
                    error: err,
                  ),
                )
              })
              RetrySummary(
                ..summary,
                failed: summary.failed + list.length(entries),
              )
            }
          }
        }
      }
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
  case resolve_target(state, entry.target) {
    Error(err) -> {
      let _ =
        append_entry_state_with_channel(
          state.paths,
          entry,
          "dead_letter",
          "",
          err,
        )
      emit_report(
        state,
        Report(
          event_id: entry.event_id,
          status: DeadLetter,
          target: entry.target,
          error: err,
        ),
      )
      RetrySummary(..summary, failed: summary.failed + 1)
    }

    Ok(target) -> {
      let content =
        entry
        |> format_retry_immediate
        |> discord_message.clip_to_discord_limit
      case state.discord.send_message(target.channel_id, content) {
        Ok(_) -> {
          let _ =
            append_entry_state_with_channel(
              state.paths,
              entry,
              "delivered",
              target.channel_id,
              "",
            )
          emit_report(
            state,
            Report(
              event_id: entry.event_id,
              status: Delivered,
              target: entry.target,
              error: "",
            ),
          )
          RetrySummary(..summary, delivered: summary.delivered + 1)
        }

        Error(err) -> {
          let _ =
            append_entry_state_with_channel(
              state.paths,
              entry,
              "dead_letter",
              target.channel_id,
              err,
            )
          emit_report(
            state,
            Report(
              event_id: entry.event_id,
              status: DeadLetter,
              target: entry.target,
              error: err,
            ),
          )
          RetrySummary(..summary, failed: summary.failed + 1)
        }
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

fn format_retry_immediate(entry: LedgerEntry) -> String {
  let header = case entry.attention_action {
    "ask_now" -> "**Aura needs a decision**"
    _ -> "**Aura noticed something attention-worthy**"
  }

  header
  <> "\n\n"
  <> entry.summary
  <> "\n\nRationale: "
  <> entry.rationale
  <> case entry.authority_required {
    "none" | "" -> ""
    other -> "\nAuthority: " <> other
  }
  <> gaps_block(entry.gaps)
  <> "\nCitations: "
  <> string.join(entry.citations, ", ")
  <> "\nEvent: "
  <> entry.event_id
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

fn resolve_target(
  state: State,
  target_id: String,
) -> Result(DeliveryTarget, String) {
  case target_id {
    "none" -> Error("delivery target none has no channel")
    _ ->
      case list.find(state.targets, fn(target) { target.id == target_id }) {
        Ok(target) -> Ok(target)
        Error(_) -> Error("unknown delivery target: " <> target_id)
      }
  }
}

fn append_decision_state(
  state: State,
  decision: cognitive_decision.DecisionEnvelope,
  status: String,
  channel_id: String,
  error: String,
) -> Result(Nil, String) {
  append_ledger(
    state.paths,
    json.object([
      #("timestamp_ms", json.int(time.now_ms())),
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
  )
}

fn append_entry_state(
  paths: xdg.Paths,
  entry: LedgerEntry,
  status: String,
  error: String,
) -> Result(Nil, String) {
  append_entry_state_with_channel(paths, entry, status, entry.channel_id, error)
}

fn append_entry_state_with_channel(
  paths: xdg.Paths,
  entry: LedgerEntry,
  status: String,
  channel_id: String,
  error: String,
) -> Result(Nil, String) {
  append_ledger(
    paths,
    json.object([
      #("timestamp_ms", json.int(time.now_ms())),
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
  )
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
