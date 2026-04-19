import aura/clients/browser_runner

pub fn production_browser_runner_destructures_test() {
  case browser_runner.production() {
    browser_runner.BrowserRunner(run: _, url_has_secret: _) -> Nil
  }
}
