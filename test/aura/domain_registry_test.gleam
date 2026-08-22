import aura/domain_registry
import aura/test_helpers
import aura/xdg
import gleam/list
import gleam/option.{None, Some}
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

pub fn stable_ids_and_aliases_are_source_neutral_test() {
  domain_registry.derive_domain_id("Congregation Accounting")
  |> should.equal("domain:congregation-accounting")
  domain_registry.normalize_aliases([
    " Personal OS ",
    "personal-os",
    "Personal OS",
  ])
  |> should.equal(["personal-os"])
}

pub fn transport_independent_manifest_round_trips_test() {
  let #(base, paths) = temp_paths("domain-manifest")
  let record =
    domain_registry.Record(
      domain_id: "domain:consulting",
      slug: "consulting",
      display_name: "Consulting",
      aliases: ["advisory"],
      purpose: "Develop and deliver bounded consulting offers.",
      status: "active",
      cwd: None,
      discord_channel: None,
      version: 1,
      created_at: 1000,
      updated_at: 1000,
    )

  domain_registry.write(paths, record) |> should.be_ok
  let loaded = domain_registry.load(paths, "consulting") |> should.be_ok

  loaded.record |> should.equal(record)
  loaded.origin |> should.equal("manifest")
  simplifile.is_file(xdg.domain_manifest_path(paths, "consulting"))
  |> should.equal(Ok(True))

  let _ = simplifile.delete_all([base])
  Nil
}

pub fn legacy_config_load_derives_id_without_writing_manifest_test() {
  let #(base, paths) = temp_paths("domain-legacy-adapter")
  let dir = xdg.domain_config_dir(paths, "delivery")
  let _ = simplifile.create_directory_all(dir)
  let _ =
    simplifile.write(
      dir <> "/config.toml",
      "name = \"HY Delivery\"\ndescription = \"Delivery operations.\"\ncwd = \"/tmp/hy\"\ntools = [\"jira\"]\n[discord]\nchannel = \"hy\"\n",
    )

  let loaded = domain_registry.load(paths, "delivery") |> should.be_ok

  loaded.record.domain_id |> should.equal("domain:hy-delivery")
  loaded.record.cwd |> should.equal(Some("/tmp/hy"))
  loaded.record.discord_channel |> should.equal(Some("hy"))
  loaded.origin |> should.equal("legacy_config")
  simplifile.is_file(xdg.domain_manifest_path(paths, "delivery"))
  |> should.equal(Ok(False))

  let _ = simplifile.delete_all([base])
  Nil
}

pub fn explicit_legacy_migration_is_idempotent_test() {
  let #(base, paths) = temp_paths("domain-explicit-migrate")
  let dir = xdg.domain_config_dir(paths, "personal-os")
  let _ = simplifile.create_directory_all(dir)
  let _ =
    simplifile.write(
      dir <> "/config.toml",
      "name = \"Personal OS\"\ndescription = \"Personal operating system.\"\ncwd = \".\"\ntools = []\n[discord]\nchannel = \"aura\"\n",
    )

  let first =
    domain_registry.migrate_legacy(paths, "personal-os", 1000)
    |> should.be_ok
  let second =
    domain_registry.migrate_legacy(paths, "personal-os", 2000)
    |> should.be_ok

  first |> should.equal(second)
  let files =
    simplifile.read_directory(xdg.domain_data_dir(paths, "personal-os"))
    |> should.be_ok
  files
  |> list.filter(fn(name) { name == "domain.json" })
  |> list.length
  |> should.equal(1)

  let _ = simplifile.delete_all([base])
  Nil
}
