//// Dependency-injected browser runner. Wraps `browser.run_ffi` (agent-browser
//// subprocess) and `browser.url_has_secret` (URL sanity check). Tests
//// substitute via `test/fakes/fake_browser.new()` (later tasks).

import aura/browser

pub type BrowserRunner {
  BrowserRunner(
    run: fn(String, String, String, List(String), Int) -> Result(String, String),
    url_has_secret: fn(String) -> Bool,
  )
}

pub fn production() -> BrowserRunner {
  BrowserRunner(
    run: browser.run_ffi,
    url_has_secret: browser.url_has_secret,
  )
}
