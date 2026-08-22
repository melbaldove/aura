//// Durable attention queue contracts and deterministic identity rules.

import aura/cognitive_decision
import aura/operating_contracts
import gleam/bit_array
import gleam/crypto
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub const delivery_owner = "discord_compat"

pub type EnqueueRequest {
  EnqueueRequest(
    queue_id: String,
    decision_id: String,
    domain_id: String,
    concern_id: Option(String),
    event_refs: List(String),
    action: String,
    summary: String,
    rationale: String,
    why_now: Option(String),
    deferral_cost: Option(String),
    why_not_digest: Option(String),
    authority_request: Option(String),
    citations: List(String),
    delivery_owner: String,
    delivery_target: String,
    delivery_key: String,
    available_at: Int,
    expires_at: Option(Int),
  )
}

pub type Claim {
  Claim(item: operating_contracts.AttentionQueueItem, lease_token: String)
}

pub type DeliveryAttempt {
  DeliveryAttempt(
    attempt_id: Int,
    queue_id: String,
    attempt_number: Int,
    lease_owner: String,
    lease_token: String,
    lease_expires_at: Int,
    phase: String,
    external_receipts: List(String),
    error: String,
    created_at: Int,
    updated_at: Int,
  )
}

pub type RecoverySummary {
  RecoverySummary(requeued: Int, unknown: Int)
}

/// Convert one validated immediate policy decision to a canonical queue input.
pub fn from_decision(
  decision: cognitive_decision.DecisionEnvelope,
  now: Int,
) -> Result(EnqueueRequest, String) {
  case list.contains(["surface_now", "ask_now"], decision.attention.action) {
    False -> Error("Only surface_now or ask_now can enter the attention queue")
    True -> {
      let concern_id = case decision.concern_refs {
        [first, ..] -> Some(first)
        [] -> None
      }
      let domain_id = domain_from_target(decision.delivery.target)
      Ok(EnqueueRequest(
        queue_id: "attention:" <> decision.event_id,
        decision_id: decision.event_id,
        domain_id:,
        concern_id:,
        event_refs: [decision.event_id],
        action: decision.attention.action,
        summary: decision.summary,
        rationale: decision.attention.rationale,
        why_now: present_option(decision.attention.why_now),
        deferral_cost: present_option(decision.attention.deferral_cost),
        why_not_digest: present_option(decision.attention.why_not_digest),
        authority_request: case decision.authority.required {
          "none" | "" -> None
          required -> Some(required <> ": " <> decision.authority.reason)
        },
        citations: decision.citations,
        delivery_owner:,
        delivery_target: decision.delivery.target,
        delivery_key: "cognitive:" <> decision.event_id,
        available_at: now,
        expires_at: None,
      ))
    }
  }
}

/// Convert one validated decision to an authorized Codex monitor queue input.
pub fn from_authorized_decision(
  decision: cognitive_decision.DecisionEnvelope,
  authorization: operating_contracts.CanaryAuthorizationV1,
  now: Int,
) -> Result(EnqueueRequest, String) {
  use request <- result.try(from_decision(decision, now))
  let concern_matches = decision.concern_refs == [authorization.concern_id]
  let policy_cited =
    list.any(authorization.policy_refs, fn(reference) {
      list.contains(decision.citations, reference)
    })
  case
    authorization.attention_owner == "codex"
    && authorization.attention_target == "codex_monitor"
    && !authorization.discord_delivery_allowed
    && concern_matches
    && policy_cited
  {
    False -> Error("authorized_attention_decision_mismatch")
    True ->
      Ok(
        EnqueueRequest(
          ..request,
          domain_id: domain_from_target(authorization.domain_id),
          concern_id: Some(authorization.concern_id),
          delivery_owner: authorization.attention_owner,
          delivery_target: authorization.attention_target,
          delivery_key: "codex:"
            <> authorization.authorization_id
            <> ":"
            <> decision.event_id,
          authority_request: Some(authorization.authorization_id),
        ),
      )
  }
}

/// Hash all immutable enqueue fields for idempotency conflict detection.
pub fn payload_hash(request: EnqueueRequest) -> String {
  let payload =
    json.object([
      #("decision_id", json.string(request.decision_id)),
      #("domain_id", json.string(request.domain_id)),
      #("concern_id", json.nullable(request.concern_id, of: json.string)),
      #("event_refs", json.array(request.event_refs, of: json.string)),
      #("action", json.string(request.action)),
      #("summary", json.string(request.summary)),
      #("rationale", json.string(request.rationale)),
      #("why_now", json.nullable(request.why_now, of: json.string)),
      #("deferral_cost", json.nullable(request.deferral_cost, of: json.string)),
      #(
        "why_not_digest",
        json.nullable(request.why_not_digest, of: json.string),
      ),
      #(
        "authority_request",
        json.nullable(request.authority_request, of: json.string),
      ),
      #("citations", json.array(request.citations, of: json.string)),
      #("delivery_owner", json.string(request.delivery_owner)),
      #("delivery_target", json.string(request.delivery_target)),
      #("delivery_key", json.string(request.delivery_key)),
    ])
    |> json.to_string
  crypto.hash(crypto.Sha256, <<payload:utf8>>) |> bit_array.base16_encode
}

/// Hash the immutable fields of one stored item.
pub fn stored_payload_hash(
  item: operating_contracts.AttentionQueueItem,
) -> String {
  payload_hash(EnqueueRequest(
    queue_id: item.queue_id,
    decision_id: item.decision_id,
    domain_id: item.domain_id,
    concern_id: item.concern_id,
    event_refs: item.event_refs,
    action: item.action,
    summary: item.summary,
    rationale: item.rationale,
    why_now: item.why_now,
    deferral_cost: item.deferral_cost,
    why_not_digest: item.why_not_digest,
    authority_request: item.authority_request,
    citations: item.citations,
    delivery_owner: item.delivery_owner,
    delivery_target: item.delivery_target,
    delivery_key: item.delivery_key,
    available_at: item.available_at,
    expires_at: item.expires_at,
  ))
}

fn present_option(value: String) -> Option(String) {
  case string.trim(value) {
    "" -> None
    present -> Some(present)
  }
}

fn domain_from_target(target: String) -> String {
  case string.starts_with(target, "domain:") {
    True -> string.replace(target, "domain:", "")
    False -> "global"
  }
}
