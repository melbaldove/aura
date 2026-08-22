import aura/config
import aura/connector_runtime
import aura/db
import gleam/erlang/process
import gleam/list
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

pub fn disabled_or_missing_persisted_activation_starts_no_runtime_test() {
  let assert Ok(subject) = db.start(":memory:")
  let first = connector_runtime.load(subject, configurations()) |> should.be_ok
  connector_runtime.activation_ids(first) |> should.equal([])
  let second = connector_runtime.load(subject, configurations()) |> should.be_ok
  connector_runtime.activation_ids(second) |> should.equal([])
}

pub fn runtime_does_not_treat_configuration_as_activation_test() {
  let assert Ok(subject) = db.start(":memory:")
  let runtime =
    connector_runtime.load(subject, configurations()) |> should.be_ok
  connector_runtime.activation_ids(runtime) |> should.equal([])
  configurations()
  |> list.map(fn(configuration) { configuration.connector_id })
  |> should.equal(["gmail", "calendar"])
}

pub fn supervised_runtime_starts_without_a_provider_session_test() {
  let assert Ok(subject) = db.start(":memory:")
  let name = process.new_name("connector_runtime_test")
  let started =
    connector_runtime.start_named(name, subject, configurations())
    |> should.be_ok
  let assert Ok(pid) = process.subject_owner(started.data)
  process.unlink(pid)
  process.kill(pid)
  process.send(subject, db.Shutdown)
}

fn configurations() -> List(config.ConnectorConfiguration) {
  [
    config.ConnectorConfiguration(
      configuration_ref: "configuration:gmail-runtime",
      connector_id: "gmail",
      oauth_client_ref: "oauth-client:runtime",
      credential_ref: "credential:runtime",
      resource_ref: "resource:runtime",
      oauth_scope: "https://www.googleapis.com/auth/gmail.readonly",
      configuration_hash: config.connector_configuration_hash(
        "configuration:gmail-runtime",
        "gmail",
        "oauth-client:runtime",
        "credential:runtime",
        "resource:runtime",
        "https://www.googleapis.com/auth/gmail.readonly",
      ),
    ),
    config.ConnectorConfiguration(
      configuration_ref: "configuration:calendar-runtime",
      connector_id: "calendar",
      oauth_client_ref: "oauth-client:runtime",
      credential_ref: "credential:runtime",
      resource_ref: "resource:runtime",
      oauth_scope: "https://www.googleapis.com/auth/calendar.readonly",
      configuration_hash: config.connector_configuration_hash(
        "configuration:calendar-runtime",
        "calendar",
        "oauth-client:runtime",
        "credential:runtime",
        "resource:runtime",
        "https://www.googleapis.com/auth/calendar.readonly",
      ),
    ),
  ]
}
