import gleam/list
import gleam/result
import gleam/string
import simplifile

@external(erlang, "aura_env_ffi", "set_env")
fn set_env(key: String, value: String) -> Nil

pub fn parse(content: String) -> List(#(String, String)) {
  content
  |> string.split("\n")
  |> list.filter(fn(line) {
    let trimmed = string.trim(line)
    trimmed != "" && !string.starts_with(trimmed, "#")
  })
  |> list.filter_map(fn(line) {
    use #(key, value) <- result.map(string.split_once(line, "="))
    let key = string.trim(key)
    let value = strip_quotes(string.trim(value))
    #(key, value)
  })
}

fn strip_quotes(value: String) -> String {
  let len = string.length(value)
  case len >= 2 {
    True -> {
      let first = string.slice(value, 0, 1)
      let last = string.slice(value, len - 1, 1)
      case first, last {
        "\"", "\"" -> string.slice(value, 1, len - 2)
        "'", "'" -> string.slice(value, 1, len - 2)
        _, _ -> value
      }
    }
    False -> value
  }
}

pub fn load(path: String) -> Result(Nil, String) {
  case simplifile.read(path) {
    Error(e) -> Error("Failed to read file: " <> simplifile.describe_error(e))
    Ok(content) -> {
      let pairs = parse(content)
      list.each(pairs, fn(pair) { set_env(pair.0, pair.1) })
      Ok(Nil)
    }
  }
}
