//// Transport-neutral boundary for one local Codex attention monitor.

import aura/attention_queue
import aura/concern
import aura/db
import aura/domain_registry
import aura/operating_contracts
import aura/secret
import aura/time
import aura/xdg
import gleam/bit_array
import gleam/crypto
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// Claim one authorized route. The capability is read from its private file.
pub fn claim_authorized(
  paths: xdg.Paths,
  db_subject: process.Subject(db.DbMessage),
  command: operating_contracts.AuthorizedMonitorClaimCommand,
) -> Result(Option(operating_contracts.MonitorAttentionEnvelope), String) {
  use _ <- result.try(validate_authorized_claim_command(command))
  let proof_payload =
    operating_contracts.authorized_monitor_claim_proof_payload(command)
  use authorization <- result.try(load_authorization(
    paths,
    db_subject,
    command.authorization_id,
    command.monitor_id,
    command.monitor_runtime_ref,
    command.authority_grants,
    True,
  ))
  use _ <- result.try(verify_command_proof(
    paths,
    authorization.monitor_capability_hash,
    proof_payload,
    command.capability_proof,
  ))
  use loaded_route <- result.try(load_effective_route(db_subject, authorization))
  let route =
    db.MonitorRoute(
      ..loaded_route,
      claim_command_id: command.command_id,
      claim_payload_hash: sha256(proof_payload),
    )
  let now = time.now_ms()
  use _ <- result.try(db.expire_attention(db_subject, "codex", now))
  use _ <- result.try(db.recover_attention(db_subject, "codex", now))
  use claimed <- result.try(db.claim_authorized_attention(
    db_subject,
    command.monitor_id,
    command.lease_ms,
    route,
    now,
  ))
  case claimed {
    None -> Ok(None)
    Some(value) ->
      case build_envelope(paths, command.monitor_id, value) {
        Error(error) -> {
          let recovery_now = time.now_ms()
          let _ =
            db.reschedule_attention(
              db_subject,
              value.lease_token,
              "monitor_context_error",
              recovery_now + command.lease_ms,
              recovery_now,
            )
          Error(error)
        }
        Ok(envelope) -> {
          use _ <- result.try(db.begin_authorized_attention_delivery(
            db_subject,
            value.lease_token,
          ))
          Ok(Some(envelope))
        }
      }
  }
}

/// Apply one outcome using Aura server time and the original route binding.
pub fn submit_authorized_outcome(
  paths: xdg.Paths,
  db_subject: process.Subject(db.DbMessage),
  command: operating_contracts.AuthorizedMonitorOutcomeCommand,
) -> Result(operating_contracts.MonitorOutcomeReceipt, String) {
  use _ <- result.try(validate_authorized_outcome_command(command))
  let proof_payload =
    operating_contracts.authorized_monitor_outcome_proof_payload(command)
  use authorization <- result.try(load_authorization(
    paths,
    db_subject,
    command.authorization_id,
    command.monitor_id,
    command.monitor_runtime_ref,
    command.authority_grants,
    True,
  ))
  use _ <- result.try(verify_command_proof(
    paths,
    authorization.monitor_capability_hash,
    proof_payload,
    command.capability_proof,
  ))
  let route = route_for_authorization(authorization)
  let outcome =
    operating_contracts.MonitorOutcome(
      schema_version: 1,
      outcome_id: command.outcome_id,
      queue_id: command.queue_id,
      lease_token: command.lease_token,
      monitor_id: command.monitor_id,
      disposition: command.disposition,
      defer_until: command.defer_until,
      codex_task_ref: command.codex_task_ref,
      codex_conversation_ref: command.codex_conversation_ref,
      codex_turn_ref: command.codex_turn_ref,
      authority_grants: command.authority_grants,
      occurred_at: time.now_ms(),
    )
  db.apply_authorized_monitor_outcome(db_subject, outcome, route)
}

fn validate_authorized_claim_command(
  command: operating_contracts.AuthorizedMonitorClaimCommand,
) -> Result(Nil, String) {
  case
    command.schema_version == 1
    && operating_contracts.valid_codex_reference(command.command_id, "command")
    && string.trim(command.authorization_id) != ""
    && operating_contracts.valid_codex_reference(
      command.monitor_runtime_ref,
      "runtime",
    )
    && command.lease_ms > 0
    && command.lease_ms <= 300_000
    && has_exact_grants(command.authority_grants, [
      "attention.read",
      "attention.claim",
    ])
  {
    True -> Ok(Nil)
    False -> Error("monitor_authentication_failed")
  }
}

