@native @gtk4 @lifecycle
Feature: gtknode4 owns and destroys native widgets safely

  Background:
    Given erm is running gtknode4 in local_cnode mode
    And the gtknode4 process environment contains "G_DEBUG=fatal-criticals"
    And I record the native gtknode4 operating-system process id

  Scenario: Repeated nested tree destruction does not corrupt GTK ownership
    When I create, present, synchronize and destroy 100 nested gtkgs trees
    Then the gtknode4 controller should remain ready
    And the native gtknode4 process should remain alive
    And the native gtknode4 operating-system process id should be unchanged
