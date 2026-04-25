import aura/cognitive_context
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

fn temp_paths(label: String) -> #(String, xdg.Paths) {
  let base = "/tmp/aura-" <> label <> "-" <> test_helpers.random_suffix()
  let _ = simplifile.delete_all([base])
  #(base, xdg.resolve_with_home(base))
}

fn sample_observation() -> cognitive_event.Observation {
  cognitive_event.Observation(
    id: "ev-ctx-1",
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
}

pub fn build_creates_and_loads_default_policies_test() {
  let #(base, paths) = temp_paths("cognitive-context-policies")
  let observation = sample_observation()
  let evidence = cognitive_event.extract_evidence(observation)

  let packet =
    cognitive_context.build(paths, observation, evidence) |> should.be_ok

  list.length(packet.policies) |> should.equal(5)
  simplifile.is_file(xdg.policy_dir(paths) <> "/attention.md")
  |> should.equal(Ok(True))

  let rendered = cognitive_context.render(packet)
  rendered |> string.contains("policy:attention.md") |> should.be_true
  rendered |> string.contains("evidence:e1") |> should.be_true
  rendered |> string.contains("gmail:msg-1") |> should.be_true

  let _ = simplifile.delete_all([base])
  Nil
}

pub fn build_loads_markdown_concerns_as_text_refs_test() {
  let #(base, paths) = temp_paths("cognitive-context-concerns")
  let _ = simplifile.create_directory_all(xdg.concerns_dir(paths))
  let _ =
    simplifile.write(
      xdg.concerns_dir(paths) <> "/rel-42.md",
      "# REL-42\n\nRelease concern.",
    )
  let observation = sample_observation()
  let evidence = cognitive_event.extract_evidence(observation)

  let packet =
    cognitive_context.build(paths, observation, evidence) |> should.be_ok

  list.length(packet.concerns) |> should.equal(1)
  let refs = cognitive_context.concern_citation_refs(packet)
  refs |> should.equal(["concerns/rel-42.md"])
  cognitive_context.render(packet)
  |> string.contains("Release concern")
  |> should.be_true

  let _ = simplifile.delete_all([base])
  Nil
}
