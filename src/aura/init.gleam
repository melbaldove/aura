import aura/discord/rest
import aura/llm
import aura/models
import aura/prompt
import aura/xdg
import gleam/io
import gleam/list
import gleam/result
import gleam/string
import simplifile

pub fn run(paths: xdg.Paths) -> Result(Nil, String) {
  io.println("")
  io.println("Aura — First-time setup")
  io.println("========================")
  io.println("")

  use _ <- result.try(check_dependencies())
  use _ <- result.try(create_directories(paths))
  use token <- result.try(prompt_discord_token())
  use guild_id <- result.try(resolve_guild(token))
  use #(provider, api_key) <- result.try(prompt_llm_key())
  use _ <- result.try(write_env_file(paths, token, provider, api_key))
  use #(name, timezone) <- result.try(prompt_user_info())
  use _ <- result.try(generate_config(paths, provider, guild_id, timezone))
  use _ <- result.try(generate_identity_files(paths, name, timezone))
  use _ <- result.try(generate_validations(paths))

  io.println("")
  io.println("Setup complete!")
  Ok(Nil)
}

// ---------------------------------------------------------------------------
// Dependency checks
// ---------------------------------------------------------------------------

fn check_dependencies() -> Result(Nil, String) {
  io.println("Checking dependencies...")

  // Erlang is implicit — we're running inside the BEAM
  io.println("  Erlang/OTP ✓ (running)")

  // Check tmux via `which tmux` since spawn_executable needs PATH lookup
  use _ <- result.try(check_dep_which("tmux"))

  io.println("")
  Ok(Nil)
}

fn check_dep_which(program: String) -> Result(Nil, String) {
  // Use os:find_executable which searches PATH
  case find_executable(program) {
    Ok(path) -> {
      io.println("  " <> program <> " ✓ (" <> path <> ")")
      Ok(Nil)
    }
    Error(_) -> {
      Error(program <> " not found. Please install it.")
    }
  }
}

@external(erlang, "aura_init_ffi", "find_executable")
fn find_executable(name: String) -> Result(String, Nil)

// ---------------------------------------------------------------------------
// Directory creation
// ---------------------------------------------------------------------------

fn create_directories(paths: xdg.Paths) -> Result(Nil, String) {
  io.println("Creating directories...")

  let dirs = [
    paths.config,
    paths.config <> "/domains",
    paths.data,
    paths.data <> "/skills",
    paths.state,
  ]

  use _ <- result.try(
    list.try_each(dirs, fn(dir) {
      simplifile.create_directory_all(dir)
      |> result.map_error(fn(_) { "Failed to create directory: " <> dir })
    }),
  )

  io.println("  Directories created")
  io.println("")
  Ok(Nil)
}

// ---------------------------------------------------------------------------
// Discord token prompting
// ---------------------------------------------------------------------------

fn prompt_discord_token() -> Result(String, String) {
  io.println("Discord Bot Configuration")
  io.println("-------------------------")
  prompt_discord_token_loop()
}

fn prompt_discord_token_loop() -> Result(String, String) {
  use token <- result.try(prompt.ask_secret("Discord bot token"))
  case rest.validate_token(token) {
    Ok(bot_name) -> {
      io.println("  Connected as @" <> bot_name)
      io.println("")
      Ok(token)
    }
    Error(_) -> {
      io.println("  Invalid token. Try again.")
      prompt_discord_token_loop()
    }
  }
}

// ---------------------------------------------------------------------------
// Guild resolution
// ---------------------------------------------------------------------------

fn resolve_guild(token: String) -> Result(String, String) {
  use guilds <- result.try(rest.list_guilds(token))
  case guilds {
    [] ->
      Error("Bot is not in any guilds. Please add the bot to a server first.")
    [#(id, name)] -> {
      io.println("  Guild: " <> name)
      io.println("")
      Ok(id)
    }
    _ -> {
      let names = list.map(guilds, fn(g) { g.1 })
      use choice <- result.try(prompt.choose("Select a guild:", names))
      case list.drop(guilds, choice - 1) |> list.first {
        Ok(#(id, _name)) -> {
          io.println("")
          Ok(id)
        }
        Error(_) -> Error("Invalid guild selection")
      }
    }
  }
}

// ---------------------------------------------------------------------------
// LLM provider prompting
// ---------------------------------------------------------------------------

fn prompt_llm_key() -> Result(#(String, String), String) {
  io.println("LLM Provider Configuration")
  io.println("--------------------------")
  use choice <- result.try(
    prompt.choose("Select LLM provider:", [
      "zai (ZhipuAI)",
      "claude (Anthropic)",
    ]),
  )
  let provider = case choice {
    1 -> "zai"
    _ -> "claude"
  }
  let default_model = models.default_brain_model(provider)
  prompt_llm_key_loop(provider, default_model)
}

