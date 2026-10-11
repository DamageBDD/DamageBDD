Feature: GS-style GTK4 dialog and visual contract

  The fast profile verifies the logical object protocol with a deterministic
  Erlang backend. The visual profile uses the real GTK4 C-node and renderer.

  @contract
  Scenario: A button exposes deterministic state and events
    Given gtkgs is running with the deterministic backend
    And I created a window named "bdd_window"
    And I created a button named "action_button" with label "Act"
    When I remember the gtkgs event cursor
    And I inject a "click" event into "action_button"
    Then a "click" event for "action_button" occurs after the remembered cursor
    And the event data and payload are recorded in the report

  @contract
  Scenario: A dialog can be driven without arbitrary sleeps
    Given gtkgs is running in test mode
    And I created a window named "dialog_window"
    When I open a question dialog with buttons "no,yes" and auto-response "yes"
    Then the dialog result is "yes"
    And dialog opened and dialog closed events are observable

  @visual
  Scenario: A human can verify the rendered dialog
    Given gtkgs is running with the real local GTK4 C-node
    And the renderer profile, theme, fonts, scale and locale are recorded
    And I created the dialog demo window
    When I open the About dialog
    And I wait for the gtkgs renderer barrier
    And I capture the parent window and active dialog
    Then the PNG artifacts are attached to the DamageBDD report
    And a human reviewer can accept or reject the visual checkpoint
