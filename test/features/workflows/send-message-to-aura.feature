Feature: send a message to the aura channel and get a text response
  Baseline tool loop. Message arrives, LLM returns text, Discord receives a response.
  No tools, no vision, no state mutations.

  Scenario: aura channel text response
    Given a fresh Aura system
    And the LLM will respond with "Hello, Melbs"
    When a user message "hi" arrives in "aura-channel"
    Then a Discord message is sent to "aura-channel"
    And the Discord message sent to "aura-channel" contains "Hello, Melbs"
