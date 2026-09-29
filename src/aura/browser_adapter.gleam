import aura/browser_observation.{type Action, type Page}
import aura/clients/browser_runner.{type BrowserRunner}
import gleam/dynamic/decode
import gleam/json
import gleam/result

pub type Adapter {
  Adapter(
    runner: BrowserRunner,
    session: String,
    cdp_url: String,
    script: String,
  )
}

pub fn observe(adapter: Adapter, timeout: Int) -> Result(Page, String) {
  use raw <- result.try(evaluate(
    adapter,
    [
      #("operation", json.string("observe")),
    ],
    timeout,
  ))
  browser_observation.decode_page(raw)
}

pub fn fresh(adapter: Adapter, page: Page, timeout: Int) -> Result(Bool, String) {
  use raw <- result.try(evaluate(
    adapter,
    [
      #("operation", json.string("fresh")),
      #("token", json.string(page.token)),
    ],
    timeout,
  ))
  json.parse(raw, decode.at(["data", "result", "fresh"], decode.bool))
  |> result.map_error(fn(_) { "Invalid browser freshness response" })
}

pub fn prepare(
  adapter: Adapter,
  page: Page,
  action: Action,
  timeout: Int,
) -> Result(String, String) {
  use raw <- result.try(evaluate(
    adapter,
    [
      #("operation", json.string("prepare")),
      #("token", json.string(page.token)),
      #("action", json.string(action.id)),
    ],
    timeout,
  ))
  let decoder = {
    use fresh <- decode.field("fresh", decode.bool)
    use selector <- decode.optional_field("selector", "", decode.string)
    decode.success(#(fresh, selector))
  }
  case json.parse(raw, decode.at(["data", "result"], decoder)) {
    Ok(#(True, selector)) -> Ok(selector)
    Ok(#(False, _)) -> Error("stale")
    Error(_) -> Error("Invalid browser preparation response")
  }
}

pub fn act(
  adapter: Adapter,
  action: Action,
  selector: String,
  text: String,
  timeout: Int,
) -> Result(Nil, String) {
  let command = case action.kind, action.id {
    "click", _ -> Ok(#("click", [selector]))
    "fill", _ -> Ok(#("fill", [selector, text]))
    "select", _ -> Ok(#("select", [selector, action.value]))
    "wait", _ -> Ok(#("wait", ["100"]))
    "scroll", "scroll_up" -> Ok(#("scroll", ["up", "560"]))
    "scroll", "scroll_down" -> Ok(#("scroll", ["down", "560"]))
    _, _ -> Error("Unsupported browser action")
  }
  use pair <- result.try(command)
  use _ <- result.try(run(adapter, pair.0, pair.1, timeout))
  Ok(Nil)
}

fn evaluate(adapter: Adapter, fields: List(#(String, json.Json)), timeout: Int) {
  let expression =
    adapter.script <> "(" <> json.to_string(json.object(fields)) <> ")"
  run(adapter, "eval", [expression], timeout)
}

fn run(adapter: Adapter, command: String, args: List(String), timeout: Int) {
  case timeout <= 0 {
    True -> Error("timeout")
    False -> {
      use raw <- result.try(
        adapter.runner.run(
          adapter.session,
          adapter.cdp_url,
          command,
          args,
          timeout,
        )
        |> result.map_error(fn(_) {
          "Browser command failed; execution may be uncertain"
        }),
      )
      case json.parse(raw, decode.at(["success"], decode.bool)) {
        Ok(True) -> Ok(raw)
        _ -> Error("Browser command failed; execution may be uncertain")
      }
    }
  }
}

@external(erlang, "aura_jev_ffi", "read_script")
pub fn read_script() -> Result(String, String)
