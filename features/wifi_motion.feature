Given I enable wifi motion on wlan0
When I wait for motion for 3000 ms
Then motion must be detected within 3000 ms
