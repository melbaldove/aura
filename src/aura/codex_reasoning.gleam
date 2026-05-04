import gleam/list
import gleam/string

pub const default_effort = "medium"

pub fn normalize(effort: String) -> String {
  effort |> string.trim |> string.lowercase
}

pub fn supported_efforts() -> List(String) {
  ["none", "minimal", "low", "medium", "high", "xhigh"]
}

pub fn is_supported(effort: String) -> Bool {
  list.contains(supported_efforts(), normalize(effort))
}
