// test/aura/browser_test.gleam
import aura/browser
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
