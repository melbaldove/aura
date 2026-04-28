//// Model decision envelope for the cognitive loop.
////
//// The envelope is intentionally broad. It is a transport and validation
//// boundary, not a typed theory of attention, concern matching, or cognition.

import aura/cognitive_context
import aura/llm
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/result
import gleam/string

pub type AttentionDecision {
  AttentionDecision(
    action: String,
    rationale: String,
    why_now: String,
    deferral_cost: String,
    why_not_digest: String,
  )
}

pub type WorkDecision {
  WorkDecision(action: String, target: String, proof_required: String)
}

pub type AuthorityDecision {
  AuthorityDecision(required: String, reason: String)
}

pub type DeliveryDecision {
  DeliveryDecision(target: String, rationale: String)
}

pub type ProposedPatch {
  ProposedPatch(path: String, summary: String, diff: String)
}

pub type DecisionEnvelope {
  DecisionEnvelope(
    event_id: String,
    concern_refs: List(String),
    summary: String,
    citations: List(String),
    attention: AttentionDecision,
    work: WorkDecision,
    authority: AuthorityDecision,
    delivery: DeliveryDecision,
    gaps: List(String),
    proposed_patches: List(ProposedPatch),
  )
}

/// Build the model messages for a single cognitive decision.
pub fn build_messages(
  context: cognitive_context.ContextPacket,
) -> List(llm.Message) {
  [
    llm.SystemMessage(
      "You are Aura's cognitive decision loop. Read the event context, "
      <> "policies, user/domain context, concerns, and evidence. Return only "
      <> "one JSON object matching the requested DecisionEnvelope schema. Do "
      <> "not use markdown. Do not invent citation refs; cite only refs listed "
      <> "in Known Citation Refs.",
    ),
    llm.UserMessage(
      cognitive_context.render(context) <> "\n\n" <> decision_instructions(),
    ),
  ]
}

/// Decode the model's JSON response into a decision envelope.
pub fn decode_response(raw_response: String) -> Result(DecisionEnvelope, String) {
  let json_text = strip_code_fence(raw_response)
  json.parse(json_text, decision_decoder())
  |> result.map_error(fn(e) {
    "Failed to decode DecisionEnvelope: " <> string.inspect(e)
  })
}

/// Validate the model decision against the exact context packet it saw.
pub fn validate(
  decision: DecisionEnvelope,
  context: cognitive_context.ContextPacket,
) -> Result(DecisionEnvelope, List(String)) {
  let known_refs = cognitive_context.known_citation_refs(context)
  let evidence_refs = cognitive_context.evidence_citation_refs(context)
  let policy_refs = cognitive_context.policy_citation_refs(context)
  let concern_refs = cognitive_context.concern_citation_refs(context)

  let unknown_citations =
    decision.citations
    |> list.filter(fn(ref) { !list.contains(known_refs, ref) })
    |> list.map(fn(ref) { "unknown citation ref: " <> ref })

  let unknown_concerns =
    decision.concern_refs
    |> list.filter(fn(ref) { !list.contains(concern_refs, ref) })
    |> list.map(fn(ref) { "unknown concern ref: " <> ref })

  let errors =
    []
    |> require(
      decision.event_id == context.observation.id,
      "event_id does not match context",
    )
    |> require(present(decision.summary), "summary is required")
    |> require(decision.citations != [], "at least one citation is required")
    |> require(
      has_any(decision.citations, evidence_refs),
      "at least one evidence or raw citation is required",
    )
    |> require(
      has_any(decision.citations, policy_refs),
      "at least one policy citation is required",
    )
    |> require(
      valid_attention_action(decision.attention.action),
      "invalid attention.action",
    )
    |> require(
      present(decision.attention.rationale),
      "attention.rationale is required",
    )
    |> require(valid_work_action(decision.work.action), "invalid work.action")
    |> require(
      valid_authority(decision.authority.required),
      "invalid authority.required",
    )
    |> require(
      authority_has_reason(decision.authority),
      "non-none authority requires reason",
    )
    |> require(
      delivery_target_allowed(decision.delivery.target, context),
      "invalid delivery.target",
    )
    |> require(
      present(decision.delivery.rationale),
      "delivery.rationale is required",
    )
    |> require(
      attention_delivery_is_consistent(decision.attention, decision.delivery),
      "attention.action and delivery.target are inconsistent",
    )
    |> require(
      attention_has_surface_proof(decision.attention),
      "surface_now/ask_now requires why_now, deferral_cost, and why_not_digest",
    )
    |> require(
      valid_patch_paths(decision.proposed_patches),
      "proposed patches must target policies/*.md or concerns/*.md without path traversal",
    )
    |> require(
      valid_patch_bodies(decision.proposed_patches),
      "proposed patches require summary and diff",
    )

  let errors =
    list.append(errors, list.append(unknown_citations, unknown_concerns))

  case errors {
    [] -> Ok(decision)
    _ -> Error(errors)
  }
}

