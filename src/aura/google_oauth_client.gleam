//// Private, connector-specific Google Desktop OAuth client installation.

import aura/secret
import aura/xdg
import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/result
import gleam/string

const google_authorization_endpoint = "https://accounts.google.com/o/oauth2/auth"

const google_token_endpoint = "https://oauth2.googleapis.com/token"

const google_cert_endpoint = "https://www.googleapis.com/oauth2/v1/certs"

const clients_relative_directory = "credentials/google/oauth-clients"

const client_sets_relative_directory = "credentials/google/client-sets"

/// One installed client record. This value contains a provider secret and must
/// not enter command output, operational state, audit, or logs.
pub type InstalledClient {
  InstalledClient(
    connector_id: String,
    client_ref: String,
    client_hash: String,
    client_id: String,
    client_secret: String,
  )
}

/// Secret-free receipt for one installed connector client.
pub type InstallReceipt {
  InstallReceipt(connector_id: String, client_ref: String, client_hash: String)
}

/// Secret-free immutable mapping of the Gmail and Calendar clients.
pub type ClientSetReceipt {
  ClientSetReceipt(
    client_set_ref: String,
    client_set_hash: String,
    gmail_client_ref: String,
    gmail_client_hash: String,
    calendar_client_ref: String,
    calendar_client_hash: String,
  )
}

/// Versioned, secret-free install command payload for the ctl socket.
pub type InstallCommand {
  InstallCommand(
    connector_id: String,
    source_path: String,
    source_sha256: String,
  )
}

/// Versioned, secret-free client-set command payload for the ctl socket.
pub type ClientSetCommand {
  ClientSetCommand(gmail_client_ref: String, calendar_client_ref: String)
}

type SourceClient {
  SourceClient(client_id: String, client_secret: String)
}

/// Calculate the approved SHA-256 for one private source file.
pub fn sha256_file(path: String) -> Result(String, String) {
  use raw <- result.try(secret.secure_read(path))
  Ok(secret.sha256(raw))
}

/// Encode one versioned install command without flattening its path.
pub fn encode_install_command(
  connector_id: String,
  source_path: String,
  source_sha256: String,
) -> String {
  json.object([
    #("schema_version", json.int(1)),
    #("connector_id", json.string(connector_id)),
    #("source_path", json.string(source_path)),
    #("source_sha256", json.string(source_sha256)),
  ])
  |> json.to_string
}

/// Decode one strict install command and reject unsafe path controls.
pub fn decode_install_command(raw: String) -> Result(InstallCommand, String) {
  use fields <- result.try(parse_object(raw))
  use _ <- result.try(
    require_exact_keys(fields, [
      "connector_id",
      "schema_version",
      "source_path",
      "source_sha256",
    ]),
  )
  use version <- result.try(required_int(fields, "schema_version"))
  use connector_id <- result.try(required_string(fields, "connector_id"))
  use source_path <- result.try(required_string(fields, "source_path"))
  use source_sha256 <- result.try(required_string(fields, "source_sha256"))
  use _ <- result.try(validate_connector(connector_id))
  use _ <- result.try(validate_sha256(source_sha256))
  case version == 1 && valid_local_path(source_path) {
    True -> Ok(InstallCommand(connector_id:, source_path:, source_sha256:))
    False -> Error("invalid_google_oauth_client_command")
  }
}

/// Encode one versioned client-set command.
pub fn encode_client_set_command(
  gmail_ref: String,
  calendar_ref: String,
) -> String {
  json.object([
    #("schema_version", json.int(1)),
    #("gmail_client_ref", json.string(gmail_ref)),
    #("calendar_client_ref", json.string(calendar_ref)),
  ])
  |> json.to_string
}

/// Decode one strict client-set command.
pub fn decode_client_set_command(
  raw: String,
) -> Result(ClientSetCommand, String) {
  use fields <- result.try(parse_object(raw))
  use _ <- result.try(
    require_exact_keys(fields, [
      "calendar_client_ref",
      "gmail_client_ref",
      "schema_version",
    ]),
  )
  use version <- result.try(required_int(fields, "schema_version"))
  use gmail_ref <- result.try(required_string(fields, "gmail_client_ref"))
  use calendar_ref <- result.try(required_string(fields, "calendar_client_ref"))
  use #(gmail_connector, _) <- result.try(parse_client_ref(gmail_ref))
  use #(calendar_connector, _) <- result.try(parse_client_ref(calendar_ref))
  case
    version == 1
    && gmail_connector == "gmail"
    && calendar_connector == "calendar"
  {
    True ->
      Ok(ClientSetCommand(
        gmail_client_ref: gmail_ref,
        calendar_client_ref: calendar_ref,
      ))
    False -> Error("invalid_google_oauth_client_command")
  }
}

