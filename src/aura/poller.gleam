import aura/backoff
import aura/brain
import aura/config
import aura/discord
import aura/discord/gateway
import aura/discord/rest
import aura/discord/types as discord_types
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/otp/actor
import gleam/otp/supervision
import gleam/string
import logging

/// GUILDS (1) + GUILD_MESSAGES (512) + DIRECT_MESSAGES (4096) + MESSAGE_CONTENT (32768)
const default_intents = 37_377

const base_backoff_ms = 5000

const max_backoff_ms = 60_000

/// Only known-hopeless errors are fatal: 4xx responses (bad token, forbidden,
/// wrong endpoint) and parse failures (Discord changed the response shape).
/// Everything else — network drops, TLS handshake, 5xx, 429, WebSocket errors
/// — is transient and gets retried.
pub fn is_fatal_error(message: String) -> Bool {
  string.starts_with(message, "Unexpected status 4")
  || string.starts_with(message, "Failed to parse")
}

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
/// On transient network errors, retries in-place with exponential backoff
/// so the root supervisor's restart budget isn't burned during outages.
fn start(
  discord_config: config.DiscordConfig,
  brain_subject: process.Subject(brain.BrainMessage),
) -> Result(
  actor.Started(process.Subject(gateway.GatewayMessage)),
  actor.StartError,
) {
  connect_loop(discord_config, brain_subject, 0)
}

fn connect_loop(
  discord_config: config.DiscordConfig,
  brain_subject: process.Subject(brain.BrainMessage),
  attempt: Int,
) -> Result(
  actor.Started(process.Subject(gateway.GatewayMessage)),
  actor.StartError,
) {
  let token = discord_config.token
  logging.log(logging.Info, "[poller] Fetching gateway URL...")

  case rest.get_gateway_url(token) {
    Error(e) -> {
      logging.log(logging.Error, "[poller] Failed to get gateway URL: " <> e)
      retry_or_fail(e, attempt, discord_config, brain_subject)
    }
    Ok(gateway_url) -> {
      logging.log(logging.Info, "[poller] Gateway URL: " <> gateway_url)

      let on_event = fn(event: discord_types.GatewayEvent) {
        case event {
          discord_types.MessageCreate(msg) -> {
            case msg.author.bot {
              True -> Nil
              False -> {
                let incoming = discord.from_received(msg, None)
                logging.log(
                  logging.Info,
                  "[poller] Message from "
                    <> msg.author.username
                    <> " in "
                    <> msg.channel_id
                    <> " (attachments: "
                    <> int.to_string(list.length(msg.attachments))
                    <> ")",
                )
                process.send(brain_subject, brain.HandleMessage(incoming))
              }
            }
          }
          discord_types.InteractionCreate(
            interaction_id,
            interaction_token,
            custom_id,
            channel_id,
            user_id,
            _message_id,
          ) -> {
            logging.log(
              logging.Info,
              "[poller] Interaction from "
                <> user_id
                <> " in "
                <> channel_id
                <> ": "
                <> custom_id,
            )
            process.send(
              brain_subject,
              brain.HandleInteraction(
                interaction_id: interaction_id,
                interaction_token: interaction_token,
                custom_id: custom_id,
                channel_id: channel_id,
              ),
            )
          }
          discord_types.Ready(_) -> {
            logging.log(logging.Info, "[poller] Bot is ready!")
          }
          _ -> Nil
        }
      }

      case gateway.connect(token, default_intents, gateway_url, on_event) {
        Ok(started) -> {
          logging.log(logging.Info, "[poller] Connected to Discord gateway")
          Ok(started)
        }
        Error(e) -> {
          logging.log(logging.Error, "[poller] Gateway connect failed: " <> e)
          retry_or_fail(e, attempt, discord_config, brain_subject)
        }
      }
    }
  }
}

fn retry_or_fail(
  error: String,
  attempt: Int,
  discord_config: config.DiscordConfig,
  brain_subject: process.Subject(brain.BrainMessage),
) -> Result(
  actor.Started(process.Subject(gateway.GatewayMessage)),
  actor.StartError,
) {
  case is_fatal_error(error) {
    True -> Error(actor.InitTimeout)
    False -> {
      let delay =
        backoff.compute(attempt, base: base_backoff_ms, cap: max_backoff_ms)
      logging.log(
        logging.Info,
        "[poller] Retrying in " <> int.to_string(delay) <> "ms",
      )
      process.sleep(delay)
      connect_loop(discord_config, brain_subject, attempt + 1)
    }
  }
}
