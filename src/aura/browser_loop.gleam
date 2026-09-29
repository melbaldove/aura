//// One bounded browser task. Session ownership stays with BrowserRunner.

import aura/browser
import aura/browser_adapter.{type Adapter}
import aura/browser_observation.{type Action, type Page}
import aura/clients/browser_runner.{type BrowserRunner}
import aura/jev_client.{type Client, type Config}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub type Dependencies {
  Dependencies(client: Client, now: fn() -> Int)
}

type State {
  State(
    goal: String,
    started: Int,
    deadline: Int,
    actions: Int,
    decisions: Int,
    text_calls: Int,
    unchanged: Int,
    history: List(json.Json),
    page: Option(Page),
  )
}

pub fn execute(
  goal: String,
  session: String,
  cdp_url: String,
  timeout: Int,
  runner: BrowserRunner,
) -> String {
  execute_with_client(
    goal,
    session,
    cdp_url,
    timeout,
    runner,
    jev_client.production(),
  )
}

pub fn execute_with_client(
  goal: String,
  session: String,
  cdp_url: String,
  timeout: Int,
  runner: BrowserRunner,
  client: Client,
) -> String {
  let setup = {
    use config <- result.try(jev_client.from_env())
    use script <- result.try(browser_adapter.read_script())
    Ok(#(config, browser_adapter.Adapter(runner, session, cdp_url, script)))
  }
  case setup {
    Error(reason) -> "Error: " <> reason
    Ok(#(config, adapter)) ->
      run(goal, timeout, adapter, config, Dependencies(client, monotonic_ms))
  }
}

pub fn run(
  goal: String,
  timeout: Int,
  adapter: Adapter,
  config: Config,
  deps: Dependencies,
) -> String {
  let start = deps.now()
  let state =
    State(goal, start, start + int.min(timeout, 600_000), 0, 0, 0, 0, [], None)
  case string.trim(goal) == "" || string.length(goal) > 8000 {
    True ->
      finish(state, deps, "error", "Supply a goal of 1 to 8000 characters")
    False -> cycle(state, adapter, config, deps)
  }
}

fn cycle(
  state: State,
  adapter: Adapter,
  config: Config,
  deps: Dependencies,
) -> String {
  case
    remaining(state, deps) <= 0,
    state.actions >= 30 || state.decisions >= 60
  {
    True, _ -> finish(state, deps, "timeout", "Run deadline reached")
    _, True ->
      finish(state, deps, "limit", "Run action or decision limit reached")
    _, _ -> {
      case browser_adapter.observe(adapter, remaining(state, deps)) {
        Error(reason) -> finish(state, deps, "error", reason)
        Ok(page) -> {
          let state = State(..state, page: Some(page))
          case browser.detect_auth_required(page.url, page.title) {
            True -> finish(state, deps, "auth_required", "AUTH_REQUIRED")
            False -> {
              case
                browser.is_safe_url(page.url)
                && !adapter.runner.url_has_secret(page.url)
              {
                False ->
                  finish(
                    state,
                    deps,
                    "blocked",
                    "Current page URL is not allowed",
                  )
                True -> predict(state, adapter, config, deps, page)
              }
            }
          }
        }
      }
    }
  }
}

fn predict(
  state: State,
  adapter: Adapter,
  config: Config,
  deps: Dependencies,
  page: Page,
) -> String {
  case remaining(state, deps) <= 0 {
    True -> finish(state, deps, "timeout", "Run deadline reached")
    False -> {
      let state = State(..state, decisions: state.decisions + 1)
      case
        jev_client.choose(
          deps.client,
          config,
          page,
          state.goal,
          state.history,
          remaining(state, deps),
        )
      {
        Error(reason) -> finish(state, deps, "error", reason)
        Ok(jev_client.Stop(status)) -> {
          case browser_adapter.fresh(adapter, page, remaining(state, deps)) {
            Ok(True) ->
              finish(
                state,
                deps,
                status,
                "Model stopped; verify the final observation",
              )
            Ok(False) -> cycle(state, adapter, config, deps)
            Error(reason) -> finish(state, deps, "error", reason)
          }
        }
        Ok(jev_client.Execute(action)) ->
          input(state, adapter, config, deps, page, action)
      }
    }
  }
}

fn input(
  state: State,
  adapter: Adapter,
  config: Config,
  deps: Dependencies,
  page: Page,
  action: Action,
) -> String {
  case browser_adapter.fresh(adapter, page, remaining(state, deps)) {
    Ok(False) -> cycle(state, adapter, config, deps)
    Error(reason) -> finish(state, deps, "error", reason)
    Ok(True) -> {
      let #(state, text) = case action.kind {
        "fill" -> {
          case remaining(state, deps) <= 0 {
            True -> #(state, Error("timeout"))
            False -> #(
              State(..state, text_calls: state.text_calls + 1),
              jev_client.field_text(
                deps.client,
                config,
                page,
                action,
                state.goal,
                state.history,
                remaining(state, deps),
              ),
            )
          }
        }
        _ -> #(state, Ok(""))
      }
      case text {
        Error(reason) -> finish(state, deps, "error", reason)
        Ok(text) -> {
          case
            browser_adapter.prepare(
              adapter,
              page,
              action,
              remaining(state, deps),
            )
          {
            Error("stale") -> cycle(state, adapter, config, deps)
            Error(reason) -> finish(state, deps, "error", reason)
            Ok(selector) -> {
              case
                browser_adapter.act(
                  adapter,
                  action,
                  selector,
                  text,
                  remaining(state, deps),
                )
              {
                Error(reason) ->
                  finish(
                    state,
                    deps,
                    "uncertain",
                    reason <> "; inspect before retrying",
                  )
                Ok(_) ->
                  after_action(state, adapter, config, deps, page, action)
              }
            }
          }
        }
      }
    }
  }
}

