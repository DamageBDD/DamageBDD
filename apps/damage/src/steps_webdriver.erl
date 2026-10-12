%% Executable DamageBDD steps for Selenium/Appium mobile-web dashboard verification.
%% These steps can use operator credentials and a privileged browser automation service.
%% Public feature authors must not be able to borrow that browser or its credentials.
-module(steps_webdriver).
-damage_roles([node_admin]).
-export([step/6, step_dry/6, cleanup/1, cleanup_owner/0]).

step(Config, Context, _Keyword, _Line, ["I use WebDriver profile", Name], _Body) ->
    perform(Config, Context, profile, [Name]);
step(Config, Context, _Keyword, _Line, ["I use the WebDriver sidebar action", Action], _Body) ->
    perform(Config, Context, sidebar_action, [Action]);
step(Config, Context, _Keyword, _Line, ["the dashboard fixture response gate is", Gate], _Body) ->
    perform(Config, Context, fixture_gate, [Gate]);
step(Config, Context, _Keyword, _Line, ["I select the WebDriver dashboard section", Panel], _Body) ->
    perform(Config, Context, select_panel, [Panel]);
step(
    Config,
    Context,
    _Keyword,
    _Line,
    ["exactly one WebDriver dashboard section should be visible"],
    _Body
) ->
    perform(Config, Context, one_panel, []);
step(Config, Context, _Keyword, _Line, ["the WebDriver dashboard layout should be", Layout], _Body) ->
    perform(Config, Context, layout, [Layout]);
step(
    Config,
    Context,
    _Keyword,
    _Line,
    ["I dismiss the WebDriver dashboard drawer using the backdrop"],
    _Body
) ->
    perform(Config, Context, backdrop, []);
step(Config, Context, _Keyword, _Line, ["the dashboard fixture should be idle"], _Body) ->
    perform(Config, Context, fixture_idle, []);
step(
    Config,
    Context,
    _Keyword,
    _Line,
    ["the WebDriver value of", Css, "should contain", Value],
    _Body
) ->
    perform(Config, Context, value_contains, [Css, Value]);
step(Config, Context, _Keyword, _Line, ["I start the configured WebDriver browser"], _Body) ->
    perform(Config, Context, start, []);
step(Config, Context, _Keyword, _Line, ["I open the WebDriver dashboard"], _Body) ->
    perform(Config, Context, open, []);
step(Config, Context, _Keyword, _Line, ["I open the authenticated WebDriver dashboard"], _Body) ->
    perform(Config, Context, open_authenticated, []);
step(
    Config,
    Context,
    _Keyword,
    _Line,
    ["I open the WebDriver dashboard at fragment", Fragment],
    _Body
) ->
    perform(Config, Context, open_fragment, [Fragment]);
step(Config, Context, _Keyword, _Line, ["I click the WebDriver element", Css], _Body) ->
    perform(Config, Context, click, [Css]);
step(Config, Context, _Keyword, _Line, ["I fill the WebDriver element", Css, "with", Text], _Body) ->
    perform(Config, Context, fill, [Css, Text]);
step(Config, Context, _Keyword, _Line, ["I fill the WebDriver element", Css, "with"], Body) ->
    perform(Config, Context, fill, [Css, Body]);
step(
    Config,
    Context,
    _Keyword,
    _Line,
    ["I enter the WebDriver credential", Alias, "into", Css],
    _Body
) ->
    perform(Config, Context, credential, [Alias, Css]);
step(
    Config, Context, _Keyword, _Line, ["I remember the WebDriver value of", Css, "as", Name], _Body
) ->
    perform(Config, Context, remember, [Css, Name]);
step(
    Config,
    Context,
    _Keyword,
    _Line,
    ["the WebDriver value of", Css, "should equal remembered", Name],
    _Body
) ->
    perform(Config, Context, unchanged, [Css, Name]);
step(Config, Context, _Keyword, _Line, ["the WebDriver element", Css, "should be", State], _Body) ->
    perform(Config, Context, state, [Css, State]);
step(
    Config, Context, _Keyword, _Line, ["the WebDriver text in", Css, "should contain", Text], _Body
) ->
    perform(Config, Context, text, [Css, Text]);
step(Config, Context, _Keyword, _Line, ["the WebDriver value of", Css, "should be", Value], _Body) ->
    perform(Config, Context, value, [Css, Value]);