fn validate_authorized_outcome_command(
  command: operating_contracts.AuthorizedMonitorOutcomeCommand,
) -> Result(Nil, String) {
  let expected = case command.disposition {
    "acknowledge" -> ["attention.acknowledge"]
    "defer" -> ["attention.defer"]
    _ -> []
  }
  let disposition_valid = case command.disposition, command.defer_until {
    "acknowledge", None -> True
    "defer", Some(_) -> True
    _, _ -> False
  }
  case
    command.schema_version == 1
    && operating_contracts.valid_codex_reference(command.command_id, "command")
    && string.trim(command.authorization_id) != ""
    && operating_contracts.valid_codex_reference(
      command.monitor_runtime_ref,
      "runtime",
    )
    && expected != []
    && has_exact_grants(command.authority_grants, expected)
    && disposition_valid
    && valid_command_ref(command.codex_task_ref, "task")
    && valid_command_ref(command.codex_conversation_ref, "conversation")
    && valid_command_ref(command.codex_turn_ref, "turn")
  {
    True -> Ok(Nil)
    False -> Error("monitor_authentication_failed")
  }
}

fn valid_command_ref(value: Option(String), kind: String) -> Bool {
  case value {
    None -> True
    Some(reference) ->
      operating_contracts.valid_codex_reference(reference, kind)
  }
}

fn load_authorization(
  _paths: xdg.Paths,
  db_subject: process.Subject(db.DbMessage),
  authorization_id: String,
  monitor_id: String,
  runtime_ref: String,
  grants: List(String),
  require_effective_window: Bool,
) -> Result(operating_contracts.CanaryAuthorizationV1, String) {
  use stored <- result.try(
    db.get_canary_authorization(db_subject, authorization_id)
    |> result.map_error(fn(_) { "monitor_authentication_failed" }),
  )
  use value <- result.try(case stored {
    Some(value) -> Ok(value.authorization)
    None -> Error("monitor_authentication_failed")
  })
  let now = time.now_ms()
  let grants_authorized =
    list.all(grants, fn(grant) { list.contains(value.monitor_grants, grant) })
  use _ <- result.try(
    case
      value.monitor_id == monitor_id
      && value.monitor_runtime_ref == runtime_ref
      && value.attention_owner == "codex"
      && value.attention_target == "codex_monitor"
      && !value.discord_delivery_allowed
      && grants_authorized
      && {
        !require_effective_window
        || { value.starts_at_ms <= now && value.ends_at_ms > now }
      }
    {
      True -> Ok(Nil)
      False -> Error("monitor_authentication_failed")
    },
  )
  Ok(value)
}

fn verify_command_proof(
  paths: xdg.Paths,
  capability_hash: String,
  payload: String,
  proof: String,
) -> Result(Nil, String) {
  secret.verify_monitor_command_proof(
    xdg.monitor_capability_path(paths, capability_hash),
    payload,
    proof,
  )
}

fn sha256(value: String) -> String {
  crypto.hash(crypto.Sha256, <<value:utf8>>)
  |> bit_array.base16_encode
  |> string.lowercase
}

fn load_effective_route(
  db_subject: process.Subject(db.DbMessage),
  authorization: operating_contracts.CanaryAuthorizationV1,
) -> Result(db.MonitorRoute, String) {
  use activations <- result.try(
    authorization.connectors
    |> list.try_map(fn(connector) {
      use found <- result.try(
        db.get_effective_connector_activation(
          db_subject,
          connector.activation_id,
          authorization.authorization_id,
        )
        |> result.map_error(fn(_) { "monitor_authentication_failed" }),
      )
      case found {
        Some(value)
          if value.domain_id == authorization.domain_id
          && value.concern_id == authorization.concern_id
        -> Ok(value.activation_id)
        _ -> Error("monitor_authentication_failed")
      }
    }),
  )
  Ok(route_for(authorization, activations))
}

fn route_for_authorization(
  authorization: operating_contracts.CanaryAuthorizationV1,
) -> db.MonitorRoute {
  route_for(
    authorization,
    list.map(authorization.connectors, fn(connector) { connector.activation_id }),
  )
}

