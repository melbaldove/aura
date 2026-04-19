Feature: tool call round-trip — read_file result surfaces in reply
  LLM requests a file read; the tool runs; a second LLM call synthesizes
  a response using the content. Discord receives the final synthesis.

  Scenario: read_file tool result surfaces in final reply
    Given a fresh Aura system
    And a tmp file at "/tmp/aura-test-read-file-fixture.txt" containing "hello world"
    And the LLM will call "read_file" with "{\"path\": \"/tmp/aura-test-read-file-fixture.txt\"}"
    And the LLM will respond with "The file says: hello world"
    When a user message "read the file" arrives in "aura-channel"
    Then a Discord message is sent to "aura-channel"
    And the Discord message sent to "aura-channel" contains "hello world"
