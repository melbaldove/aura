import aura/llm
import aura/models
import gleeunit/should

// --- resolve_model_name ---

pub fn resolve_model_name_with_provider_prefix_test() {
  models.resolve_model_name("zai/glm-5-turbo") |> should.equal("glm-5-turbo")
}

pub fn resolve_model_name_claude_prefix_test() {
  models.resolve_model_name("claude/haiku") |> should.equal("haiku")
}

pub fn resolve_model_name_bare_model_test() {
  models.resolve_model_name("glm-5-turbo") |> should.equal("glm-5-turbo")
}

pub fn resolve_model_name_empty_string_test() {
  models.resolve_model_name("") |> should.equal("")
}

// --- default_brain_model ---

pub fn default_brain_model_zai_test() {
  models.default_brain_model("zai") |> should.equal("zai/glm-5-turbo")
}

pub fn default_brain_model_openai_codex_test() {
  models.default_brain_model("openai-codex")
  |> should.equal("openai-codex/gpt-5.5")
}

pub fn default_brain_model_unknown_falls_back_to_claude_test() {
  models.default_brain_model("unknown") |> should.equal("claude/haiku")
}

pub fn default_brain_model_empty_falls_back_to_claude_test() {
  models.default_brain_model("") |> should.equal("claude/haiku")
}

// --- api_key_env_var ---

pub fn api_key_env_var_zai_test() {
  models.api_key_env_var("zai") |> should.equal("ZAI_API_KEY")
}

pub fn api_key_env_var_openai_codex_test() {
  models.api_key_env_var("openai-codex")
  |> should.equal("AURA_OPENAI_CODEX_ACCESS_TOKEN")
}

pub fn api_key_env_var_unknown_falls_back_to_anthropic_test() {
  models.api_key_env_var("unknown") |> should.equal("ANTHROPIC_API_KEY")
}

pub fn api_key_env_var_empty_falls_back_to_anthropic_test() {
  models.api_key_env_var("") |> should.equal("ANTHROPIC_API_KEY")
}

// --- build_llm_config_with_key ---

pub fn build_llm_config_with_key_zai_test() {
  models.build_llm_config_with_key("zai/glm-5-turbo", "test-key-123")
  |> should.equal(
    Ok(llm.LlmConfig(
      base_url: "https://api.z.ai/api/coding/paas/v4",
      api_key: "test-key-123",
      model: "glm-5-turbo",
      codex_reasoning_effort: "medium",
    )),
  )
}

pub fn build_llm_config_with_key_claude_test() {
  models.build_llm_config_with_key("claude/haiku", "sk-ant-abc")
  |> should.equal(
    Ok(llm.LlmConfig(
      base_url: "https://api.anthropic.com/v1",
      api_key: "sk-ant-abc",
      model: "haiku",
      codex_reasoning_effort: "medium",
    )),
  )
}

pub fn build_llm_config_with_key_openai_codex_test() {
  models.build_llm_config_with_key("openai-codex/gpt-5.5", "access\nacct")
  |> should.equal(
    Ok(llm.LlmConfig(
      base_url: "https://chatgpt.com/backend-api/codex",
      api_key: "access\nacct",
      model: "gpt-5.5",
      codex_reasoning_effort: "medium",
    )),
  )
}

pub fn build_llm_config_with_key_and_codex_reasoning_effort_test() {
  models.build_llm_config_with_key_and_codex_reasoning_effort(
    "openai-codex/gpt-5.5",
    "access\nacct",
    "high",
  )
  |> should.equal(
    Ok(llm.LlmConfig(
      base_url: "https://chatgpt.com/backend-api/codex",
      api_key: "access\nacct",
      model: "gpt-5.5",
      codex_reasoning_effort: "high",
    )),
  )
}

pub fn build_llm_config_with_key_unknown_provider_test() {
  models.build_llm_config_with_key("openai/gpt-4", "some-key")
  |> should.equal(Error("Unknown model provider in spec: openai/gpt-4"))
}

pub fn build_llm_config_with_key_bare_model_errors_test() {
  models.build_llm_config_with_key("glm-5-turbo", "some-key")
  |> should.equal(Error("Unknown model provider in spec: glm-5-turbo"))
}

// --- memory_token_budget ---

pub fn memory_token_budget_known_model_test() {
  // zai/glm-5.1 has 204_800 context, 10% = 20_480
  models.memory_token_budget("zai/glm-5.1", 0, 10)
  |> should.equal(20_480)
}

pub fn memory_token_budget_unknown_model_fallback_test() {
  // Unknown model with no config override falls back to 20_000
  models.memory_token_budget("unknown/model", 0, 10)
  |> should.equal(20_000)
}
