import aura/cognitive_episode_context
import aura/db
import aura/test_helpers
import aura/xdg
import gleam/string
import gleeunit
import gleeunit/should
import simplifile

pub fn main() {
  gleeunit.main()
}

fn temp_paths(label: String) -> xdg.Paths {
  let base = "/tmp/aura-" <> label <> "-" <> test_helpers.random_suffix()
  let _ = simplifile.delete_all([base])
  xdg.resolve_with_home(base)
}

fn write_ledger(paths: xdg.Paths, lines: List(String)) -> Nil {
  let assert Ok(Nil) = simplifile.create_directory_all(xdg.cognitive_dir(paths))
  let assert Ok(Nil) =
    simplifile.write(
      xdg.deliveries_path(paths),
      string.join(lines, "\n") <> "\n",
    )
  Nil
}

fn ledger_line(
  event_id: String,
  status: String,
  attention_action: String,
  target: String,
  channel_id: String,
  summary: String,
) -> String {
  "{\"timestamp_ms\":1,\"event_id\":\""
  <> event_id
  <> "\",\"status\":\""
  <> status
  <> "\",\"attention_action\":\""
  <> attention_action
  <> "\",\"target\":\""
  <> target
  <> "\",\"channel_id\":\""
  <> channel_id
  <> "\",\"summary\":\""
  <> summary
  <> "\",\"rationale\":\"The model saw material timing and risk.\",\"authority_required\":\"human_judgment\",\"citations\":[\"e1\"],\"gaps\":[],\"error\":\"\"}"
}

pub fn render_recent_outputs_uses_delivered_channel_history_test() {
  let paths = temp_paths("cognitive-episode-context")
  let assert Ok(db_subject) = db.start(":memory:")
  let assert Ok(convo_id) =
    db.resolve_conversation(db_subject, "discord", "aura-channel", 1)
  let assert Ok(Nil) =
    db.append_message(
      db_subject,
      convo_id,
      "assistant",
      "**Aura needs a decision**\n\nCheckout rollback needs approval.\nEvent: checkout-rollback-1",
      "aura",
      "Aura",
      2,
    )

  write_ledger(paths, [
    ledger_line(
      "checkout-rollback-1",
      "delivered",
      "ask_now",
      "default",
      "aura-channel",
      "Checkout rollback needs attention.",
    ),
    ledger_line(
      "other-channel-1",
      "delivered",
      "surface_now",
      "default",
      "other-channel",
      "Other channel should stay out.",
    ),
    ledger_line(
      "recorded-only-1",
      "recorded",
      "record",
      "none",
      "aura-channel",
      "Recorded entries were not user-facing.",
    ),
  ])

  let rendered =
    cognitive_episode_context.render(paths, db_subject, "aura-channel", 5)
    |> should.be_ok

  rendered
  |> string.contains("## Recent Aura Attention Outputs")
  |> should.be_true
  rendered |> string.contains("event_id: checkout-rollback-1") |> should.be_true
  rendered |> string.contains("attention: ask_now") |> should.be_true
  rendered
  |> string.contains("summary: Checkout rollback needs attention.")
  |> should.be_true
  rendered |> string.contains("Aura needs a decision") |> should.be_true
  rendered |> string.contains("other-channel-1") |> should.be_false
  rendered |> string.contains("recorded-only-1") |> should.be_false
}
