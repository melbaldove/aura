import aura/config
import gleam/dict
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some, type Option}
import gleam/result
import gleam/regexp
import gleam/string
import tom

/// Lane a hook rule fires into.
pub type Lane {
  Event
  Notify
  Ask
}

/// A single parsed hook rule with a pre-compiled matcher regex.
pub type Rule {
  Rule(
    name: String,
    lane: Lane,
    regex: regexp.Regexp,
    target: String,
    text: String,
    buttons: List(String),
    ttl_minutes: Int,
    external_id_template: Option(String),
  )
}

/// A parsed hook ruleset from a TOML file.
pub type Ruleset {
  Ruleset(name: String, source: String, rules: List(Rule))
}

/// A decoded action to fire for a matching line.
pub type Fire {
  FireEvent(rule_name: String, subject: String, external_id: String, data: String)
  FireNotify(rule_name: String, target: String, text: String, external_id: String)
  FireAsk(
    rule_name: String,
    target: String,
    text: String,
    buttons: List(String),
    ttl_minutes: Int,
    correlation_id: String,
  )
}

/// Parse a hook ruleset TOML document. Every rule's `match` regex is compiled
/// up front, so a bad pattern is a parse error rather than a runtime surprise.
pub fn parse(toml_string: String) -> Result(Ruleset, String) {
  use doc <- result.try(
    tom.parse(toml_string)
    |> result.map_error(fn(e) { "TOML parse error: " <> config.format_parse_error(e) }),
  )
  use name <- result.try(
    tom.get_string(doc, ["name"]) |> result.map_error(fn(_) { "Missing ruleset.name" }),
  )
  use source <- result.try(
    tom.get_string(doc, ["source"]) |> result.map_error(fn(_) { "Missing ruleset.source" }),
  )

  let rule_tomls = tom.get_array(doc, ["rule"]) |> result.unwrap([])
  use rules <- result.try(list.try_map(rule_tomls, parse_one_rule))

  Ok(Ruleset(name: name, source: source, rules: rules))
}

fn parse_one_rule(toml_value: tom.Toml) -> Result(Rule, String) {
  let tbl = case toml_value {
    tom.Table(t) -> t
    tom.InlineTable(t) -> t
    _ -> dict.new()
  }
  use name <- result.try(
    tom.get_string(tbl, ["name"]) |> result.map_error(fn(_) { "Missing rule.name" }),
  )
  use match_pattern <- result.try(
    tom.get_string(tbl, ["match"]) |> result.map_error(fn(_) { "Missing rule.match" }),
  )
  use lane_str <- result.try(
    tom.get_string(tbl, ["lane"]) |> result.map_error(fn(_) { "Missing rule.lane" }),
  )
  use lane <- result.try(parse_lane(lane_str))
  use regex <- result.try(
    regexp.compile(
      match_pattern,
      with: regexp.Options(case_insensitive: False, multi_line: False),
    )
    |> result.map_error(fn(e) { "Invalid regex for rule '" <> name <> "': " <> e.error }),
  )
  use target <- result.try(
    tom.get_string(tbl, ["target"]) |> result.map_error(fn(_) { "Missing rule.target" }),
  )
  use text <- result.try(
    tom.get_string(tbl, ["text"]) |> result.map_error(fn(_) { "Missing rule.text" }),
  )

  let buttons =
    tom.get_array(tbl, ["buttons"])
    |> result.unwrap([])
    |> list.filter_map(tom.as_string)
  let ttl_minutes = tom.get_int(tbl, ["ttl_minutes"]) |> result.unwrap(60)
  let external_id_template = tom.get_string(tbl, ["external_id"]) |> result.unwrap("")

  Ok(Rule(
    name: name,
    lane: lane,
    regex: regex,
    target: target,
    text: text,
    buttons: buttons,
    ttl_minutes: ttl_minutes,
    external_id_template: case external_id_template {
      "" -> None
      template -> Some(template)
    },
  ))
}

fn parse_lane(lane: String) -> Result(Lane, String) {
  case lane {
    "event" -> Ok(Event)
    "notify" -> Ok(Notify)
    "ask" -> Ok(Ask)
    other -> Error("Unknown lane: " <> other)
  }
}

