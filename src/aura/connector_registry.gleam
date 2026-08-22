//// Data-driven connector declarations, activation, health, and authority checks.
////
//// This module does not call a connector and does not make attention decisions.

import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// One installed connector adapter declaration.
pub type ConnectorDescriptor {
  ConnectorDescriptor(
    schema_version: Int,
    connector_id: String,
    display_name: String,
    source_kind: String,
    capabilities: List(String),
    scopes: List(String),
    descriptor_provenance_ref: String,
    summary_limit: Int,
    value_limit: Int,
    read_authority_ref: Option(String),
    write_authority_ref: Option(String),
    policy_boundary_ref: String,
  )
}

/// One explicit connector configuration selection.
pub type ConnectorActivation {
  ConnectorActivation(
    schema_version: Int,
    connector_id: String,
    state: String,
    configuration_ref: String,
  )
}

/// Connector health is operational state. It cannot change activation.
pub type ConnectorHealth {
  ConnectorHealth(
    connector_id: String,
    status: String,
    error_code: Option(String),
    checked_at: Int,
  )
}

/// A connector request that has not executed an external action.
pub type ConnectorActionRequest {
  ConnectorActionRequest(
    schema_version: Int,
    request_id: String,
    connector_id: String,
    capability: String,
    scope: String,
    operation: String,
    resource_ref: String,
    authority_grants: List(String),
  )
}

/// An installed connector with an explicit enabled configuration.
pub type EnabledConnector {
  EnabledConnector(
    descriptor: ConnectorDescriptor,
    activation: ConnectorActivation,
  )
}

/// A validated connector registry.
pub opaque type Registry {
  Registry(
    descriptors: Dict(String, ConnectorDescriptor),
    activations: Dict(String, ConnectorActivation),
    health: Dict(String, ConnectorHealth),
  )
}

/// Build a registry from installed descriptors and separate configuration data.
pub fn build(
  descriptors: List(ConnectorDescriptor),
  activations: List(ConnectorActivation),
) -> Result(Registry, String) {
  use descriptor_index <- result.try(index_descriptors(descriptors, dict.new()))
  use activation_index <- result.try(index_activations(
    activations,
    descriptor_index,
    dict.new(),
  ))
  Ok(Registry(
    descriptors: descriptor_index,
    activations: activation_index,
    health: dict.new(),
  ))
}

/// Find a connector only when explicit configuration enables it.
pub fn lookup_enabled(
  registry: Registry,
  connector_id: String,
) -> Result(EnabledConnector, String) {
  use descriptor <- result.try(
    dict.get(registry.descriptors, connector_id)
    |> result.replace_error("connector_unconfigured:" <> connector_id),
  )
  use activation <- result.try(
    dict.get(registry.activations, connector_id)
    |> result.replace_error("connector_not_enabled:" <> connector_id),
  )
  case activation.state {
    "enabled" -> Ok(EnabledConnector(descriptor:, activation:))
    _ -> Error("connector_not_enabled:" <> connector_id)
  }
}

/// Store health without changing the descriptor or activation selection.
pub fn update_health(
  registry: Registry,
  health: ConnectorHealth,
) -> Result(Registry, String) {
  use _ <- result.try(
    dict.get(registry.descriptors, health.connector_id)
    |> result.replace_error("connector_unconfigured:" <> health.connector_id),
  )
  use _ <- result.try(
    case
      list.contains(
        ["unknown", "healthy", "degraded", "unavailable"],
        health.status,
      )
    {
      True -> Ok(Nil)
      False -> Error("invalid_connector_health")
    },
  )
  use _ <- result.try(case health.error_code {
    None -> Ok(Nil)
    Some(error_code) -> require_error_code(error_code)
  })
  use _ <- result.try(case health.checked_at >= 0 {
    True -> Ok(Nil)
    False -> Error("invalid_connector_checked_at")
  })
  Ok(
    Registry(
      ..registry,
      health: dict.insert(registry.health, health.connector_id, health),
    ),
  )
}

