import aura/google_oauth_client
import aura/secret
import aura/test_helpers
import aura/xdg
import gleam/string
import gleeunit
import gleeunit/should
import simplifile

pub fn main() {
  gleeunit.main()
}

const client_secret_sentinel = "client-secret-must-not-escape"

pub fn installed_clients_are_private_and_connector_bound_test() {
  let root = "/tmp/aura-google-client-" <> test_helpers.random_suffix()
  let paths = xdg.resolve_with_home(root)
  let source = root <> "/gmail-client.json"
  write_private(source, installed_json("gmail-client", client_secret_sentinel))
  let digest = google_oauth_client.sha256_file(source) |> should.be_ok
  let assert Ok(receipt) =
    google_oauth_client.install(paths, "gmail", source, digest)

  receipt.connector_id |> should.equal("gmail")
  receipt.client_ref
  |> string.starts_with("oauth-client:gmail:sha256:")
  |> should.be_true
  let assert Ok(stored) =
    google_oauth_client.load(paths, "gmail", receipt.client_ref)
  stored.client_id |> should.equal("gmail-client.apps.googleusercontent.com")
  stored.client_secret |> should.equal(client_secret_sentinel)
  google_oauth_client.load(paths, "calendar", receipt.client_ref)
  |> should.equal(Error("google_oauth_client_connector_mismatch"))
  let output = google_oauth_client.encode_install_receipt(receipt)
  string.contains(output, client_secret_sentinel) |> should.be_false

  let info =
    simplifile.file_info(google_oauth_client.client_path(
      paths,
      receipt.client_ref,
    ))
    |> should.be_ok
  simplifile.file_info_permissions_octal(info) |> should.equal(0o600)
  let parent =
    simplifile.file_info(xdg.google_oauth_clients_dir(paths))
    |> should.be_ok
  simplifile.file_info_permissions_octal(parent) |> should.equal(0o700)
  let _ = simplifile.delete_all([root])
}

pub fn source_shape_hash_permissions_and_collision_fail_closed_test() {
  let root = "/tmp/aura-google-client-bad-" <> test_helpers.random_suffix()
  let paths = xdg.resolve_with_home(root)
  let source = root <> "/client.json"
  write_private(source, "{\"web\":{\"client_id\":\"bad\"}}")
  let web_hash = google_oauth_client.sha256_file(source) |> should.be_ok
  google_oauth_client.install(paths, "gmail", source, web_hash)
  |> should.equal(Error("google_oauth_client_invalid"))

  write_private(source, installed_json("gmail-client", client_secret_sentinel))
  let digest = google_oauth_client.sha256_file(source) |> should.be_ok
  google_oauth_client.install(paths, "gmail", source, string.repeat("0", 64))
  |> should.equal(Error("google_oauth_client_source_hash_mismatch"))
  let assert Ok(_) = simplifile.set_permissions_octal(source, 0o644)
  google_oauth_client.install(paths, "gmail", source, digest)
  |> should.equal(Error("secret_permissions_invalid"))
  let assert Ok(_) = simplifile.set_permissions_octal(source, 0o600)
  google_oauth_client.install(paths, "gmail", source, digest)
  |> should.be_ok
  google_oauth_client.install(paths, "gmail", source, digest)
  |> should.equal(Error("google_oauth_client_already_exists"))
  let _ = simplifile.delete_all([root])
}

pub fn installed_client_rejects_endpoint_override_and_invalid_secret_test() {
  let root = "/tmp/aura-google-client-fields-" <> test_helpers.random_suffix()
  let paths = xdg.resolve_with_home(root)
  let source = root <> "/client.json"
  write_private(
    source,
    "{\"installed\":{\"client_id\":\"x.apps.googleusercontent.com\",\"client_secret\":\"\",\"token_uri\":\"https://attacker.invalid/token\"}}",
  )
  let digest = google_oauth_client.sha256_file(source) |> should.be_ok
  google_oauth_client.install(paths, "gmail", source, digest)
  |> should.equal(Error("google_oauth_client_invalid"))
  write_private(
    source,
    "{\"installed\":{\"client_id\":\"x.apps.googleusercontent.com\",\"client_secret\":\"contains a space\"}}",
  )
  let invalid_secret_hash =
    google_oauth_client.sha256_file(source) |> should.be_ok
  google_oauth_client.install(paths, "gmail", source, invalid_secret_hash)
  |> should.equal(Error("google_oauth_client_invalid"))
  write_private(source, "{\"installed\":{\"client_secret\":\"valid-shape\"}}")
  let missing_id_hash = google_oauth_client.sha256_file(source) |> should.be_ok
  google_oauth_client.install(paths, "gmail", source, missing_id_hash)
  |> should.equal(Error("google_oauth_client_invalid"))
  let _ = simplifile.delete_all([root])
}

