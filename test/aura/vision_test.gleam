import aura/config
import aura/discord/types
import aura/vision
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should

pub fn resolve_vision_config_global_only_test() {
  let global =
    config.GlobalConfig(
      ..config.default_global(),
      models: config.ModelsConfig(
        brain: "",
        domain: "",
        acp: "",
        heartbeat: "",
        monitor: "",
        vision: "zai/glm-5v-turbo",
        dream: "",
      ),
      vision: config.VisionConfig(prompt: "Describe this image."),
    )
  let result = vision.resolve_vision_config(global, None)
  result.model_spec |> should.equal("zai/glm-5v-turbo")
  result.prompt |> should.equal("Describe this image.")
}

pub fn resolve_vision_config_domain_override_test() {
  let global =
    config.GlobalConfig(
      ..config.default_global(),
      models: config.ModelsConfig(
        brain: "",
        domain: "",
        acp: "",
        heartbeat: "",
        monitor: "",
        vision: "zai/glm-5v-turbo",
        dream: "",
      ),
      vision: config.VisionConfig(prompt: "Global prompt."),
    )
  let domain =
    config.DomainConfig(
      ..config.default_domain(),
      vision_model: "zai/custom-vision",
      vision_prompt: "Domain-specific prompt.",
    )
  let result = vision.resolve_vision_config(global, Some(domain))
  result.model_spec |> should.equal("zai/custom-vision")
  result.prompt |> should.equal("Domain-specific prompt.")
}

pub fn resolve_vision_config_domain_partial_override_test() {
  let global =
    config.GlobalConfig(
      ..config.default_global(),
      models: config.ModelsConfig(
        brain: "",
        domain: "",
        acp: "",
        heartbeat: "",
        monitor: "",
        vision: "zai/glm-5v-turbo",
        dream: "",
      ),
      vision: config.VisionConfig(prompt: "Global prompt."),
    )
  let domain =
    config.DomainConfig(
      ..config.default_domain(),
      vision_model: "zai/custom-vision",
      vision_prompt: "",
    )
  let result = vision.resolve_vision_config(global, Some(domain))
  result.model_spec |> should.equal("zai/custom-vision")
  result.prompt |> should.equal("Global prompt.")
}

pub fn resolve_vision_config_no_config_test() {
  let result = vision.resolve_vision_config(config.default_global(), None)
  result.model_spec |> should.equal("")
  result.prompt |> should.equal("")
}

pub fn extract_image_urls_test() {
  let attachments = [
    types.Attachment(
      url: "https://cdn.discordapp.com/a.png",
      content_type: "image/png",
      filename: "a.png",
    ),
    types.Attachment(
      url: "https://cdn.discordapp.com/b.txt",
      content_type: "text/plain",
      filename: "b.txt",
    ),
    types.Attachment(
      url: "https://cdn.discordapp.com/c.jpg",
      content_type: "image/jpeg",
      filename: "c.jpg",
    ),
  ]
  let urls = vision.extract_image_urls(attachments)
  list.length(urls) |> should.equal(2)
}

pub fn extract_image_urls_empty_content_type_test() {
  let attachments = [
    types.Attachment(
      url: "https://cdn.discordapp.com/photo.png",
      content_type: "",
      filename: "photo.png",
    ),
    types.Attachment(
      url: "https://cdn.discordapp.com/doc.pdf",
      content_type: "",
      filename: "doc.pdf",
    ),
  ]
  let urls = vision.extract_image_urls(attachments)
  list.length(urls) |> should.equal(1)
}

pub fn is_vision_enabled_test() {
  let vc =
    vision.ResolvedVisionConfig(
      model_spec: "zai/glm-5v-turbo",
      prompt: "describe",
    )
  vision.is_enabled(vc) |> should.be_true
}

pub fn is_vision_disabled_test() {
  let empty = vision.ResolvedVisionConfig(model_spec: "", prompt: "")
  vision.is_enabled(empty) |> should.be_false
}
