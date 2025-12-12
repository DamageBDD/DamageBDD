Scenario: Configure a Syncthing share for a device
  Given I am using syncthing at "http://127.0.0.1:8384"
  And I set syncthing api key to "{{SYNCTHING_API_KEY}}"

  When I add syncthing device "6Q5DZNK-OUR81B9-7XVBNEW-G98K9LW-E7ZI313-MSF2DZJ-YU0POJ9-N4FGYV9" named "my-laptop"

  And I share folder "default" 
    at path "/srv/syncthing/default" 
    named "Default" 
    with device "6Q5DZNK-OUR81B9-7XVBNEW-G98K9LW-E7ZI313-MSF2DZJ-YU0POJ9-N4FGYV9"

  Then the syncthing response status must be "200"
