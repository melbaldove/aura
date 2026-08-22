import aura/connector_registry
import gleam/list
import gleam/option.{None, Some}
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

fn descriptor(connector_id: String, source_kind: String) {
  connector_registry.ConnectorDescriptor(
    schema_version: 1,
    connector_id: connector_id,
    display_name: connector_id,
    source_kind: source_kind,
    capabilities: ["resource.read", "resource.write"],
    scopes: ["fixture.records"],
    descriptor_provenance_ref: "descriptor://fixture/" <> connector_id,
    summary_limit: 300,
    value_limit: 1000,
    read_authority_ref: None,
    write_authority_ref: Some(
      "authority://fixture/" <> connector_id <> "/write",
    ),
    policy_boundary_ref: "policy://attention/default",
  )
}

fn activation(connector_id: String, state: String) {
  connector_registry.ConnectorActivation(
    schema_version: 1,
    connector_id: connector_id,
    state: state,
    configuration_ref: "config://fixture/" <> connector_id,
  )
}

pub fn named_adapter_descriptors_are_data_driven_and_valid_test() {
  let fixtures = [
    #("gmail", "connector"),
    #("calendar", "connector"),
    #("slack", "connector"),
    #("jira", "connector"),
    #("github", "connector"),
    #("codex", "codex"),
    #("claude", "claude"),
    #("mcp", "mcp_tool"),
  ]
  let registry =
    connector_registry.build(
      list.map(fixtures, fn(item) { descriptor(item.0, item.1) }),
      list.map(fixtures, fn(item) { activation(item.0, "enabled") }),
    )
    |> should.be_ok

  fixtures
  |> list.each(fn(item) {
    let found =
      connector_registry.lookup_enabled(registry, item.0) |> should.be_ok
    found.descriptor.source_kind |> should.equal(item.1)
  })
}

pub fn authorization_configuration_reference_is_valid_registry_lineage_test() {
  connector_registry.build([descriptor("calendar", "connector")], [
    connector_registry.ConnectorActivation(
      schema_version: 1,
      connector_id: "calendar",
      state: "enabled",
      configuration_ref: "configuration:calendar-readonly",
    ),
  ])
  |> should.be_ok
}

pub fn installed_or_configured_connector_is_not_enabled_test() {
  let installed = [descriptor("calendar", "connector")]
  let installed_only = connector_registry.build(installed, []) |> should.be_ok
  connector_registry.lookup_enabled(installed_only, "calendar")
  |> should.equal(Error("connector_not_enabled:calendar"))

  let configured =
    connector_registry.build(installed, [activation("calendar", "configured")])
    |> should.be_ok
  connector_registry.lookup_enabled(configured, "calendar")
  |> should.equal(Error("connector_not_enabled:calendar"))
  connector_registry.lookup_enabled(configured, "unknown")
  |> should.equal(Error("connector_unconfigured:unknown"))
}

pub fn health_cannot_enable_a_connector_test() {
  let registry =
    connector_registry.build([descriptor("slack", "connector")], [
      activation("slack", "configured"),
    ])
    |> should.be_ok
  let updated =
    connector_registry.update_health(
      registry,
      connector_registry.ConnectorHealth(
        connector_id: "slack",
        status: "healthy",
        error_code: None,
        checked_at: 1000,
      ),
    )
    |> should.be_ok
  connector_registry.get_health(updated, "slack")
  |> should.equal(
    Ok(
      Some(connector_registry.ConnectorHealth(
        connector_id: "slack",
        status: "healthy",
        error_code: None,
        checked_at: 1000,
      )),
    ),
  )
  connector_registry.lookup_enabled(updated, "slack")
  |> should.equal(Error("connector_not_enabled:slack"))
}

pub fn health_rejects_free_text_error_content_test() {
  let registry =
    connector_registry.build([descriptor("slack", "connector")], [])
    |> should.be_ok
  connector_registry.update_health(
    registry,
    connector_registry.ConnectorHealth(
      connector_id: "slack",
      status: "unavailable",
      error_code: Some("copied failure conversation"),
      checked_at: 1000,
    ),
  )
  |> should.equal(Error("invalid_connector_error_code"))
}

pub fn write_request_requires_the_exact_explicit_authority_test() {
  let registry =
    connector_registry.build([descriptor("github", "connector")], [
      activation("github", "enabled"),
    ])
    |> should.be_ok
  let request =
    connector_registry.ConnectorActionRequest(
      schema_version: 1,
      request_id: "request-1",
      connector_id: "github",
      capability: "resource.write",
      scope: "fixture.records",
      operation: "write",
      resource_ref: "opaque://fixture/resource/1",
      authority_grants: [],
    )
  connector_registry.validate_action(registry, request)
  |> should.equal(Error("connector_authority_required"))
  connector_registry.validate_action(
    registry,
    connector_registry.ConnectorActionRequest(..request, authority_grants: [
      "authority://fixture/github/write",
    ]),
  )
  |> should.be_ok
}
