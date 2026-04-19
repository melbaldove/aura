Feature: progressive edits — long replies get streamed to Discord in chunks
  Brain edits the in-progress Discord message every ~150 chars of streamed
  content. A long stream produces multiple edits.

  Scenario: long reply produces multiple Discord edits
    Given a fresh Aura system
    And the LLM will stream 10 deltas of 100 characters each
    When a user message "tell me a long story" arrives in "aura-channel"
    Then a Discord message is sent to "aura-channel"
    And Discord received at least 3 edits to the same message
