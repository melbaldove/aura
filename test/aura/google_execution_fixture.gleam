import aura/db
import aura/operating_contracts
import gleam/bit_array
import gleam/crypto
import gleam/erlang/process
import gleam/list
import gleam/result
import gleam/string

/// Store successful synthetic OAuth and identity proofs for one authorization.
/// Tests call this before they create the immutable final authorization.
pub fn seed_authorization_proofs(
  subject: process.Subject(db.DbMessage),
  preparation: operating_contracts.CanaryPreparationAuthorizationV1,
  authorization: operating_contracts.CanaryAuthorizationV1,
) -> Result(Nil, String) {
  use _ <- result.try(register_client_set(subject, preparation))
  authorization.connectors
  |> list.try_each(fn(connector) {
    let client_ref = "oauth-client:fixture:" <> connector.connector_id
    let client_hash = hash("oauth-client:" <> connector.connector_id)
    let oauth =
      effect(
        preparation,
        connector,
        client_ref,
        client_hash,
        "oauth_exchange",
        "oauth:" <> connector.oauth_proof_ref,
        connector.oauth_proof_ref,
      )
    use _ <- result.try(db.begin_google_external_effect(subject, oauth))
    use _ <- result.try(db.finish_google_external_effect(
      subject,
      oauth.effect_id,
      "succeeded",
      connector.oauth_proof_ref,
      "",
      hash("oauth-result:" <> connector.connector_id),
      "",
    ))
    let identity =
      effect(
        preparation,
        connector,
        client_ref,
        client_hash,
        "identity_read",
        "identity:" <> connector.identity_proof_ref,
        connector.identity_proof_ref,
      )
    use _ <- result.try(db.begin_google_external_effect(subject, identity))
    use _ <- result.try(db.finish_google_external_effect(
      subject,
      identity.effect_id,
      "succeeded",
      connector.identity_proof_ref,
      connector.account_fingerprint,
      hash("identity-result:" <> connector.connector_id),
      "",
    ))
    Ok(Nil)
  })
}

/// Register the secret-free client-set binding used by Google execution tests.
pub fn register_client_set(
  subject: process.Subject(db.DbMessage),
  preparation: operating_contracts.CanaryPreparationAuthorizationV1,
) -> Result(db.GoogleOAuthClientSet, String) {
  db.register_google_oauth_client_set(
    subject,
    db.GoogleOAuthClientSet(
      client_set_ref: preparation.oauth_client_ref,
      client_set_hash: preparation.oauth_client_hash,
      gmail_client_ref: "oauth-client:fixture:gmail",
      gmail_client_hash: hash("oauth-client:gmail"),
      calendar_client_ref: "oauth-client:fixture:calendar",
      calendar_client_hash: hash("oauth-client:calendar"),
    ),
  )
}

fn effect(
  preparation: operating_contracts.CanaryPreparationAuthorizationV1,
  connector: operating_contracts.AuthorizedConnectorV1,
  client_ref: String,
  client_hash: String,
  effect_kind: String,
  effect_id: String,
  logical_key: String,
) -> db.GoogleExternalEffect {
  db.GoogleExternalEffect(
    effect_id:,
    preparation_authorization_id: preparation.authorization_id,
    authorization_id: "",
    activation_id: "",
    configuration_ref: connector.configuration_ref,
    configuration_hash: connector.configuration_hash,
    connector_id: connector.connector_id,
    oauth_client_ref: client_ref,
    oauth_client_hash: client_hash,
    client_set_ref: preparation.oauth_client_ref,
    client_set_hash: preparation.oauth_client_hash,
    effect_kind:,
    logical_effect_key: logical_key,
    attempt_number: 1,
    request_hash: hash(effect_id),
    phase: "intent",
    proof_ref: "",
    oauth_scope: connector.oauth_scope,
    account_fingerprint: "",
    result_hash: "",
    error_class: "",
  )
}

fn hash(value: String) -> String {
  crypto.hash(crypto.Sha256, <<value:utf8>>)
  |> bit_array.base16_encode
  |> string.lowercase
}
