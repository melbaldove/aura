import aura/db
import aura/operating_contracts
import aura/operational_mutation
import aura/test_helpers
import aura/xdg
import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/option
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

fn command(
  key: String,
  intent: String,
  basis: String,
  fields: List(#(String, operating_contracts.StructuredValue)),
) -> operating_contracts.CommandMutation {
  operating_contracts.CommandMutation(
    schema_version: 1,
    command_id: "command-" <> key,
    idempotency_key: key,
    origin: "codex_voice",
    codex_task_ref: option.None,
    codex_conversation_ref: option.None,
    codex_turn_ref: option.None,
    intent_kind: intent,
    structured_payload: dict.from_list(fields),
    creation_basis: basis,
    issued_at: 1000,
  )
}

fn domain_fields(name: String) {
  [
    #("display_name", operating_contracts.StructuredString(name)),
    #(
      "purpose",
      operating_contracts.StructuredString("A durable operating partition."),
    ),
  ]
}

pub fn explicit_domain_upsert_is_transport_free_and_idempotent_test() {
  let assert Ok(subject) = db.start(":memory:")
  let #(base, paths) = temp_paths("mutation-domain-explicit")
  let mutation =
    command(
      "domain-key",
      "domain.upsert",
      "explicit",
      domain_fields("Personal Life"),
    )

  let first =
    operational_mutation.apply(paths, subject, mutation) |> should.be_ok
  let second =
    operational_mutation.apply(paths, subject, mutation) |> should.be_ok

  first |> should.equal(second)
  first.status |> should.equal("applied")
  first.target_id |> should.equal("domain:personal-life")
  let manifest =
    simplifile.read(xdg.domain_manifest_path(paths, "personal-life"))
    |> should.be_ok
  manifest |> string.contains("\"cwd\":null") |> should.be_true
  manifest |> string.contains("discord_channel") |> should.be_false
  db.get_mutation_receipt(subject, "domain-key") |> should.be_ok
  db.list_operational_audit(subject, "domain", "domain:personal-life")
  |> should.be_ok
  |> list.length
  |> should.equal(1)

  process.send(subject, db.Shutdown)
  let _ = simplifile.delete_all([base])
  Nil
}

pub fn inferred_unknown_domain_returns_proposal_without_writes_test() {
  let assert Ok(subject) = db.start(":memory:")
  let #(base, paths) = temp_paths("mutation-domain-inferred")
  let mutation =
    command(
      "inferred-key",
      "domain.upsert",
      "inferred",
      domain_fields("Consulting"),
    )

  let result =
    operational_mutation.apply(paths, subject, mutation) |> should.be_ok

  result.status |> should.equal("confirmation_required")
  result.target_id |> should.equal("domain:consulting")
  simplifile.is_file(xdg.domain_manifest_path(paths, "consulting"))
  |> should.equal(Ok(False))
  db.get_mutation_receipt(subject, "inferred-key")
  |> should.equal(Ok(option.None))
  db.list_operational_audit(subject, "domain", "domain:consulting")
  |> should.equal(Ok([]))

  process.send(subject, db.Shutdown)
  let _ = simplifile.delete_all([base])
  Nil
}

pub fn confirmed_domain_proposal_creates_exactly_one_domain_test() {
  let assert Ok(subject) = db.start(":memory:")
  let #(base, paths) = temp_paths("mutation-domain-confirmed")
  let inferred =
    command(
      "proposal-key",
      "domain.upsert",
      "inferred",
      domain_fields("Consulting"),
    )
  let confirmed =
    command(
      "confirmed-key",
      "domain.upsert",
      "confirmed",
      domain_fields("Consulting"),
    )

  operational_mutation.apply(paths, subject, inferred) |> should.be_ok
  operational_mutation.apply(paths, subject, confirmed) |> should.be_ok
  operational_mutation.apply(paths, subject, confirmed) |> should.be_ok

  simplifile.read_directory(xdg.domain_data_dir(paths, "consulting"))
  |> should.be_ok
  |> list.filter(fn(name) { name == "domain.json" })
  |> list.length
  |> should.equal(1)

  process.send(subject, db.Shutdown)
  let _ = simplifile.delete_all([base])
  Nil
}

