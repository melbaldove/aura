// test/aura/browser_test.gleam
import aura/browser
import gleeunit/should

pub fn browser_module_compiles_test() {
  browser.Navigate |> should.equal(browser.Navigate)
}
