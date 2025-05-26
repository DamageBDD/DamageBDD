Feature: Docker Cleanup Relative Date

  Scenario: Remove all unused Docker resources since relative date
    Given the system has unused Docker containers or resources since "7 days ago"
    When I clean up all unused Docker containers, images, volumes and networks since "7 days ago"
    Then the Docker system should have no unused resources older than "7 days ago"

