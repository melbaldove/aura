Feature: multi-tool turn — multiple sequential tool calls in one conversation
  LLM runs two tools across two iterations; final reply references both results.

  Scenario: read file then list directory then synthesize
    Given a fresh Aura system
    And a tmp file at "/tmp/aura-test-multi-tool-content.txt" containing "alpha"
    And the LLM will call "read_file" with "{\"path\": \"/tmp/aura-test-multi-tool-content.txt\"}"
    And the LLM will call "list_directory" with "{\"path\": \"/tmp\"}"
    And the LLM will respond with "I read alpha and listed /tmp"
    When a user message "do the thing" arrives in "aura-channel"
    Then a Discord message is sent to "aura-channel"
    And the Discord message sent to "aura-channel" contains "I read alpha and listed /tmp"
