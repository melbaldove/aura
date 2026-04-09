import aura/env
import aura/llm
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// Resolve a model spec like "zai/glm-5-turbo" -> model name "glm-5-turbo"
pub fn resolve_model_name(model_spec: String) -> String {
  case string.split(model_spec, "/") {
    [_prefix, name] -> name
    _ -> model_spec
  }
}

/// Build an LlmConfig from a model spec string
/// Supports "zai/" and "claude/" prefixes
pub fn build_llm_config(model_spec: String) -> Result(llm.LlmConfig, String) {
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

/// Get the default model spec for a provider
pub fn default_brain_model(provider: String) -> String {
  case provider {
    "zai" -> "zai/glm-5-turbo"
    _ -> "claude/haiku"
  }
}

/// Get the environment variable name for a provider's API key
pub fn api_key_env_var(provider: String) -> String {
  case provider {
    "zai" -> "ZAI_API_KEY"
    _ -> "ANTHROPIC_API_KEY"
  }
}

/// Known context window sizes for models.
/// Exact matches first, then prefix fallbacks for unknown variants.
/// Returns None if the model is completely unknown.
pub fn context_length(model_spec: String) -> Option(Int) {
  case model_spec {
    // Zhipu / Z.AI
    "zai/glm-5.1" -> Some(204_800)
    "zai/glm-5-turbo" -> Some(202_752)
    "zai/glm-5v-turbo" -> Some(202_752)

    // Anthropic Claude 4.6 (1M context)
    "claude/claude-opus-4-6" | "claude/opus-4-6" -> Some(1_000_000)
    "claude/claude-sonnet-4-6" | "claude/sonnet-4-6" -> Some(1_000_000)

    // Anthropic Claude 4.5 / 4 (200K context)
    "claude/claude-opus-4-5" | "claude/opus-4-5" -> Some(200_000)
    "claude/claude-sonnet-4-5" | "claude/sonnet-4-5" -> Some(200_000)
    "claude/opus" -> Some(200_000)
    "claude/sonnet" -> Some(200_000)
    "claude/haiku" | "claude/claude-haiku-4-5" -> Some(200_000)

    // OpenAI
    "openai/gpt-4o" -> Some(128_000)
    "openai/gpt-4o-mini" -> Some(128_000)
    "openai/gpt-4.1" -> Some(1_047_576)

    // Google Gemini
    "google/gemini-2.0-flash" -> Some(1_048_576)
    "google/gemini-2.5-pro" -> Some(1_048_576)

    // DeepSeek
    "deepseek/deepseek-v3" -> Some(128_000)
    "deepseek/deepseek-r1" -> Some(128_000)

    // Meta Llama 4
    "meta/llama-4-scout" -> Some(1_048_576)
    "meta/llama-4-maverick" -> Some(1_048_576)

    // Prefix fallbacks for unknown variants
    _ -> context_length_by_prefix(model_spec)
  }
}

fn context_length_by_prefix(model_spec: String) -> Option(Int) {
  case string.split_once(model_spec, "/") {
    Ok(#("zai", _)) -> Some(202_752)
    Ok(#("claude", _)) -> Some(200_000)
    Ok(#("openai", _)) -> Some(128_000)
    Ok(#("google", _)) -> Some(1_048_576)
    Ok(#("deepseek", _)) -> Some(128_000)
    Ok(#("meta", _)) -> Some(131_072)
    _ -> None
  }
}

/// Resolve context length: config override first, then built-in table, then error.
pub fn resolve_context_length(
  model_spec: String,
  config_override: Int,
) -> Result(Int, String) {
  case config_override > 0 {
    True -> Ok(config_override)
    False ->
      case context_length(model_spec) {
        Some(len) -> Ok(len)
        None ->
          Error(
            "Unknown context length for model: "
            <> model_spec
            <> ". Set brain_context in config.toml.",
          )
      }
  }
}

/// Build LLM config with an explicit API key (for validation during init).
/// Similar to build_llm_config but uses the provided key instead of reading from env.
pub fn build_llm_config_with_key(
  model_spec: String,
  api_key: String,
) -> Result(llm.LlmConfig, String) {
  let model = resolve_model_name(model_spec)
  use base_url <- result.try(case string.starts_with(model_spec, "zai/") {
    True -> Ok("https://api.z.ai/api/coding/paas/v4")
    False ->
      case string.starts_with(model_spec, "claude/") {
        True -> Ok("https://api.anthropic.com/v1")
        False -> Error("Unknown model provider in spec: " <> model_spec)
      }
  })
  Ok(llm.LlmConfig(base_url: base_url, api_key: api_key, model: model))
}
