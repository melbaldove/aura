import gleam/json

/// A cross-domain event emitted to events.jsonl
pub type Event {
  Event(
    ts: String,
    domain: String,
    event_type: String,
    ref: String,
    summary: String,
  )
}

pub fn event_to_json(event: Event) -> json.Json {
  json.object([
    #("ts", json.string(event.ts)),
    #("domain", json.string(event.domain)),
    #("type", json.string(event.event_type)),
    #("ref", json.string(event.ref)),
    #("summary", json.string(event.summary)),
  ])
}
