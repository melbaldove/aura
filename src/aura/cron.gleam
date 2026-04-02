import gleam/int
import gleam/list
import gleam/result
import gleam/string

pub type CronField {
  Any
  Exact(Int)
  Step(Int)
}

pub type CronExpr {
  CronExpr(
    minute: CronField,
    hour: CronField,
    day_of_month: CronField,
    month: CronField,
    day_of_week: CronField,
  )
}

/// Parse a 5-field cron expression string.
pub fn parse(expression: String) -> Result(CronExpr, String) {
  let fields =
    string.split(string.trim(expression), " ")
    |> list.filter(fn(s) { s != "" })
  case fields {
    [min, hour, dom, month, dow] -> {
      use min_f <- result.try(parse_field(min, "minute"))
      use hour_f <- result.try(parse_field(hour, "hour"))
      use dom_f <- result.try(parse_field(dom, "day_of_month"))
      use month_f <- result.try(parse_field(month, "month"))
      use dow_f <- result.try(parse_field(dow, "day_of_week"))
      Ok(CronExpr(
        minute: min_f,
        hour: hour_f,
        day_of_month: dom_f,
        month: month_f,
        day_of_week: dow_f,
      ))
    }
    _ ->
      Error(
        "Expected 5 fields, got " <> int.to_string(list.length(fields)),
      )
  }
}

fn parse_field(field: String, name: String) -> Result(CronField, String) {
  case field {
    "*" -> Ok(Any)
    _ -> {
      case string.starts_with(field, "*/") {
        True -> {
          let step_str = string.drop_start(field, 2)
          case int.parse(step_str) {
            Ok(n) ->
              case n > 0 {
                True -> Ok(Step(n))
                False -> Error("Step must be > 0 in " <> name)
              }
            Error(_) ->
              Error("Invalid step in " <> name <> ": " <> field)
          }
        }
        False -> {
          case int.parse(field) {
            Ok(n) -> Ok(Exact(n))
            Error(_) ->
              Error("Invalid value in " <> name <> ": " <> field)
          }
        }
      }
    }
  }
}

/// Check if a cron expression matches the given time components.
/// minute: 0-59, hour: 0-23, day: 1-31, month: 1-12, weekday: 0-6 (0=Sunday)
pub fn matches(
  expr: CronExpr,
  minute minute: Int,
  hour hour: Int,
  day day: Int,
  month month: Int,
  weekday weekday: Int,
) -> Bool {
  field_matches(expr.minute, minute)
  && field_matches(expr.hour, hour)
  && field_matches(expr.day_of_month, day)
  && field_matches(expr.month, month)
  && field_matches(expr.day_of_week, weekday)
}

fn field_matches(field: CronField, value: Int) -> Bool {
  case field {
    Any -> True
    Exact(n) -> value == n
    Step(n) -> value % n == 0
  }
}
