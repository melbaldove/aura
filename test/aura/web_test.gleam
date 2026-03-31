import aura/web
import gleam/string
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// HTML stripping
// ---------------------------------------------------------------------------

pub fn strip_html_basic_test() {
  let html = "<p>Hello <b>world</b></p>"
  let result = web.strip_html(html)
  should.be_true(string.contains(result, "Hello"))
  should.be_true(string.contains(result, "world"))
  should.be_false(string.contains(result, "<p>"))
  should.be_false(string.contains(result, "<b>"))
}

pub fn strip_html_entities_test() {
  let html = "&amp; &lt; &gt; &quot; &#39;"
  let result = web.strip_html(html)
  should.be_true(string.contains(result, "&"))
  should.be_true(string.contains(result, "<"))
  should.be_true(string.contains(result, ">"))
}

pub fn strip_html_whitespace_test() {
  let html = "  lots   of    spaces   "
  let result = web.strip_html(html)
  // Should collapse multiple spaces
  should.be_false(string.contains(result, "  "))
}

// ---------------------------------------------------------------------------
// Search result formatting
// ---------------------------------------------------------------------------

pub fn format_empty_results_test() {
  web.format_search_results([])
  |> should.equal("No results found.")
}

pub fn format_results_test() {
  let results = [
    web.SearchResult(title: "Gleam Language", url: "https://gleam.run", description: "A friendly language"),
    web.SearchResult(title: "Erlang", url: "https://erlang.org", description: "The BEAM VM"),
  ]
  let formatted = web.format_search_results(results)
  should.be_true(string.contains(formatted, "1. **Gleam Language**"))
  should.be_true(string.contains(formatted, "https://gleam.run"))
  should.be_true(string.contains(formatted, "2. **Erlang**"))
}

// ---------------------------------------------------------------------------
// Search requires API key
// ---------------------------------------------------------------------------

pub fn search_fails_without_api_key_test() {
  // BRAVE_API_KEY is not set in test environment
  let result = web.search("test query", 3)
  should.be_error(result)
}