pub fn symlink_source_is_rejected_test() {
  let root = "/tmp/aura-google-client-link-" <> test_helpers.random_suffix()
  let paths = xdg.resolve_with_home(root)
  let source = root <> "/client.json"
  let link = root <> "/client-link.json"
  write_private(source, installed_json("gmail-client", client_secret_sentinel))
  let assert Ok(_) = simplifile.create_symlink(source, link)
  google_oauth_client.sha256_file(link)
  |> should.equal(Error("secret_symlink_rejected"))
  google_oauth_client.install(paths, "gmail", link, string.repeat("0", 64))
  |> should.equal(Error("secret_symlink_rejected"))
  let _ = simplifile.delete_all([root])
}

pub fn install_command_preserves_spaces_and_rejects_unsafe_paths_test() {
  let digest = string.repeat("a", 64)
  let encoded =
    google_oauth_client.encode_install_command(
      "gmail",
      "/tmp/client file.json",
      digest,
    )
  let decoded =
    google_oauth_client.decode_install_command(encoded) |> should.be_ok
  decoded.source_path |> should.equal("/tmp/client file.json")
  google_oauth_client.decode_install_command(
    google_oauth_client.encode_install_command(
      "gmail",
      "/tmp/client.json\nnotify {}",
      digest,
    ),
  )
  |> should.equal(Error("invalid_google_oauth_client_command"))
  google_oauth_client.decode_install_command(
    google_oauth_client.encode_install_command(
      "gmail",
      "/tmp/client\tfile.json",
      digest,
    ),
  )
  |> should.equal(Error("invalid_google_oauth_client_command"))
  google_oauth_client.decode_install_command(
    google_oauth_client.encode_install_command(
      "gmail",
      "/tmp/client\u{1b}file.json",
      digest,
    ),
  )
  |> should.equal(Error("invalid_google_oauth_client_command"))
  google_oauth_client.decode_install_command(
    google_oauth_client.encode_install_command("gmail", "client.json", digest),
  )
  |> should.equal(Error("invalid_google_oauth_client_command"))
}

pub fn client_set_is_immutable_distinct_and_secret_free_test() {
  let root = "/tmp/aura-google-client-set-" <> test_helpers.random_suffix()
  let paths = xdg.resolve_with_home(root)
  let gmail = install_fixture(paths, root, "gmail", "gmail-client")
  let calendar = install_fixture(paths, root, "calendar", "calendar-client")
  let assert Ok(set) =
    google_oauth_client.create_client_set(
      paths,
      gmail.client_ref,
      calendar.client_ref,
    )
  set.client_set_ref
  |> string.starts_with("oauth-client-set:sha256:")
  |> should.be_true
  let output = google_oauth_client.encode_client_set_receipt(set)
  string.contains(output, client_secret_sentinel) |> should.be_false
  let assert Ok(loaded) =
    google_oauth_client.load_client_set(paths, set.client_set_ref)
  loaded |> should.equal(set)
  google_oauth_client.create_client_set(
    paths,
    gmail.client_ref,
    gmail.client_ref,
  )
  |> should.equal(Error("google_oauth_client_set_requires_distinct_clients"))
  google_oauth_client.create_client_set(
    paths,
    gmail.client_ref,
    calendar.client_ref,
  )
  |> should.equal(Error("google_oauth_client_set_already_exists"))
  let _ = simplifile.delete_all([root])
}

pub fn client_set_rejects_one_provider_client_installed_twice_test() {
  let root = "/tmp/aura-google-client-set-same-" <> test_helpers.random_suffix()
  let paths = xdg.resolve_with_home(root)
  let gmail = install_fixture(paths, root, "gmail", "shared-client")
  let calendar = install_fixture(paths, root, "calendar", "shared-client")
  google_oauth_client.create_client_set(
    paths,
    gmail.client_ref,
    calendar.client_ref,
  )
  |> should.equal(Error("google_oauth_client_set_requires_distinct_clients"))
  let _ = simplifile.delete_all([root])
}

fn install_fixture(paths, root: String, connector: String, name: String) {
  let source = root <> "/" <> connector <> ".json"
  write_private(source, installed_json(name, client_secret_sentinel))
  let digest = google_oauth_client.sha256_file(source) |> should.be_ok
  google_oauth_client.install(paths, connector, source, digest) |> should.be_ok
}

fn write_private(path: String, contents: String) {
  secret.atomic_write(path, contents) |> should.be_ok
}

fn installed_json(name: String, client_secret: String) -> String {
  "{\"installed\":{\"client_id\":\""
  <> name
  <> ".apps.googleusercontent.com\",\"project_id\":\"synthetic-project\",\"auth_uri\":\"https://accounts.google.com/o/oauth2/auth\",\"token_uri\":\"https://oauth2.googleapis.com/token\",\"auth_provider_x509_cert_url\":\"https://www.googleapis.com/oauth2/v1/certs\",\"client_secret\":\""
  <> client_secret
  <> "\",\"redirect_uris\":[\"http://localhost\"]}}"
}
