import aura/brain
import aura/config
import aura/discord
import aura/discord/gateway
import aura/discord/rest
import aura/discord/types as discord_types
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None}
import gleam/otp/actor
import gleam/otp/supervision

/// GUILDS (1) + GUILD_MESSAGES (512) + DIRECT_MESSAGES (4096) + MESSAGE_CONTENT (32768)
const default_intents = 37_377

/// Create a supervised child spec for the Discord gateway.
/// OTP restarts it automatically if it crashes — no manual reconnect loop needed.
pub fn supervised(
  discord_config: config.DiscordConfig,
  brain_subject: process.Subject(brain.BrainMessage),
) -> supervision.ChildSpecification(process.Subject(gateway.GatewayMessage)) {
  supervision.worker(fn() { start(discord_config, brain_subject) })
}

/// Start the Discord poller.
/// Fetches gateway URL, connects, and forwards messages to the brain actor.
fn start(
  discord_config: config.DiscordConfig,
  brain_subject: process.Subject(brain.BrainMessage),
) -> Result(actor.Started(process.Subject(gateway.GatewayMessage)), actor.StartError) {
  let token = discord_config.token
  io.println("[poller] Fetching gateway URL...")

  case rest.get_gateway_url(token) {
    Error(e) -> {
      io.println("[poller] Failed to get gateway URL: " <> e)
      Error(actor.InitTimeout)
    }
    Ok(gateway_url) -> {
      io.println("[poller] Gateway URL: " <> gateway_url)

      let on_event = fn(event: discord_types.GatewayEvent) {
        case event {
          discord_types.MessageCreate(msg) -> {
            case msg.author.bot {
              True -> Nil
              False -> {
                let incoming = discord.from_received(msg, None)
                io.println("[poller] Message from " <> msg.author.username <> " in " <> msg.channel_id <> " (attachments: " <> int.to_string(list.length(msg.attachments)) <> ")")
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

      case gateway.connect(token, default_intents, gateway_url, on_event) {
        Ok(started) -> {
          io.println("[poller] Connected to Discord gateway")
          Ok(started)
        }
        Error(e) -> {
          io.println("[poller] Gateway connect failed: " <> e)
          Error(actor.InitTimeout)
        }
      }
    }
  }
}
