Feature: channel_actor path produces the same text response as synchronous brain
  With the channel_actor allowlist enabled for a channel, an incoming user
  message routes through the per-channel actor path instead of the legacy
  synchronous brain loop. Observable outcome: identical — LLM responds with
  text, Discord receives it.

  Scenario: allowlisted channel text response
    Given a fresh Aura system with channel "aura-channel" on the channel_actor allowlist
    And the LLM will respond with "Hello from channel_actor"
    When a user message "hi" arrives in "aura-channel"
    Then a Discord message is sent to "aura-channel"
    And the Discord message sent to "aura-channel" contains "Hello from channel_actor"
