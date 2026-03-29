pub type TaskSpec {
  TaskSpec(
    id: String,
    workstream: String,
    prompt: String,
    cwd: String,
    timeout_ms: Int,
    acceptance_criteria: List(String),
  )
}

pub type SessionStatus {
  Running
  Stuck
  Blocked
  Dangerous
  Complete
  TimedOut
  Unknown
}

pub type Outcome {
  Clean
  Partial
  Failed
  OutcomeUnknown
}

pub type AcpReport {
  AcpReport(
    outcome: Outcome,
    files_changed: List(String),
    decisions: String,
    tests: String,
    blockers: String,
    anchor: String,
  )
}

pub fn status_to_string(status: SessionStatus) -> String {
  case status {
    Running -> "running"
    Stuck -> "stuck"
    Blocked -> "blocked"
    Dangerous -> "dangerous"
    Complete -> "complete"
    TimedOut -> "timed_out"
    Unknown -> "unknown"
  }
}

pub fn outcome_to_string(outcome: Outcome) -> String {
  case outcome {
    Clean -> "clean"
    Partial -> "partial"
    Failed -> "failed"
    OutcomeUnknown -> "unknown"
  }
}
