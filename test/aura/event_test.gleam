import aura/event
import gleam/dict
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

pub fn tags_round_trip_test() {
  let tags =
    dict.from_list([
      #("domain", "work"),
      #("priority", "high"),
      #("from", "alice@example.com"),
    ])

  let json_string = event.tags_to_json(tags)
  let assert Ok(decoded) = event.tags_from_json(json_string)

  should.equal(decoded, tags)
}

pub fn tags_from_invalid_json_returns_error_test() {
  let result = event.tags_from_json("{not valid json")
  should.be_error(result)
}
