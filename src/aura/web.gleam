import aura/env
import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import gleam/uri
import logging

const user_agent = "Aura/0.1 (bot)"

/// A web search result.
pub type SearchResult {
  SearchResult(title: String, url: String, description: String)
}

/// Search the web using Brave Search API.
/// Returns up to `limit` results. Requires BRAVE_API_KEY env var.
pub fn search(query: String, limit: Int) -> Result(List(SearchResult), String) {
  use api_key <- result.try(
    env.get_env("BRAVE_API_KEY")
    |> result.map_error(fn(_) {
      "BRAVE_API_KEY not configured. Set it in ~/.config/aura/.env"
    }),
  )

  let encoded_query = uri.percent_encode(query)
  let url =
    "https://api.search.brave.com/res/v1/web/search?q="
    <> encoded_query
    <> "&count="
    <> int.to_string(limit)

  logging.log(logging.Info, "[web] Searching: " <> query)

  use parsed_uri <- result.try(
    uri.parse(url)
    |> result.map_error(fn(_) { "Failed to parse search URL" }),
  )
  use req <- result.try(
    request.from_uri(parsed_uri)
    |> result.map_error(fn(_) { "Failed to build search request" }),
  )
  let req =
    req
    |> request.set_method(http.Get)
    |> request.set_header("accept", "application/json")
    |> request.set_header("x-subscription-token", api_key)

  use resp <- result.try(
    httpc.configure()
    |> httpc.timeout(15_000)
    |> httpc.dispatch(req)
    |> result.map_error(fn(e) { "Search request failed: " <> string.inspect(e) }),
  )

  case resp.status {
    200 -> parse_brave_results(resp.body)
    status ->
      Error(
        "Search API error: status "
        <> int.to_string(status)
        <> " — "
        <> string.slice(resp.body, 0, 200),
      )
  }
}

/// Format search results for LLM consumption.
pub fn format_search_results(results: List(SearchResult)) -> String {
  case results {
    [] -> "No results found."
    _ ->
      list.index_map(results, fn(r, i) {
        int.to_string(i + 1)
        <> ". **"
        <> r.title
        <> "**\n   "
        <> r.url
        <> "\n   "
        <> r.description
      })
      |> string.join("\n\n")
  }
}

/// Fetch a URL and return its text content (HTML stripped).
/// Truncates to max_chars to avoid overwhelming the LLM context.
pub fn fetch(url: String, max_chars: Int) -> Result(String, String) {
  logging.log(logging.Info, "[web] Fetching: " <> url)

  use parsed_uri <- result.try(
    uri.parse(url)
    |> result.map_error(fn(_) { "Failed to parse URL: " <> url }),
  )
  use req <- result.try(
    request.from_uri(parsed_uri)
    |> result.map_error(fn(_) { "Failed to build request for: " <> url }),
  )
  let req =
    req
    |> request.set_method(http.Get)
    |> request.set_header("user-agent", user_agent)
    |> request.set_header("accept", "text/html,text/plain,application/json")

  use resp <- result.try(
    httpc.configure()
    |> httpc.timeout(15_000)
    |> httpc.dispatch(req)
    |> result.map_error(fn(e) { "Fetch failed: " <> string.inspect(e) }),
  )

  case resp.status {
    status if status >= 200 && status < 400 -> {
      let text = strip_html(resp.body)
      let truncated = case string.length(text) > max_chars {
        True ->
          string.slice(text, 0, max_chars)
          <> "\n\n[Truncated at "
          <> int.to_string(max_chars)
          <> " chars]"
        False -> text
      }
      Ok(truncated)
    }
    status ->
      Error("Fetch error: status " <> int.to_string(status) <> " from " <> url)
  }
}

/// Fetch a URL and return the raw response body as BitArray.
/// For binary downloads (images, PDFs, etc.) where strip_html is wrong.
pub fn fetch_bytes(url: String, timeout_ms: Int) -> Result(BitArray, String) {
  logging.log(logging.Info, "[web] Fetching bytes: " <> url)

  use parsed_uri <- result.try(
    uri.parse(url)
    |> result.map_error(fn(_) { "Failed to parse URL: " <> url }),
  )
  use req <- result.try(
    request.from_uri(parsed_uri)
    |> result.map_error(fn(_) { "Failed to build request for: " <> url }),
  )
  let req =
    req
    |> request.set_method(http.Get)
    |> request.set_header("user-agent", user_agent)
    |> request.set_body(<<>>)

  use resp <- result.try(
    httpc.configure()
    |> httpc.timeout(timeout_ms)
    |> httpc.dispatch_bits(req)
    |> result.map_error(fn(e) { "Fetch failed: " <> string.inspect(e) }),
  )

  case resp.status {
    status if status >= 200 && status < 400 -> Ok(resp.body)
    status ->
      Error("Fetch error: status " <> int.to_string(status) <> " from " <> url)
  }
}

// ---------------------------------------------------------------------------
// Internal
// ---------------------------------------------------------------------------

fn parse_brave_results(body: String) -> Result(List(SearchResult), String) {
  let result_decoder = {
    use title <- decode.field("title", decode.string)
    use url <- decode.field("url", decode.string)
    use description <- decode.optional_field("description", "", decode.string)
    decode.success(SearchResult(
      title: title,
      url: url,
      description: description,
    ))
  }
  let decoder = decode.at(["web", "results"], decode.list(result_decoder))
  json.parse(body, decoder)
  |> result.map_error(fn(_) { "Failed to parse search results" })
}

/// Strip HTML tags from a string. Removes everything between < and >,
/// decodes common entities, and collapses whitespace.
pub fn strip_html(html: String) -> String {
  strip_tags(html, False, "")
  |> decode_entities
  |> collapse_whitespace
}

fn strip_tags(input: String, in_tag: Bool, acc: String) -> String {
  case string.pop_grapheme(input) {
    Error(_) -> acc
    Ok(#("<", rest)) -> strip_tags(rest, True, acc)
    Ok(#(">", rest)) -> strip_tags(rest, False, acc <> " ")
    Ok(#(char, rest)) -> {
      case in_tag {
        True -> strip_tags(rest, True, acc)
        False -> strip_tags(rest, False, acc <> char)
      }
    }
  }
}

fn decode_entities(text: String) -> String {
  text
  |> string.replace("&amp;", "&")
  |> string.replace("&lt;", "<")
  |> string.replace("&gt;", ">")
  |> string.replace("&quot;", "\"")
  |> string.replace("&#39;", "'")
  |> string.replace("&nbsp;", " ")
}

fn collapse_whitespace(text: String) -> String {
  collapse_ws(text, False, "")
}

fn collapse_ws(input: String, prev_space: Bool, acc: String) -> String {
  case string.pop_grapheme(input) {
    Error(_) -> string.trim(acc)
    Ok(#(" ", rest)) | Ok(#("\n", rest)) | Ok(#("\t", rest)) | Ok(#("\r", rest)) -> {
      case prev_space {
        True -> collapse_ws(rest, True, acc)
        False -> collapse_ws(rest, True, acc <> " ")
      }
    }
    Ok(#(char, rest)) -> collapse_ws(rest, False, acc <> char)
  }
}
