import aura/env
import aura/llm
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
