import aura/dotenv
import aura/test_helpers
import gleam/list
import gleeunit/should
import simplifile

pub fn parse_env_file_test() {
  let content = "AURA_DISCORD_TOKEN=abc123\nZAI_API_KEY=def456\n"
  let pairs = dotenv.parse(content)
  list.length(pairs) |> should.equal(2)
}

pub fn parse_with_comments_test() {
  let content = "# This is a comment\nKEY=value\n\n# Another comment\nKEY2=value2\n"
  let pairs = dotenv.parse(content)
  list.length(pairs) |> should.equal(2)
}

pub fn parse_with_double_quotes_test() {
  let pairs = dotenv.parse("KEY=\"quoted value\"\n")
  case pairs {
    [#("KEY", val)] -> val |> should.equal("quoted value")
    _ -> should.fail()
  }
}

pub fn parse_with_single_quotes_test() {
  let pairs = dotenv.parse("KEY='single quoted'\n")
  case pairs {
    [#("KEY", val)] -> val |> should.equal("single quoted")
    _ -> should.fail()
  }
}

pub fn parse_empty_test() {
  dotenv.parse("") |> list.length |> should.equal(0)
  dotenv.parse("\n\n") |> list.length |> should.equal(0)
}

pub fn load_file_test() {
  let base = "/tmp/aura-dotenv-test-" <> test_helpers.random_suffix()
  let _ = simplifile.create_directory_all(base)
  let path = base <> "/.env"
  let _ = simplifile.write(path, "TEST_DOTENV_UNIQUE_KEY=hello123\n")

  dotenv.load(path) |> should.be_ok

  // Verify the env var was set
  case env_get("TEST_DOTENV_UNIQUE_KEY") {
    Ok(val) -> val |> should.equal("hello123")
    Error(_) -> should.fail()
  }

  let _ = simplifile.delete_all([base])
  Nil
}

@external(erlang, "aura_env_ffi", "get_env")
fn env_get(name: String) -> Result(String, Nil)
