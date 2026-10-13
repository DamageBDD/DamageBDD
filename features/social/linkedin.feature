Feature: LinkedIn API behaviour

  Background:
    Given I set LinkedIn API version to "202606"
    And I set LinkedIn OAuth token from secret "linkedin_access_token"

  Scenario: Read authenticated LinkedIn profile
    When I get my LinkedIn OpenID profile
    Then the LinkedIn response status must be "200"
    And I store the LinkedIn JSON at path "$.sub" in "linkedin_sub"

  Scenario: Publish an organization text post
    Given I set LinkedIn author URN to "urn:li:organization:123456789"
    When I create a LinkedIn text post from the configured author
    """
    DamageBDD behaviour verification now reaches LinkedIn.
    """
    Then the LinkedIn response status must be "201"
    And I store the LinkedIn response header "x-restli-id" in "linkedin_post_urn"