step(Config, Context, _Keyword, _Line, ["the WebDriver value of", Css, "should be"], Body) ->
    perform(Config, Context, value, [Css, Body]);
step(
    Config,
    Context,
    _Keyword,
    _Line,
    ["the WebDriver element", Css, "attribute", Attribute, "should be", Value],
    _Body
) ->
    perform(Config, Context, attribute, [Css, Attribute, Value]);
step(
    Config,
    Context,
    _Keyword,
    _Line,
    ["the WebDriver element", Css, "property", Property, "should equal JSON", Json],
    _Body
) ->
    perform(Config, Context, property, [Css, Property, Json]);
step(Config, Context, _Keyword, _Line, ["the WebDriver URL fragment should be", Fragment], _Body) ->
    perform(Config, Context, fragment, [Fragment]);
step(
    Config,
    Context,
    _Keyword,
    _Line,
    ["the WebDriver page should have no horizontal overflow"],
    _Body
) ->
    perform(Config, Context, no_overflow, []);
step(Config, Context, _Keyword, _Line, ["I go back in the WebDriver browser"], _Body) ->
    perform(Config, Context, back, []);
step(Config, Context, _Keyword, _Line, ["I go forward in the WebDriver browser"], _Body) ->
    perform(Config, Context, forward, []);
step(Config, Context, _Keyword, _Line, ["I refresh the WebDriver page"], _Body) ->
    perform(Config, Context, refresh, []);
step(Config, Context, _Keyword, _Line, ["I press the WebDriver key", Name, "in", Css], _Body) ->
    perform(Config, Context, key_element, [Name, Css]);
step(Config, Context, _Keyword, _Line, ["I press the WebDriver key", Name], _Body) ->
    perform(Config, Context, key, [Name]);
step(Config, Context, _Keyword, _Line, ["I respond to the WebDriver alert with", Choice], _Body) ->
    perform(Config, Context, alert, [Choice]);
step(
    Config,
    Context,
    _Keyword,
    _Line,
    ["I set the WebDriver wait to", Milliseconds, "milliseconds"],
    _Body
) ->
    perform(Config, Context, wait_ms, [Milliseconds]);
step(
    Config,
    Context,
    _Keyword,
    _Line,
    ["I resize the WebDriver viewport to", Width, "by", Height],
    _Body
) ->
    perform(Config, Context, viewport, [Width, Height]);
step(Config, Context, _Keyword, _Line, ["the dashboard fixture response mode is", Mode], _Body) ->
    perform(Config, Context, fixture_mode, [Mode]);
step(
    Config,
    Context,
    _Keyword,
    _Line,
    ["the dashboard fixture should have", Count, "requests for", Action],
    _Body
) ->
    perform(Config, Context, fixture_count, [Action, Count]);
step(
    Config,
    Context,
    _Keyword,
    _Line,
    ["the dashboard fixture billing navigation is", Visible],
    _Body
) ->
    perform(Config, Context, fixture_billing, [Visible]);
step(
    Config,
    Context,
    _Keyword,
    _Line,
    ["the dashboard fixture should not execute injected content"],
    _Body
) ->
    perform(Config, Context, fixture_no_injection, []);
step(Config, Context, _Keyword, _Line, ["I close the WebDriver browser"], _Body) ->
    perform(Config, Context, close, []).

%% Dry runs deliberately avoid the browser, credentials, network and assertions.
step_dry(_Config, Context, _Keyword, _Line, ["I use WebDriver profile", _Name], _Body) ->
    Context;
step_dry(_Config, Context, _Keyword, _Line, ["I use the WebDriver sidebar action", _Action], _Body) ->
    Context;
step_dry(
    _Config, Context, _Keyword, _Line, ["the dashboard fixture response gate is", _Gate], _Body
) ->
    Context;
step_dry(
    _Config, Context, _Keyword, _Line, ["I select the WebDriver dashboard section", _Panel], _Body
) ->
    Context;
step_dry(
    _Config,
    Context,
    _Keyword,
    _Line,
    ["exactly one WebDriver dashboard section should be visible"],
    _Body
) ->
    Context;
step_dry(
    _Config, Context, _Keyword, _Line, ["the WebDriver dashboard layout should be", _Layout], _Body
) ->
    Context;
