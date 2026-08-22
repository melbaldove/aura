import aura/secret
import aura/test_helpers
import gleam/string
import gleeunit
import gleeunit/should
import simplifile

pub fn main() {
  gleeunit.main()
}

pub fn scoped_secret_round_trip_uses_private_permissions_test() {
  let root = "/tmp/aura-secret-" <> test_helpers.random_suffix()
  let path = root <> "/token.json"
  let assert Ok(Nil) = secret.atomic_write(path, "synthetic-secret")
  secret.secure_read(path) |> should.equal(Ok("synthetic-secret"))
  let info = simplifile.file_info(path) |> should.be_ok
  simplifile.file_info_permissions_octal(info) |> should.equal(0o600)
  let _ = simplifile.delete(root)
}

pub fn broad_or_symlink_secret_files_fail_closed_test() {
  let root = "/tmp/aura-secret-bad-" <> test_helpers.random_suffix()
  let path = root <> "/token.json"
  let link = root <> "/link.json"
  let assert Ok(Nil) = simplifile.create_directory_all(root)
  let assert Ok(Nil) = simplifile.write(path, "synthetic-secret")
  let assert Ok(Nil) = simplifile.set_permissions_octal(path, 0o644)
  secret.secure_read(path) |> should.equal(Error("secret_permissions_invalid"))
  let assert Ok(Nil) = simplifile.create_symlink(path, link)
  secret.secure_read(link) |> should.equal(Error("secret_symlink_rejected"))
  secret.atomic_write(link, "replacement")
  |> should.equal(Error("secret_symlink_rejected"))
  let _ = simplifile.delete(root)
}

pub fn oversized_secret_file_fails_before_read_test() {
  let root = "/tmp/aura-secret-large-" <> test_helpers.random_suffix()
  let path = root <> "/token.json"
  let assert Ok(Nil) = simplifile.create_directory_all(root)
  let assert Ok(Nil) = simplifile.write(path, string.repeat("x", 65_537))
  let assert Ok(Nil) = simplifile.set_permissions_octal(path, 0o600)
  secret.secure_read(path) |> should.equal(Error("secret_file_too_large"))
  let _ = simplifile.delete(root)
}

pub fn monitor_capability_is_private_exclusive_and_verifiable_test() {
  let root = "/tmp/aura-monitor-capability-" <> test_helpers.random_suffix()
  let path = root <> "/capability"
  let assert Ok(capability) = secret.prepare_monitor_capability(path)

  capability.reference
  |> string.starts_with("monitor-capability:sha256:")
  |> should.be_true
  string.length(capability.sha256) |> should.equal(64)
  secret.verify_monitor_capability(path, capability.sha256)
  |> should.equal(Ok(Nil))
  secret.verify_monitor_capability(path, string.repeat("0", 64))
  |> should.equal(Error("monitor_authentication_failed"))
  secret.prepare_monitor_capability(path)
  |> should.equal(Error("monitor_capability_already_exists"))

  let info = simplifile.file_info(path) |> should.be_ok
  simplifile.file_info_permissions_octal(info) |> should.equal(0o600)
  let _ = simplifile.delete_all([root])
}

pub fn exclusive_secret_create_and_exact_remove_are_confined_test() {
  let root = "/tmp/aura-secret-exclusive-" <> test_helpers.random_suffix()
  let directory = root <> "/private"
  secret.create_exclusive_beneath(root, "private", "one.json", "bounded-secret")
  |> should.equal(Ok(Nil))
  secret.create_exclusive_beneath(root, "private", "one.json", "replacement")
  |> should.equal(Error("secret_already_exists"))
  secret.create_exclusive_beneath(root, "private", "../escape", "bad")
  |> should.equal(Error("secret_name_invalid"))
  secret.remove_exact_beneath(
    root,
    "private",
    "one.json",
    string.repeat("0", 64),
  )
  |> should.equal(Error("secret_hash_mismatch"))
  let digest = secret.sha256("bounded-secret")
  secret.remove_exact_beneath(root, "private", "one.json", digest)
  |> should.equal(Ok(Nil))
  simplifile.is_file(directory <> "/one.json") |> should.equal(Ok(False))
  let _ = simplifile.delete_all([root])
}

