//// Secure local secret-file and keyed-identity primitives.

import gleam/bit_array
import gleam/list
import gleam/result
import gleam/string
import simplifile

pub type MonitorCapability {
  MonitorCapability(reference: String, sha256: String)
}

/// Write a secret by same-directory atomic replacement.
///
/// The parent directory becomes `0700`. The resulting regular file is `0600`.
/// A pre-existing symlink or unsafe file fails closed.
pub fn atomic_write(path: String, contents: String) -> Result(Nil, String) {
  use _ <- result.try(validate_existing_target(path))
  ffi_atomic_write(path, contents)
}

/// Read one private regular file. Symlinks and non-`0600` files fail closed.
pub fn secure_read(path: String) -> Result(String, String) {
  ffi_secure_read(path, 65_536)
}

/// Return a URL-safe random value. This does not log the value.
pub fn random_urlsafe(byte_count: Int) -> Result(String, String) {
  case byte_count >= 16 && byte_count <= 96 {
    False -> Error("secret_random_size_invalid")
    True ->
      ffi_random_bytes(byte_count)
      |> bit_array.base64_url_encode(False)
      |> Ok
  }
}

/// Derive a keyed, opaque SHA-256 identity proof.
pub fn hmac_sha256(key: String, value: String) -> String {
  ffi_hmac_sha256(key, value) |> bit_array.base16_encode
}

/// Compare two secret values without content-dependent early return.
pub fn constant_time_equal(left: String, right: String) -> Bool {
  ffi_constant_time_equal(left, right)
}

/// Return the lower-case SHA-256 digest of one secret value.
pub fn sha256(value: String) -> String {
  ffi_sha256(value) |> bit_array.base16_encode |> string.lowercase
}

/// Create one private file beneath a selected XDG trust anchor.
///
/// Relative directory components and the file name cannot escape the anchor.
/// The FFI pins and rechecks the directory chain around the exclusive write.
pub fn create_exclusive_beneath(
  anchor: String,
  relative_directory: String,
  file_name: String,
  contents: String,
) -> Result(Nil, String) {
  use _ <- result.try(validate_secret_name(file_name))
  use _ <- result.try(validate_relative_directory(relative_directory))
  ffi_create_exclusive_beneath(anchor, relative_directory, file_name, contents)
  |> result.map_error(fn(error) {
    case error {
      "monitor_capability_already_exists" -> "secret_already_exists"
      other -> other
    }
  })
}

/// Read one private file beneath a selected XDG trust anchor.
pub fn secure_read_beneath(
  anchor: String,
  relative_directory: String,
  file_name: String,
) -> Result(String, String) {
  use _ <- result.try(validate_secret_name(file_name))
  use _ <- result.try(validate_relative_directory(relative_directory))
  ffi_secure_read_beneath(anchor, relative_directory, file_name, 65_536)
}

/// Remove one exact private file after its SHA-256 digest is verified.
///
/// A mismatch leaves the file in place. The operation rejects path traversal,
/// symlinks, non-regular files, unsafe modes, and files owned by another user.
pub fn remove_exact_beneath(
  anchor: String,
  relative_directory: String,
  file_name: String,
  expected_sha256: String,
) -> Result(Nil, String) {
  use _ <- result.try(validate_secret_name(file_name))
  use _ <- result.try(validate_relative_directory(relative_directory))
  use _ <- result.try(validate_sha256(expected_sha256))
  ffi_remove_exact_beneath(
    anchor,
    relative_directory,
    file_name,
    expected_sha256,
  )
}

/// Atomically replace one exact private file after its current digest is verified.
///
/// A mismatch leaves the current file in place. The new file is published with
/// mode `0600` beneath the same pinned private directory.
pub fn replace_exact_beneath(
  anchor: String,
  relative_directory: String,
  file_name: String,
  expected_sha256: String,
  contents: String,
) -> Result(Nil, String) {
  use _ <- result.try(validate_secret_name(file_name))
  use _ <- result.try(validate_relative_directory(relative_directory))
  use _ <- result.try(validate_sha256(expected_sha256))
  ffi_replace_exact_beneath(
    anchor,
    relative_directory,
    file_name,
    expected_sha256,
    contents,
  )
}

/// Create one monitor capability file without replacing an existing file.
pub fn prepare_monitor_capability(
  path: String,
) -> Result(MonitorCapability, String) {
  use raw <- result.try(random_urlsafe(32))
  use _ <- result.try(ffi_create_exclusive(path, raw))
  let digest = ffi_sha256(raw) |> bit_array.base16_encode |> string.lowercase
  Ok(MonitorCapability(
    reference: "monitor-capability:sha256:" <> digest,
    sha256: digest,
  ))
}

/// Create one digest-named monitor capability in a private directory.
pub fn prepare_monitor_capability_in(
  directory: String,
) -> Result(MonitorCapability, String) {
  use raw <- result.try(random_urlsafe(32))
  let digest = ffi_sha256(raw) |> bit_array.base16_encode |> string.lowercase
  use _ <- result.try(ffi_create_exclusive(
    directory <> "/" <> digest <> ".capability",
    raw,
  ))
  Ok(MonitorCapability(
    reference: "monitor-capability:sha256:" <> digest,
    sha256: digest,
  ))
}

