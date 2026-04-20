import aura/acp/types
import gleam/list
import gleam/string

pub fn empty_report() -> types.AcpReport {
  types.AcpReport(
    outcome: types.OutcomeUnknown,
    files_changed: [],
    decisions: "",
    tests: "",
    blockers: "",
    anchor: "",
  )
}

pub fn parse(output: String) -> Result(types.AcpReport, String) {
  // Normalize: trim each line to handle tmux indentation
  let normalized =
    output
    |> string.split("\n")
    |> list.map(string.trim)
    |> string.join("\n")

  // Split on ALL occurrences of the marker and take the LAST block.
  // The prompt contains the marker as instructions — we want Claude's actual output,
  // which is always the last occurrence.
  let parts = string.split(normalized, "---AURA-REPORT---")
  case list.last(parts) {
    Error(_) -> Error("No ---AURA-REPORT--- marker found")
    Ok(last_part) -> {
      // Only valid if there were at least 2 parts (marker appeared at least once)
      case list.length(parts) < 2 {
        True -> Error("No ---AURA-REPORT--- marker found")
        False -> {
          case string.split_once(last_part, "---END-REPORT---") {
            Error(_) -> Error("No ---END-REPORT--- marker found")
            Ok(#(block, _)) -> {
              let lines =
                block
                |> string.split("\n")
                |> list.map(string.trim)
                |> list.filter(fn(l) { l != "" })
              Ok(parse_lines(lines, empty_report()))
            }
          }
        }
      }
    }
  }
}

fn parse_lines(lines: List(String), acc: types.AcpReport) -> types.AcpReport {
  case lines {
    [] -> acc
    [line, ..rest] -> {
      let updated = parse_line(line, acc)
      parse_lines(rest, updated)
    }
  }
}

fn parse_line(line: String, acc: types.AcpReport) -> types.AcpReport {
  case string.split_once(line, ":") {
    Error(_) -> acc
    Ok(#(key, value)) -> {
      let v = string.trim(value)
      case string.trim(key) {
        "OUTCOME" ->
          types.AcpReport(..acc, outcome: parse_outcome(string.lowercase(v)))
        "FILES_CHANGED" ->
          types.AcpReport(..acc, files_changed: parse_files_changed(v))
        "DECISIONS" -> types.AcpReport(..acc, decisions: v)
        "TESTS" -> types.AcpReport(..acc, tests: v)
        "BLOCKERS" -> types.AcpReport(..acc, blockers: v)
        "ANCHOR" -> types.AcpReport(..acc, anchor: v)
        _ -> acc
      }
    }
  }
}

fn parse_outcome(s: String) -> types.Outcome {
  case s {
    "clean" -> types.Clean
    "partial" -> types.Partial
    "failed" -> types.Failed
    _ -> types.OutcomeUnknown
  }
}

fn parse_files_changed(s: String) -> List(String) {
  s
  |> string.split(",")
  |> list.map(string.trim)
  |> list.filter(fn(f) { f != "" && string.lowercase(f) != "none" })
}
