import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/json
import gleam/result
import gleam/string

/// An ambient-awareness event ingested from an external source
/// (gmail, linear, calendar, etc.). `type_` uses a trailing underscore
/// because `type` is a reserved Gleam keyword. `data` is the raw payload
/// stored verbatim as a JSON string.
pub type AuraEvent {
  AuraEvent(
    id: String,
    source: String,
    type_: String,
    subject: String,
    time_ms: Int,
    tags: Dict(String, String),
    external_id: String,
    data: String,
  )
}

/// Encode a tag dict as a JSON object string.
pub fn tags_to_json(tags: Dict(String, String)) -> String {
  json.dict(tags, fn(k) { k }, json.string)
  |> json.to_string
}

/// Decode a JSON object string into a tag dict.
/// Returns `Error` if the input is not valid JSON or not a flat
/// string-to-string object.
pub fn tags_from_json(raw: String) -> Result(Dict(String, String), String) {
  json.parse(raw, decode.dict(decode.string, decode.string))
  |> result.map_error(fn(err) {
    "Failed to decode tags JSON: " <> string.inspect(err)
  })
}
