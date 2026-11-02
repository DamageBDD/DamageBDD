%% Recorder vocabulary adapter for the current DamageBDD WebDriver runtime.
%% All sessions are owned/cleaned by steps_webdriver and damage:execute_steps/3.
%% Recording/export is local; replay deliberately follows the node_admin policy.
-module(steps_browser_recorder).
-author("DamageBDD").
-license("Apache-2.0").
-damage_roles([node_admin]).
-export([step/6, step_dry/6]).

-define(START(Url), ["I start a recorded browser at", Url]).
-define(NAVIGATE(Url), ["I navigate the recorded browser to", Url]).
-define(CLICK(Selector), ["I click recorded element", Selector]).
-define(FILL(Selector), ["I type into recorded field", Selector]).
-define(SECRET(SecretName, Selector), ["I type secret", SecretName, "into recorded field", Selector]).
-define(SELECT(Selector), ["I select recorded option in", Selector]).
-define(CHECK(Selector), ["I set recorded checkbox", Selector, "to checked"]).
-define(UNCHECK(Selector), ["I set recorded checkbox", Selector, "to unchecked"]).
-define(PRESS(Selector), ["I press Enter in recorded field", Selector]).
-define(TEXT(Selector), ["recorded element", Selector, "should contain text"]).
-define(URL(ExpectedUrl), ["the recorded browser URL should start with", ExpectedUrl]).
-define(CLOSE, ["I close the recorded browser"]).

%% No catch-all clauses: unrelated steps must continue through the registry.
step_dry(Config, Context, Keyword, Line, ?START(_) = Parts, Body) ->
    dry(Config, Context, Keyword, Line, Parts, Body);
step_dry(Config, Context, Keyword, Line, ?NAVIGATE(_) = Parts, Body) ->
    dry(Config, Context, Keyword, Line, Parts, Body);
step_dry(Config, Context, Keyword, Line, ?CLICK(_) = Parts, Body) ->
    dry(Config, Context, Keyword, Line, Parts, Body);
step_dry(Config, Context, Keyword, Line, ?FILL(_) = Parts, Body) ->
    dry(Config, Context, Keyword, Line, Parts, Body);
step_dry(Config, Context, Keyword, Line, ?SECRET(_, _) = Parts, Body) ->
    dry(Config, Context, Keyword, Line, Parts, Body);
step_dry(Config, Context, Keyword, Line, ?SELECT(_) = Parts, Body) ->
    dry(Config, Context, Keyword, Line, Parts, Body);
step_dry(Config, Context, Keyword, Line, ?CHECK(_) = Parts, Body) ->
    dry(Config, Context, Keyword, Line, Parts, Body);
step_dry(Config, Context, Keyword, Line, ?UNCHECK(_) = Parts, Body) ->
    dry(Config, Context, Keyword, Line, Parts, Body);
step_dry(Config, Context, Keyword, Line, ?PRESS(_) = Parts, Body) ->
    dry(Config, Context, Keyword, Line, Parts, Body);
step_dry(Config, Context, Keyword, Line, ?TEXT(_) = Parts, Body) ->
    dry(Config, Context, Keyword, Line, Parts, Body);
step_dry(Config, Context, Keyword, Line, ?URL(_) = Parts, Body) ->
    dry(Config, Context, Keyword, Line, Parts, Body);
step_dry(Config, Context, Keyword, Line, ?CLOSE = Parts, Body) ->
    dry(Config, Context, Keyword, Line, Parts, Body).

dry(Config, Context, Keyword, Line, Parts, Body) ->
    case steps_utils:is_admin(Context) of
        true -> steps_utils:step_dry(Config, Context, Keyword, Line, Parts, Body);
        false -> denied(Context)
    end.

step(Config, Context, Keyword, Line, ?START(Url), _Body) ->
    case steps_utils:is_admin(Context) of
        false ->
            denied(Context);
        true ->
            case damage_webdriver:navigation_url(Url) of
                {ok, Target} ->
                    case recorder_config(Config, Target) of
                        {ok, Config1} ->
                            Started = steps_webdriver:step(
                                Config1, Context, Keyword, Line,
                                ["I start the configured WebDriver browser"], <<>>
                            ),
                            case maps:is_key(fail, Started) of
                                true -> Started;
                                false ->
                                    delegate(Config1, Started, Keyword, Line,
                                        ["I navigate the WebDriver browser to", Target], <<>>)
                            end;
                        {error, _} ->
                            Context#{fail => <<"Invalid recorder WebDriver configuration">>}
                    end;
                {error, _} ->
                    Context#{fail => <<"Recorded browser URL must be HTTP(S), without embedded credentials">>}
            end
    end;
