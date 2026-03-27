import gleam/json

/// A cross-workstream event emitted to events.jsonl
pub type Event {
  Event(
    ts: String,
    workstream: String,
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
    workstream: String,
    content: String,
    context: String,
  )
}

/// Urgency level for heartbeat findings
pub type Urgency {
  Urgent
  Normal
  Low
}

/// ACP session outcome
pub type AcpOutcome {
  Clean
  Partial
  Failed
  Unknown
}

/// ACP structured exit report
pub type AcpReport {
  AcpReport(
    outcome: AcpOutcome,
    files_changed: List(String),
    decisions: String,
    tests: String,
    blockers: String,
    anchor: String,
  )
}

pub fn event_to_json(event: Event) -> json.Json {
  json.object([
    #("ts", json.string(event.ts)),
    #("workstream", json.string(event.workstream)),
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
    #("workstream", json.string(anchor.workstream)),
    #("content", json.string(anchor.content)),
    #("context", json.string(anchor.context)),
  ])
}

pub fn urgency_to_string(urgency: Urgency) -> String {
  case urgency {
    Urgent -> "urgent"
    Normal -> "normal"
    Low -> "low"
  }
}

pub fn outcome_to_string(outcome: AcpOutcome) -> String {
  case outcome {
    Clean -> "clean"
    Partial -> "partial"
    Failed -> "failed"
    Unknown -> "unknown"
  }
}
