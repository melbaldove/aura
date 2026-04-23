//// Blather poller — supervised actor that maintains the WS gateway
//// connection and relays decoded events to the brain. Parallel to
//// `src/aura/poller.gleam` (the Discord poller) but much simpler:
//// Blather has no gateway-URL-discovery step, so we go straight from
//// config to `blather/gateway.connect`.

import aura/blather/gateway
import aura/blather/types as blather_types
import aura/brain
import aura/config
import gleam/erlang/process
import gleam/int
import gleam/otp/actor
import gleam/otp/supervision
import logging

const base_backoff_ms = 5000

const max_backoff_ms = 60_000

/// Reconnect backoff: 5s → 10s → 20s → 40s → 60s (capped). Mirrors the
/// Discord poller's schedule so operators see the same behavior on
/// transient drops across platforms.
pub fn compute_backoff_ms(attempt: Int) -> Int {
  let shift = int.clamp(attempt, min: 0, max: 4)
  int.min(base_backoff_ms * int.bitwise_shift_left(1, shift), max_backoff_ms)
}

/// Create a supervised child spec for the Blather gateway. OTP
/// restarts it automatically if it crashes.
pub fn supervised(
  blather_config: config.BlatherConfig,
  brain_subject: process.Subject(brain.BrainMessage),
) -> supervision.ChildSpecification(
  process.Subject(gateway.GatewayMessage),
) {
  supervision.worker(fn() { start(blather_config, brain_subject) })
}

fn start(
  blather_config: config.BlatherConfig,
  brain_subject: process.Subject(brain.BrainMessage),
) -> Result(
  actor.Started(process.Subject(gateway.GatewayMessage)),
  actor.StartError,
) {
  connect_loop(blather_config, brain_subject, 0)
}

fn connect_loop(
  blather_config: config.BlatherConfig,
  brain_subject: process.Subject(brain.BrainMessage),
  attempt: Int,
) -> Result(
  actor.Started(process.Subject(gateway.GatewayMessage)),
  actor.StartError,
) {
  let on_event = fn(event: blather_types.GatewayEvent) {
    case event {
      blather_types.Connected(user_id) ->
        logging.log(
          logging.Info,
          "[blather-poller] Connected as " <> user_id,
        )
      blather_types.MessageCreated(msg) -> {
        case msg.is_bot {
          True -> Nil
          False -> {
            logging.log(
              logging.Info,
              "[blather-poller] Message from "
                <> msg.author_name
                <> " in "
                <> msg.channel_id,
            )
            process.send(brain_subject, brain.HandleMessage(msg))
          }
        }
      }
      blather_types.Unknown(type_name) ->
        logging.log(
          logging.Info,
          "[blather-poller] Unhandled event type: " <> type_name,
        )
    }
  }

  case gateway.connect(blather_config.url, blather_config.api_key, on_event) {
    Ok(started) -> {
      logging.log(logging.Info, "[blather-poller] Connected")
      Ok(started)
    }
    Error(e) -> {
      logging.log(logging.Error, "[blather-poller] Connect failed: " <> e)
      retry_or_fail(e, attempt, blather_config, brain_subject)
    }
  }
}

fn retry_or_fail(
  _error: String,
  attempt: Int,
  blather_config: config.BlatherConfig,
  brain_subject: process.Subject(brain.BrainMessage),
) -> Result(
  actor.Started(process.Subject(gateway.GatewayMessage)),
  actor.StartError,
) {
  let delay = compute_backoff_ms(attempt)
  logging.log(
    logging.Info,
    "[blather-poller] Retrying in " <> int.to_string(delay) <> "ms",
  )
  process.sleep(delay)
  connect_loop(blather_config, brain_subject, attempt + 1)
}

