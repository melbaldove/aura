import aura/imap
import gleam/bit_array
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// parse_response_line
// ---------------------------------------------------------------------------

pub fn parse_tagged_ok_test() {
  let line = "a001 OK LOGIN completed\r\n"
  imap.parse_response_line(line)
  |> should.equal(Ok(imap.Tagged("a001", imap.StatusOk, "LOGIN completed")))
}

pub fn parse_tagged_no_test() {
  let line = "a002 NO [AUTHENTICATIONFAILED] Invalid credentials\r\n"
  imap.parse_response_line(line)
  |> should.equal(
    Ok(imap.Tagged(
      "a002",
      imap.StatusNo,
      "[AUTHENTICATIONFAILED] Invalid credentials",
    )),
  )
}

pub fn parse_tagged_bad_test() {
  let line = "a003 BAD Unknown command\r\n"
  imap.parse_response_line(line)
  |> should.equal(Ok(imap.Tagged("a003", imap.StatusBad, "Unknown command")))
}

pub fn parse_untagged_exists_test() {
  let line = "* 1847 EXISTS\r\n"
  imap.parse_response_line(line)
  |> should.equal(Ok(imap.Untagged("1847 EXISTS")))
}

pub fn parse_untagged_expunge_test() {
  let line = "* 1847 EXPUNGE\r\n"
  imap.parse_response_line(line)
  |> should.equal(Ok(imap.Untagged("1847 EXPUNGE")))
}

pub fn parse_continuation_test() {
  let line = "+ idling\r\n"
  imap.parse_response_line(line)
  |> should.equal(Ok(imap.Continuation("idling")))
}

pub fn parse_continuation_bare_test() {
  let line = "+\r\n"
  imap.parse_response_line(line)
  |> should.equal(Ok(imap.Continuation("")))
}

pub fn parse_empty_line_error_test() {
  imap.parse_response_line("")
  |> should.be_error
}

pub fn parse_tagged_without_status_error_test() {
  let line = "a001 GARBAGE\r\n"
  imap.parse_response_line(line)
  |> should.be_error
}

// ---------------------------------------------------------------------------
// xoauth2_auth_string
// ---------------------------------------------------------------------------

pub fn xoauth2_auth_string_construction_test() {
  let s = imap.xoauth2_auth_string("alice@gmail.com", "ya29.FAKE")
  // Expected bytes: "user=alice@gmail.com\x01auth=Bearer ya29.FAKE\x01\x01"
  let expected =
    bit_array.concat([
      <<"user=alice@gmail.com":utf8>>,
      <<0x01>>,
      <<"auth=Bearer ya29.FAKE":utf8>>,
      <<0x01, 0x01>>,
    ])
  bit_array.from_string(s)
  |> should.equal(expected)
}

// ---------------------------------------------------------------------------
// SELECT response parsing
// ---------------------------------------------------------------------------

pub fn parse_exists_count_test() {
  imap.parse_exists_count("1847 EXISTS")
  |> should.equal(Ok(1847))
}

pub fn parse_exists_count_zero_test() {
  imap.parse_exists_count("0 EXISTS")
  |> should.equal(Ok(0))
}

pub fn parse_exists_count_malformed_test() {
  imap.parse_exists_count("EXISTS")
  |> should.be_error
}

pub fn parse_resp_code_uidvalidity_test() {
  imap.parse_resp_code_int("OK [UIDVALIDITY 1234567] UIDs valid", "UIDVALIDITY")
  |> should.equal(Ok(1_234_567))
}

pub fn parse_resp_code_uidnext_test() {
  imap.parse_resp_code_int("OK [UIDNEXT 1848] Predicted next UID", "UIDNEXT")
  |> should.equal(Ok(1848))
}

pub fn parse_resp_code_missing_test() {
  imap.parse_resp_code_int("OK nothing here", "UIDNEXT")
  |> should.be_error
}

// ---------------------------------------------------------------------------
// FETCH envelope
// ---------------------------------------------------------------------------

pub fn parse_envelope_gmail_fixture_test() {
  let raw =
    "* 42 FETCH (ENVELOPE (\"Wed, 22 Apr 2026 14:30:00 +0000\" \"Re: Q4 terms\" ((\"Alice\" NIL \"alice\" \"acme.com\")) ((\"Alice\" NIL \"alice\" \"acme.com\")) ((\"Alice\" NIL \"alice\" \"acme.com\")) ((\"Bob\" NIL \"bob\" \"x.com\")) NIL NIL NIL \"<msg-xyz@acme.com>\") UID 100)"
  let env = imap.parse_envelope_fetch(raw)
  env |> should.be_ok
  let assert Ok(e) = env
  e.uid |> should.equal(100)
  e.message_id |> should.equal("<msg-xyz@acme.com>")
  e.subject |> should.equal("Re: Q4 terms")
  e.date |> should.equal("Wed, 22 Apr 2026 14:30:00 +0000")
  e.from |> should.equal("alice@acme.com")
  e.to |> should.equal("bob@x.com")
}

pub fn parse_envelope_nil_fields_test() {
  // NIL subject, NIL date, NIL to. Real-world: bounce messages, drafts.
  let raw =
    "* 1 FETCH (ENVELOPE (NIL NIL ((\"A\" NIL \"a\" \"x.com\")) ((\"A\" NIL \"a\" \"x.com\")) ((\"A\" NIL \"a\" \"x.com\")) NIL NIL NIL NIL \"<m@x.com>\") UID 7)"
  let env = imap.parse_envelope_fetch(raw)
  env |> should.be_ok
  let assert Ok(e) = env
  e.uid |> should.equal(7)
  e.message_id |> should.equal("<m@x.com>")
  e.subject |> should.equal("")
  e.date |> should.equal("")
  e.from |> should.equal("a@x.com")
  e.to |> should.equal("")
}

pub fn parse_envelope_malformed_test() {
  imap.parse_envelope_fetch("* 42 FETCH (garbage)")
  |> should.be_error
}

pub fn parse_envelope_uid_first_test() {
  // RFC 3501 §7.4.2: server may return FETCH attrs in any order. Gmail
  // in practice returns UID before ENVELOPE even when the client requests
  // (ENVELOPE UID).
  let raw =
    "* 42 FETCH (UID 100 ENVELOPE (\"Wed, 22 Apr 2026 14:30:00 +0000\" \"Re: Q4 terms\" ((\"Alice\" NIL \"alice\" \"acme.com\")) ((\"Alice\" NIL \"alice\" \"acme.com\")) ((\"Alice\" NIL \"alice\" \"acme.com\")) ((\"Bob\" NIL \"bob\" \"x.com\")) NIL NIL NIL \"<msg-xyz@acme.com>\"))"
  let env = imap.parse_envelope_fetch(raw)
  env |> should.be_ok
  let assert Ok(e) = env
  e.uid |> should.equal(100)
  e.subject |> should.equal("Re: Q4 terms")
  e.from |> should.equal("alice@acme.com")
}

pub fn parse_body_text_fetch_fixture_test() {
  let raw =
    "* 42 FETCH (BODY[TEXT]<0> {43}\r\nAURA cognitive smoke test: Please review REL-42 tomorrow\r\n)\r\na123 OK Success\r\n"

  let body = imap.parse_body_text_fetch(raw)

  body
  |> should.equal(Ok("AURA cognitive smoke test: Please review REL-42 tomorrow"))
}
