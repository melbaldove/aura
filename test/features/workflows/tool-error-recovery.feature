Feature: tool error recovery — LLM sees errors and adapts
  When a tool call fails, the error is returned to the LLM as a tool result
  message. The LLM's next iteration can reference that error in its reply.

  Scenario: read_file on missing path returns error; LLM acknowledges in reply
    Given a fresh Aura system
    And the LLM will call "read_file" with "{\"path\": \"/tmp/aura-nonexistent-xyz-guaranteed-missing\"}"
    And the LLM will respond with "Sorry, that file doesn't exist"
    When a user message "read that file" arrives in "aura-channel"
    Then a Discord message is sent to "aura-channel"
    And the Discord message sent to "aura-channel" contains "doesn't exist"
    And the LLM last call messages contain "Error:"
