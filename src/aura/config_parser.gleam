import aura/env
import gleam/result
import gleam/string

pub fn resolve_env_string(value: String) -> Result(String, String) {
  case string.starts_with(value, "${") && string.ends_with(value, "}") {
    True -> {
      let var_name =
        value
        |> string.drop_start(2)
        |> string.drop_end(1)
      env.get_env(var_name)
      |> result.map_error(fn(_) {
        "Environment variable not set: " <> var_name
      })
    }
    False -> Ok(value)
  }
}
