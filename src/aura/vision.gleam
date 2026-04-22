import aura/clients/llm_client
import aura/config
import aura/llm
import aura/message
import aura/models
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// Resolved vision configuration after tiered override.
pub type ResolvedVisionConfig {
  ResolvedVisionConfig(model_spec: String, prompt: String)
}

pub const default_vision_prompt = "Describe this image concisely. Focus on text content, numbers, structure, and any actionable information. Be specific about what you see."

/// Resolve vision config: domain overrides global, built-in defaults as fallback.
pub fn resolve_vision_config(
  global: config.GlobalConfig,
  domain: Option(config.DomainConfig),
) -> ResolvedVisionConfig {
  let global_model = global.models.vision
  let global_prompt = global.vision.prompt

  case domain {
    Some(d) -> {
      let model = case d.vision_model {
        "" -> global_model
        m -> m
      }
      let prompt = case d.vision_prompt {
        "" ->
          case global_prompt {
            "" ->
              case model {
                "" -> ""
                _ -> default_vision_prompt
              }
            p -> p
          }
        p -> p
      }
      ResolvedVisionConfig(model_spec: model, prompt: prompt)
    }
    None -> {
      let prompt = case global_prompt {
        "" ->
          case global_model {
            "" -> ""
            _ -> default_vision_prompt
          }
        p -> p
      }
      ResolvedVisionConfig(model_spec: global_model, prompt: prompt)
    }
  }
}

/// Whether vision is configured (has a model spec).
pub fn is_enabled(config: ResolvedVisionConfig) -> Bool {
  config.model_spec != ""
}

/// Extract image URLs from Discord attachments.
pub fn extract_image_urls(attachments: List(message.Attachment)) -> List(String) {
  list.filter_map(attachments, fn(att) {
    case is_image_attachment(att) {
      True -> Ok(att.url)
      False -> Error(Nil)
    }
  })
}

pub fn is_image_attachment(att: message.Attachment) -> Bool {
  case string.starts_with(att.content_type, "image/") {
    True -> True
    False -> {
      let lower = string.lowercase(att.filename)
      string.ends_with(lower, ".png")
      || string.ends_with(lower, ".jpg")
      || string.ends_with(lower, ".jpeg")
      || string.ends_with(lower, ".gif")
      || string.ends_with(lower, ".webp")
    }
  }
}

/// Call the vision model to describe an image. Resolves the LlmConfig from
/// the vision config's model_spec, then calls the LLM client's `chat_text`.
/// Shared helper used by channel_actor's vision_fn closure and other callers.
pub fn describe_via_client(
  client: llm_client.LLMClient,
  cfg: ResolvedVisionConfig,
  image_url: String,
) -> Result(String, String) {
  use llm_config <- result.try(models.build_llm_config(cfg.model_spec))
  describe_with_config(client, llm_config, cfg.prompt, image_url)
}

/// Lower-level helper: describe an image using a pre-built `LlmConfig` and
/// an explicit prompt. Useful in tests where the model spec cannot be resolved
/// from environment variables.
pub fn describe_with_config(
  client: llm_client.LLMClient,
  llm_config: llm.LlmConfig,
  prompt: String,
  image_url: String,
) -> Result(String, String) {
  let messages = [
    llm.UserMessageWithImage(content: prompt, image_url: image_url),
  ]
  client.chat_text(llm_config, messages, None)
}
