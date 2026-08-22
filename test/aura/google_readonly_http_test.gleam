import aura/google_readonly_http
import gleam/string
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

pub fn rejects_non_get_and_unapproved_gmail_request_before_transport_test() {
  google_readonly_http.validate_request(
    "POST",
    "https://gmail.googleapis.com/gmail/v1/users/me/profile",
  )
  |> should.equal(Error("google_readonly_method_not_allowed"))
  google_readonly_http.validate_request(
    "GET",
    "https://mail.google.com/mail/u/0",
  )
  |> should.equal(Error("google_readonly_host_not_allowed"))
  google_readonly_http.validate_request(
    "GET",
    "https://gmail.googleapis.com/gmail/v1/users/me/messages/id?format=full",
  )
  |> should.equal(Error("google_readonly_query_not_allowed"))
  google_readonly_http.validate_request(
    "GET",
    "https://gmail.googleapis.com/gmail/v1/users/me/history?startHistoryId=1&evil=1",
  )
  |> should.equal(Error("google_readonly_query_not_allowed"))
}

pub fn permits_only_gmail_profile_history_and_metadata_requests_test() {
  google_readonly_http.validate_request(
    "GET",
    "https://gmail.googleapis.com/gmail/v1/users/me/profile?fields=emailAddress%2ChistoryId",
  )
  |> should.be_ok
  google_readonly_http.validate_request(
    "GET",
    "https://gmail.googleapis.com/gmail/v1/users/me/history?startHistoryId=1&pageToken=x&historyTypes=messageAdded&maxResults=100&fields=history%28messagesAdded%28message%28id%2CthreadId%2ClabelIds%2ChistoryId%29%29%29%2CnextPageToken%2ChistoryId",
  )
  |> should.be_ok
  google_readonly_http.validate_request(
    "GET",
    "https://gmail.googleapis.com/gmail/v1/users/me/messages/id?format=metadata&metadataHeaders=Subject&metadataHeaders=From&metadataHeaders=Date&fields=id%2CthreadId%2ClabelIds%2ChistoryId%2CinternalDate%2CsizeEstimate%2Cpayload%28headers%29",
  )
  |> should.be_ok
}

pub fn rejects_missing_or_widened_partial_response_fields_test() {
  google_readonly_http.validate_request(
    "GET",
    "https://gmail.googleapis.com/gmail/v1/users/me/profile",
  )
  |> should.equal(Error("google_readonly_query_not_allowed"))
  google_readonly_http.validate_request(
    "GET",
    "https://gmail.googleapis.com/gmail/v1/users/me/history?startHistoryId=1&historyTypes=messageAdded&maxResults=101&fields=history",
  )
  |> should.equal(Error("google_readonly_query_not_allowed"))
  google_readonly_http.validate_request(
    "GET",
    "https://gmail.googleapis.com/gmail/v1/users/me/messages/id?format=metadata&metadataHeaders=Subject&metadataHeaders=From&metadataHeaders=Date&fields=id%2Csnippet",
  )
  |> should.equal(Error("google_readonly_query_not_allowed"))
}

pub fn rejects_oversized_provider_identifiers_before_transport_test() {
  let history_id = string.repeat("x", 257)
  google_readonly_http.validate_request(
    "GET",
    "https://gmail.googleapis.com/gmail/v1/users/me/history?startHistoryId="
      <> history_id
      <> "&historyTypes=messageAdded&maxResults=100&fields=history%28messagesAdded%28message%28id%2CthreadId%2ClabelIds%2ChistoryId%29%29%29%2CnextPageToken%2ChistoryId",
  )
  |> should.equal(Error("google_readonly_query_not_allowed"))
  let page_token = string.repeat("x", 1025)
  google_readonly_http.validate_request(
    "GET",
    "https://gmail.googleapis.com/gmail/v1/users/me/history?startHistoryId=1&pageToken="
      <> page_token
      <> "&historyTypes=messageAdded&maxResults=100&fields=history%28messagesAdded%28message%28id%2CthreadId%2ClabelIds%2ChistoryId%29%29%29%2CnextPageToken%2ChistoryId",
  )
  |> should.equal(Error("google_readonly_query_not_allowed"))
  google_readonly_http.validate_request(
    "GET",
    "https://gmail.googleapis.com/gmail/v1/users/me/messages/"
      <> string.repeat("x", 257)
      <> "?format=metadata&metadataHeaders=Subject&metadataHeaders=From&metadataHeaders=Date&fields=id%2CthreadId%2ClabelIds%2ChistoryId%2CinternalDate%2CsizeEstimate%2Cpayload%28headers%29",
  )
  |> should.equal(Error("google_readonly_path_not_allowed"))
}

