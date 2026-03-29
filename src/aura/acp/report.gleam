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
  case string.split_once(output, "---AURA-REPORT---") {
    Error(_) -> Error("No ---AURA-REPORT--- marker found")
    Ok(#(_, after_marker)) -> {
      case string.split_once(after_marker, "---END-REPORT---") {
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

fn parse_lines(
  lines: List(String),
  acc: types.AcpReport,
) -> types.AcpReport {
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
          types.AcpReport(
            ..acc,
            outcome: parse_outcome(string.lowercase(v)),
          )
        "FILES_CHANGED" ->
          types.AcpReport(
            ..acc,
            files_changed: parse_files_changed(v),
          )
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
