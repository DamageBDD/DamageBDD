Feature: Verify functionality of damagebdd dashboard interface
  Scenario: Signup form
    When I make a POST request to "/signup" with 
    """
    {
        "username": "{{dashboard_username}}",
        "password": "{{dashboard_password}}",
        "email": "{{email}}"
    }
    """

