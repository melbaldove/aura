import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import tom

pub type Rule {
  Rule(path: String, rule_type: RuleType, message: String)
}

pub type RuleType {
  ValidToml
  ValidJsonl
  MustContain(value: String)
  NoPatterns(patterns: List(String))
  MaxSizeKb(kb: Int)
  RequiredFields(fields: List(String))
}

/// Glob matching with `*` as single-segment wildcard.
/// Splits both pattern and path by "/" and matches segment by segment.
pub fn path_matches(file_path: String, pattern: String) -> Bool {
  let path_segments = string.split(file_path, "/")
  let pattern_segments = string.split(pattern, "/")
  match_segments(path_segments, pattern_segments)
}

fn match_segments(
  path_segments: List(String),
  pattern_segments: List(String),
) -> Bool {
  case path_segments, pattern_segments {
    [], [] -> True
    [_path_seg, ..path_rest], ["*", ..pattern_rest] ->
      match_segments(path_rest, pattern_rest)
    [path_seg, ..path_rest], [pattern_seg, ..pattern_rest] ->
      match_segment(path_seg, pattern_seg)
      && match_segments(path_rest, pattern_rest)
    _, _ -> False
  }
}

/// Match a single segment: supports `*` prefix/suffix patterns like "*.toml"
fn match_segment(segment: String, pattern: String) -> Bool {
  case pattern {
    "*" -> True
    _ ->
      case string.starts_with(pattern, "*") {
        True -> {
          let suffix = string.drop_start(pattern, 1)
          string.ends_with(segment, suffix)
        }
        False ->
          case string.ends_with(pattern, "*") {
            True -> {
              let prefix =
                string.drop_end(pattern, 1)
              string.starts_with(segment, prefix)
            }
            False -> segment == pattern
          }
      }
  }
}

/// Check one rule against content.
pub fn check_rule(rule: Rule, content: String) -> Result(Nil, String) {
  case rule.rule_type {
    ValidToml -> check_valid_toml(content, rule.message)
    ValidJsonl -> check_valid_jsonl(content, rule.message)
    MustContain(value) -> check_must_contain(content, value, rule.message)
    NoPatterns(patterns) -> check_no_patterns(content, patterns, rule.message)
    MaxSizeKb(kb) -> check_max_size(content, kb, rule.message)
    RequiredFields(fields) ->
      check_required_fields(content, fields, rule.message)
  }
}

fn check_valid_toml(content: String, message: String) -> Result(Nil, String) {
  case tom.parse(content) {
    Ok(_) -> Ok(Nil)
    Error(_) -> Error(message)
  }
}

fn check_valid_jsonl(content: String, message: String) -> Result(Nil, String) {
  let lines =
    content
    |> string.split("\n")
    |> list.filter(fn(line) { string.trim(line) != "" })
  case list.all(lines, fn(line) { is_valid_json(line) }) {
    True -> Ok(Nil)
    False -> Error(message)
  }
}

fn is_valid_json(line: String) -> Bool {
  case json.parse(line, decode.dynamic) {
    Ok(_) -> True
    Error(_) -> False
  }
}

fn check_must_contain(
  content: String,
  value: String,
  message: String,
) -> Result(Nil, String) {
  case string.contains(content, value) {
    True -> Ok(Nil)
    False -> Error(message)
  }
}

fn check_no_patterns(
  content: String,
  patterns: List(String),
  message: String,
) -> Result(Nil, String) {
  let lower_content = string.lowercase(content)
  let found =
    list.any(patterns, fn(pattern) {
      string.contains(lower_content, string.lowercase(pattern))
    })
  case found {
    True -> Error(message)
    False -> Ok(Nil)
  }
}

fn check_max_size(
  content: String,
  kb: Int,
  message: String,
) -> Result(Nil, String) {
  case string.byte_size(content) <= kb * 1024 {
    True -> Ok(Nil)
    False -> Error(message)
  }
}

