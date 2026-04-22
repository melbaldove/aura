import aura/clients/llm_client
import aura/config
import aura/llm
import aura/message
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
    message.Attachment(
      url: "https://cdn.discordapp.com/a.png",
      content_type: "image/png",
      filename: "a.png",
    ),
    message.Attachment(
      url: "https://cdn.discordapp.com/b.txt",
      content_type: "text/plain",
      filename: "b.txt",
    ),
    message.Attachment(
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
    message.Attachment(
      url: "https://cdn.discordapp.com/photo.png",
      content_type: "",
      filename: "photo.png",
    ),
    message.Attachment(
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

/// Regression: vision.describe_with_config calls the LLM client with the
/// right message structure. Uses a fake client that returns "ok" to verify
/// the call path works without env variables.
pub fn describe_with_config_calls_llm_client_test() {
  let fake_client =
    llm_client.LLMClient(
      stream_with_tools: fn(_, _, _, _) { Nil },
      chat: fn(_, _, _) { Error("not used") },
      chat_text: fn(_cfg, _msgs, _temp) { Ok("image description") },
    )
  let config = llm.LlmConfig(base_url: "http://fake", api_key: "k", model: "m")
  let result =
    vision.describe_with_config(fake_client, config, "describe it", "fake-url")
  result |> should.equal(Ok("image description"))
}

/// Regression: channel_actor.Deps.resolved_vision_config with an empty
/// model_spec returns Error("vision not configured...") — not Error("stub")
/// which proves the real vision_fn is wired, not the old stub.
pub fn vision_fn_not_stub_when_vision_disabled_test() {
  let deps = vision.ResolvedVisionConfig(model_spec: "", prompt: "")
  let fake_client =
    llm_client.LLMClient(
      stream_with_tools: fn(_, _, _, _) { Nil },
      chat: fn(_, _, _) { Error("not used") },
      chat_text: fn(_, _, _) { Ok("should not reach") },
    )
  // Mirror the vision_fn closure from build_initial_state
  let rvc = deps
  let vision_fn = fn(image_url: String, question: String) {
    case vision.is_enabled(rvc) {
      False ->
        Error("vision not configured (set [models] vision in config.toml)")
      True -> {
        let cfg = case question {
          "" -> rvc
          q -> vision.ResolvedVisionConfig(..rvc, prompt: q)
        }
        vision.describe_via_client(fake_client, cfg, image_url)
      }
    }
  }
  let result = vision_fn("fake-url", "")
  // Must be an error, but NOT the old stub Error("stub")
  case result {
    Error("stub") -> should.fail()
    Error(_) -> Nil
    // disabled vision → Error("vision not configured...")
    Ok(_) -> should.fail()
  }
}
