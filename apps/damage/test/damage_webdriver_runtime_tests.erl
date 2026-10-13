-module(damage_webdriver_runtime_tests).
-include_lib("eunit/include/eunit.hrl").

config(P) -> damage_webdriver_runtime_config:parse(chromedriver, P).

disabled_by_default_test() ->
    ?assertMatch({ok, #{enabled := false}}, config([])).
requires_both_enable_flags_test() ->
    ?assertMatch({ok, #{enabled := false}}, config([{enabled, true}])),
    ?assertMatch({ok, #{enabled := false}}, config([{chromedriver, [{enabled, true}]}])),
    ?assertMatch(
        {ok, #{enabled := true}}, config([{enabled, true}, {chromedriver, [{enabled, true}]}])
    ).
reject_map_config_test() -> ?assertMatch({error, _}, config(#{enabled => true})).
reject_nested_map_test() -> ?assertMatch({error, _}, config([{chromedriver, #{enabled => true}}])).
reject_unknown_key_test() -> ?assertMatch({error, _}, config([{shell, "/bin/sh"}])).
reject_duplicate_key_test() ->
    ?assertMatch({error, _}, config([{enabled, true}, {enabled, false}])).
reject_non_boolean_test() -> ?assertMatch({error, _}, config([{bootstrap, "true"}])).
reject_privileged_port_test() -> ?assertMatch({error, _}, config([{chromedriver, [{port, 80}]}])).
reject_duplicate_ports_test() ->
    ?assertMatch(
        {error, _},
        config([
            {chromedriver, [{enabled, true}, {port, 9515}]},
            {appium, [{enabled, true}, {port, 9515}]}
        ])
    ).
reject_public_bind_override_test() ->
    ?assertMatch({error, _}, config([{chromedriver, [{host, "0.0.0.0"}]}])).
reject_base_path_query_test() ->
    ?assertMatch({error, _}, config([{chromedriver, [{base_path, "/wd?x=1"}]}])).
reject_unbounded_restart_policy_test() ->
    ?assertMatch({error, _}, config([{max_failures, 0}])),
    ?assertMatch({error, _}, config([{restart_delay_ms, 5000}, {max_restart_delay_ms, 1000}])).
reject_arbitrary_version_argument_test() ->
    ?assertMatch({error, _}, config([{chromedriver, [{version, "stable; touch /tmp/bad"}]}])).
accept_pinned_version_and_offline_test() ->
    ?assertMatch(
        {ok, #{request := #{version := <<"140.0.1.2">>, offline := true}}},
        config([{offline, true}, {chromedriver, [{version, "140.0.1.2"}]}])
    ).
accept_tuple_appium_settings_test() ->
    ?assertMatch(
        {ok, #{request := #{drivers := #{<<"uiautomator2">> := <<"latest">>}}}},
        damage_webdriver_runtime_config:parse(appium, [
            {appium, [
                {node, [{source, download}, {version, lts}]}, {drivers, [{uiautomator2, latest}]}
            ]}
        ])
    ).
json_objects_and_arrays_test() ->
    ?assertEqual(
        #{<<"source">> => <<"download">>, <<"packages">> => [<<"platform-tools">>]},
        damage_webdriver_runtime_config:json([
            {source, download}, {packages, [<<"platform-tools">>]}
        ])
    ).
chrome_command_has_no_shell_or_public_binding_test() ->
    Cmd = damage_webdriver_service:command(
        #{backend => chromedriver, port => 9515, base_path => "/"},
        #{<<"chromedriver">> => <<"/private path/chromedriver">>}
    ),
    ?assertEqual(
        ["/private path/chromedriver", "--port=9515", "--url-base=/", "--log-level=WARNING"], Cmd
    ).
appium_command_restricts_interface_test() ->
    Cmd = appium_command(false),
    ?assert(lists:member("127.0.0.1", Cmd)),
    ?assertNot(lists:member("--relaxed-security", Cmd)),
    ?assertNot(lists:member("--allow-cors", Cmd)),
    ?assertNot(lists:member("--session-override", Cmd)),
    ?assertNot(lists:member("--allow-insecure", Cmd)).
appium_download_feature_is_scoped_test() ->
    Cmd = appium_command(true),
    ?assertEqual(
        ["--allow-insecure", "uiautomator2:chromedriver_autodownload"],
        lists:nthtail(length(Cmd) - 2, Cmd)
    ).
appium_command(Flag) ->
    damage_webdriver_service:command(
        #{backend => appium, port => 4723, base_path => "/wd/hub"},
        #{
            <<"argv">> => [<<"/private/node">>, <<"/private/appium/index.js">>],
            <<"chromedriver_autodownload">> => Flag
        }
    ).
health_start_requires_ready_test() ->
    ?assert(
        damage_webdriver_service:probe_json(
            {chromedriver, starting},
            #{<<"value">> => #{<<"ready">> => true}}
        )
    ),
    ?assertNot(
        damage_webdriver_service:probe_json(
            {chromedriver, starting},
            #{<<"value">> => #{<<"ready">> => false}}
        )
    ).
health_busy_is_not_a_crash_test() ->
    ?assert(
        damage_webdriver_service:probe_json(
            {appium, ready},
            #{<<"value">> => #{<<"ready">> => false}}
        )
    ).
health_rejects_malformed_or_wrong_service_test() ->
    ?assertNot(damage_webdriver_service:probe_json({appium, starting}, #{})),
    ?assertNot(
        damage_webdriver_service:probe_json(
            {appium, ready},
            #{<<"value">> => #{<<"ready">> => <<"true">>}}
        )
    ),
    ?assertNot(
        damage_webdriver_service:probe_json(
            {fixture, starting},
            #{<<"value">> => #{<<"ready">> => true}}
        )
    ).
fixture_health_requires_fixture_marker_test() ->
    ?assert(
        damage_webdriver_service:probe_json(
            {fixture, starting},
            #{<<"fixture">> => true, <<"ready">> => true}
        )
    ),
    ?assertNot(damage_webdriver_service:probe_json({fixture, starting}, #{<<"ready">> => true})).
managed_and_external_endpoint_cannot_mix_test() ->
    ?assertMatch(
        {error, _},
        damage_webdriver_runtime:resolve_profile(
            [{managed, chromedriver}, {endpoint, <<"http://127.0.0.1:9515">>}]
        )
    ).
external_profile_is_preserved_test() ->
    P = [
        {endpoint, <<"https://grid.example.invalid/wd/hub">>},
        {dashboard_url, <<"https://staging.example.invalid">>}
    ],
    ?assertEqual({ok, P}, damage_webdriver_runtime:resolve_profile(P)).
invalid_runtime_timeout_test() ->
    ?assertEqual(
        {error, invalid_webdriver_runtime_timeout}, damage_webdriver_runtime:await(appium, 0)
    ).
empty_owner_cleanup_test() -> ?assertEqual(ok, steps_webdriver:cleanup_owner()).

%% Callback-level tests: deterministic admission/state tests, NOT OS process tests.
state() ->
    #{
        backend => appium,
        phase => ready,
        config => #{max_sessions => 1},
        sessions => #{},
        generation => make_ref(),
        manifest => #{},
        pid => undefined,
        os_pid => undefined,
        timer => undefined,
        failures => 0,
        health_errors => 0,
        last_error => undefined
    }.
claim_requires_current_generation_test() ->
    S = state(),
    ?assertMatch(
        {reply, {error, webdriver_backend_changed}, _},
        damage_webdriver_service:handle_call({claim, {self(), make_ref()}}, {self(), make_ref()}, S)
    ).
claim_requires_current_service_test() ->
    S = state(),
    ?assertMatch(
        {reply, {error, webdriver_backend_changed}, _},
        damage_webdriver_service:handle_call(
            {claim, {undefined, maps:get(generation, S)}}, {self(), make_ref()}, S
        )
    ).
capacity_and_explicit_release_test() ->
    S = state(),
    G = maps:get(generation, S),
    From = {self(), make_ref()},
    {reply, {ok, _}, S1} = damage_webdriver_service:handle_call({claim, {self(), G}}, From, S),
    ?assertMatch(
        {reply, {error, webdriver_capacity_exhausted}, _},
        damage_webdriver_service:handle_call({claim, {self(), G}}, From, S1)
    ),
    ?assertMatch(
        {reply, {error, webdriver_sessions_active}, _},
        damage_webdriver_service:handle_call(restart, From, S1)
    ),
    {reply, ok, S2} = damage_webdriver_service:handle_call({release, G}, From, S1),
    ?assertEqual(0, map_size(maps:get(sessions, S2))).
owner_down_releases_admission_test() ->
    Ref = make_ref(),
    S = (state())#{sessions => #{Ref => self()}},
    {noreply, S1} = damage_webdriver_service:handle_info({'DOWN', Ref, process, self(), normal}, S),
    ?assertEqual(0, map_size(maps:get(sessions, S1))).
old_exit_notification_does_not_kill_new_generation_test() ->
    S = (state())#{pid => self(), os_pid => 200},
    ?assertEqual(
        {noreply, S},
        damage_webdriver_service:handle_info({'DOWN', 100, process, self(), normal}, S)
    ).
old_invalidation_is_ignored_test() ->
    S = state(),
    ?assertEqual(
        {noreply, S}, damage_webdriver_service:handle_cast({invalidate, self(), make_ref()}, S)
    ).
