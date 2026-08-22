//// Discord compatibility delivery for one claimed attention queue item.

import aura/discord/message as discord_message
import aura/transport.{type Transport}
import gleam/list
import gleam/string

pub type Outcome {
  Complete(visible_content: String, receipts: List(String))
  EffectUnknown(visible_content: String, receipts: List(String), error: String)
}

/// Send all Discord-sized chunks and retain each confirmed external receipt.
pub fn deliver(
  discord: Transport,
  channel_id: String,
  content: String,
) -> Outcome {
  deliver_chunks(
    discord,
    channel_id,
    discord_message.split_to_discord_messages(content),
    [],
    [],
  )
}

fn deliver_chunks(
  discord: Transport,
  channel_id: String,
  chunks: List(String),
  sent_chunks: List(String),
  receipts: List(String),
) -> Outcome {
  case chunks {
    [] ->
      Complete(
        visible_content: sent_chunks |> list.reverse |> string.concat,
        receipts: list.reverse(receipts),
      )
    [chunk, ..rest] ->
      case discord.send_message(channel_id, chunk) {
        Ok(receipt) ->
          deliver_chunks(discord, channel_id, rest, [chunk, ..sent_chunks], [
            receipt,
            ..receipts
          ])
        Error(error) ->
          EffectUnknown(
            visible_content: sent_chunks |> list.reverse |> string.concat,
            receipts: list.reverse(receipts),
            error:,
          )
      }
  }
}
