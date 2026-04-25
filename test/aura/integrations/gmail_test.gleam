import aura/event
import aura/imap
import aura/integrations/gmail
import aura/oauth
import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleeunit/should

fn sample_config() -> gmail.GmailConfig {
  gmail.GmailConfig(
    name: "gmail-work",
    user_email: "alice@example.com",
    oauth: oauth.OAuthConfig(
      client_id: "cid",
      client_secret: "secret",
      token_endpoint: "https://oauth2.googleapis.com/token",
    ),
    token_path: "/tmp/aura-gmail-test-token.json",
  )
}

fn sample_envelope() -> imap.Envelope {
  imap.Envelope(
    uid: 100,
    message_id: "<msg-xyz@acme.com>",
    from: "alice@acme.com",
    to: "bob@x.com",
    subject: "Re: Q4 terms",
    date: "Wed, 22 Apr 2026 14:30:00 +0000",
  )
}

pub fn envelope_to_event_sets_source_and_type_test() {
  let config = sample_config()
  let env = sample_envelope()
  let ae =
    gmail.envelope_to_event(
      config,
      env,
      "Please review REL-42",
      1_776_880_000_000,
    )
  ae.source |> should.equal("gmail-work")
  ae.type_ |> should.equal("email.received")
}

pub fn envelope_to_event_uses_message_id_as_dedup_key_test() {
  let config = sample_config()
  let env = sample_envelope()
  let ae =
    gmail.envelope_to_event(
      config,
      env,
      "Please review REL-42",
      1_776_880_000_000,
    )
  ae.external_id |> should.equal("<msg-xyz@acme.com>")
  ae.id |> should.equal("<msg-xyz@acme.com>")
}

pub fn envelope_to_event_subject_is_email_subject_test() {
  let config = sample_config()
  let env = sample_envelope()
  let ae =
    gmail.envelope_to_event(
      config,
      env,
      "Please review REL-42",
      1_776_880_000_000,
    )
  ae.subject |> should.equal("Re: Q4 terms")
}

pub fn envelope_to_event_passes_now_ms_through_test() {
  let config = sample_config()
  let env = sample_envelope()
  let ae =
    gmail.envelope_to_event(
      config,
      env,
      "Please review REL-42",
      1_776_880_000_000,
    )
  ae.time_ms |> should.equal(1_776_880_000_000)
}

pub fn envelope_to_event_starts_with_empty_tags_test() {
  // Tagger enriches downstream; integration doesn't pre-populate.
  let config = sample_config()
  let env = sample_envelope()
  let ae = gmail.envelope_to_event(config, env, "Please review REL-42", 0)
  dict.size(ae.tags) |> should.equal(0)
}

pub fn envelope_to_json_round_trip_test() {
  let env = sample_envelope()
  let raw = gmail.envelope_to_json(env, "Please review REL-42 tomorrow")
  let decoder = {
    use from <- decode.field("from", decode.string)
    use to <- decode.field("to", decode.string)
    use subject <- decode.field("subject", decode.string)
    use body_text <- decode.field("body_text", decode.string)
    use message_id <- decode.field("message_id", decode.string)
    use thread_id <- decode.field("thread_id", decode.string)
    use uid <- decode.field("uid", decode.int)
    decode.success(#(from, to, subject, body_text, message_id, thread_id, uid))
  }
  let assert Ok(#(f, t, s, body, m, th, u)) = json.parse(raw, decoder)
  f |> should.equal("alice@acme.com")
  t |> should.equal("bob@x.com")
  s |> should.equal("Re: Q4 terms")
  body |> should.equal("Please review REL-42 tomorrow")
  m |> should.equal("<msg-xyz@acme.com>")
  // Thread id falls back to message id in phase 1.5.
  th |> should.equal("<msg-xyz@acme.com>")
  u |> should.equal(100)
}

pub fn envelope_to_event_data_carries_full_envelope_test() {
  // event.data should be parseable back to all envelope fields.
  let config = sample_config()
  let env = sample_envelope()
  let ae: event.AuraEvent =
    gmail.envelope_to_event(config, env, "Please review REL-42 tomorrow", 0)
  let decoder = {
    use subject <- decode.field("subject", decode.string)
    use body_text <- decode.field("body_text", decode.string)
    decode.success(#(subject, body_text))
  }
  let assert Ok(#(subject, body_text)) = json.parse(ae.data, decoder)
  subject |> should.equal("Re: Q4 terms")
  body_text |> should.equal("Please review REL-42 tomorrow")
}
