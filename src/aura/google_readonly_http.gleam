//// Guard for the Gmail REST read-only transport.
////
//// This module validates a request before a transport can receive it. It does
//// not contain an HTTP client and cannot perform a provider action.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order.{Lt}
import gleam/result
import gleam/string
import gleam/uri

const calendar_events_fields = "nextPageToken,items(id,etag,status,summary,start(date,dateTime),end(date,dateTime),updated,recurringEventId,eventType,transparency,visibility)"

/// Validate one exact Gmail metadata request.
pub fn validate_request(method: String, url: String) -> Result(Nil, String) {
  case method {
    "GET" -> validate_gmail_url(url)
    _ -> Error("google_readonly_method_not_allowed")
  }
}

/// Validate the exact Calendar primary-calendar identity request.
pub fn validate_calendar_identity_request(
  method: String,
  url: String,
) -> Result(Nil, String) {
  case method {
    "GET" ->
      case uri.parse(url) {
        Error(_) -> Error("google_calendar_url_invalid")
        Ok(parsed) -> {
          use _ <- result.try(validate_calendar_origin(parsed))
          case parsed.path, parsed.query {
            "/calendar/v3/calendars/primary", Some(query) ->
              case uri.parse_query(query) {
                Ok([#("fields", "id")]) -> Ok(Nil)
                _ -> Error("google_readonly_query_not_allowed")
              }
            _, _ -> Error("google_calendar_path_not_allowed")
          }
        }
      }
    _ -> Error("google_readonly_method_not_allowed")
  }
}

/// Validate one bounded Calendar events request.
///
/// The caller supplies the authorized time window and item limit. The request
/// must match them exactly, so a transport cannot widen the read.
pub fn validate_calendar_request(
  method: String,
  url: String,
  expected_time_min: String,
  expected_time_max: String,
  expected_max_results: Int,
) -> Result(Nil, String) {
  case method {
    "GET" ->
      case
        valid_calendar_window(
          expected_time_min,
          expected_time_max,
          expected_max_results,
        ),
        uri.parse(url)
      {
        False, _ -> Error("google_calendar_window_invalid")
        _, Error(_) -> Error("google_calendar_url_invalid")
        True, Ok(parsed) -> {
          use _ <- result.try(validate_calendar_origin(parsed))
          case parsed.path, parsed.query {
            "/calendar/v3/calendars/primary/events", Some(query) ->
              validate_calendar_events_query(
                query,
                expected_time_min,
                expected_time_max,
                expected_max_results,
              )
            _, _ -> Error("google_calendar_path_not_allowed")
          }
        }
      }
    _ -> Error("google_readonly_method_not_allowed")
  }
}

fn validate_calendar_origin(parsed: uri.Uri) -> Result(Nil, String) {
  case parsed {
    uri.Uri(
      scheme: Some("https"),
      userinfo: None,
      host: Some("www.googleapis.com"),
      port: None,
      fragment: None,
      ..,
    ) -> Ok(Nil)
    _ -> Error("google_calendar_host_not_allowed")
  }
}

fn valid_calendar_window(
  time_min: String,
  time_max: String,
  maximum: Int,
) -> Bool {
  maximum > 0
  && maximum <= 100
  && valid_calendar_time(time_min)
  && valid_calendar_time(time_max)
  && string.compare(time_min, time_max) == Lt
}

fn valid_calendar_time(value: String) -> Bool {
  value != ""
  && string.byte_size(value) <= 64
  && string.ends_with(value, "Z")
  && !string.contains(value, "\n")
  && !string.contains(value, "\r")
}

fn validate_calendar_events_query(
  query: String,
  time_min: String,
  time_max: String,
  maximum: Int,
) -> Result(Nil, String) {
  case string.byte_size(query) <= 8192, uri.parse_query(query) {
    False, _ -> Error("google_readonly_query_not_allowed")
    _, Error(_) -> Error("google_readonly_query_not_allowed")
    True, Ok(fields) -> {
      let keys_valid =
        list.all(fields, fn(field) {
          list.contains(
            [
              "singleEvents",
              "showDeleted",
              "timeMin",
              "timeMax",
              "maxResults",
              "fields",
              "pageToken",
            ],
            field.0,
          )
        })
      let page_tokens = values_for(fields, "pageToken")
      case
        keys_valid
        && values_for(fields, "singleEvents") == ["true"]
        && values_for(fields, "showDeleted") == ["true"]
        && values_for(fields, "timeMin") == [time_min]
        && values_for(fields, "timeMax") == [time_max]
        && values_for(fields, "maxResults") == [int.to_string(maximum)]
        && values_for(fields, "fields") == [calendar_events_fields]
        && list.length(page_tokens) <= 1
        && list.all(page_tokens, valid_calendar_page_token)
      {
        True -> Ok(Nil)
        False -> Error("google_readonly_query_not_allowed")
      }
    }
  }
}

fn valid_calendar_page_token(value: String) -> Bool {
  value != ""
  && string.byte_size(value) <= 1024
  && !string.contains(value, " ")
  && !string.contains(value, "\n")
  && !string.contains(value, "\r")
}

fn validate_gmail_url(url: String) -> Result(Nil, String) {
  case uri.parse(url) {
    Error(_) -> Error("google_readonly_url_invalid")
    Ok(parsed) -> {
      use _ <- result.try(validate_origin(parsed))
      validate_path(parsed.path, parsed.query)
    }
  }
}

fn validate_origin(parsed: uri.Uri) -> Result(Nil, String) {
  case parsed {
    uri.Uri(
      scheme: Some("https"),
      userinfo: None,
      host: Some("gmail.googleapis.com"),
      port: None,
      fragment: None,
      ..,
    ) -> Ok(Nil)
    _ -> Error("google_readonly_host_not_allowed")
  }
}

fn validate_path(path: String, query: Option(String)) -> Result(Nil, String) {
  case path, query {
    "/gmail/v1/users/me/profile", Some(value) -> validate_profile_query(value)
    "/gmail/v1/users/me/profile", None ->
      Error("google_readonly_query_not_allowed")
    "/gmail/v1/users/me/history", Some(value) -> validate_history_query(value)
    value, Some(query) ->
      case string.starts_with(value, "/gmail/v1/users/me/messages/") {
        True -> validate_message_path_and_query(value, query)
        False -> Error("google_readonly_path_not_allowed")
      }
    _, _ -> Error("google_readonly_path_not_allowed")
  }
}

fn validate_profile_query(query: String) -> Result(Nil, String) {
  case uri.parse_query(query) {
    Ok([#("fields", "emailAddress,historyId")]) -> Ok(Nil)
    _ -> Error("google_readonly_query_not_allowed")
  }
}

fn validate_history_query(query: String) -> Result(Nil, String) {
  case string.byte_size(query) <= 4096, uri.parse_query(query) {
    False, _ -> Error("google_readonly_query_not_allowed")
    _, Error(_) -> Error("google_readonly_query_not_allowed")
    True, Ok(fields) -> {
      let keys_valid =
        list.all(fields, fn(field) {
          list.contains(
            [
              "startHistoryId",
              "pageToken",
              "historyTypes",
              "maxResults",
              "fields",
            ],
            field.0,
          )
        })
      let start_ids = values_for(fields, "startHistoryId")
      let page_tokens = values_for(fields, "pageToken")
      let history_types = values_for(fields, "historyTypes")
      let maximums = values_for(fields, "maxResults")
      let projections = values_for(fields, "fields")
      case
        keys_valid
        && list.length(start_ids) == 1
        && list.all(start_ids, fn(value) {
          value != "" && string.byte_size(value) <= 256
        })
        && list.length(page_tokens) <= 1
        && list.all(page_tokens, fn(value) { string.byte_size(value) <= 1024 })
        && history_types == ["messageAdded"]
        && valid_maximum(maximums)
        && projections
        == [
          "history(messagesAdded(message(id,threadId,labelIds,historyId))),nextPageToken,historyId",
        ]
      {
        True -> Ok(Nil)
        False -> Error("google_readonly_query_not_allowed")
      }
    }
  }
}

fn validate_message_path_and_query(
  path: String,
  query: String,
) -> Result(Nil, String) {
  let prefix = "/gmail/v1/users/me/messages/"
  let message_id = string.drop_start(path, string.length(prefix))
  case
    message_id != ""
    && string.byte_size(message_id) <= 256
    && !string.contains(message_id, "/")
    && !string.contains(message_id, "..")
  {
    False -> Error("google_readonly_path_not_allowed")
    True -> validate_message_query(query)
  }
}

fn validate_message_query(query: String) -> Result(Nil, String) {
  case uri.parse_query(query) {
    Error(_) -> Error("google_readonly_query_not_allowed")
    Ok(fields) -> {
      let formats = values_for(fields, "format")
      let headers = values_for(fields, "metadataHeaders")
      let projections = values_for(fields, "fields")
      case
        list.length(fields) == 5
        && formats == ["metadata"]
        && list.length(headers) == 3
        && list.contains(headers, "Subject")
        && list.contains(headers, "From")
        && list.contains(headers, "Date")
        && projections
        == [
          "id,threadId,labelIds,historyId,internalDate,sizeEstimate,payload(headers)",
        ]
      {
        True -> Ok(Nil)
        False -> Error("google_readonly_query_not_allowed")
      }
    }
  }
}

fn valid_maximum(values: List(String)) -> Bool {
  case values {
    [value] ->
      case int.parse(value) {
        Ok(number) -> number > 0 && number <= 100
        Error(_) -> False
      }
    _ -> False
  }
}

fn values_for(fields: List(#(String, String)), key: String) -> List(String) {
  fields
  |> list.filter_map(fn(field) {
    case field.0 == key {
      True -> Ok(field.1)
      False -> Error(Nil)
    }
  })
}