fn route_for(
  authorization: operating_contracts.CanaryAuthorizationV1,
  activation_ids: List(String),
) -> db.MonitorRoute {
  let stored_domain_id = case
    string.starts_with(authorization.domain_id, "domain:")
  {
    True -> string.drop_start(authorization.domain_id, string.length("domain:"))
    False -> authorization.domain_id
  }
  db.MonitorRoute(
    authorization_id: authorization.authorization_id,
    activation_ids_json: activation_ids
      |> list.sort(by: string.compare)
      |> json.array(of: json.string)
      |> json.to_string,
    domain_id: stored_domain_id,
    concern_id: authorization.concern_id,
    claim_command_id: "",
    claim_payload_hash: "",
  )
}

/// Recover Codex-owned leases, claim one item, and return a compact envelope.
pub fn claim(
  paths: xdg.Paths,
  db_subject: process.Subject(db.DbMessage),
  request: operating_contracts.MonitorClaimRequest,
) -> Result(Option(operating_contracts.MonitorAttentionEnvelope), String) {
  use _ <- result.try(validate_claim(request))
  let now = time.now_ms()
  use _ <- result.try(db.expire_attention(db_subject, "codex", now))
  use _ <- result.try(db.recover_attention(db_subject, "codex", now))
  use claimed <- result.try(db.claim_attention(
    db_subject,
    "codex",
    request.monitor_id,
    request.lease_ms,
    now,
  ))
  case claimed {
    None -> Ok(None)
    Some(value) ->
      case build_envelope(paths, request.monitor_id, value) {
        Error(error) -> {
          let _ =
            db.reschedule_attention(
              db_subject,
              value.lease_token,
              "monitor_context_error",
              now + request.lease_ms,
              now,
            )
          Error(error)
        }
        Ok(envelope) -> {
          use _ <- result.try(db.begin_attention_delivery(
            db_subject,
            value.lease_token,
            now,
          ))
          Ok(Some(envelope))
        }
      }
  }
}

/// Apply one bounded Codex outcome. Aura creates the stored receipt.
pub fn submit_outcome(
  db_subject: process.Subject(db.DbMessage),
  outcome: operating_contracts.MonitorOutcome,
) -> Result(operating_contracts.MonitorOutcomeReceipt, String) {
  use _ <- result.try(validate_outcome(outcome))
  db.apply_monitor_outcome(db_subject, outcome)
}

fn validate_claim(
  request: operating_contracts.MonitorClaimRequest,
) -> Result(Nil, String) {
  case
    request.schema_version == 1
    && string.trim(request.monitor_id) != ""
    && request.lease_ms > 0
    && request.lease_ms <= 300_000
    && has_exact_grants(request.authority_grants, [
      "attention.read",
      "attention.claim",
    ])
  {
    True -> Ok(Nil)
    False -> Error("authority_denied_or_invalid_claim")
  }
}

fn validate_outcome(
  outcome: operating_contracts.MonitorOutcome,
) -> Result(Nil, String) {
  let required = case outcome.disposition {
    "acknowledge" -> ["attention.acknowledge"]
    "defer" -> ["attention.defer"]
    _ -> []
  }
  use _ <- result.try(
    case
      required != [] && has_exact_grants(outcome.authority_grants, required)
    {
      True -> Ok(Nil)
      False -> Error("authority_denied")
    },
  )
  use _ <- result.try(case outcome.disposition, outcome.defer_until {
    "acknowledge", None -> Ok(Nil)
    "defer", Some(at) if at > outcome.occurred_at -> Ok(Nil)
    _, _ -> Error("invalid_monitor_outcome")
  })
  use _ <- result.try(validate_codex_ref(outcome.codex_task_ref, "task"))
  use _ <- result.try(validate_codex_ref(
    outcome.codex_conversation_ref,
    "conversation",
  ))
  use _ <- result.try(validate_codex_ref(outcome.codex_turn_ref, "turn"))
  case
    outcome.schema_version == 1
    && string.trim(outcome.outcome_id) != ""
    && string.trim(outcome.queue_id) != ""
    && string.trim(outcome.lease_token) != ""
    && string.trim(outcome.monitor_id) != ""
  {
    True -> Ok(Nil)
    False -> Error("invalid_monitor_outcome")
  }
}

fn validate_codex_ref(
  value: Option(String),
  kind: String,
) -> Result(Nil, String) {
  case value {
    None -> Ok(Nil)
    Some(reference) ->
      case operating_contracts.valid_codex_reference(reference, kind) {
        True -> Ok(Nil)
        False -> Error("invalid_codex_reference")
      }
  }
}

fn has_exact_grants(actual: List(String), expected: List(String)) -> Bool {
  list.sort(actual, by: string.compare)
  == list.sort(expected, by: string.compare)
}

