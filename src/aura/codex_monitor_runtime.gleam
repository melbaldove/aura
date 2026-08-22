//// Local run-once package for an external Codex-owned attention monitor.

import aura/ctl
import aura/mcp/jsonrpc
import aura/operating_contracts
import aura/secret
import aura/xdg
import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

const max_output_bytes = 16_384

/// Public, non-secret bindings for one local monitor runtime.
pub type RuntimeConfig {
  RuntimeConfig(
    schema_version: Int,
    authorization_id: String,
    monitor_id: String,
    monitor_runtime_ref: String,
    capability_sha256: String,
    lease_ms: Int,
  )
}

/// Decode a strict version-1 runtime configuration.
pub fn decode_config(raw: String) -> Result(RuntimeConfig, String) {
  use dynamic_value <- result.try(
    json.parse(raw, decode.dynamic)
    |> result.map_error(fn(_) { "invalid_monitor_runtime_config" }),
  )
  use fields <- result.try(
    decode.run(dynamic_value, decode.dict(decode.string, decode.dynamic))
    |> result.map_error(fn(_) { "invalid_monitor_runtime_config" }),
  )
  let allowed = [
    "schema_version",
    "authorization_id",
    "monitor_id",
    "monitor_runtime_ref",
    "capability_sha256",
    "lease_ms",
  ]
  use _ <- result.try(
    case
      dict.keys(fields)
      |> list.all(fn(key) { list.contains(allowed, key) })
      && dict.size(fields) == list.length(allowed)
    {
      True -> Ok(Nil)
      False -> Error("invalid_monitor_runtime_config")
    },
  )
  let decoder = {
    use schema_version <- decode.field("schema_version", decode.int)
    use authorization_id <- decode.field("authorization_id", decode.string)
    use monitor_id <- decode.field("monitor_id", decode.string)
    use monitor_runtime_ref <- decode.field(
      "monitor_runtime_ref",
      decode.string,
    )
    use capability_sha256 <- decode.field("capability_sha256", decode.string)
    use lease_ms <- decode.field("lease_ms", decode.int)
    decode.success(RuntimeConfig(
      schema_version:,
      authorization_id:,
      monitor_id:,
      monitor_runtime_ref:,
      capability_sha256:,
      lease_ms:,
    ))
  }
  use config <- result.try(
    decode.run(dynamic_value, decoder)
    |> result.map_error(fn(_) { "invalid_monitor_runtime_config" }),
  )
  case valid_config(config) {
    True -> Ok(config)
    False -> Error("invalid_monitor_runtime_config")
  }
}

/// Claim at most one item with the configured local ctl socket.
pub fn run_once(paths: xdg.Paths) -> Result(String, String) {
  use raw <- result.try(load_config(paths))
  run_once_with(paths, raw, fn(command) {
    ctl.send(paths, command)
    |> result.map_error(fn(_) { "monitor_ctl_unavailable" })
  })
}

/// Claim at most one item with an injected local ctl sender.
pub fn run_once_with(
  paths: xdg.Paths,
  raw_config: String,
  send: fn(String) -> Result(String, String),
) -> Result(String, String) {
  use config <- result.try(decode_config(raw_config))
  use command <- result.try(build_claim(paths, config))
  use raw_response <- result.try(send(
    "monitor claim "
    <> operating_contracts.encode_authorized_monitor_claim_command(command),
  ))
  decode_claim_response(raw_response)
}

/// Acknowledge one leased item with the configured local ctl socket.
pub fn acknowledge(
  paths: xdg.Paths,
  outcome_id: String,
  queue_id: String,
  lease_token: String,
  codex_task_ref: Option(String),
) -> Result(String, String) {
  use raw <- result.try(load_config(paths))
  acknowledge_with(
    paths,
    raw,
    outcome_id,
    queue_id,
    lease_token,
    codex_task_ref,
    fn(command) {
      ctl.send(paths, command)
      |> result.map_error(fn(_) { "monitor_ctl_unavailable" })
    },
  )
}

/// Acknowledge one leased item with an injected local ctl sender.
pub fn acknowledge_with(
  paths: xdg.Paths,
  raw_config: String,
  outcome_id: String,
  queue_id: String,
  lease_token: String,
  codex_task_ref: Option(String),
  send: fn(String) -> Result(String, String),
) -> Result(String, String) {
  submit_outcome_with(
    paths,
    raw_config,
    outcome_id,
    queue_id,
    lease_token,
    "acknowledge",
    None,
    codex_task_ref,
    send,
  )
}

/// Defer one leased item with the configured local ctl socket.
pub fn defer(
  paths: xdg.Paths,
  outcome_id: String,
  queue_id: String,
  lease_token: String,
  defer_until: Int,
  codex_task_ref: Option(String),
) -> Result(String, String) {
  use raw <- result.try(load_config(paths))
  defer_with(
    paths,
    raw,
    outcome_id,
    queue_id,
    lease_token,
    defer_until,
    codex_task_ref,
    fn(command) {
      ctl.send(paths, command)
      |> result.map_error(fn(_) { "monitor_ctl_unavailable" })
    },
  )
}