step_dry(
    _Config,
    Context,
    _Keyword,
    _Line,
    ["I dismiss the WebDriver dashboard drawer using the backdrop"],
    _Body
) ->
    Context;
step_dry(_Config, Context, _Keyword, _Line, ["the dashboard fixture should be idle"], _Body) ->
    Context;
step_dry(
    _Config,
    Context,
    _Keyword,
    _Line,
    ["the WebDriver value of", _Css, "should contain", _Value],
    _Body
) ->
    Context;
step_dry(_Config, Context, _Keyword, _Line, ["I start the configured WebDriver browser"], _Body) ->
    Context;
step_dry(_Config, Context, _Keyword, _Line, ["I open the WebDriver dashboard"], _Body) ->
    Context;
step_dry(
    _Config, Context, _Keyword, _Line, ["I open the authenticated WebDriver dashboard"], _Body
) ->
    Context;
step_dry(
    _Config,
    Context,
    _Keyword,
    _Line,
    ["I open the WebDriver dashboard at fragment", _Fragment],
    _Body
) ->
    Context;
step_dry(_Config, Context, _Keyword, _Line, ["I click the WebDriver element", _Css], _Body) ->
    Context;
step_dry(
    _Config, Context, _Keyword, _Line, ["I fill the WebDriver element", _Css, "with", _Text], _Body
) ->
    Context;
step_dry(_Config, Context, _Keyword, _Line, ["I fill the WebDriver element", _Css, "with"], _Body) ->
    Context;
step_dry(
    _Config,
    Context,
    _Keyword,
    _Line,
    ["I enter the WebDriver credential", _Alias, "into", _Css],
    _Body
) ->
    Context;
step_dry(
    _Config,
    Context,
    _Keyword,
    _Line,
    ["I remember the WebDriver value of", _Css, "as", _Name],
    _Body
) ->
    Context;
step_dry(
    _Config,
    Context,
    _Keyword,
    _Line,
    ["the WebDriver value of", _Css, "should equal remembered", _Name],
    _Body
) ->
    Context;
step_dry(
    _Config, Context, _Keyword, _Line, ["the WebDriver element", _Css, "should be", _State], _Body
) ->
    Context;
step_dry(
    _Config,
    Context,
    _Keyword,
    _Line,
    ["the WebDriver text in", _Css, "should contain", _Text],
    _Body
) ->
    Context;
step_dry(
    _Config, Context, _Keyword, _Line, ["the WebDriver value of", _Css, "should be", _Value], _Body
) ->
    Context;
step_dry(_Config, Context, _Keyword, _Line, ["the WebDriver value of", _Css, "should be"], _Body) ->
    Context;
step_dry(
    _Config,
    Context,
    _Keyword,
    _Line,
    ["the WebDriver element", _Css, "attribute", _Attribute, "should be", _Value],
    _Body
) ->
    Context;
step_dry(
    _Config,
    Context,
    _Keyword,
    _Line,
    ["the WebDriver element", _Css, "property", _Property, "should equal JSON", _Json],
    _Body
) ->
    Context;
step_dry(
    _Config, Context, _Keyword, _Line, ["the WebDriver URL fragment should be", _Fragment], _Body
) ->
    Context;
step_dry(
    _Config,
    Context,
    _Keyword,
    _Line,
    ["the WebDriver page should have no horizontal overflow"],
    _Body
) ->
    Context;
step_dry(_Config, Context, _Keyword, _Line, ["I go back in the WebDriver browser"], _Body) ->
    Context;
step_dry(_Config, Context, _Keyword, _Line, ["I go forward in the WebDriver browser"], _Body) ->
    Context;
step_dry(_Config, Context, _Keyword, _Line, ["I refresh the WebDriver page"], _Body) ->
    Context;
step_dry(
    _Config, Context, _Keyword, _Line, ["I press the WebDriver key", _Name, "in", _Css], _Body
) ->
    Context;
step_dry(_Config, Context, _Keyword, _Line, ["I press the WebDriver key", _Name], _Body) ->
    Context;
step_dry(
    _Config, Context, _Keyword, _Line, ["I respond to the WebDriver alert with", _Choice], _Body
) ->
    Context;