fn build_envelope(
  paths: xdg.Paths,
  monitor_id: String,
  claim: attention_queue.Claim,
) -> Result(operating_contracts.MonitorAttentionEnvelope, String) {
  let item = claim.item
  use domain_slug <- result.try(normalize_domain_slug(item.domain_id))
  use loaded_domain <- result.try(domain_registry.load(paths, domain_slug))
  use concern_context <- result.try(load_concern_context(
    paths,
    domain_slug,
    item.concern_id,
  ))
  let evidence_refs =
    unique_refs(list.append(
      item.event_refs,
      list.filter(item.citations, fn(ref) {
        string.starts_with(ref, "evidence:")
      }),
    ))
  let policy_refs =
    unique_refs(
      list.filter(item.citations, fn(ref) { string.starts_with(ref, "policy:") }),
    )
  Ok(
    operating_contracts.MonitorAttentionEnvelope(
      schema_version: 1,
      queue_id: item.queue_id,
      lease_token: claim.lease_token,
      lease_expires_at: item.lease_expires_at |> option.unwrap(0),
      queue_version: item.version,
      monitor_id:,
      action: item.action,
      summary: compact_text(item.summary, 2000),
      rationale: compact_text(item.rationale, 2000),
      why_now: compact_optional(item.why_now, 1000),
      deferral_cost: compact_optional(item.deferral_cost, 1000),
      why_not_digest: compact_optional(item.why_not_digest, 1000),
      authority_request: compact_optional(item.authority_request, 1000),
      evidence_refs:,
      policy_refs:,
      domain_context: operating_contracts.MonitorDomainContext(
        domain_id: loaded_domain.record.domain_id,
        source_ref: "domains/" <> domain_slug <> "/domain.json",
        display_name: compact_text(loaded_domain.record.display_name, 256),
        purpose: compact_text(loaded_domain.record.purpose, 2000),
        status: loaded_domain.record.status,
      ),
      concern_context:,
      allowed_outcomes: ["acknowledge", "defer"],
    ),
  )
}

fn normalize_domain_slug(domain_id: String) -> Result(String, String) {
  let slug = case string.starts_with(domain_id, "domain:") {
    True -> string.drop_start(domain_id, string.length("domain:"))
    False -> domain_id
  }
  case string.trim(slug) == "" {
    True -> Error("invalid_domain_id")
    False -> Ok(slug)
  }
}

fn load_concern_context(
  paths: xdg.Paths,
  domain_slug: String,
  concern_id: Option(String),
) -> Result(Option(operating_contracts.MonitorConcernContext), String) {
  case concern_id {
    None -> Ok(None)
    Some(id) -> {
      let slug = concern_slug(id)
      use loaded <- result.try(concern.load_for_domain(paths, domain_slug, slug))
      Ok(
        Some(operating_contracts.MonitorConcernContext(
          concern_id: id,
          source_ref: loaded.source_ref,
          status: markdown_value(loaded.content, "Status:")
            |> option.unwrap("unknown"),
          summary: compact_text(markdown_summary(loaded.content), 2000),
        )),
      )
    }
  }
}

fn concern_slug(id: String) -> String {
  id |> string.split(":") |> list.last |> result.unwrap(id)
}

fn markdown_value(content: String, prefix: String) -> Option(String) {
  case
    content
    |> string.split("\n")
    |> list.find(fn(line) { string.starts_with(line, prefix) })
  {
    Ok(line) ->
      line
      |> string.drop_start(string.length(prefix))
      |> string.trim
      |> Some
    Error(_) -> None
  }
}

fn markdown_summary(content: String) -> String {
  case string.split(content, "## Summary") {
    [_, tail, ..] ->
      tail
      |> string.trim
      |> string.split("\n")
      |> list.first
      |> result.unwrap("")
    _ -> ""
  }
}

fn unique_refs(values: List(String)) -> List(String) {
  values
  |> list.take(50)
  |> list.fold([], fn(acc, value) {
    let compact = compact_text(value, 256)
    case compact == "" || list.contains(acc, compact) {
      True -> acc
      False -> list.append(acc, [compact])
    }
  })
}

fn compact_optional(value: Option(String), limit: Int) -> Option(String) {
  option.map(value, fn(text) { compact_text(text, limit) })
}

fn compact_text(value: String, limit: Int) -> String {
  case string.length(value) > limit {
    True -> string.slice(value, 0, limit)
    False -> value
  }
}