pub fn reused_key_with_changed_domain_payload_conflicts_before_write_test() {
  let assert Ok(subject) = db.start(":memory:")
  let #(base, paths) = temp_paths("mutation-domain-conflict")
  let first =
    command(
      "same-key",
      "domain.upsert",
      "explicit",
      domain_fields("Personal OS"),
    )
  let changed =
    command(
      "same-key",
      "domain.upsert",
      "explicit",
      domain_fields("Personal Life"),
    )

  operational_mutation.apply(paths, subject, first) |> should.be_ok
  operational_mutation.apply(paths, subject, changed)
  |> should.equal(Error("idempotency_conflict"))
  simplifile.is_file(xdg.domain_manifest_path(paths, "personal-life"))
  |> should.equal(Ok(False))

  process.send(subject, db.Shutdown)
  let _ = simplifile.delete_all([base])
  Nil
}

pub fn mutation_claim_blocks_changed_payload_before_file_effect_test() {
  let assert Ok(subject) = db.start(":memory:")
  db.claim_operational_mutation(
    subject,
    "claim-key",
    "domain.upsert",
    "one",
    1000,
  )
  |> should.equal(Ok(option.None))
  db.claim_operational_mutation(
    subject,
    "claim-key",
    "domain.upsert",
    "two",
    1001,
  )
  |> should.equal(Error("idempotency_conflict"))
  let pending =
    db.claim_operational_mutation(
      subject,
      "claim-key",
      "domain.upsert",
      "one",
      1001,
    )
    |> should.be_ok
    |> should.be_some
  pending.result_version |> should.equal(0)
  process.send(subject, db.Shutdown)
  Nil
}

pub fn migration_claim_blocks_changed_target_before_copy_test() {
  let assert Ok(subject) = db.start(":memory:")
  db.claim_operational_mutation(
    subject,
    "migration-key",
    "concern.migrate_legacy",
    "target-one",
    1000,
  )
  |> should.equal(Ok(option.None))
  db.claim_operational_mutation(
    subject,
    "migration-key",
    "concern.migrate_legacy",
    "target-two",
    1001,
  )
  |> should.equal(Error("idempotency_conflict"))
  process.send(subject, db.Shutdown)
  Nil
}

pub fn domain_upsert_rejects_corrupt_manifest_and_stable_id_change_test() {
  let assert Ok(subject) = db.start(":memory:")
  let #(base, paths) = temp_paths("mutation-domain-stability")
  operational_mutation.apply(
    paths,
    subject,
    command(
      "stable-one",
      "domain.upsert",
      "explicit",
      domain_fields("Personal OS"),
    ),
  )
  |> should.be_ok
  let changed_id =
    command(
      "stable-two",
      "domain.upsert",
      "explicit",
      list.append(domain_fields("Personal OS"), [
        #(
          "domain_id",
          operating_contracts.StructuredString("domain:replacement"),
        ),
      ]),
    )
  operational_mutation.apply(paths, subject, changed_id)
  |> should.equal(Error("domain_id_conflict: domain:personal-os"))

  let corrupt_path = xdg.domain_manifest_path(paths, "corrupt")
  let _ = simplifile.create_directory_all(xdg.domain_data_dir(paths, "corrupt"))
  let _ = simplifile.write(corrupt_path, "not-json")
  operational_mutation.apply(
    paths,
    subject,
    command(
      "corrupt-key",
      "domain.upsert",
      "explicit",
      domain_fields("Corrupt"),
    ),
  )
  |> should.be_error
  simplifile.read(corrupt_path) |> should.equal(Ok("not-json"))

  process.send(subject, db.Shutdown)
  let _ = simplifile.delete_all([base])
  Nil
}

fn concern_fields(domain_id: String, slug: String) {
  [
    #("domain_id", operating_contracts.StructuredString(domain_id)),
    #("slug", operating_contracts.StructuredString(slug)),
    #("title", operating_contracts.StructuredString("Weekly accounts review")),
    #(
      "summary",
      operating_contracts.StructuredString("Review the weekly accounts."),
    ),
  ]
}

