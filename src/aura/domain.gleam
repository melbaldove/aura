import aura/memory
import aura/skill
import aura/time
import logging
import gleam/list
import gleam/string
import simplifile

/// Domain context loaded from disk for injection into the LLM system prompt.
pub type DomainContext {
  DomainContext(
    agents_md: String,
    description: String,
    state_md: String,
    memory_md: String,
    todays_log: String,
    skill_descriptions: String,
  )
}

/// Read a file that may or may not exist, logging errors.
fn read_optional_file(path: String, label: String, domain: String) -> String {
  case simplifile.read(path) {
    Ok(content) -> content
    Error(simplifile.Enoent) -> ""
    Error(e) -> {
      logging.log(logging.Info, 
        "[domain] Failed to read " <> label <> " for "
        <> domain <> ": " <> string.inspect(e),
      )
      ""
    }
  }
}

/// Load domain context from config and data directories.
pub fn load_context(
  config_dir: String,
  data_dir: String,
  state_dir: String,
  skills: List(skill.SkillInfo),
) -> DomainContext {
  let domain_name = extract_domain_name(config_dir)

  let agents_md = read_optional_file(config_dir <> "/AGENTS.md", "AGENTS.md", domain_name)

  let description = case load_description(config_dir) {
    Ok(desc) -> desc
    Error(e) -> {
      logging.log(logging.Error, "[domain] Failed to load description for " <> config_dir <> ": " <> string.inspect(e))
      ""
    }
  }

  let state_md = read_optional_file(state_dir <> "/STATE.md", "STATE.md", domain_name)
  let memory_md = read_optional_file(data_dir <> "/MEMORY.md", "MEMORY.md", domain_name)

  let date = time.today_date_string()
  let todays_log = case memory.read_daily_log(data_dir, date) {
    Ok(log) -> log
    Error(e) -> {
      logging.log(logging.Error, "[domain] Failed to read daily log for " <> domain_name <> ": " <> e)
      ""
    }
  }

  let skill_desc = skill.descriptions_for_prompt(skills)

  DomainContext(
    agents_md: agents_md,
    description: description,
    state_md: state_md,
    memory_md: memory_md,
    todays_log: todays_log,
    skill_descriptions: skill_desc,
  )
}

/// Build a prompt section from domain context.
pub fn build_domain_prompt(context: DomainContext) -> String {
  let sections = [
    build_agents_section(context.agents_md),
    "## Domain\n" <> case context.description {
      "" -> "No description."
      desc -> desc
    },
    build_state_section(context.state_md),
    build_memory_section(context.memory_md),
    build_log_section(context.todays_log),
    "## Skills\n" <> case context.skill_descriptions {
      "" -> "No skills available."
      desc -> desc
    },
  ]
  string.join(list.filter(sections, fn(s) { s != "" }), "\n\n")
}

fn build_agents_section(agents_md: String) -> String {
  case agents_md {
    "" -> ""
    content -> "## Domain Instructions\n" <> content
  }
}

fn build_state_section(state: String) -> String {
  case string.trim(state) {
    "" -> ""
    content -> "## Current State\n" <> content
  }
}

fn build_memory_section(mem: String) -> String {
  case string.trim(mem) {
    "" -> ""
    content -> "## Domain Knowledge\n" <> content
  }
}

fn build_log_section(log: String) -> String {
  case string.trim(log) {
    "" -> "## Today's Log\nNo activity yet."
    content -> "## Today's Log\n" <> content
  }
}

fn load_description(config_dir: String) -> Result(String, Nil) {
  case simplifile.read(config_dir <> "/config.toml") {
    Ok(content) -> {
      let lines = string.split(content, "\n")
      case
        list.find(lines, fn(l) {
          string.starts_with(string.trim(l), "description")
        })
      {
        Ok(line) -> {
          case string.split(line, "\"") {
            [_, value, ..] -> Ok(value)
            _ -> Error(Nil)
          }
        }
        Error(_) -> Error(Nil)
      }
    }
    Error(_) -> Error(Nil)
  }
}

fn extract_domain_name(data_dir: String) -> String {
  let parts = string.split(data_dir, "/")
  case list.last(parts) {
    Ok(name) -> name
    Error(_) -> ""
  }
}

