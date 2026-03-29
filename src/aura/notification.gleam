import gleam/dict
import gleam/int
import gleam/list
import gleam/result
import gleam/string

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

pub type Urgency {
  Urgent
  Normal
  Low
}

pub type Finding {
  Finding(workstream: String, summary: String, urgency: Urgency, source: String)
}

pub type NotificationQueue {
  NotificationQueue(items: List(Finding))
}

// ---------------------------------------------------------------------------
// Queue operations
// ---------------------------------------------------------------------------

/// Create an empty notification queue.
pub fn new_queue() -> NotificationQueue {
  NotificationQueue(items: [])
}

/// Add a finding to the queue.
pub fn enqueue(queue: NotificationQueue, finding: Finding) -> NotificationQueue {
  NotificationQueue(items: list.append(queue.items, [finding]))
}

/// Return the number of items in the queue.
pub fn queue_size(queue: NotificationQueue) -> Int {
  list.length(queue.items)
}

/// Return all items and reset the queue to empty.
pub fn drain(queue: NotificationQueue) -> #(List(Finding), NotificationQueue) {
  #(queue.items, new_queue())
}

// ---------------------------------------------------------------------------
// Classification
// ---------------------------------------------------------------------------

/// Returns True if the finding has Urgent urgency.
pub fn is_urgent(finding: Finding) -> Bool {
  finding.urgency == Urgent
}

// ---------------------------------------------------------------------------
// Digest formatting
// ---------------------------------------------------------------------------

/// Format a list of findings grouped by workstream.
/// Returns "No pending notifications." for an empty list.
pub fn format_digest(findings: List(Finding)) -> String {
  case findings {
    [] -> "No pending notifications."
    _ -> {
      let grouped = list.group(findings, fn(f) { f.workstream })
      let sections =
        dict.to_list(grouped)
        |> list.map(fn(entry) {
          let #(workstream, ws_findings) = entry
          let header = "**" <> workstream <> "**"
          let lines =
            list.map(ws_findings, fn(f) {
              "  - " <> f.summary <> " (" <> f.source <> ")"
            })
          string.join([header, ..lines], "\n")
        })
      string.join(sections, "\n\n")
    }
  }
}

// ---------------------------------------------------------------------------
// Interval parsing
// ---------------------------------------------------------------------------

/// Parse an interval string like "15m", "30s", or "1h" into milliseconds.
pub fn parse_interval(interval: String) -> Result(Int, String) {
  let len = string.length(interval)
  case len < 2 {
    True -> Error("Invalid interval: " <> interval)
    False -> {
      let unit = string.slice(interval, len - 1, 1)
      let digits = string.slice(interval, 0, len - 1)
      use n <- result.try(
        int.parse(digits)
        |> result.map_error(fn(_) { "Invalid number in interval: " <> interval }),
      )
      case unit {
        "s" -> Ok(n * 1000)
        "m" -> Ok(n * 60_000)
        "h" -> Ok(n * 3_600_000)
        _ -> Error("Unknown unit '" <> unit <> "' in interval: " <> interval)
      }
    }
  }
}