step_dry(
    _Config,
    Context,
    _Keyword,
    _Line,
    ["I set the WebDriver wait to", _Milliseconds, "milliseconds"],
    _Body
) ->
    Context;
step_dry(
    _Config,
    Context,
    _Keyword,
    _Line,
    ["I resize the WebDriver viewport to", _Width, "by", _Height],
    _Body
) ->
    Context;
step_dry(
    _Config, Context, _Keyword, _Line, ["the dashboard fixture response mode is", _Mode], _Body
) ->
    Context;
step_dry(
    _Config,
    Context,
    _Keyword,
    _Line,
    ["the dashboard fixture should have", _Count, "requests for", _Action],
    _Body
) ->
    Context;
step_dry(
    _Config,
    Context,
    _Keyword,
    _Line,
    ["the dashboard fixture billing navigation is", _Visible],
    _Body
) ->
    Context;
step_dry(
    _Config,
    Context,
    _Keyword,
    _Line,
    ["the dashboard fixture should not execute injected content"],
    _Body
) ->
    Context;
step_dry(_Config, Context, _Keyword, _Line, ["I close the WebDriver browser"], _Body) ->
    Context.

perform(Config, Context, Op, Args) ->
    %% Keep the runner annotation AND the runtime guard. Local calls must not bypass it.
    case steps_utils:is_admin(Context) of
        false ->
            Context#{fail => <<"WebDriver steps require node_admin">>};
        true ->
            try do_perform(Config, Context, Op, Args) of
                {ok, C} -> C;
                {error, Reason} -> failure(Context, Op, Reason)
            catch
                _:_ -> failure(Context, Op, webdriver_step_failed)
            end
    end.

do_perform(_Config, Context, profile, [Name0]) ->
    Name = unicode:characters_to_binary(Name0),
    case named_profile(Name) of
        {ok, _} -> {ok, Context#{webdriver_profile => Name}};
        Error -> Error
    end;
do_perform(Config, Context, start, []) ->
    case cleanup(Context) of
        ok ->
            Profile =
                case maps:get(webdriver_profile, Context, undefined) of
                    undefined ->
                        proplists:get_value(
                            webdriver,
                            Config,
                            application:get_env(damage, webdriver, [])
                        );
                    Name ->
                        {ok, Named} = named_profile(Name),
                        Named
                end,
            case damage_webdriver:start(Profile) of
                {ok, Pid} ->
                    put({?MODULE, session}, Pid),
                    {ok, Context#{webdriver_session => Pid}};
                Error ->
                    Error
            end;
        Error ->
            Error
    end;
do_perform(_Config, Context, close, []) ->
    case cleanup(Context) of
        ok -> {ok, maps:remove(webdriver_session, Context)};
        Error -> Error
    end;
do_perform(_Config, Context, Op, Args) ->
    case maps:get(webdriver_session, Context, undefined) of
        Pid when is_pid(Pid) ->
            case damage_webdriver:perform(Pid, Op, Args) of
                ok -> {ok, Context};
                Error -> Error
            end;
        _ ->
            {error, webdriver_session_missing}
    end.

named_profile(Name) ->
    Profiles = application:get_env(damage, webdriver_profiles, []),
    case [P || {K, P} <- Profiles, is_atom(K), atom_to_binary(K, utf8) =:= Name] of
        [P] when is_list(P) -> {ok, P};
        _ -> {error, unknown_webdriver_profile}
    end.

cleanup(Context) ->
    Pid = maps:get(webdriver_session, Context, undefined),
    Result = damage_webdriver:close(Pid),
    case {Result, get({?MODULE, session})} of
        {ok, Pid} -> erase({?MODULE, session});
        _ -> ok
    end,
    Result.

%% Exception-safe scope cleanup for the normal Damage runner. No session data
%% or credentials are stored here: just the current process's owned client pid.
cleanup_owner() -> damage_webdriver:close(erase({?MODULE, session})).
failure(Context, Op, Reason) ->
    Cleanup = cleanup(Context),
    %% Error terms have no entered text, request bodies, remote diagnostics or credentials.
    Message = iolist_to_binary(
        io_lib:format(
            "WebDriver ~p failed: ~p (cleanup: ~p)",
            [Op, Reason, Cleanup]
        )
    ),
    (maps:remove(webdriver_session, Context))#{fail => Message}.