pub fn calendar_requests_require_exact_readonly_window_and_projection_test() {
  let url =
    "https://www.googleapis.com/calendar/v3/calendars/primary/events?singleEvents=true&showDeleted=true&timeMin=2026-08-10T00%3A00%3A00Z&timeMax=2026-08-17T00%3A00%3A00Z&maxResults=50&fields=nextPageToken%2Citems%28id%2Cetag%2Cstatus%2Csummary%2Cstart%28date%2CdateTime%29%2Cend%28date%2CdateTime%29%2Cupdated%2CrecurringEventId%2CeventType%2Ctransparency%2Cvisibility%29"
  google_readonly_http.validate_calendar_request(
    "GET",
    url,
    "2026-08-10T00:00:00Z",
    "2026-08-17T00:00:00Z",
    50,
  )
  |> should.be_ok
  google_readonly_http.validate_calendar_request(
    "GET",
    url <> "&syncToken=forbidden",
    "2026-08-10T00:00:00Z",
    "2026-08-17T00:00:00Z",
    50,
  )
  |> should.equal(Error("google_readonly_query_not_allowed"))
  google_readonly_http.validate_calendar_request(
    "POST",
    url,
    "2026-08-10T00:00:00Z",
    "2026-08-17T00:00:00Z",
    50,
  )
  |> should.equal(Error("google_readonly_method_not_allowed"))
}

pub fn calendar_identity_request_has_one_exact_partial_field_test() {
  google_readonly_http.validate_calendar_identity_request(
    "GET",
    "https://www.googleapis.com/calendar/v3/calendars/primary?fields=id",
  )
  |> should.be_ok
  google_readonly_http.validate_calendar_identity_request(
    "GET",
    "https://www.googleapis.com/calendar/v3/calendars/primary?fields=id%2Cdescription",
  )
  |> should.equal(Error("google_readonly_query_not_allowed"))
}

pub fn calendar_request_rejects_widened_window_pages_and_origin_test() {
  let url =
    "https://www.googleapis.com/calendar/v3/calendars/primary/events?singleEvents=true&showDeleted=true&timeMin=2026-08-10T00%3A00%3A00Z&timeMax=2026-08-17T00%3A00%3A00Z&maxResults=50&fields=nextPageToken%2Citems%28id%2Cetag%2Cstatus%2Csummary%2Cstart%28date%2CdateTime%29%2Cend%28date%2CdateTime%29%2Cupdated%2CrecurringEventId%2CeventType%2Ctransparency%2Cvisibility%29"
  google_readonly_http.validate_calendar_request(
    "GET",
    url,
    "2026-08-11T00:00:00Z",
    "2026-08-17T00:00:00Z",
    50,
  )
  |> should.equal(Error("google_readonly_query_not_allowed"))
  google_readonly_http.validate_calendar_request(
    "GET",
    url <> "&pageToken=" <> string.repeat("x", 1025),
    "2026-08-10T00:00:00Z",
    "2026-08-17T00:00:00Z",
    50,
  )
  |> should.equal(Error("google_readonly_query_not_allowed"))
  google_readonly_http.validate_calendar_request(
    "GET",
    string.replace(url, "www.googleapis.com", "calendar.googleapis.com"),
    "2026-08-10T00:00:00Z",
    "2026-08-17T00:00:00Z",
    50,
  )
  |> should.equal(Error("google_calendar_host_not_allowed"))
}
