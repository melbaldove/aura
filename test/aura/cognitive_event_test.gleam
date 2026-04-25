import aura/cognitive_event
import aura/event
import gleam/dict
import gleam/list
import gleam/string
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

fn sample_event(
  source: String,
  type_: String,
  subject: String,
  data: String,
  tags: dict.Dict(String, String),
) -> event.AuraEvent {
  event.AuraEvent(
    id: "ev-1",
    source: source,
    type_: type_,
    subject: subject,
    time_ms: 1000,
    tags: tags,
    external_id: "ext-1",
    data: data,
  )
}

pub fn from_event_projects_source_neutral_observation_test() {
  let e =
    sample_event(
      "gmail",
      "email.received",
      "Release REL-42 tomorrow",
      "{\"from\":\"alice@example.com\",\"thread_id\":\"t-1\"}",
      dict.from_list([#("from", "alice@example.com")]),
    )

  let observation = cognitive_event.from_event(e)

  observation.id |> should.equal("ev-1")
  observation.source |> should.equal("gmail")
  observation.resource_id |> should.equal("ext-1")
  observation.resource_type |> should.equal("email")
  observation.event_type |> should.equal("email.received")
  observation.actors |> should.equal(["alice@example.com"])
  observation.raw_ref |> should.equal("gmail:ext-1")
}

pub fn extract_evidence_finds_gmail_atoms_test() {
  let subject = "Please review REL-42 tomorrow https://example.com/doc"
  let message_id =
    "<CANUMZe+V0GsAKM6pY0D_=eSoEejhJ+=x0o6NYfrvZLYkSBEHgQ@mail.gmail.com>"

  let e =
    sample_event(
      "gmail",
      "email.received",
      subject,
      "{\"from\":\"alice@example.com\",\"to\":\"bob@example.com\","
        <> "\"message_id\":\""
        <> message_id
        <> "\","
        <> "\"thread_id\":\"t-1\",\"date\":\"2026-04-24\"}",
      dict.from_list([
        #("from", "alice@example.com"),
        #("to", "bob@example.com"),
        #("thread_id", "t-1"),
        #("subject_line", subject),
      ]),
    )

  let bundle =
    e |> cognitive_event.from_event |> cognitive_event.extract_evidence

  has_atom(bundle, "actor_email", "alice@example.com") |> should.be_true
  has_atom(bundle, "actor_email", "bob@example.com") |> should.be_true
  has_atom(bundle, "actor_email", "x0o6NYfrvZLYkSBEHgQ@mail.gmail.com")
  |> should.be_false
  has_atom(bundle, "thread_id", "t-1") |> should.be_true
  has_atom(bundle, "message_id", message_id) |> should.be_true
  has_atom(bundle, "resource_id", "REL-42") |> should.be_true
  has_atom(bundle, "datetime", "tomorrow") |> should.be_true
  has_atom(bundle, "datetime", "2026-04-24") |> should.be_true
  has_atom(bundle, "url", "https://example.com/doc") |> should.be_true
  let assert [first_atom, ..] = bundle.atoms
  first_atom.id |> should.equal("e1")
  first_atom.id |> string.contains("ev-1") |> should.be_false
  count_atoms(bundle, "actor_email", "alice@example.com") |> should.equal(1)
  count_atoms(bundle, "actor_email", "bob@example.com") |> should.equal(1)
  count_atoms(bundle, "thread_id", "t-1") |> should.equal(1)
  count_atoms(bundle, "text", subject) |> should.equal(1)
  { list.length(bundle.resource_refs) >= 3 } |> should.be_true
}

pub fn from_event_includes_gmail_body_text_in_observation_test() {
  let e =
    sample_event(
      "gmail",
      "email.received",
      "Cognitive",
      "{\"from\":\"alice@example.com\",\"body_text\":\"AURA cognitive smoke test: Please review REL-42 tomorrow\"}",
      dict.from_list([#("from", "alice@example.com")]),
    )

  let observation = cognitive_event.from_event(e)

  observation.text |> string.contains("Subject: Cognitive") |> should.be_true
  observation.text
  |> string.contains("AURA cognitive smoke test: Please review REL-42 tomorrow")
  |> should.be_true
}

pub fn extract_evidence_uses_gmail_body_text_for_text_atoms_test() {
  let e =
    sample_event(
      "gmail",
      "email.received",
      "Cognitive",
      "{\"body_text\":\"AURA cognitive smoke test: Please review REL-42 tomorrow\"}",
      dict.new(),
    )

  let bundle =
    e |> cognitive_event.from_event |> cognitive_event.extract_evidence

  has_atom(bundle, "resource_id", "REL-42") |> should.be_true
  has_atom(bundle, "datetime", "tomorrow") |> should.be_true
}

pub fn extract_evidence_handles_ticket_calendar_ci_and_world_shapes_test() {
  let events = [
    sample_event(
      "linear",
      "issue.updated",
      "ENG-99 is blocked",
      "{\"issue\":{\"identifier\":\"ENG-99\","
        <> "\"state\":{\"name\":\"Blocked\"},"
        <> "\"assignee\":{\"email\":\"dev@example.com\"}}}",
      dict.new(),
    ),
    sample_event(
      "calendar",
      "event.updated",
      "Meeting moved earlier",
      "{\"start\":\"2026-04-24T09:00:00Z\",\"end\":\"2026-04-24T09:30:00Z\"}",
      dict.new(),
    ),
    sample_event(
      "github",
      "check_run.completed",
      "CI failed on release/x",
      "{\"conclusion\":\"failure\",\"sha\":\"abc123def\",\"branch\":\"release/x\"}",
      dict.new(),
    ),
    sample_event(
      "world-search",
      "company.launch",
      "Local-first agent startup launches",
      "{\"url\":\"https://example.com/launch\",\"status\":\"launched\"}",
      dict.new(),
    ),
  ]

  let bundles =
    events
    |> list.map(fn(e) {
      e |> cognitive_event.from_event |> cognitive_event.extract_evidence
    })

  let all_atoms = bundles |> list.flat_map(fn(b) { b.atoms })

  has_atom_list(all_atoms, "resource_id", "ENG-99") |> should.be_true
  has_atom_list(all_atoms, "status", "Blocked") |> should.be_true
  has_atom_list(all_atoms, "datetime", "2026-04-24T09:00:00Z")
  |> should.be_true
  has_atom_list(all_atoms, "commit_sha", "abc123def") |> should.be_true
  has_atom_list(all_atoms, "branch", "release/x") |> should.be_true
  has_atom_list(all_atoms, "url", "https://example.com/launch")
  |> should.be_true
}

fn has_atom(
  bundle: cognitive_event.EvidenceBundle,
  kind: String,
  value: String,
) -> Bool {
  has_atom_list(bundle.atoms, kind, value)
}

fn has_atom_list(
  atoms: List(cognitive_event.EvidenceAtom),
  kind: String,
  value: String,
) -> Bool {
  list.any(atoms, fn(atom) { atom.kind == kind && atom.value == value })
}

fn count_atoms(
  bundle: cognitive_event.EvidenceBundle,
  kind: String,
  value: String,
) -> Int {
  bundle.atoms
  |> list.filter(fn(atom) { atom.kind == kind && atom.value == value })
  |> list.length
}
