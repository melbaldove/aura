import aura/browser_observation as observation
import aura/jev_client
import aura/llm
import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/string
import gleeunit/should

pub fn page() -> observation.Page {
  observation.Page(
    "token",
    "https://example.com/",
    "Example",
    "Choose a color",
    "fingerprint",
    [
      observation.Action(
        "e1",
        "fill",
        "Name",
        "textbox",
        "old",
        "old",
        "",
        "",
        "",
        node: 0,
      ),
      observation.Action(
        "e2",
        "click",
        "Apply",
        "button",
        "",
        "",
        "",
        "",
        "",
        node: 0,
      ),
      observation.Action(
        "e3",
        "select",
        "Color → Blue",
        "combobox",
        "blue",
        "Red",
        "",
        "",
        "",
        node: 0,
      ),
      observation.Action(
        "wait",
        "wait",
        "Wait",
        "",
        "",
        "",
        "",
        "",
        "",
        node: 0,
      ),
    ],
  )
}

pub fn config() -> jev_client.Config {
  jev_client.Config(
    "test-key",
    "jev-latest",
    "text-key",
    "https://text.example",
    "test-model",
  )
}

// Produce the provider contract from the offered criteria, not a second action table.
pub fn response(body: json.Json, operation: String, target: String) -> String {
  let decoder =
    decode.at(
      ["questions"],
      decode.dict(
        decode.string,
        decode.at(["criteria"], decode.dict(decode.string, decode.dynamic)),
      ),
    )
  let assert Ok(questions) = json.parse(json.to_string(body), decoder)
  json.to_string(
    json.object([
      #(
        "answers",
        json.object(
          list.map(dict.to_list(questions), fn(pair) {
            let choice = case pair.0 {
              "operation" -> operation
              _ ->
                case list.contains(dict.keys(pair.1), target) {
                  True -> target
                  False -> {
                    let assert Ok(id) = list.first(dict.keys(pair.1))
                    id
                  }
                }
            }
            #(
              pair.0,
              json.object([
                #("choice", json.string(choice)),
                #("confidence", json.float(1.0)),
                #(
                  "probabilities",
                  json.object(
                    list.map(dict.keys(pair.1), fn(id) {
                      #(
                        id,
                        json.int(case id == choice {
                          True -> 1
                          False -> 0
                        }),
                      )
                    }),
                  ),
                ),
              ]),
            )
          }),
        ),
      ),
    ]),
  )
}

pub fn validates_only_the_selected_target_head_test() {
  let body = jev_client.choice_body(page(), "Apply", [], "jev")
  let raw = response(body, "CLICK", "e2")
  // Unused target head may be malformed without executing its target.
  let raw =
    string.replace(
      raw,
      "\"type_text_target\":{",
      "\"unused_type_text_target\":{",
    )
  jev_client.parse_choice(raw, page())
  |> should.equal(
    Ok(
      jev_client.Execute(observation.Action(
        "e2",
        "click",
        "Apply",
        "button",
        "",
        "",
        "",
        "",
        "",
        node: 0,
      )),
    ),
  )
}

pub fn rejects_target_from_another_operation_test() {
  let body = jev_client.choice_body(page(), "Apply", [], "jev")
  let raw = response(body, "CLICK", "e2") |> string.replace("\"e2\"", "\"e1\"")
  jev_client.parse_choice(raw, page()) |> should.be_error
}

pub fn rejects_bad_probabilities_and_unknown_operation_test() {
  let body = jev_client.choice_body(page(), "Apply", [], "jev")
  response(body, "CLICK", "e2")
  |> string.replace("\"confidence\":1.0", "\"confidence\":2.0")
  |> jev_client.parse_choice(page())
  |> should.be_error
  response(body, "DELETE", "e2")
  |> jev_client.parse_choice(page())
  |> should.be_error
  response(body, "CLICK", "e2")
  |> string.replace("\"CLICK\":1", "\"CLICK\":0")
  |> jev_client.parse_choice(page())
  |> should.be_error
}

pub fn done_is_explicitly_unverified_test() {
  let body = jev_client.choice_body(page(), "Apply", [], "jev")
  response(body, "DONE", "")
  |> jev_client.parse_choice(page())
  |> should.equal(Ok(jev_client.Stop("done_unverified")))
}

