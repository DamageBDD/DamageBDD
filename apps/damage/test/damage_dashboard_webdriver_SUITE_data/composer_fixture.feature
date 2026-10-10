Feature: Composer and billing-navigation fixture regressions
  Browser actions use Selenium or Appium W3C WebDriver.
  Credentials and endpoints come from operator configuration, not this file.

  Background:
    Given I start the configured WebDriver browser
    Given I open the authenticated WebDriver dashboard
    Then the WebDriver element "[data-dashboard-shell]" should be "visible"

  Scenario: Prompt examples enable generation without executing anything
    Then the WebDriver element "#bdd-generate" should be "disabled"
    When I click the WebDriver element "[data-bdd-example=health]"
    Then the WebDriver element "#bdd-generate" should be "enabled"
    Then the WebDriver value of "#bdd-prompt" should contain "200"
    Then the dashboard fixture should have "0" requests for "generate"
    Then the dashboard fixture should have "0" requests for "execute"
    Then I close the WebDriver browser

  Scenario: Generating a draft preserves the editor and blocks repeated submission
    Given the dashboard fixture response mode is "ok"
    When I fill the WebDriver element "#damageTextArea" with "Feature: Keep my editor"
    When I remember the WebDriver value of "#damageTextArea" as "original"
    When I fill the WebDriver element "#bdd-prompt" with "Check that the health endpoint returns HTTP 200"
    Given the dashboard fixture response gate is "hold"
    When I click the WebDriver element "#bdd-generate"
    Then the WebDriver element "#bdd-generate" should be "disabled"
    Then the WebDriver element "#bdd-prompt" property "readOnly" should equal JSON "true"
    When the dashboard fixture response gate is "release"
    Then the dashboard fixture should be idle
    Then the WebDriver element "#bdd-draft-panel" should be "visible"
    Then the WebDriver element "#bdd-accept" should be "enabled"
    Then the WebDriver value of "#damageTextArea" should equal remembered "original"
    Then the dashboard fixture should have "1" requests for "generate"
    Then the dashboard fixture should have "0" requests for "execute"
    Then I close the WebDriver browser

  Scenario: Accepting a draft requires confirmation and can be undone
    Given the dashboard fixture response mode is "ok"
    When I fill the WebDriver element "#damageTextArea" with "Feature: Keep my editor"
    When I remember the WebDriver value of "#damageTextArea" as "original"
    When I fill the WebDriver element "#bdd-prompt" with "Check that the health endpoint returns HTTP 200"
    When I click the WebDriver element "#bdd-generate"
    Then the dashboard fixture should be idle
    Then the WebDriver element "#bdd-cancel" should be "hidden"
    When I click the WebDriver element "#bdd-accept"
    When I respond to the WebDriver alert with "dismiss"
    Then the WebDriver value of "#damageTextArea" should equal remembered "original"
    When I click the WebDriver element "#bdd-accept"
    When I respond to the WebDriver alert with "accept"
    Then the WebDriver value of "#damageTextArea" should contain "API health"
    Then the WebDriver text in "#bdd-validation-status" should contain "Runtime behaviour is not verified"
    When I click the WebDriver element "#bdd-undo"
    When I respond to the WebDriver alert with "accept"
    Then the WebDriver value of "#damageTextArea" should equal remembered "original"
    Then the dashboard fixture should have "0" requests for "execute"
    Then I close the WebDriver browser

  Scenario: An invalid draft cannot replace the editor
    Given the dashboard fixture response mode is "ok"
    When I fill the WebDriver element "#damageTextArea" with "Feature: Keep my editor"
    When I remember the WebDriver value of "#damageTextArea" as "original"
    When I fill the WebDriver element "#bdd-prompt" with "Check that the health endpoint returns HTTP 200"
    Given the dashboard fixture response mode is "invalid"
    When I click the WebDriver element "#bdd-generate"
    Then the dashboard fixture should be idle
    Then the WebDriver element "#bdd-cancel" should be "hidden"
    Then the WebDriver element "#bdd-draft-panel" should be "visible"
    Then the WebDriver element "#bdd-accept" should be "disabled"
    Then the WebDriver value of "#damageTextArea" should equal remembered "original"
    Then the dashboard fixture should have "0" requests for "execute"
    Then I close the WebDriver browser

  Scenario: An incomplete draft cannot replace the editor
    Given the dashboard fixture response mode is "ok"
    When I fill the WebDriver element "#damageTextArea" with "Feature: Keep my editor"
    When I remember the WebDriver value of "#damageTextArea" as "original"
    When I fill the WebDriver element "#bdd-prompt" with "Check that the health endpoint returns HTTP 200"
    Given the dashboard fixture response mode is "incomplete"
    When I click the WebDriver element "#bdd-generate"
    Then the dashboard fixture should be idle
    Then the WebDriver element "#bdd-cancel" should be "hidden"
    Then the WebDriver element "#bdd-draft-panel" should be "visible"
    Then the WebDriver element "#bdd-accept" should be "disabled"
    Then the WebDriver value of "#damageTextArea" should equal remembered "original"
    Then the dashboard fixture should have "0" requests for "execute"
    Then I close the WebDriver browser

  Scenario: Cancellation recovers controls without changing the editor
    Given the dashboard fixture response mode is "ok"
    When I fill the WebDriver element "#damageTextArea" with "Feature: Keep my editor"
    When I remember the WebDriver value of "#damageTextArea" as "original"
    When I fill the WebDriver element "#bdd-prompt" with "Check that the health endpoint returns HTTP 200"
    Given the dashboard fixture response gate is "hold"
    When I click the WebDriver element "#bdd-generate"
    Then the WebDriver element "#bdd-cancel" should be "visible"
    When I click the WebDriver element "#bdd-cancel"
    Then the dashboard fixture should be idle
    Then the WebDriver text in "#bdd-generation-status" should contain "Generation cancelled"
    Then the WebDriver element "#bdd-generate" should be "enabled"
    Then the WebDriver value of "#damageTextArea" should equal remembered "original"
    Then the dashboard fixture should have "1" requests for "cancel"
    Then I close the WebDriver browser

  Scenario: http-error response preserves work and shows the error
    Given the dashboard fixture response mode is "ok"
    When I fill the WebDriver element "#damageTextArea" with "Feature: Keep my editor"
    When I remember the WebDriver value of "#damageTextArea" as "original"
    When I fill the WebDriver element "#bdd-prompt" with "Check that the health endpoint returns HTTP 200"
    Given the dashboard fixture response mode is "http-error"
    When I click the WebDriver element "#bdd-generate"
    Then the dashboard fixture should be idle
    Then the WebDriver element "#bdd-cancel" should be "hidden"
    Then the WebDriver text in "#bdd-generation-status" should contain "model service unavailable"
    Then the WebDriver element "#bdd-generate" should be "enabled"
    Then the WebDriver element "#bdd-prompt" property "readOnly" should equal JSON "false"
    Then the WebDriver value of "#damageTextArea" should equal remembered "original"
    Then I close the WebDriver browser

  Scenario: unauthorized response preserves work and shows the error
    Given the dashboard fixture response mode is "ok"
    When I fill the WebDriver element "#damageTextArea" with "Feature: Keep my editor"
    When I remember the WebDriver value of "#damageTextArea" as "original"
    When I fill the WebDriver element "#bdd-prompt" with "Check that the health endpoint returns HTTP 200"
    Given the dashboard fixture response mode is "unauthorized"
    When I click the WebDriver element "#bdd-generate"
    Then the dashboard fixture should be idle
    Then the WebDriver element "#bdd-cancel" should be "hidden"
    Then the WebDriver text in "#bdd-generation-status" should contain "session has expired"
    Then the WebDriver element "#bdd-generate" should be "enabled"
    Then the WebDriver element "#bdd-prompt" property "readOnly" should equal JSON "false"
    Then the WebDriver value of "#damageTextArea" should equal remembered "original"
    Then I close the WebDriver browser

  Scenario: An unavailable model leaves manual editing and validation available
    Given the dashboard fixture response mode is "no-engine"
    When I click the WebDriver element "#bdd-refresh-catalog"
    Then the dashboard fixture should be idle
    When I fill the WebDriver element "#bdd-prompt" with "Check health"
    Then the WebDriver element "#bdd-generate" should be "disabled"
    When I fill the WebDriver element "#damageTextArea" with "Feature: Manual authoring"
    Then the WebDriver element "#bdd-validate" should be "enabled"
    Then the WebDriver text in "#bdd-generation-status" should contain "ECAI generation is unavailable"
    Then I close the WebDriver browser

  Scenario: Model content is rendered as text rather than executable markup
    Given the dashboard fixture response mode is "ok"
    When I fill the WebDriver element "#damageTextArea" with "Feature: Keep my editor"
    When I remember the WebDriver value of "#damageTextArea" as "original"
    When I fill the WebDriver element "#bdd-prompt" with "Check that the health endpoint returns HTTP 200"
    Given the dashboard fixture response mode is "xss"
    When I click the WebDriver element "#bdd-generate"
    Then the dashboard fixture should be idle
    Then the WebDriver element "#bdd-cancel" should be "hidden"
    Then the WebDriver text in "#bdd-draft-source" should contain "<img"
    Then the WebDriver element "#bdd-draft-source img" should be "absent"
    Then the dashboard fixture should not execute injected content
    Then I close the WebDriver browser

  Scenario: A stale validation response cannot validate newly edited content
    Given the dashboard fixture response mode is "ok"
    When I fill the WebDriver element "#damageTextArea" with "Feature: Keep my editor"
    When I remember the WebDriver value of "#damageTextArea" as "original"
    When I fill the WebDriver element "#bdd-prompt" with "Check that the health endpoint returns HTTP 200"
    Given the dashboard fixture response gate is "hold"
    When I click the WebDriver element "#bdd-validate"
    When I fill the WebDriver element "#damageTextArea" with "Feature: Changed during validation"
    When the dashboard fixture response gate is "release"
    Then the dashboard fixture should be idle
    Then the WebDriver text in "#bdd-validation-status" should contain "Editor changed"
    Then the WebDriver element "#bdd-validate" should be "enabled"
    Then the dashboard fixture should have "0" requests for "execute"
    Then I close the WebDriver browser

  Scenario: Simulated run output appears only after an explicit Run
    Given the dashboard fixture response mode is "ok"
    When I fill the WebDriver element "#damageTextArea" with "Feature: Keep my editor"
    When I remember the WebDriver value of "#damageTextArea" as "original"
    When I fill the WebDriver element "#bdd-prompt" with "Check that the health endpoint returns HTTP 200"
    Given the dashboard fixture response gate is "hold"
    When I click the WebDriver element "#execute-feature-btn"
    Then the WebDriver element "#execute-feature-btn" should be "disabled"
    Then the WebDriver text in "#bdd-run-status" should contain "Running"
    When the dashboard fixture response gate is "release"
    Then the WebDriver element "#execute-feature-btn" should be "enabled"
    Then the WebDriver text in "#bdd-run-status" should contain "Request complete"
    Then the WebDriver text in "#run-reports" should contain "no feature was executed"
    Then the dashboard fixture should have "1" requests for "execute"
    Then I close the WebDriver browser

  Scenario: Hidden billing links cannot be selected until revealed
    Given the dashboard fixture billing navigation is "hidden"
    When I open the WebDriver dashboard at fragment "#billing-tab"
    Then the WebDriver element "#execution-tab" should be "visible"
    Then the WebDriver element "#billing-nav" should be "hidden"
    Given the dashboard fixture billing navigation is "visible"
    Then the WebDriver element "#billing-tab" should be "visible"
    Given the dashboard fixture billing navigation is "hidden"
    Then the WebDriver element "#execution-tab" should be "visible"
    Then the WebDriver URL fragment should be "#execution-tab"
    Then I close the WebDriver browser
