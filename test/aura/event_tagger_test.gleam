import aura/event_tagger
import gleam/dict
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// Gmail
// ---------------------------------------------------------------------------

pub fn tag_gmail_received_extracts_from_and_thread_test() {
  let data =
    "{\"from\":\"alice@example.com\",\"to\":\"bob@example.com\","
    <> "\"thread_id\":\"thread-123\",\"subject\":\"Lunch tomorrow?\"}"

  let tags = event_tagger.tag("gmail", "email.received", data)

  should.equal(dict.get(tags, "from"), Ok("alice@example.com"))
  should.equal(dict.get(tags, "to"), Ok("bob@example.com"))
  should.equal(dict.get(tags, "thread_id"), Ok("thread-123"))
  should.equal(dict.get(tags, "subject_line"), Ok("Lunch tomorrow?"))
}

pub fn tag_gmail_variant_source_test() {
  let data =
    "{\"from\":\"alice@example.com\",\"to\":\"bob@example.com\","
    <> "\"thread_id\":\"thread-123\",\"subject\":\"Hi\"}"

  let tags_base = event_tagger.tag("gmail", "email.received", data)
  let tags_work = event_tagger.tag("gmail-work", "email.received", data)

  should.equal(tags_base, tags_work)
  should.equal(dict.get(tags_work, "from"), Ok("alice@example.com"))
  should.equal(dict.get(tags_work, "thread_id"), Ok("thread-123"))
}

pub fn tag_gmail_missing_fields_partial_test() {
  let data = "{\"from\":\"alice@example.com\"}"

  let tags = event_tagger.tag("gmail", "email.received", data)

  should.equal(dict.get(tags, "from"), Ok("alice@example.com"))
  should.equal(dict.get(tags, "thread_id"), Error(Nil))
  should.equal(dict.get(tags, "to"), Error(Nil))
  should.equal(dict.get(tags, "subject_line"), Error(Nil))
}

// ---------------------------------------------------------------------------
// Linear
// ---------------------------------------------------------------------------

pub fn tag_linear_issue_commented_extracts_ticket_and_author_test() {
  let data =
    "{\"issue\":{\"identifier\":\"ENG-42\"},"
    <> "\"comment\":{\"user\":{\"email\":\"carol@example.com\"}}}"

  let tags = event_tagger.tag("linear", "issue.commented", data)

  should.equal(dict.get(tags, "ticket_id"), Ok("ENG-42"))
  should.equal(dict.get(tags, "author"), Ok("carol@example.com"))
}

pub fn tag_linear_issue_updated_extracts_status_test() {
  let data =
    "{\"issue\":{\"identifier\":\"ENG-99\","
    <> "\"state\":{\"name\":\"In Progress\"},"
    <> "\"assignee\":{\"email\":\"dave@example.com\"}}}"

  let tags = event_tagger.tag("linear", "issue.updated", data)

  should.equal(dict.get(tags, "ticket_id"), Ok("ENG-99"))
  should.equal(dict.get(tags, "status"), Ok("In Progress"))
  should.equal(dict.get(tags, "author"), Ok("dave@example.com"))
}

// ---------------------------------------------------------------------------
// Unknown / malformed
// ---------------------------------------------------------------------------

pub fn tag_unknown_source_returns_empty_test() {
  let data = "{\"from\":\"alice@example.com\"}"

  let tags = event_tagger.tag("unknown", "email.received", data)

  should.equal(tags, dict.new())
}

pub fn tag_unknown_type_for_known_source_returns_empty_test() {
  let data = "{\"from\":\"alice@example.com\",\"thread_id\":\"t-1\"}"

  let tags = event_tagger.tag("gmail", "weird.event", data)

  should.equal(tags, dict.new())
}

pub fn tag_malformed_json_returns_empty_test() {
  let tags = event_tagger.tag("gmail", "email.received", "{not-json")

  should.equal(tags, dict.new())
}