pub fn concern_mutations_stay_under_selected_domain_test() {
  let assert Ok(subject) = db.start(":memory:")
  let #(base, paths) = temp_paths("mutation-concern")
  let domain =
    command(
      "domain-accounting",
      "domain.upsert",
      "explicit",
      domain_fields("Congregation Accounting"),
    )
  operational_mutation.apply(paths, subject, domain) |> should.be_ok
  let upsert =
    command(
      "concern-upsert",
      "concern.upsert",
      "explicit",
      concern_fields("domain:congregation-accounting", "weekly-review"),
    )
  let pause =
    command(
      "concern-pause",
      "concern.pause",
      "explicit",
      concern_fields("domain:congregation-accounting", "weekly-review"),
    )
  let close =
    command(
      "concern-close",
      "concern.close",
      "explicit",
      concern_fields("domain:congregation-accounting", "weekly-review"),
    )

  operational_mutation.apply(paths, subject, upsert) |> should.be_ok
  operational_mutation.apply(paths, subject, upsert) |> should.be_ok
  operational_mutation.apply(paths, subject, pause) |> should.be_ok
  operational_mutation.apply(paths, subject, pause) |> should.be_ok
  operational_mutation.apply(paths, subject, close) |> should.be_ok
  operational_mutation.apply(paths, subject, close) |> should.be_ok

  let path =
    xdg.domain_concerns_dir(paths, "congregation-accounting")
    <> "/weekly-review.md"
  let content = simplifile.read(path) |> should.be_ok
  content
  |> string.contains("Domain-ID: domain:congregation-accounting")
  |> should.be_true
  content
  |> string.contains(
    "Concern-ID: concern:domain:congregation-accounting:weekly-review",
  )
  |> should.be_true
  content |> string.contains("Status: closed") |> should.be_true
  simplifile.is_file(xdg.concerns_dir(paths) <> "/weekly-review.md")
  |> should.equal(Ok(False))

  process.send(subject, db.Shutdown)
  let _ = simplifile.delete_all([base])
  Nil
}

pub fn status_only_concern_mutation_preserves_existing_content_test() {
  let assert Ok(subject) = db.start(":memory:")
  let #(base, paths) = temp_paths("mutation-concern-preserve")
  operational_mutation.apply(
    paths,
    subject,
    command(
      "preserve-domain",
      "domain.upsert",
      "explicit",
      domain_fields("Personal Life"),
    ),
  )
  |> should.be_ok
  operational_mutation.apply(
    paths,
    subject,
    command(
      "preserve-upsert",
      "concern.upsert",
      "explicit",
      concern_fields("domain:personal-life", "household"),
    ),
  )
  |> should.be_ok
  let path = xdg.domain_concerns_dir(paths, "personal-life") <> "/household.md"
  let original = simplifile.read(path) |> should.be_ok
  let _ = simplifile.write(path, original <> "\n## Notes\nKeep this detail.\n")
  operational_mutation.apply(
    paths,
    subject,
    command("preserve-pause", "concern.pause", "explicit", [
      #(
        "domain_id",
        operating_contracts.StructuredString("domain:personal-life"),
      ),
      #("slug", operating_contracts.StructuredString("household")),
    ]),
  )
  |> should.be_ok
  let updated = simplifile.read(path) |> should.be_ok
  updated |> string.contains("Weekly accounts review") |> should.be_true
  updated |> string.contains("Review the weekly accounts.") |> should.be_true
  updated |> string.contains("Keep this detail.") |> should.be_true
  updated |> string.contains("Status: paused") |> should.be_true

  process.send(subject, db.Shutdown)
  let _ = simplifile.delete_all([base])
  Nil
}

pub fn concern_rejects_unknown_domain_link_test() {
  let assert Ok(subject) = db.start(":memory:")
  let #(base, paths) = temp_paths("mutation-concern-domain-check")
  let mutation =
    command(
      "orphan-concern",
      "concern.upsert",
      "explicit",
      concern_fields("domain:missing", "orphan"),
    )

  operational_mutation.apply(paths, subject, mutation)
  |> should.equal(Error("unknown_domain: domain:missing"))
  simplifile.is_file(xdg.domain_concerns_dir(paths, "missing") <> "/orphan.md")
  |> should.equal(Ok(False))

  process.send(subject, db.Shutdown)
  let _ = simplifile.delete_all([base])
  Nil
}

pub fn direct_mutation_rejects_raw_transcript_fields_before_write_test() {
  let assert Ok(subject) = db.start(":memory:")
  let #(base, paths) = temp_paths("mutation-transcript-rejection")
  let fields =
    list.append(domain_fields("Personal Life"), [
      #(
        "raw_voice_text",
        operating_contracts.StructuredString("copied user speech"),
      ),
    ])
  let mutation = command("transcript-key", "domain.upsert", "explicit", fields)

  operational_mutation.apply(paths, subject, mutation) |> should.be_error
  simplifile.is_file(xdg.domain_manifest_path(paths, "personal-life"))
  |> should.equal(Ok(False))
  db.get_mutation_receipt(subject, "transcript-key")
  |> should.equal(Ok(option.None))

  process.send(subject, db.Shutdown)
  let _ = simplifile.delete_all([base])
  Nil
}
