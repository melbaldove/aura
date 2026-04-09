import gleam/string

pub type Tier {
  Autonomous
  NeedsApproval
  NeedsApprovalWithPreview
}

/// Determine the write tier for an absolute file path.
pub fn for_path(path: String) -> Tier {
  // Tier 3: identity files requiring full preview
  case
    string.ends_with(path, "/SOUL.md")
    && string.contains(path, ".config/aura")
  {
    True -> NeedsApprovalWithPreview
    False -> {
      // Tier 1: autonomous writes
      let is_autonomous =
        // Domain logs
        string.contains(path, "/domains/")
        && string.contains(path, "/logs/")
        // Domain memory (data dir)
        || string.contains(path, ".local/share/aura/domains/")
        && string.ends_with(path, "/MEMORY.md")
        // Domain log.jsonl (data dir)
        || string.contains(path, ".local/share/aura/domains/")
        && string.ends_with(path, "/log.jsonl")
        // Domain state (state dir)
        || string.contains(path, ".local/state/aura")
        && string.ends_with(path, "/STATE.md")
        // Global memory (state dir)
        || string.contains(path, ".local/state/aura/MEMORY.md")
        // Global events
        || string.ends_with(path, "/events.jsonl")
        && string.contains(path, ".local/share/aura")
        // Skills
        || string.contains(path, ".local/share/aura/skills/")

      case is_autonomous {
        True -> Autonomous
        False -> NeedsApproval
      }
    }
  }
}

pub fn can_write_without_approval(path: String) -> Bool {
  for_path(path) == Autonomous
}
