Feature: Switch audio routing to predefined scenes

  Background:
    Given the audio scene config is
      """
      {
        "scenes": {
          "headphones+mic": {
            "default_sink":   "alsa_output.usb-Focusrite_Scarlett_Solo_3rd_Gen-00.analog-stereo",
            "default_source": "alsa_input.usb-Focusrite_Scarlett_Solo_3rd_Gen-00.mono-fallback",
            "move_playback":  "all",
            "move_capture":   "all"
          },
          "hdmi-only": {
            "default_sink":   "alsa_output.pci-0000_01_00.1.hdmi-stereo",
            "default_source": null,
            "move_playback":  "all",
            "move_capture":   "none"
          }
        }
      }
      """

  Scenario: Press Headphones + Mic
    When I press the "headphones+mic" audio button
    Then the default sink should be "alsa_output.usb-Focusrite_Scarlett_Solo_3rd_Gen-00.analog-stereo"
    And the default source should be "alsa_input.usb-Focusrite_Scarlett_Solo_3rd_Gen-00.mono-fallback"
    And all playback streams should be on sink "alsa_output.usb-Focusrite_Scarlett_Solo_3rd_Gen-00.analog-stereo"
    And all capture streams should be on source "alsa_input.usb-Focusrite_Scarlett_Solo_3rd_Gen-00.mono-fallback"

  Scenario: Press HDMI Only
    When I press the "hdmi-only" audio button
    Then the default sink should be "alsa_output.pci-0000_01_00.1.hdmi-stereo"
    And all playback streams should be on sink "alsa_output.pci-0000_01_00.1.hdmi-stereo"
