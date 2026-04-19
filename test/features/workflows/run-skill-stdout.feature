Feature: run_skill tool — stdout surfaces in final reply
  LLM calls run_skill; the fake skill runner returns scripted stdout;
  the LLM's next iteration synthesizes a reply including the stdout.

  Scenario: jira skill stdout flows to Discord
    Given a fresh Aura system
    And skill "jira" will return stdout "PROJECT-123 updated"
    And the LLM will call run_skill with name "jira" and args "update ticket"
    And the LLM will respond with "Done: PROJECT-123 updated"
    When a user message "update jira" arrives in "aura-channel"
    Then a Discord message is sent to "aura-channel"
    And the Discord message sent to "aura-channel" contains "PROJECT-123 updated"
