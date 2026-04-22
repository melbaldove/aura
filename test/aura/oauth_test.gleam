import aura/oauth
import aura/time
import gleam/int
import gleeunit
import gleeunit/should
import simplifile

pub fn main() {
  gleeunit.main()
}

pub fn is_expired_after_expiry_test() {
  let tokens =
    oauth.TokenSet(
      access_token: "a",
      refresh_token: "r",
      expires_at_ms: 1000,
    )
  oauth.is_expired(tokens, now_ms: 2000)
  |> should.equal(True)
}

pub fn is_expired_within_buffer_test() {
  let tokens =
    oauth.TokenSet(
      access_token: "a",
      refresh_token: "r",
      expires_at_ms: 10_000,
    )
  oauth.is_expired(tokens, now_ms: 9_950)
  |> should.equal(True)
}

pub fn is_expired_before_buffer_test() {
  let tokens =
    oauth.TokenSet(
      access_token: "a",
      refresh_token: "r",
      expires_at_ms: 10_000_000,
    )
  oauth.is_expired(tokens, now_ms: 8_000)
  |> should.equal(False)
}

pub fn tokens_round_trip_test() {
  let path =
    "/tmp/aura-oauth-roundtrip-" <> int.to_string(time.now_ms()) <> ".json"
  let tokens =
    oauth.TokenSet(
      access_token: "ya29.access",
      refresh_token: "1//refresh",
      expires_at_ms: 1_776_880_000_000,
    )

  let assert Ok(Nil) = oauth.save_token_set(path, tokens)
  let assert Ok(loaded) = oauth.load_token_set(path)
  loaded
  |> should.equal(tokens)

  let _ = simplifile.delete(path)
}

pub fn load_nonexistent_returns_error_test() {
  let path =
    "/tmp/aura-oauth-missing-" <> int.to_string(time.now_ms()) <> ".json"
  oauth.load_token_set(path)
  |> should.be_error
}

pub fn load_malformed_json_returns_error_test() {
  let path =
    "/tmp/aura-oauth-malformed-" <> int.to_string(time.now_ms()) <> ".json"
  let assert Ok(Nil) = simplifile.write(path, "{not valid json")
  let result = oauth.load_token_set(path)
  let _ = simplifile.delete(path)
  result
  |> should.be_error
}