/// Install one exact Google Desktop OAuth client for one connector.
pub fn install(
  paths: xdg.Paths,
  connector_id: String,
  source_path: String,
  approved_sha256: String,
) -> Result(InstallReceipt, String) {
  use _ <- result.try(validate_connector(connector_id))
  use _ <- result.try(validate_sha256(approved_sha256))
  use raw <- result.try(secret.secure_read(source_path))
  use _ <- result.try(case secret.sha256(raw) == approved_sha256 {
    True -> Ok(Nil)
    False -> Error("google_oauth_client_source_hash_mismatch")
  })
  use source <- result.try(decode_source_client(raw))
  let canonical =
    encode_private_record(connector_id, source.client_id, source.client_secret)
  let digest = secret.sha256(canonical)
  let client_ref = "oauth-client:" <> connector_id <> ":sha256:" <> digest
  use _ <- result.try(
    secret.create_exclusive_beneath(
      paths.config,
      clients_relative_directory,
      digest <> ".json",
      canonical,
    )
    |> result.map_error(fn(error) {
      case error {
        "secret_already_exists" -> "google_oauth_client_already_exists"
        _ -> "google_oauth_client_store_failed"
      }
    }),
  )
  Ok(InstallReceipt(connector_id:, client_ref:, client_hash: digest))
}

/// Load one installed client through its connector-bound opaque reference.
pub fn load(
  paths: xdg.Paths,
  connector_id: String,
  client_ref: String,
) -> Result(InstalledClient, String) {
  use _ <- result.try(validate_connector(connector_id))
  use #(reference_connector, digest) <- result.try(parse_client_ref(client_ref))
  use _ <- result.try(case reference_connector == connector_id {
    True -> Ok(Nil)
    False -> Error("google_oauth_client_connector_mismatch")
  })
  use raw <- result.try(secret.secure_read_beneath(
    paths.config,
    clients_relative_directory,
    digest <> ".json",
  ))
  use source <- result.try(decode_private_record(raw, connector_id))
  use _ <- result.try(case secret.sha256(raw) == digest {
    True -> Ok(Nil)
    False -> Error("google_oauth_client_hash_mismatch")
  })
  Ok(InstalledClient(
    connector_id:,
    client_ref:,
    client_hash: digest,
    client_id: source.client_id,
    client_secret: source.client_secret,
  ))
}

/// Create one immutable private client-set manifest.
pub fn create_client_set(
  paths: xdg.Paths,
  gmail_client_ref: String,
  calendar_client_ref: String,
) -> Result(ClientSetReceipt, String) {
  use receipt <- result.try(expected_client_set(
    paths,
    gmail_client_ref,
    calendar_client_ref,
  ))
  let canonical =
    encode_client_set(
      receipt.gmail_client_ref,
      receipt.gmail_client_hash,
      receipt.calendar_client_ref,
      receipt.calendar_client_hash,
    )
  use _ <- result.try(
    secret.create_exclusive_beneath(
      paths.config,
      client_sets_relative_directory,
      receipt.client_set_hash <> ".json",
      canonical,
    )
    |> result.map_error(fn(error) {
      case error {
        "secret_already_exists" -> "google_oauth_client_set_already_exists"
        _ -> "google_oauth_client_set_store_failed"
      }
    }),
  )
  Ok(receipt)
}

/// Resolve the deterministic client-set receipt without writing a manifest.
pub fn expected_client_set(
  paths: xdg.Paths,
  gmail_client_ref: String,
  calendar_client_ref: String,
) -> Result(ClientSetReceipt, String) {
  use _ <- result.try(case gmail_client_ref != calendar_client_ref {
    True -> Ok(Nil)
    False -> Error("google_oauth_client_set_requires_distinct_clients")
  })
  use gmail <- result.try(load(paths, "gmail", gmail_client_ref))
  use calendar <- result.try(load(paths, "calendar", calendar_client_ref))
  use _ <- result.try(case gmail.client_id != calendar.client_id {
    True -> Ok(Nil)
    False -> Error("google_oauth_client_set_requires_distinct_clients")
  })
  let canonical =
    encode_client_set(
      gmail.client_ref,
      gmail.client_hash,
      calendar.client_ref,
      calendar.client_hash,
    )
  let digest = secret.sha256(canonical)
  let receipt =
    ClientSetReceipt(
      client_set_ref: "oauth-client-set:sha256:" <> digest,
      client_set_hash: digest,
      gmail_client_ref: gmail.client_ref,
      gmail_client_hash: gmail.client_hash,
      calendar_client_ref: calendar.client_ref,
      calendar_client_hash: calendar.client_hash,
    )
  Ok(receipt)
}

