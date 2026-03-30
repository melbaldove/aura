import aura/brain
import aura/config
import aura/discord
import aura/discord/gateway
import aura/discord/rest
import aura/discord/types as discord_types
import gleam/erlang/process
import gleam/io
import gleam/option.{None}
import gleam/result

/// Default intents: GUILD_MESSAGES + MESSAGE_CONTENT + DIRECT_MESSAGES
const default_intents = 37_376

/// Start the Discord poller.
/// Fetches gateway URL, connects, and forwards messages to the brain actor.
pub fn start(
  discord_config: config.DiscordConfig,
  brain_subject: process.Subject(brain.BrainMessage),
) -> Result(Nil, String) {
  let token = discord_config.token
  io.println("[poller] Fetching gateway URL...")

  use gateway_url <- result.try(rest.get_gateway_url(token))
  io.println("[poller] Gateway URL: " <> gateway_url)

  let on_event = fn(event: discord_types.GatewayEvent) {
    case event {
      discord_types.MessageCreate(msg) -> {
        case msg.author.bot {
          True -> Nil
          False -> {
            let incoming = discord.from_received(msg, None)
            io.println("[poller] Message from " <> msg.author.username <> " in " <> msg.channel_id)
            process.send(brain_subject, brain.HandleMessage(incoming))
          }
        }
      }
      discord_types.Ready(_) -> {
        io.println("[poller] Bot is ready!")
      }
      _ -> Nil
    }
  }

  use _pid <- result.try(gateway.connect(token, default_intents, gateway_url, on_event))
  io.println("[poller] Connected to Discord gateway")

  Ok(Nil)
}