fn prompt_llm_key_loop(
  provider: String,
  default_model: String,
) -> Result(#(String, String), String) {
  let key_name = models.api_key_env_var(provider)
  use api_key <- result.try(prompt.ask_secret(key_name))
  use config <- result.try(models.build_llm_config_with_key(
    default_model,
    api_key,
  ))

  io.println("  Validating API key...")
  case llm.chat(config, [llm.UserMessage("Say hello in one word.")]) {
    Ok(_) -> {
      io.println("  API key valid")
      io.println("")
      Ok(#(provider, api_key))
    }
    Error(_) -> {
      io.println("  Invalid API key. Try again.")
      prompt_llm_key_loop(provider, default_model)
    }
  }
}

// ---------------------------------------------------------------------------
// .env file
// ---------------------------------------------------------------------------

fn write_env_file(
  paths: xdg.Paths,
  token: String,
  provider: String,
  api_key: String,
) -> Result(Nil, String) {
  let env_path = xdg.env_path(paths)
  let key_var = models.api_key_env_var(provider)
  let content =
    "AURA_DISCORD_TOKEN=" <> token <> "\n" <> key_var <> "=" <> api_key <> "\n"

  use _ <- result.try(
    simplifile.write(env_path, content)
    |> result.map_error(fn(_) { "Failed to write .env file" }),
  )
  prompt.set_file_permissions(env_path, 0o600)
  io.println("  .env written (permissions 600)")
  io.println("")
  Ok(Nil)
}

// ---------------------------------------------------------------------------
// User info prompting
// ---------------------------------------------------------------------------

fn prompt_user_info() -> Result(#(String, String), String) {
  io.println("User Information")
  io.println("----------------")
  use name <- result.try(prompt.ask("Your name"))
  use timezone <- result.try(prompt.ask("Timezone (e.g. Australia/Melbourne)"))
  io.println("")
  Ok(#(name, timezone))
}

// ---------------------------------------------------------------------------
// Config generation
// ---------------------------------------------------------------------------

fn generate_config(
  paths: xdg.Paths,
  provider: String,
  guild_id: String,
  timezone: String,
) -> Result(Nil, String) {
  let brain_model = models.default_brain_model(provider)
  let config_content =
    string.join(
      [
        "[discord]",
        "token = \"${AURA_DISCORD_TOKEN}\"",
        "guild = \"" <> guild_id <> "\"",
        "default_channel = \"general\"",
        "",
        "[models]",
        "brain = \"" <> brain_model <> "\"",
        "domain = \"claude/sonnet\"",
        "acp = \"claude/opus\"",
        "heartbeat = \"" <> brain_model <> "\"",
        "monitor = \"" <> brain_model <> "\"",
        "",
        "[notifications]",
        "digest_windows = [\"07:35\", \"09:10\", \"11:10\", \"15:00\"]",
        "timezone = \"" <> timezone <> "\"",
        "urgent_bypass = true",
        "",
        "[acp]",
        "global_max_concurrent = 4",
        "",
      ],
      "\n",
    )

  let config_path = xdg.config_path(paths, "config.toml")
  use _ <- result.try(
    simplifile.write(config_path, config_content)
    |> result.map_error(fn(_) { "Failed to write config.toml" }),
  )
  io.println("  config.toml written")
  Ok(Nil)
}

// ---------------------------------------------------------------------------
// Identity / scaffold files
// ---------------------------------------------------------------------------

fn generate_identity_files(
  paths: xdg.Paths,
  name: String,
  timezone: String,
) -> Result(Nil, String) {
  let soul_content =
    string.join(
      [
        "# SOUL",
        "",
        "You are Aura, a local-first executive assistant.",
        "You help your user stay organized, on track, and focused.",
        "You are calm, precise, and proactive.",
        "",
      ],
      "\n",
    )

  let meta_content =
    string.join(
      [
        "# META",
        "",
        "This file contains meta-information about the Aura instance.",
        "",
        "- Initialized: true",
        "- Version: 0.1.0",
        "",
      ],
      "\n",
    )

  let user_content =
    string.join(
      [
        "# USER",
        "",
        "- Name: " <> name,
        "- Timezone: " <> timezone,
        "",
      ],
      "\n",
    )

  let memory_content =
    string.join(
      [
        "# MEMORY",
        "",
        "This file accumulates long-term observations and learnings.",
        "",
      ],
      "\n",
    )

  let events_content = ""

  use _ <- result.try(write_file(xdg.soul_path(paths), soul_content))
  use _ <- result.try(write_file(xdg.meta_path(paths), meta_content))
  use _ <- result.try(write_file(xdg.user_path(paths), user_content))
  use _ <- result.try(write_file(xdg.memory_path(paths), memory_content))
  use _ <- result.try(write_file(xdg.events_path(paths), events_content))

  io.println("  Identity files generated")
  Ok(Nil)
}

// ---------------------------------------------------------------------------
// Validation rules
// ---------------------------------------------------------------------------

fn generate_validations(paths: xdg.Paths) -> Result(Nil, String) {
  let content =
    "# Aura Validation Rules
# These rules are enforced by the runtime on every file write.
# The agent can propose new rules (tier 3 — requires approval).

[[rules]]
path = \"SOUL.md\"
type = \"must_contain\"
value = \"# SOUL\"
message = \"SOUL.md must start with # SOUL header\"

[[rules]]
path = \"*.toml\"
type = \"valid_toml\"
message = \"TOML files must parse without errors\"

[[rules]]
path = \"domains/*/log.jsonl\"
type = \"valid_jsonl\"
message = \"Domain log entries must be valid JSON\"

[[rules]]
path = \"SOUL.md\"
type = \"no_patterns\"
patterns = [\"heartbeat\", \"interval\", \"cron\", \"timeout\", \"config.toml\"]
message = \"SOUL.md is for personality only, not operational rules\"

[[rules]]
path = \"SOUL.md\"
type = \"max_size_kb\"
value = \"50\"
message = \"SOUL.md should not exceed 50KB\"

[[rules]]
path = \"META.md\"
type = \"must_contain\"
value = \"# META\"
message = \"META.md must start with # META header\"
"

  let path = xdg.config_path(paths, "validations.toml")
  use _ <- result.try(write_file(path, content))
  io.println("  Validation rules written")
  Ok(Nil)
}

fn write_file(path: String, content: String) -> Result(Nil, String) {
  simplifile.write(path, content)
  |> result.map_error(fn(_) { "Failed to write file: " <> path })
}