step(Config, Context, Keyword, Line, ?NAVIGATE(Url), _Body) ->
    delegate(Config, Context, Keyword, Line, ["I navigate the WebDriver browser to", Url], <<>>);
step(Config, Context, Keyword, Line, ?CLICK(Selector), _Body) ->
    delegate(Config, Context, Keyword, Line, ["I click the WebDriver element", Selector], <<>>);
step(Config, Context, Keyword, Line, ?FILL(Selector), Body) ->
    delegate(Config, Context, Keyword, Line, ["I fill the WebDriver element", Selector, "with"], Body);
step(Config, Context, Keyword, Line, ?SECRET(SecretName, Selector), _Body) ->
    delegate(Config, Context, Keyword, Line, ["I enter the WebDriver account secret", SecretName, "into", Selector], <<>>);
step(Config, Context, Keyword, Line, ?SELECT(Selector), Body) ->
    delegate(Config, Context, Keyword, Line, ["I select the WebDriver option in", Selector], Body);
step(Config, Context, Keyword, Line, ?CHECK(Selector), _Body) ->
    delegate(Config, Context, Keyword, Line, ["I set the WebDriver checked state of", Selector, "to", "checked"], <<>>);
step(Config, Context, Keyword, Line, ?UNCHECK(Selector), _Body) ->
    delegate(Config, Context, Keyword, Line, ["I set the WebDriver checked state of", Selector, "to", "unchecked"], <<>>);
step(Config, Context, Keyword, Line, ?PRESS(Selector), _Body) ->
    delegate(Config, Context, Keyword, Line, ["I press the WebDriver key", "Enter", "in", Selector], <<>>);
step(Config, Context, Keyword, Line, ?TEXT(Selector), Body) ->
    delegate(Config, Context, Keyword, Line, ["the WebDriver text in", Selector, "should contain", Body], <<>>);
step(Config, Context, Keyword, Line, ?URL(ExpectedUrl), _Body) ->
    delegate(Config, Context, Keyword, Line, ["the WebDriver URL should start with", ExpectedUrl], <<>>);
step(Config, Context, Keyword, Line, ?CLOSE, _Body) ->
    delegate(Config, Context, Keyword, Line, ["I close the WebDriver browser"], <<>>).

delegate(Config, Context, Keyword, Line, Parts, Body) ->
    %% steps_webdriver also guards direct calls before touching the client.
    steps_webdriver:step(Config, Context, Keyword, Line, Parts, Body).

denied(Context) ->
    Context#{fail => <<"Recorded browser replay requires node_admin">>}.

%% Prefer the node's existing trusted webdriver profile (including managed
%% ChromeDriver/Appium). Translate explicitly configured v0.1 recorder keys
%% only when no modern profile has been configured. Never accept a profile
%% or endpoint from the scenario context.
recorder_config(Config, Target) when is_list(Config) ->
    case proplists:is_defined(webdriver, Config) orelse
        application:get_env(damage, webdriver) =/= undefined of
        true -> {ok, Config};
        false ->
            Endpoint = proplists:get_value(browser_recorder_webdriver_url, Config,
                application:get_env(damage, browser_recorder_webdriver_url, undefined)),
            case Endpoint of
                undefined -> {ok, Config};
                _ ->
                    Browser0 = proplists:get_value(browser_recorder_browser, Config,
                        application:get_env(damage, browser_recorder_browser, "chrome")),
                    case legacy_browser(Browser0) of
                        {ok, Browser} ->
                            {ok, [{webdriver, [
                                {endpoint, Endpoint}, {dashboard_url, Target},
                                {capabilities, [{browserName, Browser}]}
                            ]} | Config]};
                        Error -> Error
                    end
            end
    end;
recorder_config(_, _) ->
    {error, invalid_configuration}.

legacy_browser("chrome") -> {ok, <<"chrome">>};
legacy_browser(<<"chrome">>) -> {ok, <<"chrome">>};
legacy_browser("firefox") -> {ok, <<"firefox">>};
legacy_browser(<<"firefox">>) -> {ok, <<"firefox">>};
legacy_browser(_) -> {error, invalid_browser_name}.