/// Encode a validated decision for append-only JSONL logging.
pub fn to_json(
  decision: DecisionEnvelope,
  raw_response: String,
  timestamp_ms: Int,
) -> json.Json {
  json.object([
    #("timestamp_ms", json.int(timestamp_ms)),
    #("event_id", json.string(decision.event_id)),
    #("concern_refs", json.array(decision.concern_refs, json.string)),
    #("summary", json.string(decision.summary)),
    #("citations", json.array(decision.citations, json.string)),
    #("attention", attention_to_json(decision.attention)),
    #("work", work_to_json(decision.work)),
    #("authority", authority_to_json(decision.authority)),
    #("delivery", delivery_to_json(decision.delivery)),
    #("gaps", json.array(decision.gaps, json.string)),
    #("proposed_patches", json.array(decision.proposed_patches, patch_to_json)),
    #("raw_response", json.string(raw_response)),
  ])
}

fn decision_decoder() {
  use event_id <- decode.field("event_id", decode.string)
  use concern_refs <- decode.field("concern_refs", decode.list(decode.string))
  use summary <- decode.field("summary", decode.string)
  use citations <- decode.field("citations", decode.list(decode.string))
  use attention <- decode.field("attention", attention_decoder())
  use work <- decode.field("work", work_decoder())
  use authority <- decode.field("authority", authority_decoder())
  use delivery <- decode.field("delivery", delivery_decoder())
  use gaps <- decode.field("gaps", decode.list(decode.string))
  use proposed_patches <- decode.field(
    "proposed_patches",
    decode.list(patch_decoder()),
  )
  decode.success(DecisionEnvelope(
    event_id: event_id,
    concern_refs: concern_refs,
    summary: summary,
    citations: citations,
    attention: attention,
    work: work,
    authority: authority,
    delivery: delivery,
    gaps: gaps,
    proposed_patches: proposed_patches,
  ))
}

fn attention_decoder() {
  use action <- decode.field("action", decode.string)
  use rationale <- decode.field("rationale", decode.string)
  use why_now <- decode.field("why_now", decode.string)
  use deferral_cost <- decode.field("deferral_cost", decode.string)
  use why_not_digest <- decode.field("why_not_digest", decode.string)
  decode.success(AttentionDecision(
    action: action,
    rationale: rationale,
    why_now: why_now,
    deferral_cost: deferral_cost,
    why_not_digest: why_not_digest,
  ))
}

fn work_decoder() {
  use action <- decode.field("action", decode.string)
  use target <- decode.field("target", decode.string)
  use proof_required <- decode.field("proof_required", decode.string)
  decode.success(WorkDecision(
    action: action,
    target: target,
    proof_required: proof_required,
  ))
}

fn authority_decoder() {
  use required <- decode.field("required", decode.string)
  use reason <- decode.field("reason", decode.string)
  decode.success(AuthorityDecision(required: required, reason: reason))
}

fn delivery_decoder() {
  use target <- decode.field("target", decode.string)
  use rationale <- decode.field("rationale", decode.string)
  decode.success(DeliveryDecision(target: target, rationale: rationale))
}

fn patch_decoder() {
  use path <- decode.field("path", decode.string)
  use summary <- decode.field("summary", decode.string)
  use diff <- decode.field("diff", decode.string)
  decode.success(ProposedPatch(path: path, summary: summary, diff: diff))
}

fn strip_code_fence(raw_response: String) -> String {
  let trimmed = string.trim(raw_response)
  case string.split(trimmed, "```json") {
    [_, fenced, ..] -> take_before_fence(fenced)
    _ ->
      case string.split(trimmed, "```") {
        [_, fenced, ..] -> take_before_fence(fenced)
        _ -> trimmed
      }
  }
}

fn take_before_fence(text: String) -> String {
  case string.split(text, "```") {
    [first, ..] -> string.trim(first)
    [] -> string.trim(text)
  }
}

