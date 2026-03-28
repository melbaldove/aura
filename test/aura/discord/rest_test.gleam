import aura/discord/rest
import gleeunit/should

pub fn api_url_test() {
  rest.api_url("/channels/123/messages")
  |> should.equal("https://discord.com/api/v10/channels/123/messages")
}

pub fn auth_header_test() {
  let header = rest.auth_header("my-token")
  header.0 |> should.equal("authorization")
  header.1 |> should.equal("Bot my-token")
}