pub fn dropdown_options_do_not_replace_the_observed_current_value_test() {
  let assert [_, _, select, ..] = page().actions
  let blue = observation.Action(..select, node: 7)
  let green =
    observation.Action(..blue, id: "e4", label: "Color → Green", value: "green")
  let state = observation.Page(..page(), actions: [blue, green])
  let body =
    jev_client.choice_body(state, "Choose Blue then Apply", [], "jev")
    |> json.to_string
  let element = {
    use label <- decode.field("label", decode.string)
    use current <- decode.field("value", decode.string)
    use operations <- decode.field("operations", decode.list(decode.string))
    use choices <- decode.field(
      "options",
      decode.list(decode.at(["value"], decode.string)),
    )
    decode.success(#(label, current, operations, choices))
  }
  json.parse(body, decode.at(["state", "elements"], decode.list(element)))
  |> should.equal(Ok([#("Color", "Red", ["SELECT"], ["blue", "green"])]))
  json.parse(
    body,
    decode.at(
      ["questions", "select_target", "criteria", "e3", "current_value"],
      decode.string,
    ),
  )
  |> should.equal(Ok("Red"))
}

pub fn text_response(content: String) -> String {
  json.to_string(
    json.object([
      #(
        "choices",
        json.preprocessed_array([
          json.object([
            #("message", json.object([#("content", json.string(content))])),
          ]),
        ]),
      ),
    ]),
  )
}

pub fn rejects_missing_or_extra_text_fields_test() {
  let assert [action, ..] = page().actions
  list.each(
    [
      "{\"text\":null}",
      "{\"text\":\"value\",\"code\":\"bad\"}",
      "{\"text\":\"   \"}",
    ],
    fn(content) {
      let client =
        jev_client.Client(fn(_, _, _, _) { Ok(text_response(content)) })
      jev_client.field_text(client, config(), page(), action, "goal", [], 1000)
      |> should.be_error
    },
  )
}

pub fn accepts_text_as_data_test() {
  let assert [action, ..] = page().actions
  let text = "Quotes ' and \" and $() stay text"
  let client =
    jev_client.Client(fn(_, _, _, _) {
      Ok(
        text_response(
          json.to_string(json.object([#("text", json.string(text))])),
        ),
      )
    })
  jev_client.field_text(client, config(), page(), action, "goal", [], 1000)
  |> should.equal(Ok(text))
}

pub fn codex_text_uses_existing_provider_and_validates_json_test() {
  let assert [action, ..] = page().actions
  let config =
    jev_client.Config(
      ..config(),
      text_model: "openai-codex/gpt-5.6-luna",
      text_key: "",
      text_url: "",
    )
  let client =
    jev_client.CodexClient(
      post: fn(_, _, _, _) {
        panic as "Codex text must not use Chat Completions"
      },
      text: fn(model, messages, timeout) {
        model |> should.equal("openai-codex/gpt-5.6-luna")
        timeout |> should.equal(1234)
        let assert [llm.SystemMessage(_), llm.UserMessage(context)] = messages
        string.contains(context, "original goal") |> should.be_true
        Ok("{\"text\":\"Aura\"}")
      },
    )
  // Request tracing must retain the Codex transport.
  let client =
    jev_client.with_post(client, fn(_, _, _, _) {
      panic as "Unexpected HTTP request"
    })
  jev_client.field_text(
    client,
    config,
    page(),
    action,
    "original goal",
    [],
    1234,
  )
  |> should.equal(Ok("Aura"))
  let bad =
    jev_client.CodexClient(client.post, fn(_, _, _) { Ok("{\"text\":null}") })
  jev_client.field_text(bad, config, page(), action, "goal", [], 1234)
  |> should.be_error
}

pub fn codex_progress_does_not_extend_deadline_test() {
  codex_deadline() |> should.be_true
}

pub fn codex_request_stops_when_browser_worker_dies_test() {
  codex_owner_death() |> should.be_true
}

@external(erlang, "aura_jev_test_helpers", "codex_deadline")
fn codex_deadline() -> Bool

@external(erlang, "aura_jev_test_helpers", "codex_owner_death")
fn codex_owner_death() -> Bool
