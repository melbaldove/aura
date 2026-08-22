import aura/db
import aura/operating_contracts
import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string

/// Create the exact authorization-bound connector set in the disabled state.
pub fn prepare_disabled(
  db_subject: process.Subject(db.DbMessage),
  authorization_id: String,
  idempotency_key: String,
  actor_ref: String,
) -> Result(List(operating_contracts.ConnectorActivationV1), String) {
  db.transition_connector_activation_set(
    db_subject,
    authorization_id,
    idempotency_key,
    actor_ref,
    [],
    "prepare",
  )
}

/// Enable the exact authorization-bound connector set.
pub fn enable_set(
  db_subject: process.Subject(db.DbMessage),
  authorization_id: String,
  idempotency_key: String,
  actor_ref: String,
  authority_grants: List(String),
) -> Result(List(operating_contracts.ConnectorActivationV1), String) {
  db.transition_connector_activation_set(
    db_subject,
    authorization_id,
    idempotency_key,
    actor_ref,
    authority_grants,
    "enable",
  )
}

/// Stop new reads for the exact authorization-bound connector set.
pub fn begin_disable_set(
  db_subject: process.Subject(db.DbMessage),
  authorization_id: String,
  idempotency_key: String,
  rollback_owner_ref: String,
  authority_grants: List(String),
) -> Result(List(operating_contracts.ConnectorActivationV1), String) {
  db.transition_connector_activation_set(
    db_subject,
    authorization_id,
    idempotency_key,
    rollback_owner_ref,
    authority_grants,
    "begin_disable",
  )
}

/// Complete disable after all bounded read attempts have drained.
pub fn finalize_disable_set(
  db_subject: process.Subject(db.DbMessage),
  authorization_id: String,
  idempotency_key: String,
  rollback_owner_ref: String,
) -> Result(List(operating_contracts.ConnectorActivationV1), String) {
  db.transition_connector_activation_set(
    db_subject,
    authorization_id,
    idempotency_key,
    rollback_owner_ref,
    [],
    "finalize_disable",
  )
}

/// Begin safe disable when Aura observes an expired authorization.
pub fn expire_set(
  db_subject: process.Subject(db.DbMessage),
  authorization_id: String,
  idempotency_key: String,
) -> Result(List(operating_contracts.ConnectorActivationV1), String) {
  db.transition_connector_activation_set(
    db_subject,
    authorization_id,
    idempotency_key,
    "aura",
    [],
    "expire",
  )
}

/// Load one authorization-effective connector activation at Aura server time.
pub fn load_effective(
  db_subject: process.Subject(db.DbMessage),
  activation_id: String,
  authorization_id: String,
) -> Result(Option(operating_contracts.ConnectorActivationV1), String) {
  db.get_effective_connector_activation(
    db_subject,
    activation_id,
    authorization_id,
  )
}

/// Apply one explicit, transcript-free activation control command.
pub fn apply_command(
  db_subject: process.Subject(db.DbMessage),
  command: operating_contracts.CommandMutation,
) -> Result(List(operating_contracts.ConnectorActivationV1), String) {
  use _ <- result.try(case command.creation_basis == "explicit" {
    True -> Ok(Nil)
    False -> Error("connector_activation_requires_explicit_command")
  })
  use authorization_id <- result.try(required_string(
    command,
    "authorization_id",
  ))
  use actor_ref <- result.try(required_string(command, "actor_ref"))
  let grants = optional_strings(command, "authority_grants")
  case command.intent_kind {
    "connector_activation.prepare" ->
      prepare_disabled(
        db_subject,
        authorization_id,
        command.idempotency_key,
        actor_ref,
      )
    "connector_activation.enable" ->
      enable_set(
        db_subject,
        authorization_id,
        command.idempotency_key,
        actor_ref,
        grants,
      )
    "connector_activation.begin_disable" ->
      begin_disable_set(
        db_subject,
        authorization_id,
        command.idempotency_key,
        actor_ref,
        grants,
      )
    "connector_activation.finalize_disable" ->
      finalize_disable_set(
        db_subject,
        authorization_id,
        command.idempotency_key,
        actor_ref,
      )
    "connector_activation.expire" ->
      Error("connector_activation_expire_is_internal")
    _ -> Error("invalid_connector_activation_command")
  }
}

fn required_string(
  command: operating_contracts.CommandMutation,
  key: String,
) -> Result(String, String) {
  case dict.get(command.structured_payload, key) {
    Ok(operating_contracts.StructuredString(value)) ->
      case string.trim(value) {
        "" -> Error("missing_connector_activation_field: " <> key)
        present -> Ok(present)
      }
    _ -> Error("missing_connector_activation_field: " <> key)
  }
}

fn optional_strings(
  command: operating_contracts.CommandMutation,
  key: String,
) -> List(String) {
  case dict.get(command.structured_payload, key) {
    Ok(operating_contracts.StructuredArray(values)) ->
      values
      |> list.try_map(fn(value) {
        case value {
          operating_contracts.StructuredString(text) ->
            case string.trim(text) {
              "" -> Error(Nil)
              present -> Ok(present)
            }
          _ -> Error(Nil)
        }
      })
      |> result.unwrap([])
    _ -> []
  }
}
