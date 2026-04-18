// test/aura/browser_test.gleam
import aura/browser
import gleam/string
import gleeunit/should

pub fn browser_module_compiles_test() {
  browser.Navigate |> should.equal(browser.Navigate)
}

pub fn resolve_session_uses_channel_when_arg_empty_test() {
  browser.resolve_session("", "1234567890")
  |> should.equal(Ok("aura-ch-1234567890"))
}

pub fn resolve_session_prefixes_named_session_test() {
  browser.resolve_session("hub-jw-org", "1234567890")
  |> should.equal(Ok("aura-named-hub-jw-org"))
}

pub fn resolve_session_named_ignores_channel_test() {
  browser.resolve_session("shared", "")
  |> should.equal(Ok("aura-named-shared"))
}

pub fn resolve_session_errors_when_both_empty_test() {
  browser.resolve_session("", "")
  |> should.be_error
}

pub fn truncate_snapshot_returns_input_when_under_threshold_test() {
  let text = "line 1\nline 2\nline 3"
  browser.truncate_snapshot(text, 8000)
  |> should.equal(text)
}

pub fn truncate_snapshot_cuts_at_line_boundary_test() {
  let text = "aaaaaaaa\nbbbbbbbb\ncccccccc\ndddddddd"
  let result = browser.truncate_snapshot(text, 20)
  result
  |> string.contains("aaaaaaaa")
  |> should.be_true
  // Should not split a line mid-way — "bbbb\n" means line was cut
  result
  |> string.contains("bbbb\n")
  |> should.be_false
}

pub fn truncate_snapshot_appends_footer_when_cut_test() {
  let text = "aaaaaaaaaa\nbbbbbbbbbb\ncccccccccc\ndddddddddd"
  let result = browser.truncate_snapshot(text, 25)
  result
  |> string.contains("more lines truncated")
  |> should.be_true
}

pub fn truncate_snapshot_no_footer_when_not_cut_test() {
  let text = "short"
  browser.truncate_snapshot(text, 8000)
  |> string.contains("truncated")
  |> should.be_false
}
