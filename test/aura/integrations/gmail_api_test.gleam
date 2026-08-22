import aura/integrations/gmail_api
import aura/operating_contracts
import gleam/dict
import gleam/string
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

pub fn metadata_only_message_becomes_compact_gmail_evidence_test() {
  let result =
    gmail_api.metadata_to_result(gmail_api.MetadataMessage(
      message_id: "message-1",
      thread_id: "thread-1",
      history_id: "42",
      internal_date_ms: 1,
      label_ids: ["INBOX"],
      size_estimate: 128,
      subject: "Compact subject",
      from: "Example Person <person@example.test>",
    ))
    |> should.be_ok
  result.connector_id |> should.equal("gmail")
  result.capability |> should.equal("mail.read")
  result.scope |> should.equal("https://www.googleapis.com/auth/gmail.readonly")
  result.raw_ref |> should.equal("gmail://message/message-1")
  dict.get(result.normalized_data, "body") |> should.equal(Error(Nil))
  dict.get(result.normalized_data, "attachment") |> should.equal(Error(Nil))
  result.candidate_domain_refs |> should.equal([])
  result.candidate_concern_refs |> should.equal([])
  dict.get(result.normalized_data, "from")
  |> should.equal(
    Ok(operating_contracts.StructuredString("sender@example.test")),
  )
}

pub fn metadata_rejects_unbounded_subject_test() {
  gmail_api.metadata_to_result(gmail_api.MetadataMessage(
    message_id: "message-1",
    thread_id: "thread-1",
    history_id: "42",
    internal_date_ms: 1,
    label_ids: ["INBOX"],
    size_estimate: 128,
    subject: string.repeat("x", 513),
    from: "person@example.test",
  ))
  |> should.equal(Error("gmail_metadata_subject_too_large"))

  gmail_api.metadata_to_result(gmail_api.MetadataMessage(
    message_id: "message-1",
    thread_id: "thread-1",
    history_id: "42",
    internal_date_ms: 1,
    label_ids: string.repeat("label,", 101) |> string.split(","),
    size_estimate: 128,
    subject: "subject",
    from: "person@example.test",
  ))
  |> should.equal(Error("gmail_metadata_invalid"))
}

pub fn profile_seeds_only_an_opaque_checkpoint_test() {
  let seed =
    gmail_api.profile_seed(
      gmail_api.Profile("person@example.test", "42"),
      string.repeat("k", 32),
    )
    |> should.be_ok
  string.length(seed.account_fingerprint) |> should.equal(64)
  string.contains(seed.account_fingerprint, "person") |> should.be_false
  seed.history_id |> should.equal("42")
  string.contains(seed.proof_hash, "person") |> should.be_false
}

pub fn history_pages_are_bounded_and_deduplicated_test() {
  gmail_api.collect_history(
    [
      gmail_api.HistoryPage(["message-1", "message-2"], "101", "page-2"),
      gmail_api.HistoryPage(["message-2", "message-3"], "102", ""),
    ],
    2,
    3,
  )
  |> should.equal(Ok(["message-1", "message-2", "message-3"]))

  gmail_api.collect_history(
    [gmail_api.HistoryPage(["message-1", "message-2"], "102", "")],
    1,
    1,
  )
  |> should.equal(Error("gmail_history_item_limit_exceeded"))
}

pub fn history_gap_requires_reseed_and_creates_no_evidence_test() {
  gmail_api.history_gap("checkpoint-expired")
  |> should.equal(
    Ok(gmail_api.CaptureGap(
      reason_code: "checkpoint-expired",
      reauthorization_required: True,
    )),
  )
}

pub fn injected_executor_composes_validation_normalization_and_submission_test() {
  let message = fixture_message()
  let url =
    "https://gmail.googleapis.com/gmail/v1/users/me/messages/message-1?format=metadata&metadataHeaders=Subject&metadataHeaders=From&metadataHeaders=Date&fields=id%2CthreadId%2ClabelIds%2ChistoryId%2CinternalDate%2CsizeEstimate%2Cpayload%28headers%29"
  gmail_api.execute_metadata_with(url, fn(_) { Ok(message) }, fn(selected) {
    gmail_api.metadata_to_result(selected)
  })
  |> should.be_ok

  gmail_api.execute_metadata_with(
    "https://gmail.googleapis.com/gmail/v1/users/me/messages/message-1?format=full",
    fn(_) { Error("transport_must_not_run") },
    fn(_) { Error("submitter_must_not_run") },
  )
  |> should.equal(Error("google_readonly_query_not_allowed"))
}

