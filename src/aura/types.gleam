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

/// A temporal anchor that survives compression
pub type Anchor {
  Anchor(
    ts: String,
    anchor_type: String,
    domain: String,
    content: String,
    context: String,
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

pub fn anchor_to_json(anchor: Anchor) -> json.Json {
  json.object([
    #("ts", json.string(anchor.ts)),
    #("type", json.string(anchor.anchor_type)),
    #("anchor", json.bool(True)),
    #("domain", json.string(anchor.domain)),
    #("content", json.string(anchor.content)),
    #("context", json.string(anchor.context)),
  ])
}

