# Not implemented
Feature: Run command in docker
    Scenario: Run a Docker Container
        Given I have a Docker image named "myapp:latest"
        When I run a Docker container using the image
        Then the container should start successfully
        And the container should be running

    Scenario: Expose Ports in a Docker Container
        Given I have a Docker container running
        When I expose port 8080 in the container
        Then I should be able to access the container at "http://localhost:8080"

    Scenario: Link Docker Containers
        Given I have two Docker containers running named "app1" and "app2"
        When I link "app1" to "app2"
        Then "app2" should be able to communicate with "app1"

    Scenario: Mount Volumes in a Docker Container
        Given I have a Docker container running
        When I mount the local directory "/path/to/host/dir" to "/app/data" in the container
        Then changes made in "/app/data" should reflect in "/path/to/host/dir"

    Scenario: Build a Docker Image with Build Arguments
        Given I have a Dockerfile with build arguments defined
        When I build the Docker image with arguments "ARG1=value1" and "ARG2=value2"
        Then the image should be successfully built with the specified arguments

    Scenario: Pull Docker Images from a Private Registry
        Given I have a Docker image hosted on a private registry
        When I authenticate with the registry using credentials
        Then I should be able to pull the image successfully

    Scenario: Push Docker Images to a Private Registry
        Given I have a Docker image built locally
        When I authenticate with a private registry using credentials
        And I push the image to the registry
        Then the image should be successfully pushed to the registry

    Scenario: Docker Network Communication
        Given I have multiple Docker containers connected to the same network
        When I send a request from one container to another
        Then the receiving container should respond appropriately

    Scenario: Docker Compose Up and Down
        Given I have a Docker Compose file describing multiple services
        When I run "docker-compose up"
        Then all defined services should start successfully
        And when I run "docker-compose down"
        Then all services should be stopped and removed

    Scenario: Docker Health Checks
        Given I have a Docker container with a defined health check
        When I start the container
        Then the container should report a healthy status after a specified time