fn check_required_fields(
  content: String,
  fields: List(String),
  message: String,
) -> Result(Nil, String) {
  case tom.parse(content) {
    Error(_) -> Error(message)
    Ok(doc) -> {
      let missing =
        list.filter(fields, fn(field) {
          let path = string.split(field, ".")
          case tom.get(doc, path) {
            Ok(_) -> False
            Error(_) -> True
          }
        })
      case missing {
        [] -> Ok(Nil)
        _ -> Error(message)
      }
    }
  }
}

/// Find all rules whose path matches file_path, check each.
/// First failure stops.
pub fn validate(
  file_path: String,
  content: String,
  rules: List(Rule),
) -> Result(Nil, String) {
  let matching_rules =
    list.filter(rules, fn(rule) { path_matches(file_path, rule.path) })
  list.try_each(matching_rules, fn(rule) { check_rule(rule, content) })
}

/// Parse `[[rules]]` array-of-tables from TOML content.
pub fn parse_rules(
  toml_content: String,
) -> Result(List(Rule), String) {
  case tom.parse(toml_content) {
    Error(_) -> Error("Failed to parse TOML")
    Ok(doc) -> {
      case tom.get_array(doc, ["rules"]) {
        Error(_) -> Error("No [[rules]] section found")
        Ok(tables) -> {
          list.try_map(tables, parse_single_rule)
        }
      }
    }
  }
}

fn parse_single_rule(toml_value: tom.Toml) -> Result(Rule, String) {
  case toml_value {
    tom.Table(table) | tom.InlineTable(table) -> {
      use path <- result.try(
        tom.get_string(table, ["path"])
        |> result.map_error(fn(_) { "Rule missing 'path' field" }),
      )
      use rule_type_str <- result.try(
        tom.get_string(table, ["type"])
        |> result.map_error(fn(_) { "Rule missing 'type' field" }),
      )
      use message <- result.try(
        tom.get_string(table, ["message"])
        |> result.map_error(fn(_) { "Rule missing 'message' field" }),
      )
      use rule_type <- result.try(parse_rule_type(rule_type_str, table))
      Ok(Rule(path: path, rule_type: rule_type, message: message))
    }
    _ -> Error("Expected table in [[rules]] array")
  }
}

fn parse_rule_type(
  type_str: String,
  table: dict.Dict(String, tom.Toml),
) -> Result(RuleType, String) {
  case type_str {
    "valid_toml" -> Ok(ValidToml)
    "valid_jsonl" -> Ok(ValidJsonl)
    "must_contain" -> {
      use value <- result.try(
        tom.get_string(table, ["value"])
        |> result.map_error(fn(_) {
          "must_contain rule requires 'value' field"
        }),
      )
      Ok(MustContain(value))
    }
    "no_patterns" -> {
      use patterns_toml <- result.try(
        tom.get_array(table, ["patterns"])
        |> result.map_error(fn(_) {
          "no_patterns rule requires 'patterns' field"
        }),
      )
      use patterns <- result.try(
        list.try_map(patterns_toml, fn(t) {
          case t {
            tom.String(s) -> Ok(s)
            _ -> Error("patterns must be strings")
          }
        }),
      )
      Ok(NoPatterns(patterns))
    }
    "max_size_kb" -> {
      use kb <- result.try(
        tom.get_int(table, ["kb"])
        |> result.map_error(fn(_) { "max_size_kb rule requires 'kb' field" }),
      )
      Ok(MaxSizeKb(kb))
    }
    "required_fields" -> {
      use fields_toml <- result.try(
        tom.get_array(table, ["fields"])
        |> result.map_error(fn(_) {
          "required_fields rule requires 'fields' field"
        }),
      )
      use fields <- result.try(
        list.try_map(fields_toml, fn(t) {
          case t {
            tom.String(s) -> Ok(s)
            _ -> Error("fields must be strings")
          }
        }),
      )
      Ok(RequiredFields(fields))
    }
    _ -> Error("Unknown rule type: " <> type_str)
  }
}
