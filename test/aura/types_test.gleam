import aura/types
import gleam/json
import gleeunit/should

pub fn event_to_json_test() {
  let event =
    types.Event(
      ts: "2026-03-25T14:30:00+08:00",
      domain: "backend",
      event_type: "pr_merged",
      ref: "TASK-456",
      summary: "Fixed ACK receipt format",
    )

  event
  |> types.event_to_json
  |> json.to_string
  |> should.equal(
    "{\"ts\":\"2026-03-25T14:30:00+08:00\",\"domain\":\"backend\",\"type\":\"pr_merged\",\"ref\":\"TASK-456\",\"summary\":\"Fixed ACK receipt format\"}",
  )
}

