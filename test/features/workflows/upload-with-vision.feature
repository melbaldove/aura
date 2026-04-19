Feature: send an image and get a vision-enriched reply
  Vision preprocessing runs before the tool loop. The image's description
  is enriched into the user message so the LLM's response reflects what
  the vision model saw.

  Scenario: image attachment enriches the LLM reply
    Given a fresh Aura system
    And the vision model will describe the image as "a blue sky over mountains"
    And the LLM will respond with "Nice view"
    When a user message with image "hello" arrives in "aura-channel"
    Then a Discord message is sent to "aura-channel"
    And the Discord message sent to "aura-channel" contains "Nice view"
    And the LLM user message contains "a blue sky over mountains"