/// Verify one private monitor capability without exposing its contents.
pub fn verify_monitor_capability(
  path: String,
  expected_sha256: String,
) -> Result(Nil, String) {
  case secure_read(path) {
    Ok(raw) -> {
      let actual =
        ffi_sha256(raw) |> bit_array.base16_encode |> string.lowercase
      case ffi_constant_time_equal(actual, expected_sha256) {
        True -> Ok(Nil)
        False -> Error("monitor_authentication_failed")
      }
    }
    Error(_) -> Error("monitor_authentication_failed")
  }
}

/// Sign one canonical monitor command with a private capability file.
pub fn sign_monitor_command(
  path: String,
  payload: String,
) -> Result(String, String) {
  use raw <- result.try(secure_read(path))
  Ok(hmac_sha256(raw, payload) |> string.lowercase)
}

/// Verify proof that the command caller holds the private capability.
pub fn verify_monitor_command_proof(
  path: String,
  payload: String,
  proof: String,
) -> Result(Nil, String) {
  case sign_monitor_command(path, payload) {
    Ok(expected) ->
      case ffi_constant_time_equal(expected, string.lowercase(proof)) {
        True -> Ok(Nil)
        False -> Error("monitor_authentication_failed")
      }
    _ -> Error("monitor_authentication_failed")
  }
}

fn validate_existing_target(path: String) -> Result(Nil, String) {
  case simplifile.link_info(path) {
    Ok(info) -> validate_info(info)
    Error(simplifile.Enoent) -> Ok(Nil)
    Error(_) -> Error("secret_file_unavailable")
  }
}

fn validate_info(info: simplifile.FileInfo) -> Result(Nil, String) {
  case simplifile.file_info_type(info) {
    simplifile.Symlink -> Error("secret_symlink_rejected")
    simplifile.File ->
      case info.user_id == ffi_effective_uid() {
        False -> Error("secret_owner_invalid")
        True ->
          case simplifile.file_info_permissions_octal(info) == 0o600 {
            True -> Ok(Nil)
            False -> Error("secret_permissions_invalid")
          }
      }
    _ -> Error("secret_type_invalid")
  }
}

fn validate_secret_name(value: String) -> Result(Nil, String) {
  case
    string.length(value) > 0
    && string.length(value) <= 192
    && value
    |> string.to_graphemes
    |> list.all(fn(char) {
      string.contains(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-",
        char,
      )
    })
  {
    True -> Ok(Nil)
    False -> Error("secret_name_invalid")
  }
}

fn validate_relative_directory(value: String) -> Result(Nil, String) {
  case
    string.length(value) > 0
    && string.length(value) <= 512
    && value
    |> string.split("/")
    |> list.all(fn(component) {
      component != "" && validate_secret_name(component) == Ok(Nil)
    })
  {
    True -> Ok(Nil)
    False -> Error("secret_relative_directory_invalid")
  }
}

fn validate_sha256(value: String) -> Result(Nil, String) {
  case
    string.length(value) == 64
    && value
    |> string.to_graphemes
    |> list.all(fn(char) { string.contains("0123456789abcdef", char) })
  {
    True -> Ok(Nil)
    False -> Error("secret_hash_invalid")
  }
}

@external(erlang, "aura_secret_ffi", "atomic_write")
fn ffi_atomic_write(path: String, contents: String) -> Result(Nil, String)

@external(erlang, "aura_secret_ffi", "random_bytes")
fn ffi_random_bytes(byte_count: Int) -> BitArray

@external(erlang, "aura_secret_ffi", "hmac_sha256")
fn ffi_hmac_sha256(key: String, value: String) -> BitArray

@external(erlang, "aura_secret_ffi", "effective_uid")
fn ffi_effective_uid() -> Int

@external(erlang, "aura_secret_ffi", "create_exclusive")
fn ffi_create_exclusive(path: String, contents: String) -> Result(Nil, String)

@external(erlang, "aura_secret_ffi", "replace_exact_beneath")
fn ffi_replace_exact_beneath(
  anchor: String,
  relative_directory: String,
  file_name: String,
  expected_sha256: String,
  contents: String,
) -> Result(Nil, String)

@external(erlang, "aura_secret_ffi", "sha256")
fn ffi_sha256(value: String) -> BitArray

@external(erlang, "aura_secret_ffi", "constant_time_equal")
fn ffi_constant_time_equal(left: String, right: String) -> Bool

@external(erlang, "aura_secret_ffi", "secure_read")
fn ffi_secure_read(path: String, maximum_bytes: Int) -> Result(String, String)

@external(erlang, "aura_secret_ffi", "create_exclusive_beneath")
fn ffi_create_exclusive_beneath(
  anchor: String,
  relative_directory: String,
  file_name: String,
  contents: String,
) -> Result(Nil, String)

@external(erlang, "aura_secret_ffi", "secure_read_beneath")
fn ffi_secure_read_beneath(
  anchor: String,
  relative_directory: String,
  file_name: String,
  maximum_bytes: Int,
) -> Result(String, String)

@external(erlang, "aura_secret_ffi", "remove_exact_beneath")
fn ffi_remove_exact_beneath(
  anchor: String,
  relative_directory: String,
  file_name: String,
  expected_sha256: String,
) -> Result(Nil, String)
