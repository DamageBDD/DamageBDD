Feature: Test DamageBDD LLM features
  Scenario: Intitialize with params
    Given I start an llm with params
    """
    {}
    """
    When I send a query
