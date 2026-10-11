Feature: Rip up a default Django installation
  As a DamageBDD node
  I want to aggressively exercise a stock Django deployment
  So that obvious routing, configuration and HTTP security failures are detected

  Background:
    Given I am using server "http://127.0.0.1:8000"

  Scenario: Django root responds
    When I make a GET request to "/"
    Then the response status must be "200"

  Scenario: Default Django root does not disclose a server error
    When I make a GET request to "/"
    Then the response status must be one of "200,404"

  Scenario: Django admin exists
    When I make a GET request to "/admin/"
    Then the response status must be one of "200,301,302"

  Scenario: Django admin login renders
    When I make a GET request to "/admin/login/"
    Then the response status must be "200"
    Then the response must contain text "Django administration"

  Scenario: Anonymous admin access redirects to login
    When I make a GET request to "/admin/"
    Then the response status must be one of "301,302"

  Scenario: Missing route returns 404
    When I make a GET request to "/damagebdd-this-route-does-not-exist"
    Then the response status must be "404"

  Scenario: HEAD works on the root endpoint
    When I make a HEAD request to "/"
    Then the response status must be one of "200,404"

  Scenario: HEAD works on the admin login
    When I make a HEAD request to "/admin/login/"
    Then the response status must be "200"

  Scenario: OPTIONS does not crash Django
    When I make a OPTIONS request to "/admin/login/"
    Then the response status must be one of "200,204"

  Scenario: TRACE is rejected
    When I make a TRACE request to "/admin/login/"
    Then the response status must be one of "405,501"

  Scenario: PUT is rejected by the admin login view
    When I make a PUT request to "/admin/login/"
    """
    {"username":"damagebdd","password":"damagebdd"}
    """
    Then the response status must be "405"

  Scenario: PATCH is rejected by the admin login view
    When I make a PATCH request to "/admin/login/"
    """
    {"username":"damagebdd"}
    """
    Then the response status must be "405"

  Scenario: DELETE is rejected by the admin login view
    When I make a DELETE request to "/admin/login/"
    Then the response status must be "405"

  Scenario: Admin POST without CSRF token is rejected
    Given I set "Content-Type" header to "application/x-www-form-urlencoded"
    When I make a POST request to "/admin/login/?next=/admin/"
    """
    username=damagebdd&password=this-should-never-work&next=/admin/
    """
    Then the response status must be "403"

  Scenario: Arbitrary hostile Host header is rejected
    Given I set "Host" header to "attacker.invalid"
    When I make a GET request to "/"
    Then the response status must be "400"

  Scenario: Dot env file is not exposed
    When I make a GET request to "/.env"
    Then the response status must be "404"

  Scenario: Git repository is not exposed
    When I make a GET request to "/.git/config"
    Then the response status must be "404"

  Scenario: Django settings module is not exposed
    When I make a GET request to "/settings.py"
    Then the response status must be "404"

  Scenario: manage.py is not exposed
    When I make a GET request to "/manage.py"
    Then the response status must be "404"

  Scenario: SQLite development database is not exposed
    When I make a GET request to "/db.sqlite3"
    Then the response status must be "404"

  Scenario: Python bytecode is not exposed
    When I make a GET request to "/__pycache__/settings.cpython-312.pyc"
    Then the response status must be "404"

  Scenario: Requirements file is not exposed
    When I make a GET request to "/requirements.txt"
    Then the response status must be "404"

  Scenario: Docker environment file is not exposed
    When I make a GET request to "/docker-compose.yml"
    Then the response status must be "404"

  Scenario: Encoded parent traversal cannot retrieve manage.py
    When I make a GET request to "/%2e%2e/manage.py"
    Then the response status must be one of "400,404"

  Scenario: Double encoded parent traversal cannot retrieve settings
    When I make a GET request to "/%252e%252e/settings.py"
    Then the response status must be one of "400,404"

  Scenario: Unix passwd traversal probe fails
    When I make a GET request to "/%2e%2e/%2e%2e/%2e%2e/etc/passwd"
    Then the response status must be one of "400,404"

  Scenario: Admin path traversal probe fails
    When I make a GET request to "/admin/%2e%2e/%2e%2e/etc/passwd"
    Then the response status must be one of "400,404"

  Scenario: Null byte path does not produce an application error
    When I make a GET request to "/admin/%00"
    Then the response status must be one of "400,404"

  Scenario: Common PHP probe is dead
    When I make a GET request to "/wp-login.php"
    Then the response status must be "404"

  Scenario: Common WordPress admin probe is dead
    When I make a GET request to "/wp-admin/"
    Then the response status must be "404"

  Scenario: Common phpMyAdmin probe is dead
    When I make a GET request to "/phpmyadmin/"
    Then the response status must be "404"

  Scenario: Server status is not exposed
    When I make a GET request to "/server-status"
    Then the response status must be "404"

  Scenario: Django admin includes nosniff protection
    When I make a GET request to "/admin/login/"
    Then the response status must be "200"
    Then the "X-Content-Type-Options" header should be "nosniff"

  Scenario: Django admin uses same-origin referrer policy
    When I make a GET request to "/admin/login/"
    Then the response status must be "200"
    Then the "Referrer-Policy" header should be "same-origin"

  Scenario: Django admin enables cross origin opener isolation
    When I make a GET request to "/admin/login/"
    Then the response status must be "200"
    Then the "Cross-Origin-Opener-Policy" header should be "same-origin"

  Scenario: Admin login does not accept nonsense JSON credentials
    Given I set "Content-Type" header to "application/json"
    When I make a POST request to "/admin/login/"
    """
    {
      "username": "admin",
      "password": "' OR 1=1 --"
    }
    """
    Then the response status must be "403"

  Scenario: Huge looking query parameter does not trigger a 500
    When I make a GET request to "/admin/login/?next=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    Then the response status must be "200"

  Scenario: SQL injection shaped path is just another missing route
    When I make a GET request to "/users/1%27%20OR%20%271%27=%271"
    Then the response status must be "404"

  Scenario: Template injection shaped path does not execute
    When I make a GET request to "/%7B%7B7*7%7D%7D"
    Then the response status must be "404"

  Scenario: Script shaped path does not execute
    When I make a GET request to "/%3Cscript%3Ealert(1)%3C/script%3E"
    Then the response status must be one of "400,404"

  Scenario: Final health check proves Django survived the abuse
    When I make a GET request to "/admin/login/"
    Then the response status must be "200"
    Then the response must contain text "Django administration"