pub fn injected_profile_and_history_executor_stays_bounded_test() {
  gmail_api.execute_profile(
    "https://gmail.googleapis.com/gmail/v1/users/me/profile?fields=emailAddress%2ChistoryId",
    string.repeat("k", 32),
    fn(_) { Ok(gmail_api.Profile("person@example.test", "42")) },
  )
  |> should.be_ok

  gmail_api.execute_profile(
    "https://gmail.googleapis.com/gmail/v1/users/me/profile?fields=emailAddress%2ChistoryId",
    "weak-key",
    fn(_) { Ok(gmail_api.Profile("person@example.test", "42")) },
  )
  |> should.equal(Error("gmail_profile_invalid"))

  gmail_api.execute_history(
    "https://gmail.googleapis.com/gmail/v1/users/me/history?startHistoryId=1&historyTypes=messageAdded&maxResults=100&fields=history%28messagesAdded%28message%28id%2CthreadId%2ClabelIds%2ChistoryId%29%29%29%2CnextPageToken%2ChistoryId",
    1,
    2,
    fn(_) {
      Ok(
        gmail_api.HistoryPages([
          gmail_api.HistoryPage(["message-1", "message-1"], "102", ""),
        ]),
      )
    },
  )
  |> should.equal(Ok(gmail_api.SelectedMessageIds(["message-1"])))
}

pub fn provider_json_projection_rejects_unapproved_content_test() {
  gmail_api.decode_profile_response(
    "{\"emailAddress\":\"person@example.test\",\"historyId\":\"42\"}",
  )
  |> should.be_ok
  gmail_api.decode_history_page_response(
    "{\"history\":[{\"messagesAdded\":[{\"message\":{\"id\":\"m1\",\"threadId\":\"t1\",\"labelIds\":[\"INBOX\"],\"historyId\":\"43\"}}]}],\"historyId\":\"44\"}",
  )
  |> should.equal(Ok(gmail_api.HistoryPage(["m1"], "44", "")))
  gmail_api.decode_metadata_response(
    "{\"id\":\"m1\",\"threadId\":\"t1\",\"labelIds\":[\"INBOX\"],\"historyId\":\"44\",\"internalDate\":\"1000\",\"sizeEstimate\":42,\"payload\":{\"headers\":[{\"name\":\"Subject\",\"value\":\"Subject\"},{\"name\":\"From\",\"value\":\"Person <person@example.test>\"},{\"name\":\"Date\",\"value\":\"ignored\"}]}}",
  )
  |> should.be_ok
  gmail_api.decode_metadata_response(
    "{\"id\":\"m1\",\"threadId\":\"t1\",\"historyId\":\"44\",\"internalDate\":\"1000\",\"sizeEstimate\":42,\"raw\":\"forbidden\",\"payload\":{\"headers\":[]}}",
  )
  |> should.equal(Error("gmail_metadata_response_fields_invalid"))
  gmail_api.decode_metadata_response(
    "{\"id\":\"m1\",\"threadId\":\"t1\",\"historyId\":\"44\",\"internalDate\":\"1000\",\"sizeEstimate\":42,\"payload\":{\"body\":{\"data\":\"forbidden\"},\"headers\":[]}}",
  )
  |> should.equal(Error("gmail_metadata_response_fields_invalid"))
}

fn fixture_message() -> gmail_api.MetadataMessage {
  gmail_api.MetadataMessage(
    message_id: "message-1",
    thread_id: "thread-1",
    history_id: "42",
    internal_date_ms: 1,
    label_ids: ["INBOX"],
    size_estimate: 128,
    subject: "Compact subject",
    from: "Example Person <person@example.test>",
  )
}
