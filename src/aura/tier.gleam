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
      let is_domain_log = string.ends_with(path, "/log.jsonl")
      let is_events = path == "events.jsonl"
      let is_memory = path == "MEMORY.md"
      let is_state = path == "STATE.md" || string.ends_with(path, "/STATE.md")
      let is_skills = string.starts_with(path, "skills/")

      case
        is_log_path
        || is_domain_log
        || is_events
        || is_memory
        || is_state
        || is_skills
      {
        True -> Autonomous
        False -> NeedsApproval
      }
    }
  }
}

pub fn can_write_without_approval(path: String) -> Bool {
  for_path(path) == Autonomous
}