fn after_action(
  state: State,
  adapter: Adapter,
  config: Config,
  deps: Dependencies,
  page: Page,
  action: Action,
) -> String {
  // Count confirmed execution before observation, even if that observation fails.
  let state = State(..state, actions: state.actions + 1)
  case browser_adapter.observe(adapter, remaining(state, deps)) {
    Error(reason) -> finish(state, deps, "error", reason)
    Ok(next) -> {
      let changed = page.fingerprint != next.fingerprint
      let unchanged = case changed || action.kind == "wait" {
        True -> 0
        False -> state.unchanged + 1
      }
      // History stays in this worker and contains no typed values.
      let history = [
        json.object([
          #("action", json.string(action.label)),
          #("kind", json.string(action.kind)),
          #("page_changed", json.bool(changed)),
        ]),
        ..list.take(state.history, 9)
      ]
      let state =
        State(..state, page: Some(next), history: history, unchanged: unchanged)
      case unchanged >= 3 {
        True ->
          finish(
            state,
            deps,
            "blocked",
            "Three actions made no observed progress",
          )
        False -> cycle(state, adapter, config, deps)
      }
    }
  }
}

fn remaining(state: State, deps: Dependencies) -> Int {
  int.max(0, state.deadline - deps.now())
}

fn finish(
  state: State,
  deps: Dependencies,
  status: String,
  reason: String,
) -> String {
  let status = case remaining(state, deps) <= 0 && status != "uncertain" {
    True -> "timeout"
    False -> status
  }
  let output =
    json.to_string(
      json.object([
        #("success", json.bool(status == "done_unverified")),
        #("status", json.string(status)),
        #("reason", json.string(reason)),
        #("verified", json.bool(False)),
        #("actions", json.int(state.actions)),
        #("model_calls", json.int(state.decisions + state.text_calls)),
        #("decisions", json.int(state.decisions)),
        #("text_calls", json.int(state.text_calls)),
        #("elapsed_ms", json.int(int.max(0, deps.now() - state.started))),
        #("observation", case state.page {
          Some(page) -> browser_observation.page_json(page)
          None -> json.null()
        }),
      ]),
    )
  case status {
    "done_unverified" | "blocked" | "auth_required" -> output
    _ -> "Error: " <> output
  }
}

@external(erlang, "aura_jev_ffi", "monotonic_ms")
pub fn monotonic_ms() -> Int