fn require_error_code(value: String) -> Result(Nil, String) {
  let valid_characters =
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.:"
  case
    value != ""
    && string.length(value) <= 128
    && {
      value
      |> string.to_graphemes
      |> list.all(fn(character) { string.contains(valid_characters, character) })
    }
  {
    True -> Ok(Nil)
    False -> Error("invalid_connector_error_code")
  }
}

/// Get the current health observation without changing activation.
pub fn get_health(
  registry: Registry,
  connector_id: String,
) -> Result(Option(ConnectorHealth), String) {
  use _ <- result.try(
    dict.get(registry.descriptors, connector_id)
    |> result.replace_error("connector_unconfigured:" <> connector_id),
  )
  Ok(case dict.get(registry.health, connector_id) {
    Ok(health) -> Some(health)
    Error(_) -> None
  })
}

/// Validate a connector action request. This function does not execute it.
pub fn validate_action(
  registry: Registry,
  request: ConnectorActionRequest,
) -> Result(EnabledConnector, String) {
  use _ <- result.try(require_version(request.schema_version))
  use _ <- result.try(require_identifier("request_id", request.request_id))
  use _ <- result.try(require_reference("resource_ref", request.resource_ref))
  use _ <- result.try(require_authority_grants(request.authority_grants))
  use enabled <- result.try(lookup_enabled(registry, request.connector_id))
  use _ <- result.try(
    case list.contains(enabled.descriptor.capabilities, request.capability) {
      True -> Ok(Nil)
      False -> Error("connector_capability_not_declared")
    },
  )
  use _ <- result.try(
    case list.contains(enabled.descriptor.scopes, request.scope) {
      True -> Ok(Nil)
      False -> Error("connector_scope_not_declared")
    },
  )
  use required_grant <- result.try(case request.operation {
    "read" -> Ok(enabled.descriptor.read_authority_ref)
    "write" ->
      case enabled.descriptor.write_authority_ref {
        Some(reference) -> Ok(Some(reference))
        None -> Error("connector_write_not_allowed")
      }
    _ -> Error("invalid_connector_operation")
  })
  use _ <- result.try(case required_grant {
    None -> Ok(Nil)
    Some(reference) ->
      case list.contains(request.authority_grants, reference) {
        True -> Ok(Nil)
        False -> Error("connector_authority_required")
      }
  })
  Ok(enabled)
}

fn require_authority_grants(grants: List(String)) -> Result(Nil, String) {
  use _ <- result.try(case list.length(grants) <= 100 {
    True -> Ok(Nil)
    False -> Error("too_many_connector_authority_grants")
  })
  list.try_each(grants, fn(grant) {
    require_reference("authority_grant", grant)
  })
}

fn index_descriptors(
  remaining: List(ConnectorDescriptor),
  index: Dict(String, ConnectorDescriptor),
) -> Result(Dict(String, ConnectorDescriptor), String) {
  case remaining {
    [] -> Ok(index)
    [descriptor, ..rest] -> {
      use _ <- result.try(validate_descriptor(descriptor))
      use _ <- result.try(case dict.has_key(index, descriptor.connector_id) {
        True ->
          Error("duplicate_connector_descriptor:" <> descriptor.connector_id)
        False -> Ok(Nil)
      })
      index_descriptors(
        rest,
        dict.insert(index, descriptor.connector_id, descriptor),
      )
    }
  }
}

fn index_activations(
  remaining: List(ConnectorActivation),
  descriptors: Dict(String, ConnectorDescriptor),
  index: Dict(String, ConnectorActivation),
) -> Result(Dict(String, ConnectorActivation), String) {
  case remaining {
    [] -> Ok(index)
    [activation, ..rest] -> {
      use _ <- result.try(validate_activation(activation))
      use _ <- result.try(
        dict.get(descriptors, activation.connector_id)
        |> result.replace_error(
          "connector_activation_without_descriptor:" <> activation.connector_id,
        ),
      )
      use _ <- result.try(case dict.has_key(index, activation.connector_id) {
        True ->
          Error("duplicate_connector_activation:" <> activation.connector_id)
        False -> Ok(Nil)
      })
      index_activations(
        rest,
        descriptors,
        dict.insert(index, activation.connector_id, activation),
      )
    }
  }
}