/// Load and verify one immutable client-set manifest.
pub fn load_client_set(
  paths: xdg.Paths,
  client_set_ref: String,
) -> Result(ClientSetReceipt, String) {
  use digest <- result.try(parse_client_set_ref(client_set_ref))
  use raw <- result.try(secret.secure_read_beneath(
    paths.config,
    client_sets_relative_directory,
    digest <> ".json",
  ))
  use receipt <- result.try(decode_client_set(raw, client_set_ref, digest))
  use _ <- result.try(case secret.sha256(raw) == digest {
    True -> Ok(Nil)
    False -> Error("google_oauth_client_set_hash_mismatch")
  })
  use gmail <- result.try(load(paths, "gmail", receipt.gmail_client_ref))
  use calendar <- result.try(load(
    paths,
    "calendar",
    receipt.calendar_client_ref,
  ))
  case
    gmail.client_hash == receipt.gmail_client_hash
    && calendar.client_hash == receipt.calendar_client_hash
    && gmail.client_id != calendar.client_id
  {
    True -> Ok(receipt)
    False -> Error("google_oauth_client_set_binding_mismatch")
  }
}

/// Encode a secret-free client installation receipt.
pub fn encode_install_receipt(receipt: InstallReceipt) -> String {
  json.object([
    #("ok", json.bool(True)),
    #("connector_id", json.string(receipt.connector_id)),
    #("client_ref", json.string(receipt.client_ref)),
    #("client_hash", json.string(receipt.client_hash)),
  ])
  |> json.to_string
}

/// Encode a secret-free client-set receipt.
pub fn encode_client_set_receipt(receipt: ClientSetReceipt) -> String {
  json.object([
    #("ok", json.bool(True)),
    #("client_set_ref", json.string(receipt.client_set_ref)),
    #("client_set_hash", json.string(receipt.client_set_hash)),
  ])
  |> json.to_string
}

/// Decode a secret-free installation receipt from command output.
pub fn install_receipt_from_json(raw: String) -> Result(InstallReceipt, String) {
  use fields <- result.try(parse_object(raw))
  use _ <- result.try(
    require_exact_keys(fields, [
      "client_hash",
      "client_ref",
      "connector_id",
      "ok",
    ]),
  )
  use ok_value <- result.try(get_dynamic(fields, "ok"))
  use ok <- result.try(
    decode.run(ok_value, decode.bool)
    |> result.map_error(fn(_) { "google_oauth_client_receipt_invalid" }),
  )
  use connector_id <- result.try(required_string(fields, "connector_id"))
  use client_ref <- result.try(required_string(fields, "client_ref"))
  use client_hash <- result.try(required_string(fields, "client_hash"))
  use #(ref_connector, ref_hash) <- result.try(parse_client_ref(client_ref))
  case
    ok
    && connector_id == ref_connector
    && client_hash == ref_hash
    && valid_sha256(client_hash)
  {
    True -> Ok(InstallReceipt(connector_id:, client_ref:, client_hash:))
    False -> Error("google_oauth_client_receipt_invalid")
  }
}

