import aura/supervisor
import gleam/string
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

pub fn resolve_channel_id_matches_configured_name_test() {
  supervisor.resolve_channel_id("discord.default_channel", "general", [
    #("general", "111111111111111111"),
    #("hy", "222222222222222222"),
  ])
  |> should.equal(Ok("111111111111111111"))
}

pub fn resolve_channel_id_accepts_numeric_id_test() {
  supervisor.resolve_channel_id(
    "discord.default_channel",
    "333333333333333333",
    [],
  )
  |> should.equal(Ok("333333333333333333"))
}

pub fn resolve_channel_id_accepts_hash_prefixed_name_test() {
  supervisor.resolve_channel_id("discord.default_channel", "#general", [
    #("general", "111111111111111111"),
  ])
  |> should.equal(Ok("111111111111111111"))
}

pub fn resolve_channel_id_rejects_unknown_name_test() {
  let result =
    supervisor.resolve_channel_id("discord.default_channel", "aura", [
      #("general", "111111111111111111"),
      #("hy", "222222222222222222"),
    ])

  case result {
    Ok(_) -> should.fail()
    Error(error) -> {
      error |> string.contains("discord.default_channel") |> should.be_true
      error |> string.contains("'aura'") |> should.be_true
      error |> string.contains("general, hy") |> should.be_true
    }
  }
}
