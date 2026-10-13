Feature: Google Gemini AI Integration
  As a DamageBDD user
  I want to interact with Google Gemini
  So that I can use AI-generated content in my test scenarios

  Background:
    Given I load the Gemini API key from secret gemini_api_key
    And I use Gemini model gemini-3-flash-preview

  Scenario: Basic prompt and response
    When I send a prompt to Gemini Explain what Erlang is in one sentence
    Then the Gemini response must not be empty
    And I print the Gemini response

  Scenario: Response contains expected content
    When I send a prompt to Gemini What is the capital of France? Answer in one word.
    Then the Gemini response must contain Paris

  Scenario: Multi-turn conversation
    When I send a prompt to Gemini My name is Alice. Remember that.
    And I continue the Gemini conversation with What is my name?
    Then the Gemini response must contain Alice

  Scenario: Use a docstring prompt
    When I send a prompt to Gemini
      """
      List exactly three benefits of functional programming.
      Format as a numbered list.
      """
    Then the Gemini response must not be empty
    And I store the Gemini response in gemini_result
    And I print the variable gemini_result

  Scenario: Prompt with Google Search grounding
    When I send a prompt to Gemini with Google Search What is the current Erlang/OTP version?
    Then the Gemini response must not be empty
    And I print the Gemini response

  Scenario: Custom system instruction
    Given I set the Gemini system instruction to You are a pirate. Always respond in pirate speak.
    When I send a prompt to Gemini Hello, how are you?
    Then the Gemini response must not be empty
    And I print the Gemini response

  Scenario: Controlled temperature for deterministic output
    Given I set the Gemini temperature to 0.0
    When I send a prompt to Gemini What is 2 + 2? Reply with just the number.
    Then the Gemini response must contain 4

  Scenario: Store response and use in later step
    When I send a prompt to Gemini Generate a UUID v4 example. Reply with just the UUID.
    And I store the Gemini response in generated_uuid
    Then the variable generated_uuid should be equal to JSON "generated_uuid"
