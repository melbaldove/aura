import aura/blather/thread_channel
import aura/clients/blather
import aura/config
import gleeunit/should

pub fn production_returns_transport_wired_to_config_test() {
  let cfg =
    config.BlatherConfig(url: "http://host:18100/api", api_key: "blather_xyz")
  let t = blather.production(cfg)

  // Unsupported methods must return Error per the Transport contract
  // (src/aura/transport.gleam — ENGINEERING #12, no silent errors).
  case t.get_channel_parent("ch") {
    Error(_) -> Nil
    Ok(_) -> should.fail()
  }
  t.get_channel_parent(thread_channel.make("ch", "msg"))
  |> should.equal(Ok("ch"))
  case t.send_message_with_attachment("ch", "body", "/tmp/file") {
    Error(_) -> Nil
    Ok(_) -> should.fail()
  }
  t.create_thread_from_message("ch", "msg", "name")
  |> should.equal(Ok(thread_channel.make("ch", "msg")))
}
