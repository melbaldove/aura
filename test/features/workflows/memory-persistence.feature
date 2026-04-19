Feature: memory tool — values written in one turn persist to the next
  LLM uses memory(set) to record a fact; subsequent turn's system prompt
  includes that fact (proving the round-trip: tool writes to disk, brain
  reassembles the prompt on the next message).

  Note: target=user writes to USER.md (global, always available without
  domain setup). A separate scenario would cover per-domain memory.

  Scenario: memory set then visible in next turn's system prompt
    Given a fresh Aura system
    And the LLM will call "memory" with "{\"action\": \"set\", \"target\": \"user\", \"key\": \"favorite-color\", \"content\": \"orange\"}"
    And the LLM will respond with "saved"
    When a user message "remember my favorite color is orange" arrives in "aura-channel"
    Then the Discord message sent to "aura-channel" contains "saved"
    And the LLM will respond with "orange"
    When a user message "what is my favorite color" arrives in "aura-channel"
    Then the LLM system prompt contains "favorite-color"
    And the LLM system prompt contains "orange"
