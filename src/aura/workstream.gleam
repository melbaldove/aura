import aura/config
import aura/discord
import aura/llm
import aura/memory
import aura/skill
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/json
import gleam/otp/actor
import gleam/result
import gleam/string

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// Assembled context for LLM call
pub type WorkstreamContext {
  WorkstreamContext(
    config_description: String,
    recent_anchors: List(String),
    todays_log: String,
    skill_descriptions: String,
  )
}

/// Messages the workstream actor handles
pub type WorkstreamMessage {
  HandleTask(
    message: discord.IncomingMessage,
    reply_to: process.Subject(WorkstreamResponse),
  )
}

/// Response back to the brain
pub type WorkstreamResponse {
  WorkstreamResponse(
    workstream_name: String,
    channel_id: String,
    content: String,
  )
  WorkstreamError(workstream_name: String, channel_id: String, error: String)
}

/// Actor state
pub type WorkstreamState {
  WorkstreamState(
    name: String,
    config: config.WorkstreamConfig,
    llm_config: llm.LlmConfig,
    workspace_base: String,
    soul: String,
    skills: List(skill.SkillInfo),
  )
}

// ---------------------------------------------------------------------------
// Pure functions (testable)
// ---------------------------------------------------------------------------

/// Build a prompt from workstream context.
/// Includes: description, recent anchors (if any), today's log (if any),
/// and skill descriptions.
pub fn build_context_prompt(context: WorkstreamContext) -> String {
  let sections = [
    "## Workstream\n" <> context.config_description,
    build_anchors_section(context.recent_anchors),
    build_log_section(context.todays_log),
    "## Skills\n" <> context.skill_descriptions,
  ]
  sections
  |> string.join("\n\n")
}

fn build_anchors_section(anchors: List(String)) -> String {
  case anchors {
    [] -> "## Recent Anchors\nNone."
    _ ->
      "## Recent Anchors\n"
      <> string.join(anchors, "\n")
  }
}

fn build_log_section(log: String) -> String {
  case string.trim(log) {
    "" -> "## Today's Log\nNo activity yet."
    content -> "## Today's Log\n" <> content
  }
}

/// Return today's date as "YYYY-MM-DD" using Erlang's calendar:local_time()
pub fn today_date_string() -> String {
  let #(#(year, month, day), _time) = erlang_localtime()
  int.to_string(year)
  <> "-"
  <> pad_zero(month)
  <> "-"
  <> pad_zero(day)
}

fn pad_zero(n: Int) -> String {
  case n < 10 {
    True -> "0" <> int.to_string(n)
    False -> int.to_string(n)
  }
}

@external(erlang, "calendar", "local_time")
fn erlang_localtime() -> #(#(Int, Int, Int), #(Int, Int, Int))

// ---------------------------------------------------------------------------
// Actor
// ---------------------------------------------------------------------------

/// Start the workstream actor
pub fn start(
  name: String,
  ws_config: config.WorkstreamConfig,
  llm_config: llm.LlmConfig,
  workspace_base: String,
  soul: String,
  skills: List(skill.SkillInfo),
) -> Result(process.Subject(WorkstreamMessage), String) {
  let allowed_skills = skill.filter_allowed(skills, ws_config.tools)

  let state =
    WorkstreamState(
      name: name,
      config: ws_config,
      llm_config: llm_config,
      workspace_base: workspace_base,
      soul: soul,
      skills: allowed_skills,
    )

  actor.new(state)
  |> actor.on_message(handle_message)
  |> actor.start
  |> result.map(fn(started) { started.data })
  |> result.map_error(fn(err) {
    "Failed to start workstream actor: " <> string.inspect(err)
  })
}

fn handle_message(
  state: WorkstreamState,
  message: WorkstreamMessage,
) -> actor.Next(WorkstreamState, WorkstreamMessage) {
  case message {
    HandleTask(msg, reply_to) -> {
      handle_task(state, msg, reply_to)
      actor.continue(state)
    }
  }
}

fn handle_task(
  state: WorkstreamState,
  msg: discord.IncomingMessage,
  reply_to: process.Subject(WorkstreamResponse),
) -> Nil {
  let date = today_date_string()

  // Load context
  let anchors = case memory.read_anchors(state.workspace_base, state.name, 20) {
    Ok(a) -> a
    Error(_) -> []
  }

  let todays_log =
    case memory.read_daily_log(state.workspace_base, state.name, date) {
      Ok(log) -> log
      Error(_) -> ""
    }

  let skill_desc = skill.descriptions_for_prompt(state.skills)

  let context =
    WorkstreamContext(
      config_description: state.config.description,
      recent_anchors: anchors,
      todays_log: todays_log,
      skill_descriptions: skill_desc,
    )

  let context_prompt = build_context_prompt(context)

  // Build messages
  let messages = [
    llm.SystemMessage(state.soul <> "\n\n" <> context_prompt),
    llm.UserMessage(msg.content),
  ]

  // Call LLM
  case llm.chat(state.llm_config, messages) {
    Ok(response) -> {
      // Log the interaction
      let log_entry =
        json.object([
          #("ts", json.string(date)),
          #("user", json.string(msg.author_name)),
          #("content", json.string(msg.content)),
          #("response", json.string(response)),
        ])
      case memory.append_log(state.workspace_base, state.name, date, log_entry) {
        Ok(_) -> Nil
        Error(err) -> {
          io.println(
            "[workstream:" <> state.name <> "] Failed to log: " <> err,
          )
          Nil
        }
      }

      // Send response
      process.send(
        reply_to,
        WorkstreamResponse(
          workstream_name: state.name,
          channel_id: msg.channel_id,
          content: response,
        ),
      )
    }
    Error(err) -> {
      io.println("[workstream:" <> state.name <> "] LLM error: " <> err)
      process.send(
        reply_to,
        WorkstreamError(
          workstream_name: state.name,
          channel_id: msg.channel_id,
          error: err,
        ),
      )
    }
  }
}