/// Match a single hook line against every rule, rendering the text/external_id
/// templates for each match. An out-of-range template reference is an error —
/// the wrapper logs it noisily rather than silently dropping a fired action.
pub fn match_line(
  ruleset: Ruleset,
  line: String,
  now_ms: Int,
) -> Result(List(Fire), String) {
  list.try_map(ruleset.rules, fn(rule) {
    let matches = regexp.scan(with: rule.regex, content: line)
    list.try_map(matches, fn(m) { render_fire(ruleset, rule, line, m, now_ms) })
  })
  |> result.map(list.flatten)
}

fn render_fire(
  ruleset: Ruleset,
  rule: Rule,
  line: String,
  m: regexp.Match,
  now_ms: Int,
) -> Result(Fire, String) {
  use text <- result.try(render_template(rule.text, line, m))

  case rule.lane {
    Event ->
      Ok(FireEvent(
        rule_name: rule.name,
        subject: text,
        external_id: resolved_external_id(rule, line, m, ruleset.source, text),
        data: json.object([#("line", json.string(line))]) |> json.to_string,
      ))
    Notify ->
      Ok(FireNotify(
        rule_name: rule.name,
        target: rule.target,
        text: text,
        external_id: resolved_external_id(rule, line, m, ruleset.source, text),
      ))
    Ask -> {
      let correlation_id =
        case rule.external_id_template {
          Some(template) ->
            render_template(template, line, m) |> result.map_error(fn(_) {
              "template correlation_id group out of range"
            })
          None ->
            Ok(
              ruleset.source <> "-" <> rule.name <> "-" <> int.to_string(now_ms),
            )
        }
      use cid <- result.try(correlation_id)
      Ok(FireAsk(
        rule_name: rule.name,
        target: rule.target,
        text: text,
        buttons: rule.buttons,
        ttl_minutes: rule.ttl_minutes,
        correlation_id: cid,
      ))
    }
  }
}

fn resolved_external_id(
  rule: Rule,
  line: String,
  m: regexp.Match,
  source: String,
  rendered_text: String,
) -> String {
  let default_ext = source <> ":" <> rule.name <> ":" <> rendered_text
  case rule.external_id_template {
    None -> default_ext
    Some(template) ->
      render_template(template, line, m) |> result.unwrap(default_ext)
  }
}

/// Render a template string, substituting `{line}` (the whole line), `{0}`
/// (the whole regex match), and `{1}`..`{n}` (capture groups). Referencing an
/// out-of-range or unmatched group is an error.
pub fn render_template(
  template: String,
  line: String,
  m: regexp.Match,
) -> Result(String, String) {
  let groups = list.map(m.submatches, fn(o) { option.unwrap(o, "") })
  // {0} is the whole match; {1}..{n} are capture groups; `{line}` is the line.
  let pool = [m.content, ..groups]
  segment(template, line, pool)
    |> result.map(string.join(_, ""))
}

/// Split the template on `{`, resolving each `{N}` token against the value
/// pool. Tokens with no closing `}` are left verbatim (they are not templates).
fn segment(
  template: String,
  line: String,
  pool: List(String),
) -> Result(List(String), String) {
  let raw = string.split(template, on: "{")
  case raw {
    [] -> Ok([])
    [first, ..rest] ->
      list.try_map(rest, fn(chunk) {
        case string.split_once(chunk, on: "}") {
          Error(_) -> Ok(chunk)
          Ok(#(index_str, tail)) ->
            render_one(index_str, line, pool)
            |> result.map(fn(value) { value <> tail })
        }
      })
      |> result.map(fn(replacements) { [first, ..replacements] })
  }
}

fn render_one(index_str: String, line: String, pool: List(String)) -> Result(String, String) {
  case index_str {
    "line" -> Ok(line)
    _ ->
      case int.parse(index_str) {
        Ok(index) -> string_fetch(pool, index, index_str)
        Error(_) -> Ok("{")
      }
  }
}

fn string_fetch(
  pool: List(String),
  index: Int,
  index_str: String,
) -> Result(String, String) {
  case pool {
    [] -> Error("template group " <> index_str <> " out of range")
    [head, ..rest] ->
      case index {
        0 -> Ok(head)
        _ -> string_fetch(rest, index - 1, index_str)
      }
  }
}