/// Resolve the private file path for one validated client reference.
pub fn client_path(paths: xdg.Paths, client_ref: String) -> String {
  case parse_client_ref(client_ref) {
    Ok(#(_, digest)) ->
      xdg.google_oauth_clients_dir(paths) <> "/" <> digest <> ".json"
    Error(_) -> xdg.google_oauth_clients_dir(paths) <> "/invalid"
  }
}

fn decode_source_client(raw: String) -> Result(SourceClient, String) {
  use root <- result.try(parse_object(raw))
  use _ <- result.try(require_exact_keys(root, ["installed"]))
  use installed_value <- result.try(get_dynamic(root, "installed"))
  use fields <- result.try(
    decode.run(installed_value, decode.dict(decode.string, decode.dynamic))
    |> result.map_error(fn(_) { "google_oauth_client_invalid" }),
  )
  let allowed = [
    "auth_provider_x509_cert_url",
    "auth_uri",
    "client_id",
    "client_secret",
    "project_id",
    "redirect_uris",
    "token_uri",
    "universe_domain",
  ]
  use _ <- result.try(require_allowed_keys(fields, allowed))
  use client_id <- result.try(required_string(fields, "client_id"))
  use client_secret <- result.try(optional_string(fields, "client_secret"))
  let client_secret_present = dict.has_key(fields, "client_secret")
  use _ <- result.try(validate_optional_exact(
    fields,
    "auth_uri",
    google_authorization_endpoint,
  ))
  use _ <- result.try(validate_optional_exact(
    fields,
    "token_uri",
    google_token_endpoint,
  ))
  use _ <- result.try(validate_optional_exact(
    fields,
    "auth_provider_x509_cert_url",
    google_cert_endpoint,
  ))
  use _ <- result.try(validate_redirects(fields))
  case
    valid_client_id(client_id)
    && { !client_secret_present || valid_present_secret(client_secret) }
  {
    True -> Ok(SourceClient(client_id:, client_secret:))
    False -> Error("google_oauth_client_invalid")
  }
}

fn decode_private_record(
  raw: String,
  expected_connector: String,
) -> Result(SourceClient, String) {
  use fields <- result.try(parse_object(raw))
  use _ <- result.try(
    require_exact_keys(fields, [
      "client_id",
      "client_secret",
      "connector_id",
      "schema_version",
    ]),
  )
  use version <- result.try(required_int(fields, "schema_version"))
  use connector <- result.try(required_string(fields, "connector_id"))
  use client_id <- result.try(required_string(fields, "client_id"))
  use client_secret <- result.try(required_string(fields, "client_secret"))
  case
    version == 1
    && connector == expected_connector
    && valid_client_id(client_id)
    && valid_optional_secret(client_secret)
  {
    True -> Ok(SourceClient(client_id:, client_secret:))
    False -> Error("google_oauth_client_invalid")
  }
}

fn encode_private_record(
  connector_id: String,
  client_id: String,
  client_secret: String,
) -> String {
  json.object([
    #("schema_version", json.int(1)),
    #("connector_id", json.string(connector_id)),
    #("client_id", json.string(client_id)),
    #("client_secret", json.string(client_secret)),
  ])
  |> json.to_string
}

fn encode_client_set(
  gmail_ref: String,
  gmail_hash: String,
  calendar_ref: String,
  calendar_hash: String,
) -> String {
  json.object([
    #("schema_version", json.int(1)),
    #("gmail_client_ref", json.string(gmail_ref)),
    #("gmail_client_hash", json.string(gmail_hash)),
    #("calendar_client_ref", json.string(calendar_ref)),
    #("calendar_client_hash", json.string(calendar_hash)),
  ])
  |> json.to_string
}

fn decode_client_set(
  raw: String,
  client_set_ref: String,
  digest: String,
) -> Result(ClientSetReceipt, String) {
  use fields <- result.try(parse_object(raw))
  use _ <- result.try(
    require_exact_keys(fields, [
      "calendar_client_hash",
      "calendar_client_ref",
      "gmail_client_hash",
      "gmail_client_ref",
      "schema_version",
    ]),
  )
  use version <- result.try(required_int(fields, "schema_version"))
  use gmail_ref <- result.try(required_string(fields, "gmail_client_ref"))
  use gmail_hash <- result.try(required_string(fields, "gmail_client_hash"))
  use calendar_ref <- result.try(required_string(fields, "calendar_client_ref"))
  use calendar_hash <- result.try(required_string(
    fields,
    "calendar_client_hash",
  ))
  use _ <- result.try(
    case
      version == 1
      && gmail_ref != calendar_ref
      && valid_sha256(gmail_hash)
      && valid_sha256(calendar_hash)
    {
      True -> Ok(Nil)
      False -> Error("google_oauth_client_set_invalid")
    },
  )
  Ok(ClientSetReceipt(
    client_set_ref:,
    client_set_hash: digest,
    gmail_client_ref: gmail_ref,
    gmail_client_hash: gmail_hash,
    calendar_client_ref: calendar_ref,
    calendar_client_hash: calendar_hash,
  ))
}

fn parse_object(raw: String) -> Result(dict.Dict(String, Dynamic), String) {
  use dynamic <- result.try(
    json.parse(raw, decode.dynamic)
    |> result.map_error(fn(_) { "google_oauth_client_invalid" }),
  )
  decode.run(dynamic, decode.dict(decode.string, decode.dynamic))
  |> result.map_error(fn(_) { "google_oauth_client_invalid" })
}

fn require_exact_keys(
  fields: dict.Dict(String, Dynamic),
  expected: List(String),
) -> Result(Nil, String) {
  case
    list.sort(dict.keys(fields), string.compare)
    == list.sort(expected, string.compare)
  {
    True -> Ok(Nil)
    False -> Error("google_oauth_client_invalid")
  }
}

fn require_allowed_keys(
  fields: dict.Dict(String, Dynamic),
  allowed: List(String),
) -> Result(Nil, String) {
  case dict.keys(fields) |> list.all(fn(key) { list.contains(allowed, key) }) {
    True -> Ok(Nil)
    False -> Error("google_oauth_client_invalid")
  }
}

fn get_dynamic(
  fields: dict.Dict(String, Dynamic),
  name: String,
) -> Result(Dynamic, String) {
  dict.get(fields, name)
  |> result.map_error(fn(_) { "google_oauth_client_invalid" })
}

fn required_string(
  fields: dict.Dict(String, Dynamic),
  name: String,
) -> Result(String, String) {
  use value <- result.try(get_dynamic(fields, name))
  decode.run(value, decode.string)
  |> result.map_error(fn(_) { "google_oauth_client_invalid" })
}

fn required_int(
  fields: dict.Dict(String, Dynamic),
  name: String,
) -> Result(Int, String) {
  use value <- result.try(get_dynamic(fields, name))
  decode.run(value, decode.int)
  |> result.map_error(fn(_) { "google_oauth_client_invalid" })
}

fn optional_string(
  fields: dict.Dict(String, Dynamic),
  name: String,
) -> Result(String, String) {
  case dict.get(fields, name) {
    Error(_) -> Ok("")
    Ok(value) ->
      decode.run(value, decode.string)
      |> result.map_error(fn(_) { "google_oauth_client_invalid" })
  }
}

fn validate_optional_exact(
  fields: dict.Dict(String, Dynamic),
  name: String,
  expected: String,
) -> Result(Nil, String) {
  case dict.get(fields, name) {
    Error(_) -> Ok(Nil)
    Ok(value) ->
      case decode.run(value, decode.string) == Ok(expected) {
        True -> Ok(Nil)
        False -> Error("google_oauth_client_invalid")
      }
  }
}

fn validate_redirects(fields: dict.Dict(String, Dynamic)) -> Result(Nil, String) {
  case dict.get(fields, "redirect_uris") {
    Error(_) -> Ok(Nil)
    Ok(value) ->
      case decode.run(value, decode.list(decode.string)) {
        Ok(values) ->
          case
            values != []
            && list.all(values, fn(item) { item == "http://localhost" })
          {
            True -> Ok(Nil)
            False -> Error("google_oauth_client_invalid")
          }
        Error(_) -> Error("google_oauth_client_invalid")
      }
  }
}

fn parse_client_ref(value: String) -> Result(#(String, String), String) {
  case string.split(value, ":") {
    ["oauth-client", connector, "sha256", digest] -> {
      use _ <- result.try(validate_connector(connector))
      use _ <- result.try(validate_sha256(digest))
      Ok(#(connector, digest))
    }
    _ -> Error("google_oauth_client_ref_invalid")
  }
}

fn parse_client_set_ref(value: String) -> Result(String, String) {
  case string.split(value, ":") {
    ["oauth-client-set", "sha256", digest] -> {
      use _ <- result.try(validate_sha256(digest))
      Ok(digest)
    }
    _ -> Error("google_oauth_client_set_ref_invalid")
  }
}

fn validate_connector(value: String) -> Result(Nil, String) {
  case value == "gmail" || value == "calendar" {
    True -> Ok(Nil)
    False -> Error("google_oauth_client_connector_invalid")
  }
}

fn validate_sha256(value: String) -> Result(Nil, String) {
  case valid_sha256(value) {
    True -> Ok(Nil)
    False -> Error("google_oauth_client_sha256_invalid")
  }
}

fn valid_sha256(value: String) -> Bool {
  string.length(value) == 64
  && value
  |> string.to_graphemes
  |> list.all(fn(char) { string.contains("0123456789abcdef", char) })
}

fn valid_client_id(value: String) -> Bool {
  string.length(value) >= 24
  && string.length(value) <= 512
  && string.ends_with(value, ".apps.googleusercontent.com")
  && no_control_or_space(value)
}

fn valid_optional_secret(value: String) -> Bool {
  value == "" || { string.length(value) <= 512 && no_control_or_space(value) }
}

fn valid_present_secret(value: String) -> Bool {
  string.length(value) >= 1
  && string.length(value) <= 512
  && no_control_or_space(value)
}

fn no_control_or_space(value: String) -> Bool {
  value
  |> string.to_utf_codepoints
  |> list.all(fn(codepoint) {
    let value = string.utf_codepoint_to_int(codepoint)
    value > 32 && value < 127
  })
}

fn valid_local_path(value: String) -> Bool {
  string.starts_with(value, "/")
  && string.length(value) <= 4096
  && value
  |> string.to_utf_codepoints
  |> list.all(fn(codepoint) {
    let value = string.utf_codepoint_to_int(codepoint)
    value >= 32 && value != 127
  })
}
