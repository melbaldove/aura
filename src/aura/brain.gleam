import aura/config
import aura/discord
import aura/discord/rest
import aura/env
import aura/llm
import aura/memory
import gleam/io
import gleam/list
import gleam/otp/actor
import gleam/erlang/process
import gleam/result
import gleam/string

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

pub type WorkstreamInfo {
  WorkstreamInfo(name: String, channel_id: String)
}

pub type RouteDecision {
  DirectRoute(workstream_name: String)
  NeedsClassification
}

pub type BrainMessage {
  HandleMessage(discord.IncomingMessage)
  UpdateWorkstreams(List(WorkstreamInfo))
}

pub type BrainState {
  BrainState(
    config: config.GlobalConfig,
    llm_config: llm.LlmConfig,
    workspace_base: String,
    workstreams: List(WorkstreamInfo),
    soul: String,
  )
}

// ---------------------------------------------------------------------------
// Pure functions (testable)
// ---------------------------------------------------------------------------

/// Route based on channel_id matching known workstreams
pub fn route_message(
  channel_id: String,
  workstreams: List(WorkstreamInfo),
) -> RouteDecision {
  case list.find(workstreams, fn(ws) { ws.channel_id == channel_id }) {
    Ok(ws) -> DirectRoute(ws.name)
    Error(_) -> NeedsClassification
  }
}

/// Build system prompt from SOUL.md content
pub fn build_system_prompt(soul_content: String) -> String {
  "You are responding in a Discord server. Stay in character.\n\n"
  <> soul_content
  <> "\n\nKeep responses concise and direct. Use Discord markdown where appropriate."
}

/// Build a routing classification prompt (for #aura messages)
pub fn build_routing_prompt(
  message_content: String,
  workstream_names: List(String),
) -> String {
  "Classify the following message into one of these workstreams: "
  <> string.join(workstream_names, ", ")
  <> "\n\nMessage: "
  <> message_content
  <> "\n\nRespond with just the workstream name, or \"none\" if it doesn't match any."
}

/// Parse model spec "zai/glm-5-turbo" -> model name "glm-5-turbo"
pub fn resolve_model_name(model_spec: String) -> String {
  case string.split(model_spec, "/") {
    [_prefix, name] -> name
    _ -> model_spec
  }
}

// ---------------------------------------------------------------------------
// Config resolution
// ---------------------------------------------------------------------------

fn build_llm_config(model_spec: String) -> Result(llm.LlmConfig, String) {
  let model = resolve_model_name(model_spec)
  case string.starts_with(model_spec, "zai/") {
    True -> {
      case env.get_env("ZAI_API_KEY") {
        Ok(key) ->
          Ok(llm.LlmConfig(
            base_url: "https://api.z.ai/api/coding/paas/v4",
            api_key: key,
            model: model,
          ))
        Error(_) -> Error("ZAI_API_KEY environment variable not set")
      }
    }
    False ->
      case string.starts_with(model_spec, "claude/") {
        True -> {
          case env.get_env("ANTHROPIC_API_KEY") {
            Ok(key) ->
              Ok(llm.LlmConfig(
                base_url: "https://api.anthropic.com/v1",
                api_key: key,
                model: model,
              ))
            Error(_) -> Error("ANTHROPIC_API_KEY environment variable not set")
          }
        }
        False -> Error("Unknown model provider in spec: " <> model_spec)
      }
  }
}

// ---------------------------------------------------------------------------
// Actor
// ---------------------------------------------------------------------------

const default_soul = "You are Aura, a helpful AI assistant. Be direct and concise."

/// Start the brain actor
pub fn start(
  config: config.GlobalConfig,
  workspace_base: String,
  workstreams: List(WorkstreamInfo),
) -> Result(process.Subject(BrainMessage), String) {
  // Read SOUL.md
  let soul_path = workspace_base <> "/SOUL.md"
  let soul = case memory.read_file(soul_path) {
    Ok(content) -> content
    Error(_) -> {
      io.println("[brain] SOUL.md not found at " <> soul_path <> ", using default")
      default_soul
    }
  }

  // Build LLM config from brain model spec
  use llm_config <- result.try(build_llm_config(config.models.brain))

  let state =
    BrainState(
      config: config,
      llm_config: llm_config,
      workspace_base: workspace_base,
      workstreams: workstreams,
      soul: soul,
    )

  actor.new(state)
  |> actor.on_message(handle_message)
  |> actor.start
  |> result.map(fn(started) { started.data })
  |> result.map_error(fn(err) {
    "Failed to start brain actor: " <> string.inspect(err)
  })
}

fn handle_message(
  state: BrainState,
  message: BrainMessage,
) -> actor.Next(BrainState, BrainMessage) {
  case message {
    HandleMessage(msg) -> {
      let _route = route_message(msg.channel_id, state.workstreams)
      // Phase 3: handle all messages directly with LLM regardless of route
      // Phase 4 will forward DirectRoute messages to workstream actors
      handle_with_llm(state, msg)
      actor.continue(state)
    }
    UpdateWorkstreams(ws) -> {
      io.println("[brain] Updated workstreams: " <> string.inspect(list.length(ws)) <> " entries")
      actor.continue(BrainState(..state, workstreams: ws))
    }
  }
}

fn handle_with_llm(state: BrainState, msg: discord.IncomingMessage) -> Nil {
  let prompt = build_system_prompt(state.soul)
  let messages = [
    llm.SystemMessage(prompt),
    llm.UserMessage(msg.content),
  ]

  let token = state.config.discord.token
  let channel_id = msg.channel_id

  case llm.chat(state.llm_config, messages) {
    Ok(response) -> {
      case rest.send_message(token, channel_id, response, []) {
        Ok(_) -> Nil
        Error(err) -> {
          io.println("[brain] Failed to send response: " <> err)
          Nil
        }
      }
    }
    Error(err) -> {
      io.println("[brain] LLM error: " <> err)
      let error_msg = "Sorry, I encountered an error processing your message."
      case rest.send_message(token, channel_id, error_msg, []) {
        Ok(_) -> Nil
        Error(send_err) -> {
          io.println("[brain] Failed to send error message: " <> send_err)
          Nil
        }
      }
    }
  }
}
