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

  list.length(packet.policies) |> should.equal(7)
  simplifile.is_file(xdg.policy_dir(paths) <> "/attention.md")
  |> should.equal(Ok(True))
  simplifile.is_file(xdg.policy_dir(paths) <> "/delivery.md")
  |> should.equal(Ok(True))
  simplifile.is_file(xdg.policy_dir(paths) <> "/concerns.md")
  |> should.equal(Ok(True))

  let rendered = cognitive_context.render(packet)
  rendered |> string.contains("policy:attention.md") |> should.be_true
  rendered |> string.contains("policy:delivery.md") |> should.be_true
  rendered |> string.contains("policy:concerns.md") |> should.be_true
  rendered |> string.contains("evidence:e1") |> should.be_true
  rendered |> string.contains("gmail:msg-1") |> should.be_true
  rendered |> string.contains("Delivery Targets") |> should.be_true

  let _ = simplifile.delete_all([base])
  Nil
}

pub fn build_renders_delivery_timing_for_attention_judgment_test() {
  let #(base, paths) = temp_paths("cognitive-context-delivery-timing")
  let observation = sample_observation()
  let evidence = cognitive_event.extract_evidence(observation)

  let packet =
    cognitive_context.build_with_delivery_targets_and_digest_windows(
      paths,
      observation,
      evidence,
      ["none", "default"],
      ["07:35", "09:10"],
    )
    |> should.be_ok

  let rendered = cognitive_context.render(packet)
  rendered |> string.contains("## Delivery Timing") |> should.be_true
  rendered
  |> string.contains("digest_windows_local: 07:35, 09:10")
  |> should.be_true
  rendered
  |> string.contains("choose digest when the next scheduled digest can reach")
  |> should.be_true
  rendered
  |> string.contains("tomorrow-morning review")
  |> should.be_true

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

pub fn build_loads_user_and_domain_context_as_citable_text_refs_test() {
  let #(base, paths) = temp_paths("cognitive-context-user-domain")
  let _ = simplifile.create_directory_all(paths.config)
  let _ = simplifile.create_directory_all(paths.state)
  let _ = simplifile.create_directory_all(xdg.domain_config_dir(paths, "hy"))
  let _ = simplifile.create_directory_all(xdg.domain_data_dir(paths, "hy"))
  let _ = simplifile.create_directory_all(xdg.domain_state_dir(paths, "hy"))
  let _ = simplifile.write(xdg.user_path(paths), "User prefers concise asks.")
  let _ =
    simplifile.write(xdg.memory_path(paths), "Global memory: deploy safely.")
  let _ =
    simplifile.write(xdg.state_path(paths, "STATE.md"), "Global state: calm.")
  let _ =
    simplifile.write(
      xdg.domain_config_dir(paths, "hy") <> "/AGENTS.md",
      "HY instructions: check Jira before code.",
    )
  let _ =
    simplifile.write(
      xdg.domain_memory_path(paths, "hy"),
      "HY memory: QA moves tickets to DONE.",
    )
  let _ =
    simplifile.write(
      xdg.domain_state_path(paths, "hy"),
      "HY state: wallet allowances active.",
    )

  let observation = sample_observation()
  let evidence = cognitive_event.extract_evidence(observation)

  let packet =
    cognitive_context.build(paths, observation, evidence) |> should.be_ok

  list.length(packet.context_files) |> should.equal(6)
  let refs = cognitive_context.context_citation_refs(packet)
  refs |> list.contains("user:USER.md") |> should.be_true
  refs |> list.contains("memory:global") |> should.be_true
  refs |> list.contains("state:global") |> should.be_true
  refs |> list.contains("domain:hy:instructions") |> should.be_true
  refs |> list.contains("domain:hy:memory") |> should.be_true
  refs |> list.contains("domain:hy:state") |> should.be_true

  let rendered = cognitive_context.render(packet)
  rendered |> string.contains("## User And Domain Context") |> should.be_true
  rendered |> string.contains("User prefers concise asks.") |> should.be_true
  rendered |> string.contains("QA moves tickets to DONE") |> should.be_true

  let _ = simplifile.delete_all([base])
  Nil
}

pub fn learned_notification_preference_is_visible_to_cognitive_context_test() {
  let #(base, paths) = temp_paths("cognitive-context-learned-preference")
  let _ = simplifile.create_directory_all(paths.config)
  let _ =
    simplifile.write(
      xdg.user_path(paths),
      "§ email-suppressions\nSuppress routine delivery-status emails from sender domain example-delivery.test. Record only; do not surface.",
    )

  let observation =
    cognitive_event.Observation(
      ..sample_observation(),
      id: "ev-delivery-pref",
      actors: ["robot@example-delivery.test"],
      tags: dict.from_list([#("from", "robot@example-delivery.test")]),
      text: "Your routine delivery status has changed.",
    )
  let evidence = cognitive_event.extract_evidence(observation)

  let packet =
    cognitive_context.build(paths, observation, evidence) |> should.be_ok
  let rendered = cognitive_context.render(packet)

  cognitive_context.context_citation_refs(packet)
  |> list.contains("user:USER.md")
  |> should.be_true
  rendered
  |> string.contains("§ email-suppressions")
  |> should.be_true
  rendered
  |> string.contains("example-delivery.test")
  |> should.be_true
  rendered
  |> string.contains("Record only; do not surface.")
  |> should.be_true

  let _ = simplifile.delete_all([base])
  Nil
}
