//// Dependency-injected browser runner. Production wraps `browser.run_ffi`
//// and `browser.url_has_secret`; tests inject scripted fakes.

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
