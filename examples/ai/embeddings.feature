@ai @live
Feature: Embedding comparisons use one profile and model

  Scenario: Similar requests are close in the selected embedding space
    Given I use AI profile "local"
    And I set the AI input to
      """
      I was charged twice for my order.
      """
    When I embed the AI input and store result in "ai_original"
    Given I set the AI input to
      """
      There is a duplicate payment on my order.
      """
    When I embed the AI input and store result in "ai_paraphrase"
    Then AI embeddings in "ai_original" and "ai_paraphrase" should have cosine similarity at least "0.70"