fn validate_descriptor(descriptor: ConnectorDescriptor) -> Result(Nil, String) {
  use _ <- result.try(require_version(descriptor.schema_version))
  use _ <- result.try(require_identifier(
    "connector_id",
    descriptor.connector_id,
  ))
  use _ <- result.try(require_identifier(
    "display_name",
    descriptor.display_name,
  ))
  use _ <- result.try(
    case
      list.contains(
        ["connector", "mcp_tool", "codex", "claude"],
        descriptor.source_kind,
      )
    {
      True -> Ok(Nil)
      False -> Error("invalid_connector_source_kind")
    },
  )
  use _ <- result.try(require_nonempty_identifiers(
    "capability",
    descriptor.capabilities,
  ))
  use _ <- result.try(require_nonempty_identifiers("scope", descriptor.scopes))
  use _ <- result.try(require_reference(
    "descriptor_provenance_ref",
    descriptor.descriptor_provenance_ref,
  ))
  use _ <- result.try(require_optional_reference(descriptor.read_authority_ref))
  use _ <- result.try(require_optional_reference(descriptor.write_authority_ref))
  use _ <- result.try(require_reference(
    "policy_boundary_ref",
    descriptor.policy_boundary_ref,
  ))
  case descriptor.summary_limit > 0 && descriptor.value_limit > 0 {
    True -> Ok(Nil)
    False -> Error("invalid_connector_retention")
  }
}

fn validate_activation(activation: ConnectorActivation) -> Result(Nil, String) {
  use _ <- result.try(require_version(activation.schema_version))
  use _ <- result.try(require_identifier(
    "connector_id",
    activation.connector_id,
  ))
  use _ <- result.try(
    case
      list.contains(["configured", "enabled", "disabled"], activation.state)
    {
      True -> Ok(Nil)
      False -> Error("invalid_connector_activation_state")
    },
  )
  require_configuration_reference(activation.configuration_ref)
}

fn require_configuration_reference(value: String) -> Result(Nil, String) {
  case
    string.starts_with(value, "configuration:")
    && string.length(value) <= 1000
    && string.trim(value) == value
    && !string.contains(value, " ")
    && !string.contains(value, "\n")
    && !string.contains(value, "\r")
  {
    True -> Ok(Nil)
    False -> require_reference("configuration_ref", value)
  }
}

fn require_version(version: Int) -> Result(Nil, String) {
  case version == 1 {
    True -> Ok(Nil)
    False -> Error("unsupported_connector_schema_version")
  }
}

fn require_nonempty_identifiers(
  name: String,
  values: List(String),
) -> Result(Nil, String) {
  case values {
    [] -> Error("missing_connector_" <> name)
    _ -> list.try_each(values, fn(value) { require_identifier(name, value) })
  }
}

fn require_identifier(name: String, value: String) -> Result(Nil, String) {
  case
    value != ""
    && string.trim(value) == value
    && string.length(value) <= 256
    && !string.contains(value, "\n")
  {
    True -> Ok(Nil)
    False -> Error("invalid_connector_" <> name)
  }
}

fn require_optional_reference(value: Option(String)) -> Result(Nil, String) {
  case value {
    None -> Ok(Nil)
    Some(reference) -> require_reference("authority_ref", reference)
  }
}

fn require_reference(name: String, value: String) -> Result(Nil, String) {
  case
    value != ""
    && string.length(value) <= 1000
    && string.contains(value, "://")
    && !string.contains(value, " ")
    && !string.contains(value, "\n")
  {
    True -> Ok(Nil)
    False -> Error("invalid_connector_" <> name)
  }
}
