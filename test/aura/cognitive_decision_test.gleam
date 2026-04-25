import aura/cognitive_context
import aura/cognitive_decision
import aura/cognitive_event
import aura/test_helpers
import aura/xdg
import gleam/dict
import gleam/list
import gleam/string
import gleeunit
import gleeunit/should
import simplifile

pub fn main() {
  gleeunit.main()
}

fn temp_context() -> #(String, cognitive_context.ContextPacket, String) {
  let base = "/tmp/aura-cognitive-decision-" <> test_helpers.random_suffix()
  let _ = simplifile.delete_all([base])
  let paths = xdg.resolve_with_home(base)
  let observation =
    cognitive_event.Observation(
      id: "ev-decision-1",
      source: "gmail",
      resource_id: "msg-1",
      resource_type: "email",
      event_type: "email.received",
      event_time_ms: 1000,
      actors: ["alice@example.com"],
      tags: dict.from_list([#("from", "alice@example.com")]),
      text: "Please review REL-42 tomorrow",
      state_before: "",
      state_after: "",
      raw_ref: "gmail:msg-1",
      raw_data: "{\"from\":\"alice@example.com\",\"thread_id\":\"t-1\"}",
    )
  let evidence = cognitive_event.extract_evidence(observation)
  let assert [first_atom, ..] = evidence.atoms
  let packet =
    cognitive_context.build(paths, observation, evidence) |> should.be_ok
  #(base, packet, first_atom.id)
}

fn valid_json(
  event_id: String,
  atom_id: String,
  attention_action: String,
) -> String {
  "{"
  <> "\"event_id\":\""
  <> event_id
  <> "\","
  <> "\"concern_refs\":[],"
  <> "\"summary\":\"Record the email for later review.\","
  <> "\"citations\":[\"evidence:"
  <> atom_id
  <> "\",\"policy:attention.md\"],"
  <> "\"attention\":{\"action\":\""
  <> attention_action
  <> "\",\"rationale\":\"No immediate user attention is needed; preserve this for later review.\",\"why_now\":\"\",\"deferral_cost\":\"\",\"why_not_digest\":\"\"},"
  <> "\"work\":{\"action\":\"none\",\"target\":\"\",\"proof_required\":\"\"},"
  <> "\"authority\":{\"required\":\"none\",\"reason\":\"\"},"
  <> "\"gaps\":[],"
  <> "\"proposed_patches\":[]"
  <> "}"
}

pub fn decode_response_accepts_fenced_json_test() {
  let #(base, _packet, atom_id) = temp_context()
  let raw =
    "```json\n" <> valid_json("ev-decision-1", atom_id, "record") <> "\n```"

  let decision = cognitive_decision.decode_response(raw) |> should.be_ok

  decision.event_id |> should.equal("ev-decision-1")
  decision.attention.action |> should.equal("record")

  let _ = simplifile.delete_all([base])
  Nil
}

pub fn validate_requires_evidence_and_policy_citations_test() {
  let #(base, packet, atom_id) = temp_context()
  let decision =
    cognitive_decision.decode_response(valid_json(
      "ev-decision-1",
      atom_id,
      "record",
    ))
    |> should.be_ok

  cognitive_decision.validate(decision, packet) |> should.be_ok

  let missing_policy =
    cognitive_decision.DecisionEnvelope(..decision, citations: [
      "evidence:" <> atom_id,
    ])
  let assert Error(errors) = cognitive_decision.validate(missing_policy, packet)
  list.any(errors, fn(e) { string.contains(e, "policy citation") })
  |> should.be_true

  let _ = simplifile.delete_all([base])
  Nil
}

pub fn validate_requires_attention_rationale_for_record_test() {
  let #(base, packet, atom_id) = temp_context()
  let decision =
    cognitive_decision.decode_response(valid_json(
      "ev-decision-1",
      atom_id,
      "record",
    ))
    |> should.be_ok
  let missing_rationale =
    cognitive_decision.DecisionEnvelope(
      ..decision,
      attention: cognitive_decision.AttentionDecision(
        ..decision.attention,
        rationale: "",
      ),
    )

  let assert Error(errors) =
    cognitive_decision.validate(missing_rationale, packet)

  list.any(errors, fn(e) { string.contains(e, "attention.rationale") })
  |> should.be_true

  let _ = simplifile.delete_all([base])
  Nil
}

pub fn validate_rejects_interrupt_without_attention_proof_test() {
  let #(base, packet, atom_id) = temp_context()
  let decision =
    cognitive_decision.decode_response(valid_json(
      "ev-decision-1",
      atom_id,
      "surface_now",
    ))
    |> should.be_ok

  let assert Error(errors) = cognitive_decision.validate(decision, packet)

  list.any(errors, fn(e) { string.contains(e, "surface_now") })
  |> should.be_true

  let _ = simplifile.delete_all([base])
  Nil
}

pub fn build_messages_demands_json_only_and_known_refs_test() {
  let #(base, packet, atom_id) = temp_context()

  let messages = cognitive_decision.build_messages(packet)
  let rendered = string.inspect(messages)

  rendered |> string.contains("Return only one JSON object") |> should.be_true
  rendered |> string.contains("evidence:" <> atom_id) |> should.be_true
  rendered |> string.contains("policy:attention.md") |> should.be_true

  let _ = simplifile.delete_all([base])
  Nil
}
