import aura/clients/llm_client

pub fn production_llm_client_destructures_with_both_fields_test() {
  // If this compiles and runs, the record has exactly two function fields.
  // A missing field would cause a compile error at destructure; this test
  // fails (at compile time) if someone removes a field without updating callers.
  case llm_client.production() {
    llm_client.LLMClient(stream_with_tools: _, chat: _) -> Nil
  }
}
