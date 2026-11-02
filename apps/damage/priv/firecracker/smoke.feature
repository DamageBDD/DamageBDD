Feature: Disposable Firecracker execution
  Scenario: An unprivileged script runs inside a microVM
    When I run a Firecracker script with profile "shell"
      """
      set -eu
      test "$(id -u)" = 1000
      test ! -e /var/run/docker.sock
      printf 'isolated guest ready\n'
      """
    Then the Firecracker exit code should be "0"
    Then the Firecracker output should contain "isolated guest ready"