/// Defer one leased item with an injected local ctl sender.
pub fn defer_with(
  paths: xdg.Paths,
  raw_config: String,
  outcome_id: String,
  queue_id: String,
  lease_token: String,
  defer_until: Int,
  codex_task_ref: Option(String),
  send: fn(String) -> Result(String, String),
) -> Result(String, String) {
  submit_outcome_with(
    paths,
    raw_config,
    outcome_id,
    queue_id,
    lease_token,
    "defer",
    Some(defer_until),
    codex_task_ref,
    send,
  )
}

fn submit_outcome_with(
  paths: xdg.Paths,
  raw_config: String,
  outcome_id: String,
  queue_id: String,
  lease_token: String,
  disposition: String,
  defer_until: Option(Int),
  codex_task_ref: Option(String),
  send: fn(String) -> Result(String, String),
) -> Result(String, String) {
  use config <- result.try(decode_config(raw_config))
  use command <- result.try(build_outcome(
    paths,
    config,
    outcome_id,
    queue_id,
    lease_token,
    disposition,
    defer_until,
    codex_task_ref,
  ))
  use raw_response <- result.try(send(
    "monitor outcome "
    <> operating_contracts.encode_authorized_monitor_outcome_command(command),
  ))
  decode_outcome_response(raw_response)
}

fn load_config(paths: xdg.Paths) -> Result(String, String) {
  secret.secure_read(xdg.codex_monitor_runtime_config_path(paths))
  |> result.map_error(fn(_) { "monitor_runtime_config_unavailable" })
}

fn build_claim(
  paths: xdg.Paths,
  config: RuntimeConfig,
) -> Result(operating_contracts.AuthorizedMonitorClaimCommand, String) {
  use _ <- result.try(verify_capability(paths, config))
  use command_id <- result.try(new_reference("command"))
  let unsigned =
    operating_contracts.AuthorizedMonitorClaimCommand(
      schema_version: 1,
      command_id:,
      authorization_id: config.authorization_id,
      monitor_runtime_ref: config.monitor_runtime_ref,
      monitor_id: config.monitor_id,
      authority_grants: ["attention.read", "attention.claim"],
      lease_ms: config.lease_ms,
      capability_proof: "",
    )
  use proof <- result.try(sign(
    paths,
    config,
    operating_contracts.authorized_monitor_claim_proof_payload(unsigned),
  ))
  Ok(
    operating_contracts.AuthorizedMonitorClaimCommand(
      ..unsigned,
      capability_proof: proof,
    ),
  )
}

fn build_outcome(
  paths: xdg.Paths,
  config: RuntimeConfig,
  outcome_id: String,
  queue_id: String,
  lease_token: String,
  disposition: String,
  defer_until: Option(Int),
  codex_task_ref: Option(String),
) -> Result(operating_contracts.AuthorizedMonitorOutcomeCommand, String) {
  use _ <- result.try(verify_capability(paths, config))
  use _ <- result.try(validate_outcome_input(
    outcome_id,
    queue_id,
    lease_token,
    disposition,
    defer_until,
    codex_task_ref,
  ))
  use command_id <- result.try(new_reference("command"))
  let grants = case disposition {
    "acknowledge" -> ["attention.acknowledge"]
    "defer" -> ["attention.defer"]
    _ -> []
  }
  let unsigned =
    operating_contracts.AuthorizedMonitorOutcomeCommand(
      schema_version: 1,
      command_id:,
      authorization_id: config.authorization_id,
      monitor_runtime_ref: config.monitor_runtime_ref,
      outcome_id:,
      queue_id:,
      lease_token:,
      monitor_id: config.monitor_id,
      disposition:,
      defer_until:,
      codex_task_ref:,
      codex_conversation_ref: None,
      codex_turn_ref: None,
      authority_grants: grants,
      capability_proof: "",
    )
  use proof <- result.try(sign(
    paths,
    config,
    operating_contracts.authorized_monitor_outcome_proof_payload(unsigned),
  ))
  Ok(
    operating_contracts.AuthorizedMonitorOutcomeCommand(
      ..unsigned,
      capability_proof: proof,
    ),
  )
}

fn verify_capability(paths: xdg.Paths, config: RuntimeConfig) {
  secret.verify_monitor_capability(
    xdg.monitor_capability_path(paths, config.capability_sha256),
    config.capability_sha256,
  )
}

fn sign(paths: xdg.Paths, config: RuntimeConfig, payload: String) {
  secret.sign_monitor_command(
    xdg.monitor_capability_path(paths, config.capability_sha256),
    payload,
  )
  |> result.map_error(fn(_) { "monitor_authentication_failed" })
}

