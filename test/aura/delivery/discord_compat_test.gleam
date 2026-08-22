import aura/delivery/discord_compat
import aura/discord/message as discord_message
import aura/transport.{type Transport, Transport}
import gleam/erlang/process
import gleam/otp/actor
import gleam/string
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

type Message {
  Send(reply: process.Subject(Result(String, String)))
}

fn scripted_transport() -> Transport {
  let assert Ok(started) =
    actor.new(0)
    |> actor.on_message(fn(count, message) {
      let Send(reply:) = message
      process.send(reply, case count {
        0 -> Ok("message-1")
        _ -> Error("connection lost")
      })
      actor.continue(count + 1)
    })
    |> actor.start
  Transport(
    send_message: fn(_, _) {
      process.call(started.data, 1000, fn(reply) { Send(reply:) })
    },
    edit_message: fn(_, _, _) { Ok(Nil) },
    trigger_typing: fn(_) { Ok(Nil) },
    get_channel_parent: fn(_) { Ok("") },
    send_message_with_attachment: fn(_, _, _) { Error("not used") },
    create_thread_from_message: fn(_, _, _) { Error("not used") },
  )
}

pub fn partial_delivery_returns_visible_prefix_and_receipt_test() {
  let content = "a" <> string.repeat("b", 1999) <> "second"
  discord_compat.deliver(scripted_transport(), "channel", content)
  |> should.equal(discord_compat.EffectUnknown(
    visible_content: discord_message.first_chunk(content),
    receipts: ["message-1"],
    error: "connection lost",
  ))
}
