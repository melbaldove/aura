Feature: domain context is loaded into the LLM prompt
  When a user messages a domain channel, the domain's AGENTS.md is
  injected into the LLM's system prompt — the LLM should see that
  context before it responds.

  Scenario: domain AGENTS.md appears in the LLM system prompt
    Given a fresh Aura system with domain "local-test" containing AGENTS.md "You are the local-test assistant. Tone: terse."
    And the LLM will respond with "understood"
    When a user message "hi" arrives in "local-test-channel"
    Then the LLM system prompt contains "You are the local-test assistant"
