import aura/db
import aura/google_execution_fixture
import aura/operating_contracts
import gleam/list
import gleam/result
import gleam/string
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

pub fn preparation_authorization_is_immutable_and_audited_test() {
  let assert Ok(subject) = db.start(":memory:")
  let value = preparation_authorization()
  let assert Ok(first) =
    db.create_canary_preparation_authorization(subject, value)

  db.create_canary_preparation_authorization(subject, value)
  |> should.equal(Ok(first))
  db.create_canary_preparation_authorization(
    subject,
    operating_contracts.CanaryPreparationAuthorizationV1(
      ..value,
      oauth_client_hash: hash("b"),
    ),
  )
  |> should.equal(Error("idempotency_conflict"))
  db.list_operational_audit(
    subject,
    "canary_preparation_authorization",
    value.authorization_id,
  )
  |> result.map(list.length)
  |> should.equal(Ok(1))
}

pub fn final_authorization_requires_preparation_and_is_immutable_test() {
  let assert Ok(subject) = db.start(":memory:")
  let final = canary_authorization()

  db.create_canary_authorization(subject, final)
  |> should.equal(Error("preparation_authorization_not_found"))

  let preparation = preparation_authorization()
  let assert Ok(_) =
    db.create_canary_preparation_authorization(subject, preparation)
  db.create_canary_authorization(subject, final)
  |> should.equal(Error("canary_connector_proof_not_found"))
  let assert Ok(_) =
    google_execution_fixture.seed_authorization_proofs(
      subject,
      preparation,
      final,
    )
  let assert Ok(first) = db.create_canary_authorization(subject, final)

  db.create_canary_authorization(
    subject,
    operating_contracts.CanaryAuthorizationV1(
      ..final,
      authorization_id: "authorization:canary-other-test",
      canary_id: "canary:other",
    ),
  )
  |> should.equal(Error("preparation_authorization_mismatch"))

  db.create_canary_authorization(subject, final)
  |> should.equal(Ok(first))
  db.create_canary_authorization(
    subject,
    operating_contracts.CanaryAuthorizationV1(
      ..final,
      monitor_prompt_hash: hash("f"),
    ),
  )
  |> should.equal(Error("idempotency_conflict"))
  db.list_operational_audit(
    subject,
    "canary_authorization",
    final.authorization_id,
  )
  |> result.map(list.length)
  |> should.equal(Ok(1))
}

fn preparation_authorization() -> operating_contracts.CanaryPreparationAuthorizationV1 {
  operating_contracts.CanaryPreparationAuthorizationV1(
    schema_version: 1,
    authorization_id: "authorization:preparation-test",
    canary_id: "canary:local-test",
    oauth_client_ref: "oauth-client:local-test",
    oauth_client_hash: hash("a"),
    connectors: [
      operating_contracts.PreparationConnectorV1(
        connector_id: "calendar",
        configuration_ref: "configuration:calendar-local-test",
        oauth_scope: "https://www.googleapis.com/auth/calendar.readonly",
        identity_endpoint_id: "calendar.calendars.get",
      ),
      operating_contracts.PreparationConnectorV1(
        connector_id: "gmail",
        configuration_ref: "configuration:gmail-local-test",
        oauth_scope: "https://www.googleapis.com/auth/gmail.readonly",
        identity_endpoint_id: "gmail.users.getProfile",
      ),
    ],
    grants: ["connector.identity.read", "oauth.authorize"],
    expires_at_ms: 9_999_999_999_999,
    authorized_by_ref: "operator:reviewer",
  )
}

fn canary_authorization() -> operating_contracts.CanaryAuthorizationV1 {
  operating_contracts.CanaryAuthorizationV1(
    schema_version: 1,
    authorization_id: "authorization:canary-test",
    preparation_authorization_id: "authorization:preparation-test",
    canary_id: "canary:local-test",
    domain_id: "domain:local-test",
    concern_id: "concern:domain:local-test:awareness",
    policy_refs: ["policy:canary:local-test"],
    connectors: [
      connector("calendar", "activation:calendar-test"),
      connector("gmail", "activation:gmail-test"),
    ],
    activation_grants: ["connector.disable", "connector.enable"],
    monitor_id: "monitor:local-test",
    monitor_capability_hash: hash("b"),
    monitor_runtime_ref: "runtime:codex-monitor-local-test",
    monitor_prompt_hash: hash("c"),
    monitor_interval_ms: 60_000,
    monitor_grants: ["attention.claim", "attention.read"],
    attention_owner: "codex",
    attention_target: "codex_monitor",
    discord_delivery_allowed: False,
    starts_at_ms: 0,
    ends_at_ms: 9_999_999_999_999,
    metric_ids: ["metric:evidence-captured"],
    metric_review_owner_ref: "operator:metrics-reviewer",
    authorized_by_ref: "operator:reviewer",
    rollback_owner_ref: "operator:rollback-owner",
  )
}

fn connector(
  connector_id: String,
  activation_id: String,
) -> operating_contracts.AuthorizedConnectorV1 {
  operating_contracts.AuthorizedConnectorV1(
    connector_id:,
    activation_id:,
    configuration_ref: "configuration:" <> connector_id <> "-local-test",
    configuration_hash: hash("d"),
    account_fingerprint: hash("e"),
    oauth_proof_ref: "proof:" <> connector_id <> "-oauth",
    identity_proof_ref: "proof:" <> connector_id <> "-identity",
    oauth_scope: "https://www.googleapis.com/auth/"
      <> connector_id
      <> ".readonly",
    capability: "read",
    retention_policy_ref: "retention:" <> connector_id <> "-compact",
    poll_interval_ms: 60_000,
    max_pages_per_poll: 1,
    max_items_per_poll: 10,
    max_response_bytes: 4096,
  )
}

fn hash(character: String) -> String {
  string.repeat(character, 64)
}
