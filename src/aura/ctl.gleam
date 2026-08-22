import aura/codex_monitor
import aura/cognitive_delivery
import aura/cognitive_eval
import aura/cognitive_improve
import aura/cognitive_label
import aura/cognitive_patch
import aura/cognitive_probe
import aura/cognitive_replay
import aura/cognitive_smoke
import aura/cognitive_worker
import aura/concern
import aura/config
import aura/connector_activation
import aura/connector_runtime
import aura/db
import aura/domain_registry
import aura/dreaming
import aura/event
import aura/event_ingest
import aura/external_asks
import aura/google_oauth_client
import aura/google_oauth_runtime
import aura/hook_protocol
import aura/operating_contracts
import aura/operational_mutation
import aura/secret
import aura/time
import aura/xdg
import gleam/bit_array
import gleam/crypto
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
    oauth_subject: process.Subject(google_oauth_runtime.Message),
    connector_runtime_subject: process.Subject(connector_runtime.Message),
    connector_configurations: List(config.ConnectorConfiguration),
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
  let buttons_json = json.array(buttons, json.string) |> json.to_string
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
    Ok(#("evidence", payload)) ->
      handle_evidence_submission(ctx, "evidence", string.trim(payload))
    Ok(#("tool-result", payload)) ->
      handle_evidence_submission(ctx, "tool-result", string.trim(payload))
    Ok(#("mutate", payload)) ->
      handle_structured_mutation(ctx, string.trim(payload))
    Ok(#("connector-activation", payload)) ->
      handle_connector_activation(ctx, string.trim(payload))
    Ok(#("canary-preparation", payload)) ->
      process_preparation_authorization_command(
        ctx.db_subject,
        string.trim(payload),
      )
    Ok(#("canary-authorization", payload)) ->
      process_canary_authorization_command(ctx.db_subject, string.trim(payload))
    Ok(#("monitor", payload)) ->
      handle_monitor_command(ctx, string.trim(payload))
    Ok(#("oauth", payload)) ->
      handle_google_oauth_command(ctx, string.trim(payload))
    Ok(#("connector-read", payload)) ->
      handle_connector_read_command(ctx, string.trim(payload))
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
          logging.log(
            logging.Info,
            "[ctl] Cognitive smoke triggered: gmail-rel42",
          )
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
            Error(err) ->
              "ERROR: cognitive replay patch proposal failed: " <> err
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
            Error(err) ->
              "ERROR: cognitive improvement proposal failed: " <> err
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
        ["domain-migrate", slug, idempotency_key] ->
          handle_domain_migration(ctx, slug, idempotency_key)
        ["concern-migrate", concern_slug, domain_slug, idempotency_key] ->
          handle_concern_migration(
            ctx,
            concern_slug,
            domain_slug,
            idempotency_key,
          )
        ["asks"] -> handle_asks_list(ctx)
        ["hooks"] -> handle_hooks_list(ctx)

        _ ->
          "ERROR: unknown command '"
          <> trimmed
          <> "'. Commands: ping, dream, status, cognitive-smoke gmail-rel42, cognitive-eval fixtures, cognitive-replay labels, cognitive-replay propose-patches, cognitive-improve propose, cognitive-test deliver-now, cognitive-digest flush, cognitive-delivery retry-dead-letter, cognitive-label <event_id> <label> [expected_attention] [note], event <json>, evidence submit <json>, tool-result submit <json>, notify <json>, ask <json>, decision <correlation_id>, asks, hooks"
      }
  }
}

/// Install connector-specific Google clients or create one immutable client set.
fn handle_google_oauth_command(ctx: CtlContext, payload: String) -> String {
  case string.split(payload, " ") {
    ["start", connector_id, preparation_id, configuration_ref, client_ref] ->
      process_google_oauth_start(
        ctx.paths,
        ctx.db_subject,
        ctx.oauth_subject,
        ctx.connector_configurations,
        connector_id,
        preparation_id,
        configuration_ref,
        client_ref,
      )
    ["status", session_ref] ->
      process_google_oauth_status(ctx.db_subject, session_ref)
    _ -> process_google_oauth_client_command(ctx.paths, ctx.db_subject, payload)
  }
}

/// Start one exact read-only OAuth session from durable preparation authority.
pub fn process_google_oauth_start(
  paths: xdg.Paths,
  db_subject: process.Subject(db.DbMessage),
  oauth_subject: process.Subject(google_oauth_runtime.Message),
  configurations: List(config.ConnectorConfiguration),
  connector_id: String,
  preparation_id: String,
  configuration_ref: String,
  client_ref: String,
) -> String {
  let result = {
    use _ <- result.try(case connector_id {
      "gmail" | "calendar" -> Ok(Nil)
      _ -> Error("google_oauth_connector_invalid")
    })
    use stored <- result.try(db.get_canary_preparation_authorization(
      db_subject,
      preparation_id,
    ))
    use preparation <- result.try(
      stored
      |> option.to_result("preparation_authorization_not_found")
      |> result.map(fn(value) { value.authorization }),
    )
    use _ <- result.try(case preparation.expires_at_ms > time.now_ms() {
      True -> Ok(Nil)
      False -> Error("preparation_authorization_expired")
    })
    use connector <- result.try(
      preparation.connectors
      |> list.find(fn(value) {
        value.connector_id == connector_id
        && value.configuration_ref == configuration_ref
      })
      |> result.map_error(fn(_) { "preparation_connector_not_authorized" }),
    )
    use configuration <- result.try(
      configurations
      |> list.find(fn(value) {
        value.connector_id == connector_id
        && value.configuration_ref == configuration_ref
      })
      |> result.map_error(fn(_) { "oauth_configuration_not_found" }),
    )
    use client_set <- result.try(google_oauth_client.load_client_set(
      paths,
      preparation.oauth_client_ref,
    ))
    let expected_client = case connector_id {
      "gmail" -> #(client_set.gmail_client_ref, client_set.gmail_client_hash)
      _ -> #(client_set.calendar_client_ref, client_set.calendar_client_hash)
    }
    use _ <- result.try(
      case
        client_set.client_set_hash == preparation.oauth_client_hash
        && client_ref == expected_client.0
        && configuration.oauth_client_ref == client_ref
        && configuration.oauth_scope == connector.oauth_scope
      {
        True -> Ok(Nil)
        False -> Error("google_oauth_client_set_binding_mismatch")
      },
    )
    use active <- result.try(db.list_effective_connector_activations(db_subject))
    use _ <- result.try(
      case
        list.any(active, fn(value) {
          value.connector_id == connector_id
          && value.configuration_ref == configuration_ref
        })
      {
        True -> Error("connector_activation_already_enabled")
        False -> Ok(Nil)
      },
    )
    google_oauth_runtime.begin(
      oauth_subject,
      google_oauth_runtime.BeginRequest(
        connector_id:,
        preparation_authorization_id: preparation_id,
        configuration_ref:,
        configuration_hash: configuration.configuration_hash,
        client_set_ref: client_set.client_set_ref,
        client_set_hash: client_set.client_set_hash,
        oauth_client_ref: client_ref,
        oauth_client_hash: expected_client.1,
      ),
    )
  }
  case result {
    Error(error) -> google_oauth_error(error)
    Ok(handle) ->
      json.object([
        #("ok", json.bool(True)),
        #("session_ref", json.string(handle.session_ref)),
        #("expires_at_ms", json.int(handle.expires_at_ms)),
        #("authorization_url", json.string(handle.authorization_url)),
      ])
      |> json.to_string
  }
}

/// Return only the durable OAuth phase and its bounded error class.
pub fn process_google_oauth_status(
  db_subject: process.Subject(db.DbMessage),
  session_ref: String,
) -> String {
  case
    db.list_operational_audit(
      db_subject,
      "connector_oauth_session",
      session_ref,
    )
  {
    Error(_) -> google_oauth_error("google_oauth_status_unavailable")
    Ok([]) -> google_oauth_error("oauth_session_not_found")
    Ok(records) -> {
      let assert Ok(latest) = list.last(records)
      let phase = oauth_phase_from_action(latest.action)
      json.object([
        #("ok", json.bool(True)),
        #("phase", json.string(phase)),
        #("error_class", json.nullable(latest.error_code, of: json.string)),
      ])
      |> json.to_string
    }
  }
}

fn oauth_phase_from_action(action: String) -> String {
  case action {
    "google.oauth.session.created" -> "waiting"
    "google.oauth.session.callback_claimed" -> "callback_claimed"
    "google.oauth.session.succeeded" -> "succeeded"
    "google.oauth.session.failed_before_effect" -> "failed_before_effect"
    "google.oauth.session.effect_unknown" -> "effect_unknown"
    "google.oauth.session.expired" -> "expired"
    _ -> "unknown"
  }
}

fn handle_connector_read_command(ctx: CtlContext, payload: String) -> String {
  case string.split(payload, " ") {
    ["run-once", authorization_id, connector_id] ->
      process_connector_read_once(
        ctx.db_subject,
        ctx.connector_runtime_subject,
        authorization_id,
        connector_id,
      )
    _ -> google_oauth_error("invalid_connector_read_command")
  }
}

/// Run one exact enabled connector through the supervised production runtime.
pub fn process_connector_read_once(
  db_subject: process.Subject(db.DbMessage),
  runtime_subject: process.Subject(connector_runtime.Message),
  authorization_id: String,
  connector_id: String,
) -> String {
  let result = {
    use _ <- result.try(case connector_id {
      "gmail" | "calendar" -> Ok(Nil)
      _ -> Error("connector_runner_unavailable")
    })
    use stored <- result.try(db.get_canary_authorization(
      db_subject,
      authorization_id,
    ))
    use authorization <- result.try(
      stored
      |> option.to_result("canary_authorization_not_found")
      |> result.map(fn(value) { value.authorization }),
    )
    use connector <- result.try(
      authorization.connectors
      |> list.find(fn(value) { value.connector_id == connector_id })
      |> result.map_error(fn(_) { "connector_authority_not_found" }),
    )
    use _ <- result.try(validate_connector_execution_proofs(
      db_subject,
      authorization.preparation_authorization_id,
      connector,
    ))
    use active <- result.try(db.get_effective_connector_activation(
      db_subject,
      connector.activation_id,
      authorization_id,
    ))
    use _ <- result.try(
      active |> option.to_result("connector_activation_not_effective"),
    )
    connector_runtime.run_once(
      runtime_subject,
      authorization_id,
      connector.activation_id,
    )
  }
  case result {
    Error(error) -> google_oauth_error(error)
    Ok(receipt) ->
      json.object([
        #("ok", json.bool(True)),
        #("connector_id", json.string(receipt.connector_id)),
        #("attempt_id", json.string(receipt.attempt_id)),
        #("evidence_count", json.int(receipt.evidence_count)),
      ])
      |> json.to_string
  }
}

fn validate_connector_execution_proofs(
  db_subject: process.Subject(db.DbMessage),
  preparation_id: String,
  connector: operating_contracts.AuthorizedConnectorV1,
) -> Result(Nil, String) {
  use oauth <- result.try(
    db.get_google_external_effect_by_proof(
      db_subject,
      connector.oauth_proof_ref,
    )
    |> result.map_error(fn(_) { "canary_connector_proof_mismatch" }),
  )
  use identity <- result.try(
    db.get_google_external_effect_by_proof(
      db_subject,
      connector.identity_proof_ref,
    )
    |> result.map_error(fn(_) { "canary_connector_proof_mismatch" }),
  )
  case
    oauth.phase == "succeeded"
    && oauth.effect_kind == "oauth_exchange"
    && identity.phase == "succeeded"
    && identity.effect_kind == "identity_read"
    && oauth.preparation_authorization_id == preparation_id
    && identity.preparation_authorization_id == preparation_id
    && oauth.connector_id == connector.connector_id
    && identity.connector_id == connector.connector_id
    && oauth.configuration_ref == connector.configuration_ref
    && identity.configuration_ref == connector.configuration_ref
    && oauth.configuration_hash == connector.configuration_hash
    && identity.configuration_hash == connector.configuration_hash
    && oauth.oauth_scope == connector.oauth_scope
    && identity.oauth_scope == connector.oauth_scope
    && identity.account_fingerprint == connector.account_fingerprint
  {
    True -> Ok(Nil)
    False -> Error("canary_connector_proof_mismatch")
  }
}

pub fn process_google_oauth_client_command(
  paths: xdg.Paths,
  db_subject: process.Subject(db.DbMessage),
  payload: String,
) -> String {
  case string.split_once(payload, " ") {
    Ok(#("google-client", rest)) ->
      case string.split_once(rest, " ") {
        Ok(#("install", raw)) ->
          process_google_client_install(paths, string.trim(raw))
        _ -> google_oauth_error("invalid_google_oauth_client_command")
      }
    Ok(#("google-client-set", rest)) ->
      case string.split_once(rest, " ") {
        Ok(#("create", raw)) ->
          case google_oauth_client.decode_client_set_command(string.trim(raw)) {
            Error(error) -> google_oauth_error(error)
            Ok(command) ->
              process_google_client_set_create(
                paths,
                db_subject,
                command.gmail_client_ref,
                command.calendar_client_ref,
              )
          }
        _ -> google_oauth_error("invalid_google_oauth_client_command")
      }
    _ -> google_oauth_error("invalid_google_oauth_client_command")
  }
}

fn process_google_client_install(paths: xdg.Paths, raw: String) -> String {
  case google_oauth_client.decode_install_command(raw) {
    Error(error) -> google_oauth_error(error)
    Ok(command) ->
      case
        google_oauth_client.install(
          paths,
          command.connector_id,
          command.source_path,
          command.source_sha256,
        )
      {
        Ok(receipt) -> google_oauth_client.encode_install_receipt(receipt)
        Error(error) -> google_oauth_error(error)
      }
  }
}

fn process_google_client_set_create(
  paths: xdg.Paths,
  db_subject: process.Subject(db.DbMessage),
  gmail_ref: String,
  calendar_ref: String,
) -> String {
  case create_or_recover_google_client_set(paths, gmail_ref, calendar_ref) {
    Error(error) -> google_oauth_error(error)
    Ok(receipt) -> {
      let registration =
        db.GoogleOAuthClientSet(
          client_set_ref: receipt.client_set_ref,
          client_set_hash: receipt.client_set_hash,
          gmail_client_ref: receipt.gmail_client_ref,
          gmail_client_hash: receipt.gmail_client_hash,
          calendar_client_ref: receipt.calendar_client_ref,
          calendar_client_hash: receipt.calendar_client_hash,
        )
      case db.register_google_oauth_client_set(db_subject, registration) {
        Ok(_) -> google_oauth_client.encode_client_set_receipt(receipt)
        Error(_) ->
          google_oauth_error("google_oauth_client_set_register_failed")
      }
    }
  }
}

fn create_or_recover_google_client_set(
  paths: xdg.Paths,
  gmail_ref: String,
  calendar_ref: String,
) -> Result(google_oauth_client.ClientSetReceipt, String) {
  case google_oauth_client.create_client_set(paths, gmail_ref, calendar_ref) {
    Ok(receipt) -> Ok(receipt)
    Error("google_oauth_client_set_already_exists") -> {
      use expected <- result.try(google_oauth_client.expected_client_set(
        paths,
        gmail_ref,
        calendar_ref,
      ))
      use stored <- result.try(google_oauth_client.load_client_set(
        paths,
        expected.client_set_ref,
      ))
      case stored == expected {
        True -> Ok(stored)
        False -> Error("google_oauth_client_set_collision")
      }
    }
    Error(error) -> Error(error)
  }
}

fn google_oauth_error(error: String) -> String {
  json.object([
    #("ok", json.bool(False)),
    #("error", json.string(error)),
  ])
  |> json.to_string
}

fn handle_monitor_command(ctx: CtlContext, payload: String) -> String {
  case string.split_once(payload, " ") {
    Ok(#("claim", raw)) ->
      process_monitor_claim(ctx.paths, ctx.db_subject, string.trim(raw))
    Ok(#("outcome", raw)) ->
      process_monitor_outcome(ctx.paths, ctx.db_subject, string.trim(raw))
    Ok(#("capability", "prepare")) -> prepare_monitor_capability(ctx.paths)
    _ -> monitor_error("invalid_monitor_command")
  }
}

/// Prepare one private monitor capability. The raw capability is never returned.
pub fn prepare_monitor_capability(paths: xdg.Paths) -> String {
  case
    secret.prepare_monitor_capability_in(xdg.monitor_capabilities_dir(paths))
  {
    Ok(capability) ->
      json.object([
        #("ok", json.bool(True)),
        #("capability_ref", json.string(capability.reference)),
        #("capability_sha256", json.string(capability.sha256)),
      ])
      |> json.to_string
    Error(_) -> monitor_error("monitor_capability_prepare_failed")
  }
}

/// Decode and execute one authorized monitor claim command.
pub fn process_monitor_claim(
  paths: xdg.Paths,
  db_subject: process.Subject(db.DbMessage),
  raw: String,
) -> String {
  case operating_contracts.decode_authorized_monitor_claim_command(raw) {
    Error(_) -> monitor_error("invalid_monitor_command")
    Ok(command) ->
      case codex_monitor.claim_authorized(paths, db_subject, command) {
        Error(error) -> monitor_error(error)
        Ok(option.None) ->
          json.object([
            #("ok", json.bool(True)),
            #("attention", json.null()),
            #("server_time_ms", json.int(time.now_ms())),
          ])
          |> json.to_string
        Ok(option.Some(envelope)) ->
          "{\"ok\":true,\"attention\":"
          <> operating_contracts.encode_monitor_attention_envelope(envelope)
          <> ",\"server_time_ms\":"
          <> int.to_string(time.now_ms())
          <> "}"
      }
  }
}

/// Decode and execute one authorized monitor outcome command.
pub fn process_monitor_outcome(
  paths: xdg.Paths,
  db_subject: process.Subject(db.DbMessage),
  raw: String,
) -> String {
  case operating_contracts.decode_authorized_monitor_outcome_command(raw) {
    Error(_) -> monitor_error("invalid_monitor_command")
    Ok(command) ->
      case codex_monitor.submit_authorized_outcome(paths, db_subject, command) {
        Error(error) -> monitor_error(error)
        Ok(receipt) ->
          "{\"ok\":true,\"receipt\":"
          <> operating_contracts.encode_monitor_outcome_receipt(receipt)
          <> ",\"server_time_ms\":"
          <> int.to_string(time.now_ms())
          <> "}"
      }
  }
}

fn monitor_error(error: String) -> String {
  let code = case
    string.contains(error, "idempotency_conflict"),
    string.contains(error, "invalid_codex_reference"),
    string.contains(error, "lease_owner_mismatch_or_inactive"),
    string.contains(error, "monitor_authentication_failed"),
    error == "invalid_monitor_command"
  {
    True, _, _, _, _ -> "idempotency_conflict"
    _, True, _, _, _ -> "invalid_codex_reference"
    _, _, True, _, _ -> "stale_or_mismatched_lease"
    _, _, _, True, _ -> "monitor_authentication_failed"
    _, _, _, _, True -> "invalid_monitor_command"
    _, _, _, _, _ -> "monitor_command_failed"
  }
  json.object([#("ok", json.bool(False)), #("error", json.string(code))])
  |> json.to_string
}

fn handle_evidence_submission(
  ctx: CtlContext,
  command: String,
  payload: String,
) -> String {
  process_evidence_submission(command, payload, fn(envelope) {
    event_ingest.submit_evidence(ctx.event_ingest_subject, envelope)
  })
}

/// Validate and execute one generic evidence control command.
pub fn process_evidence_submission(
  command: String,
  payload: String,
  submit: fn(operating_contracts.EvidenceEvent) ->
    Result(db.EvidenceInsert, String),
) -> String {
  case string.split_once(payload, " ") {
    Error(_) -> "ERROR: " <> command <> " requires submit <json>"
    Ok(#("submit", raw)) ->
      case operating_contracts.decode_evidence_event(string.trim(raw)) {
        Error(err) -> "ERROR: " <> err
        Ok(envelope) ->
          case
            command == "tool-result"
            && !list.contains(
              ["codex", "claude", "mcp_tool"],
              envelope.source_kind,
            )
          {
            True ->
              "ERROR: tool-result source_kind must be codex, claude, or mcp_tool"
            False ->
              case submit(envelope) {
                Error(err) -> "ERROR: " <> err
                Ok(insert) ->
                  case insert.inserted {
                    True -> hook_protocol.resp_ok_event_queued(insert.event_id)
                    False -> hook_protocol.resp_ok_deduped()
                  }
              }
          }
      }
    Ok(_) -> "ERROR: " <> command <> " requires submit <json>"
  }
}

fn handle_structured_mutation(ctx: CtlContext, payload: String) -> String {
  case operating_contracts.decode_command_mutation(payload) {
    Error(error) -> "ERROR: invalid command mutation: " <> error
    Ok(command) ->
      case operational_mutation.apply(ctx.paths, ctx.db_subject, command) {
        Error(error) -> "ERROR: " <> error
        Ok(result) ->
          "OK: mutation status="
          <> result.status
          <> " target_type="
          <> result.target_type
          <> " target_id="
          <> result.target_id
          <> " source_ref="
          <> result.source_ref
      }
  }
}

fn handle_connector_activation(ctx: CtlContext, payload: String) -> String {
  process_connector_activation_command(ctx.db_subject, payload)
}

/// Validate and apply one transcript-free connector activation control command.
pub fn process_connector_activation_command(
  db_subject: process.Subject(db.DbMessage),
  payload: String,
) -> String {
  case operating_contracts.decode_command_mutation(payload) {
    Error(error) -> "ERROR: invalid connector activation command: " <> error
    Ok(command) ->
      case connector_activation.apply_command(db_subject, command) {
        Error(error) -> "ERROR: " <> error
        Ok(activations) ->
          "OK: connector activation count="
          <> int.to_string(list.length(activations))
      }
  }
}

/// Draft or create one immutable preparation authorization from canonical JSON.
pub fn process_preparation_authorization_command(
  db_subject: process.Subject(db.DbMessage),
  payload: String,
) -> String {
  case string.split_once(payload, " ") {
    Ok(#("draft", raw)) ->
      case
        operating_contracts.decode_canary_preparation_authorization(string.trim(
          raw,
        ))
      {
        Error(error) -> "ERROR: " <> error
        Ok(value) ->
          authorization_draft_response(
            operating_contracts.encode_canary_preparation_authorization(value),
          )
      }
    Ok(#("create", rest)) ->
      case string.split_once(string.trim(rest), " ") {
        Error(_) -> "ERROR: canary-preparation create requires hash and JSON"
        Ok(#(approved_hash, raw)) ->
          case
            operating_contracts.decode_canary_preparation_authorization(
              string.trim(raw),
            )
          {
            Error(error) -> "ERROR: " <> error
            Ok(value) ->
              create_preparation_authorization(db_subject, approved_hash, value)
          }
      }
    _ ->
      "ERROR: canary-preparation requires draft <json> or create <hash> <json>"
  }
}

/// Draft or create one immutable final authorization from canonical JSON.
pub fn process_canary_authorization_command(
  db_subject: process.Subject(db.DbMessage),
  payload: String,
) -> String {
  case string.split_once(payload, " ") {
    Ok(#("draft", raw)) ->
      case operating_contracts.decode_canary_authorization(string.trim(raw)) {
        Error(error) -> "ERROR: " <> error
        Ok(value) ->
          authorization_draft_response(
            operating_contracts.encode_canary_authorization(value),
          )
      }
    Ok(#("create", rest)) ->
      case string.split_once(string.trim(rest), " ") {
        Error(_) -> "ERROR: canary-authorization create requires hash and JSON"
        Ok(#(approved_hash, raw)) ->
          case
            operating_contracts.decode_canary_authorization(string.trim(raw))
          {
            Error(error) -> "ERROR: " <> error
            Ok(value) ->
              create_canary_authorization(db_subject, approved_hash, value)
          }
      }
    _ ->
      "ERROR: canary-authorization requires draft <json> or create <hash> <json>"
  }
}

fn create_preparation_authorization(
  db_subject: process.Subject(db.DbMessage),
  approved_hash: String,
  value: operating_contracts.CanaryPreparationAuthorizationV1,
) -> String {
  let canonical_json =
    operating_contracts.encode_canary_preparation_authorization(value)
  case canary_payload_hash(canonical_json) == approved_hash {
    False -> "ERROR: approved_payload_hash_mismatch"
    True ->
      case db.create_canary_preparation_authorization(db_subject, value) {
        Error(error) -> "ERROR: " <> error
        Ok(stored) ->
          "OK: preparation_authorization="
          <> stored.authorization.authorization_id
          <> " payload_hash="
          <> stored.payload_hash
      }
  }
}

fn create_canary_authorization(
  db_subject: process.Subject(db.DbMessage),
  approved_hash: String,
  value: operating_contracts.CanaryAuthorizationV1,
) -> String {
  let canonical_json = operating_contracts.encode_canary_authorization(value)
  case canary_payload_hash(canonical_json) == approved_hash {
    False -> "ERROR: approved_payload_hash_mismatch"
    True ->
      case db.create_canary_authorization(db_subject, value) {
        Error(error) -> "ERROR: " <> error
        Ok(stored) ->
          "OK: canary_authorization="
          <> stored.authorization.authorization_id
          <> " payload_hash="
          <> stored.payload_hash
      }
  }
}

fn authorization_draft_response(canonical_json: String) -> String {
  "OK: payload_hash="
  <> canary_payload_hash(canonical_json)
  <> " canonical_json="
  <> canonical_json
}

fn canary_payload_hash(canonical_json: String) -> String {
  crypto.hash(crypto.Sha256, <<canonical_json:utf8>>)
  |> bit_array.base16_encode
}

fn handle_domain_migration(
  ctx: CtlContext,
  slug: String,
  idempotency_key: String,
) -> String {
  let payload = json.object([#("slug", json.string(slug))]) |> json.to_string
  let now = time.now_ms()
  case
    db.claim_operational_mutation(
      ctx.db_subject,
      idempotency_key,
      "domain.migrate_legacy",
      payload,
      now,
    )
  {
    Error(error) -> "ERROR: " <> error
    Ok(option.Some(receipt)) ->
      await_migration_receipt(ctx.db_subject, receipt, "domain-migrate", 500)
    Ok(option.None) -> {
      case domain_registry.migrate_legacy(ctx.paths, slug, now) {
        Error(error) -> {
          let _ =
            db.abandon_operational_mutation(
              ctx.db_subject,
              idempotency_key,
              "domain.migrate_legacy",
              payload,
            )
          "ERROR: " <> error
        }
        Ok(record) ->
          case
            db.complete_operational_mutation(
              ctx.db_subject,
              idempotency_key,
              "domain.migrate_legacy",
              payload,
              "domain",
              record.domain_id,
              "domain.legacy_migrated",
              "{}",
              option.None,
              now,
            )
          {
            Ok(_) -> "OK: domain-migrate target_id=" <> record.domain_id
            Error(error) ->
              "ERROR: effect_unknown: domain manifest changed but receipt failed: "
              <> error
          }
      }
    }
  }
}

fn handle_concern_migration(
  ctx: CtlContext,
  concern_slug: String,
  domain_slug: String,
  idempotency_key: String,
) -> String {
  let payload =
    json.object([
      #("concern_slug", json.string(concern_slug)),
      #("domain_slug", json.string(domain_slug)),
    ])
    |> json.to_string
  let now = time.now_ms()
  case
    db.claim_operational_mutation(
      ctx.db_subject,
      idempotency_key,
      "concern.migrate_legacy",
      payload,
      now,
    )
  {
    Error(error) -> "ERROR: " <> error
    Ok(option.Some(receipt)) ->
      await_migration_receipt(ctx.db_subject, receipt, "concern-migrate", 500)
    Ok(option.None) ->
      case domain_registry.load(ctx.paths, domain_slug) {
        Error(_) -> {
          let _ =
            db.abandon_operational_mutation(
              ctx.db_subject,
              idempotency_key,
              "concern.migrate_legacy",
              payload,
            )
          "ERROR: unknown_domain: " <> domain_slug
        }
        Ok(domain) -> {
          let concern_id =
            "concern:" <> domain.record.domain_id <> ":" <> concern_slug
          case concern.migrate_legacy(ctx.paths, concern_slug, domain_slug) {
            Error(error) -> {
              let _ =
                db.abandon_operational_mutation(
                  ctx.db_subject,
                  idempotency_key,
                  "concern.migrate_legacy",
                  payload,
                )
              "ERROR: " <> error
            }
            Ok(_) ->
              case
                db.complete_operational_mutation(
                  ctx.db_subject,
                  idempotency_key,
                  "concern.migrate_legacy",
                  payload,
                  "concern",
                  concern_id,
                  "concern.legacy_migrated",
                  "{}",
                  option.Some(domain.record.domain_id),
                  now,
                )
              {
                Ok(_) -> "OK: concern-migrate target_id=" <> concern_id
                Error(error) ->
                  "ERROR: effect_unknown: concern file changed but receipt failed: "
                  <> error
              }
          }
        }
      }
  }
}

fn await_migration_receipt(
  db_subject: process.Subject(db.DbMessage),
  receipt: db.MutationReceipt,
  command_name: String,
  attempts_remaining: Int,
) -> String {
  case receipt.result_version > 0 {
    True -> "OK: " <> command_name <> " target_id=" <> receipt.result_target_id
    False if attempts_remaining <= 0 -> "ERROR: mutation_in_progress"
    False -> {
      process.sleep(10)
      case db.get_mutation_receipt(db_subject, receipt.idempotency_key) {
        Ok(option.Some(next)) ->
          await_migration_receipt(
            db_subject,
            next,
            command_name,
            attempts_remaining - 1,
          )
        Ok(option.None) -> "ERROR: mutation_claim_lost"
        Error(error) -> "ERROR: " <> error
      }
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
      let envelope =
        hook_protocol.event_to_evidence(
          source,
          type_,
          subject,
          external_id,
          data,
          id,
          now,
        )
      case event_ingest.submit_evidence(ctx.event_ingest_subject, envelope) {
        Error(err) -> "ERROR: " <> err
        Ok(insert) if insert.inserted ->
          hook_protocol.resp_ok_event_queued(insert.event_id)
        Ok(_) -> hook_protocol.resp_ok_deduped()
      }
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
      let envelope =
        hook_protocol.notify_to_evidence(
          source,
          rule,
          target,
          text,
          external_id,
          event_id,
          now,
        )
      case event_ingest.submit_evidence(ctx.event_ingest_subject, envelope) {
        Error(err) -> "ERROR: " <> err
        Ok(insert) if insert.inserted ->
          hook_protocol.resp_ok_event_queued(insert.event_id)
        Ok(_) -> hook_protocol.resp_ok_deduped()
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
          let ask =
            build_external_ask(
              source,
              correlation_id,
              target,
              prefixed,
              buttons,
              now,
            )
          let reply = process.new_subject()
          let _ =
            external_asks.submit_ask(
              asks_subject,
              ask,
              ttl_minutes * 60_000,
              reply,
            )
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
    option.Some(asks_subject) ->
      external_asks.get_decision(asks_subject, correlation_id)
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
      |> list.map(fn(entry) {
        string.drop_start(entry, string.length(entry) - 5)
      })
    })
    |> result.unwrap([])
  let ruleset_names = string.join(rulesets, ", ")
  let sources = case db.list_event_sources(ctx.db_subject) {
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
  "rulesets: "
  <> ruleset_names
  <> case sources {
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
