import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string

pub type Action {
  Action(
    id: String,
    kind: String,
    label: String,
    role: String,
    value: String,
    current_value: String,
    checked: String,
    selected: String,
    expanded: String,
    node: Int,
  )
}

pub type Page {
  Page(
    token: String,
    url: String,
    title: String,
    text: String,
    fingerprint: String,
    actions: List(Action),
  )
}

pub fn decode_page(raw: String) -> Result(Page, String) {
  let action = {
    use id <- decode.field("id", decode.string)
    use kind <- decode.field("kind", decode.string)
    use label <- decode.field("label", decode.string)
    use role <- decode.optional_field("role", "", decode.string)
    use value <- decode.optional_field("value", "", decode.string)
    use current_value <- decode.optional_field(
      "current_value",
      value,
      decode.string,
    )
    use checked <- decode.optional_field("checked", "", decode.string)
    use selected <- decode.optional_field("selected", "", decode.string)
    use expanded <- decode.optional_field("expanded", "", decode.string)
    use node <- decode.optional_field("node", 0, decode.int)
    decode.success(Action(
      id,
      kind,
      label,
      role,
      value,
      current_value,
      checked,
      selected,
      expanded,
      node,
    ))
  }
  let page = {
    use token <- decode.field("token", decode.string)
    use url <- decode.field("url", decode.string)
    use title <- decode.field("title", decode.string)
    use text <- decode.field("text", decode.string)
    use fingerprint <- decode.field("fingerprint", decode.string)
    use actions <- decode.field("actions", decode.list(action))
    decode.success(Page(token, url, title, text, fingerprint, actions))
  }
  json.parse(raw, decode.at(["data", "result"], page))
  |> result.map_error(fn(_) { "Invalid browser observation" })
}

pub fn page_json(page: Page) -> json.Json {
  json.object([
    #("url", json.string(page.url)),
    #("title", json.string(page.title)),
    #("text", json.string(page.text)),
  ])
}

pub fn action_json(action: Action) -> json.Json {
  json.object([
    #("index", json.string(action.id)),
    #("label", json.string(action.label)),
    #("role", json.string(action.role)),
    #("value", json.string(action.current_value)),
    #("option_value", json.string(action.value)),
    #("checked", json.string(action.checked)),
    #("selected", json.string(action.selected)),
    #("expanded", json.string(action.expanded)),
    #("operation", json.string(operation(action))),
  ])
}

pub fn target_json(action: Action) -> json.Json {
  json.object([
    #("element", json.string("[" <> action.id <> "] " <> action.label)),
    #("current_value", json.string(action.current_value)),
    #("role", json.string(action.role)),
    #("checked", json.string(action.checked)),
    #("selected", json.string(action.selected)),
    #("expanded", json.string(action.expanded)),
  ])
}

// One row per observed node. Dropdown options are choices, not current values.
pub fn elements_json(actions: List(Action)) -> json.Json {
  let targets =
    list.filter(actions, fn(a) {
      a.kind == "click" || a.kind == "fill" || a.kind == "select"
    })
  let nodes = list.map(targets, node_key) |> list.unique
  json.array(nodes, fn(node) {
    let group = list.filter(targets, fn(a) { node_key(a) == node })
    let assert [first, ..] = group
    let label =
      string.split(first.label, " → ")
      |> list.first
      |> result.unwrap(first.label)
    let base = [
      #("index", json.string(first.id)),
      #("label", json.string(label)),
      #("role", json.string(first.role)),
      #("value", json.string(first.current_value)),
      #("checked", json.string(first.checked)),
      #("selected", json.string(first.selected)),
      #("expanded", json.string(first.expanded)),
      #(
        "operations",
        json.array(list.map(group, operation) |> list.unique, json.string),
      ),
    ]
    json.object(case first.kind {
      "select" -> [
        #(
          "options",
          json.array(group, fn(a) {
            json.object([
              #("index", json.string(a.id)),
              #("label", json.string(a.label)),
              #("value", json.string(a.value)),
            ])
          }),
        ),
        ..base
      ]
      _ -> base
    })
  })
}

fn node_key(action: Action) -> String {
  case action.node {
    0 -> action.id
    node -> int.to_string(node)
  }
}

pub fn operation(action: Action) -> String {
  case action.kind, action.id {
    "click", _ -> "CLICK"
    "fill", _ -> "TYPE_TEXT"
    "select", _ -> "SELECT"
    "scroll", "scroll_up" -> "SCROLL_UP"
    "scroll", "scroll_down" -> "SCROLL_DOWN"
    "wait", _ -> "WAIT"
    _, _ -> ""
  }
}