fn new_reference(kind: String) -> Result(String, String) {
  secret.random_urlsafe(24)
  |> result.map(fn(value) { "codex:" <> kind <> ":" <> value })
  |> result.map_error(fn(_) { "monitor_runtime_random_failed" })
}

fn decode_claim_response(raw: String) -> Result(String, String) {
  use response <- result.try(decode_response(raw, "attention"))
  case response {
    ResponseError(error) -> Error(error)
    ResponseEmpty -> Ok("")
    ResponseValue(value) -> {
      let encoded = jsonrpc.dynamic_to_json(value) |> json.to_string
      use envelope <- result.try(
        operating_contracts.decode_monitor_attention_envelope(encoded)
        |> result.map_error(fn(_) { "invalid_monitor_response" }),
      )
      bounded_output(operating_contracts.encode_monitor_attention_envelope(
        envelope,
      ))
    }
  }
}

fn decode_outcome_response(raw: String) -> Result(String, String) {
  use response <- result.try(decode_response(raw, "receipt"))
  case response {
    ResponseError(error) -> Error(error)
    ResponseEmpty -> Error("invalid_monitor_response")
    ResponseValue(value) -> {
      let encoded = jsonrpc.dynamic_to_json(value) |> json.to_string
      use receipt <- result.try(
        operating_contracts.decode_monitor_outcome_receipt(encoded)
        |> result.map_error(fn(_) { "invalid_monitor_response" }),
      )
      bounded_output(operating_contracts.encode_monitor_outcome_receipt(receipt))
    }
  }
}

type ResponseValue {
  ResponseEmpty
  ResponseValue(Dynamic)
  ResponseError(String)
}

fn decode_response(
  raw: String,
  value_field: String,
) -> Result(ResponseValue, String) {
  let decoder = {
    use ok <- decode.field("ok", decode.bool)
    use value <- decode.field(value_field, decode.optional(decode.dynamic))
    use error <- decode.optional_field("error", "", decode.string)
    decode.success(#(ok, value, error))
  }
  use parsed <- result.try(
    json.parse(raw, decoder)
    |> result.map_error(fn(_) { "invalid_monitor_response" }),
  )
  case parsed {
    #(False, _, error) ->
      case valid_error_code(error) {
        True -> Ok(ResponseError(error))
        False -> Error("invalid_monitor_response")
      }
    #(True, None, _) -> Ok(ResponseEmpty)
    #(True, Some(value), _) -> Ok(ResponseValue(value))
  }
}

fn bounded_output(output: String) -> Result(String, String) {
  case string.byte_size(output) <= max_output_bytes {
    True -> Ok(output)
    False -> Error("monitor_output_too_large")
  }
}

fn validate_outcome_input(
  outcome_id: String,
  queue_id: String,
  lease_token: String,
  disposition: String,
  defer_until: Option(Int),
  task_ref: Option(String),
) -> Result(Nil, String) {
  let disposition_valid = case disposition, defer_until {
    "acknowledge", None -> True
    "defer", Some(value) -> value > 0
    _, _ -> False
  }
  let task_valid = case task_ref {
    None -> True
    Some(value) -> operating_contracts.valid_codex_reference(value, "task")
  }
  case
    operating_contracts.valid_codex_reference(outcome_id, "outcome")
    && valid_identifier(queue_id, 256)
    && valid_identifier(lease_token, 512)
    && disposition_valid
    && task_valid
  {
    True -> Ok(Nil)
    False -> Error("invalid_monitor_outcome")
  }
}

fn valid_config(config: RuntimeConfig) -> Bool {
  config.schema_version == 1
  && valid_identifier(config.authorization_id, 128)
  && valid_identifier(config.monitor_id, 128)
  && operating_contracts.valid_codex_reference(
    config.monitor_runtime_ref,
    "runtime",
  )
  && valid_sha256(config.capability_sha256)
  && config.lease_ms > 0
  && config.lease_ms <= 300_000
}

fn valid_identifier(value: String, maximum: Int) -> Bool {
  let length = string.length(value)
  length > 0
  && length <= maximum
  && value
  |> string.to_graphemes
  |> list.all(fn(character) {
    string.contains(
      "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789:._-/",
      character,
    )
  })
}

fn valid_sha256(value: String) -> Bool {
  string.length(value) == 64
  && value
  |> string.to_graphemes
  |> list.all(fn(character) { string.contains("0123456789abcdef", character) })
}

fn valid_error_code(value: String) -> Bool {
  let length = string.length(value)
  length > 0
  && length <= 128
  && value
  |> string.to_graphemes
  |> list.all(fn(character) {
    string.contains("abcdefghijklmnopqrstuvwxyz0123456789_", character)
  })
}
