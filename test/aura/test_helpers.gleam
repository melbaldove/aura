import gleam/int
import gleam/string

pub fn random_suffix() -> String {
  erlang_unique_integer()
  |> int.to_string
  |> string.replace("-", "")
}

@external(erlang, "erlang", "unique_integer")
fn erlang_unique_integer() -> Int
