import gleam/string

pub type Tier {
  Autonomous
  NeedsApproval
  NeedsApprovalWithPreview
}

pub fn for_path(path: String) -> Tier {
  case path {
    "SOUL.md" -> NeedsApprovalWithPreview
    "META.md" -> NeedsApprovalWithPreview
    _ -> {
      let is_log_path = string.contains(path, "/logs/")
      let is_anchors = string.ends_with(path, "/anchors.jsonl")
      let is_events = path == "events.jsonl"
      let is_memory = path == "MEMORY.md"

      case is_log_path || is_anchors || is_events || is_memory {
        True -> Autonomous
        False -> NeedsApproval
      }
    }
  }
}

pub fn can_write_without_approval(path: String) -> Bool {
  for_path(path) == Autonomous
}