pub fn exclusive_secret_rejects_intermediate_symlink_test() {
  let root = "/tmp/aura-secret-chain-" <> test_helpers.random_suffix()
  let outside = root <> "-outside"
  let assert Ok(_) = simplifile.create_directory_all(root)
  let assert Ok(_) = simplifile.create_directory_all(outside)
  let assert Ok(_) = simplifile.set_permissions_octal(root, 0o700)
  let assert Ok(_) = simplifile.set_permissions_octal(outside, 0o700)
  let assert Ok(_) = simplifile.create_symlink(outside, root <> "/credentials")
  secret.create_exclusive_beneath(
    root,
    "credentials/google",
    "client.json",
    "bounded-secret",
  )
  |> should.equal(Error("secret_parent_symlink_rejected"))
  secret.secure_read_beneath(root, "credentials/google", "client.json")
  |> should.equal(Error("secret_parent_symlink_rejected"))
  secret.remove_exact_beneath(
    root,
    "credentials/google",
    "client.json",
    secret.sha256("bounded-secret"),
  )
  |> should.equal(Error("secret_parent_symlink_rejected"))
  simplifile.is_file(outside <> "/google/client.json")
  |> should.equal(Ok(False))
  let _ = simplifile.delete_all([root, outside])
}

pub fn exclusive_secret_rejects_writable_trust_anchor_test() {
  let root = "/tmp/aura-secret-anchor-" <> test_helpers.random_suffix()
  let assert Ok(_) = simplifile.create_directory_all(root)
  let assert Ok(_) = simplifile.set_permissions_octal(root, 0o777)
  secret.create_exclusive_beneath(root, "credentials", "client.json", "secret")
  |> should.equal(Error("secret_parent_permissions_invalid"))
  simplifile.is_file(root <> "/credentials/client.json")
  |> should.equal(Ok(False))
  let _ = simplifile.delete_all([root])
}

pub fn exact_secret_replace_requires_current_digest_and_keeps_private_mode_test() {
  let root = "/tmp/aura-secret-replace-" <> test_helpers.random_suffix()
  secret.create_exclusive_beneath(root, "private", "token.json", "old-token")
  |> should.equal(Ok(Nil))
  secret.replace_exact_beneath(
    root,
    "private",
    "token.json",
    string.repeat("0", 64),
    "new-token",
  )
  |> should.equal(Error("secret_hash_mismatch"))
  secret.secure_read_beneath(root, "private", "token.json")
  |> should.equal(Ok("old-token"))
  secret.replace_exact_beneath(
    root,
    "private",
    "token.json",
    secret.sha256("old-token"),
    "new-token",
  )
  |> should.equal(Ok(Nil))
  secret.secure_read_beneath(root, "private", "token.json")
  |> should.equal(Ok("new-token"))
  let info = simplifile.file_info(root <> "/private/token.json") |> should.be_ok
  simplifile.file_info_permissions_octal(info) |> should.equal(0o600)
  let _ = simplifile.delete_all([root])
}

pub fn exact_secret_replace_rejects_symlink_target_test() {
  let root = "/tmp/aura-secret-replace-link-" <> test_helpers.random_suffix()
  let outside = root <> "-outside"
  let assert Ok(_) = simplifile.create_directory_all(root <> "/private")
  let assert Ok(_) = simplifile.create_directory_all(outside)
  let assert Ok(_) = simplifile.set_permissions_octal(root, 0o700)
  let assert Ok(_) = simplifile.set_permissions_octal(root <> "/private", 0o700)
  let assert Ok(_) = simplifile.set_permissions_octal(outside, 0o700)
  let assert Ok(_) = simplifile.write(outside <> "/token.json", "outside-token")
  let assert Ok(_) =
    simplifile.set_permissions_octal(outside <> "/token.json", 0o600)
  let assert Ok(_) =
    simplifile.create_symlink(
      outside <> "/token.json",
      root <> "/private/token.json",
    )
  secret.replace_exact_beneath(
    root,
    "private",
    "token.json",
    secret.sha256("outside-token"),
    "replacement",
  )
  |> should.equal(Error("secret_symlink_rejected"))
  simplifile.read(outside <> "/token.json") |> should.equal(Ok("outside-token"))
  let _ = simplifile.delete_all([root, outside])
}