fn decision_instructions() -> String {
  "## Output Schema\n"
  <> "Return exactly this JSON shape:\n"
  <> "{\n"
  <> "  \"event_id\": \"event id from Observation\",\n"
  <> "  \"concern_refs\": [\"concerns/example.md\"],\n"
  <> "  \"summary\": \"one concise sentence\",\n"
  <> "  \"citations\": [\"evidence:<atom-id>\", \"policy:attention.md\"],\n"
  <> "  \"attention\": {\n"
  <> "    \"action\": \"record|digest|surface_now|ask_now\",\n"
  <> "    \"rationale\": \"required: why this is the right attention level\",\n"
  <> "    \"why_now\": \"required for surface_now or ask_now, else empty\",\n"
  <> "    \"deferral_cost\": \"required for surface_now or ask_now, else empty\",\n"
  <> "    \"why_not_digest\": \"required for surface_now or ask_now, else empty\"\n"
  <> "  },\n"
  <> "  \"work\": {\n"
  <> "    \"action\": \"none|prepare|delegate|execute\",\n"
  <> "    \"target\": \"optional target or empty\",\n"
  <> "    \"proof_required\": \"what would prove the work is done, or empty\"\n"
  <> "  },\n"
  <> "  \"authority\": {\n"
  <> "    \"required\": \"none|approval|credential|tool|human_judgment\",\n"
  <> "    \"reason\": \"required unless none\"\n"
  <> "  },\n"
  <> "  \"delivery\": {\n"
  <> "    \"target\": \"none|default|domain:<domain-name> from Delivery Targets\",\n"
  <> "    \"rationale\": \"required: why this is the right destination\"\n"
  <> "  },\n"
  <> "  \"gaps\": [\"plain-language gap with resolution path\"],\n"
  <> "  \"proposed_patches\": []\n"
  <> "}\n\n"
  <> "Rules: cite at least one evidence/raw ref and at least one policy ref. "
  <> "Cite user/domain context when it materially affects the decision. "
  <> "If there are no relevant concern files, use an empty concern_refs list. "
  <> "Use delivery.target=none only for record. Use a listed non-none Delivery Target for digest, surface_now, or ask_now. "
  <> "Do not propose patches unless the user preference or policy gap is reusable."
}

fn require(
  errors: List(String),
  condition: Bool,
  message: String,
) -> List(String) {
  case condition {
    True -> errors
    False -> list.append(errors, [message])
  }
}

fn present(value: String) -> Bool {
  string.trim(value) != ""
}

fn has_any(values: List(String), allowed: List(String)) -> Bool {
  list.any(values, fn(value) { list.contains(allowed, value) })
}

fn valid_attention_action(action: String) -> Bool {
  list.contains(["record", "digest", "surface_now", "ask_now"], action)
}

fn valid_work_action(action: String) -> Bool {
  list.contains(["none", "prepare", "delegate", "execute"], action)
}

fn valid_authority(required: String) -> Bool {
  list.contains(
    ["none", "approval", "credential", "tool", "human_judgment"],
    required,
  )
}

fn authority_has_reason(authority: AuthorityDecision) -> Bool {
  case authority.required {
    "none" -> True
    _ -> present(authority.reason)
  }
}

fn delivery_target_allowed(
  target: String,
  context: cognitive_context.ContextPacket,
) -> Bool {
  list.contains(context.delivery_targets, target)
}

fn attention_delivery_is_consistent(
  attention: AttentionDecision,
  delivery: DeliveryDecision,
) -> Bool {
  case attention.action {
    "record" -> delivery.target == "none"
    "digest" | "surface_now" | "ask_now" -> delivery.target != "none"
    _ -> False
  }
}

fn attention_has_surface_proof(attention: AttentionDecision) -> Bool {
  case attention.action {
    "surface_now" | "ask_now" ->
      present(attention.why_now)
      && present(attention.deferral_cost)
      && present(attention.why_not_digest)
    _ -> True
  }
}

fn valid_patch_paths(patches: List(ProposedPatch)) -> Bool {
  list.all(patches, fn(patch) {
    !string.contains(patch.path, "..")
    && !string.starts_with(patch.path, "/")
    && {
      string.starts_with(patch.path, "policies/")
      || string.starts_with(patch.path, "concerns/")
    }
    && string.ends_with(patch.path, ".md")
  })
}

fn valid_patch_bodies(patches: List(ProposedPatch)) -> Bool {
  list.all(patches, fn(patch) { present(patch.summary) && present(patch.diff) })
}

fn attention_to_json(attention: AttentionDecision) -> json.Json {
  json.object([
    #("action", json.string(attention.action)),
    #("rationale", json.string(attention.rationale)),
    #("why_now", json.string(attention.why_now)),
    #("deferral_cost", json.string(attention.deferral_cost)),
    #("why_not_digest", json.string(attention.why_not_digest)),
  ])
}

fn work_to_json(work: WorkDecision) -> json.Json {
  json.object([
    #("action", json.string(work.action)),
    #("target", json.string(work.target)),
    #("proof_required", json.string(work.proof_required)),
  ])
}

fn authority_to_json(authority: AuthorityDecision) -> json.Json {
  json.object([
    #("required", json.string(authority.required)),
    #("reason", json.string(authority.reason)),
  ])
}

fn delivery_to_json(delivery: DeliveryDecision) -> json.Json {
  json.object([
    #("target", json.string(delivery.target)),
    #("rationale", json.string(delivery.rationale)),
  ])
}

fn patch_to_json(patch: ProposedPatch) -> json.Json {
  json.object([
    #("path", json.string(patch.path)),
    #("summary", json.string(patch.summary)),
    #("diff", json.string(patch.diff)),
  ])
}
