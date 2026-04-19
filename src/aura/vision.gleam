import aura/config
import aura/discord/types
import gleam/list
import gleam/option.{type Option, None, Some}
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
pub fn extract_image_urls(attachments: List(types.Attachment)) -> List(String) {
  list.filter_map(attachments, fn(att) {
    case is_image_attachment(att) {
      True -> Ok(att.url)
      False -> Error(Nil)
    }
  })
}

pub fn is_image_attachment(att: types.Attachment) -> Bool {
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
