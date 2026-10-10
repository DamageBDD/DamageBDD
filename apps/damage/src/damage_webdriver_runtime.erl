%% Operator API and profile integration. No endpoint or process configuration is
%% taken from a feature body. node_admin remains enforced by steps_webdriver.
-module(damage_webdriver_runtime).
-export([status/0, status/1, await/2, restart/1, stop/1, resolve_profile/1, claim/2]).
status() -> maps:from_list([{B, status(B)} || B <- [chromedriver, appium, fixture]]).
status(B) -> call(B, status).
restart(B) -> call(B, restart).
stop(B) -> call(B, stop).
claim(B, Ticket) -> call(B, {claim, Ticket}).
call(B, Request) ->
    try gen_server:call(damage_webdriver_runtime_config:name(B), Request, 20000)
    catch _:_ -> {error, webdriver_runtime_unavailable} end.

await(B, Milliseconds) when is_integer(Milliseconds), Milliseconds > 0, Milliseconds =< 3600000 ->
    wait(B, erlang:monotonic_time(millisecond) + Milliseconds);
await(_, _) -> {error, invalid_webdriver_runtime_timeout}.
wait(B, Deadline) ->
    case call(B, connection) of
        {ok, _} = Ready -> Ready;
        {error, starting} ->
            case Deadline - erlang:monotonic_time(millisecond) of
                N when N > 0 -> timer:sleep(erlang:min(200, N)), wait(B, Deadline);
                _ -> {error, webdriver_runtime_ready_timeout}
            end;
        Other -> Other
    end.

resolve_profile(P) when is_list(P) ->
    try resolve(P) catch throw:{runtime, Why} -> {error, Why};
        _:_ -> {error, invalid_managed_webdriver_profile} end;
resolve_profile(_) -> {error, invalid_webdriver_profile}.
resolve(P0) ->
    Wait = proplists:get_value(managed_wait_ms, P0, 960000),
    P = case proplists:get_value(managed_fixture, P0, false) of
        false -> P0;
        true ->
            true = proplists:get_value(fixture, P0, false),
            case await(fixture, Wait) of
                {ok, #{endpoint := URL}} ->
                    case proplists:is_defined(dashboard_url, P0) of
                        true -> P0;
                        false -> put(dashboard_url, URL, P0)
                    end;
                {error, Why} -> throw({runtime, Why})
            end
    end,
    case proplists:get_value(managed, P) of
        undefined -> {ok, P};
        B when B =:= chromedriver; B =:= appium ->
            false = proplists:is_defined(endpoint, P),
            case await(B, Wait) of
                {ok, #{endpoint := URL0, pid := Service, generation := Generation, manifest := Manifest}} ->
                    Caps = proplists:get_value(capabilities, P, []),
                    Caps1 = managed_caps(B, Caps, Manifest),
                    {ok, put(managed_service, {B, Service, Generation},
                        put(endpoint, URL0, put(capabilities, Caps1, P)))};
                Error -> Error
            end
    end.
managed_caps(chromedriver, Caps, Manifest) ->
    Browser = proplists:get_value(browserName, Caps),
    true = Browser =:= <<"chrome">> orelse Browser =:= <<"Chrome">>,
    Chrome = proplists:get_value('goog:chromeOptions', Caps, []),
    Binary = maps:get(<<"chrome">>, Manifest),
    %% Always pair the driver with the exact installed browser, not host Chrome.
    put('goog:chromeOptions', put(binary, Binary, Chrome), Caps);
managed_caps(appium, Caps, Manifest) ->
    true = proplists:is_defined('appium:automationName', Caps),
    case proplists:get_value('appium:automationName', Caps) of
        <<"UiAutomator2">> ->
            C1 = case maps:get(<<"chromedriver_dir">>, Manifest, undefined) of
                undefined -> Caps;
                Dir -> put('appium:chromedriverExecutableDir', Dir, Caps)
            end,
            case maps:get(<<"android_chromedriver">>, Manifest, <<>>) of
                <<>> -> C1;
                Executable -> put('appium:chromedriverExecutable', Executable, C1)
            end;
        _ -> Caps
    end.
put(K, V, P) -> [{K,V}|proplists:delete(K, P)].
