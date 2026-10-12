%% Socket-level fixtures validate real client requests without Selenium or a node.
-module(damage_webdriver_tests).
-include_lib("eunit/include/eunit.hrl").

profile(Endpoint) ->
    [
        {endpoint, Endpoint},
        {dashboard_url, <<"http://127.0.0.1:8765">>},
        {fixture, true},
        {wait_ms, 200},
        {command_timeout_ms, 1000},
        {capabilities, [
            {browserName, <<"chrome">>},
            {'goog:chromeOptions', [{args, [<<"--headless=new">>]}]}
        ]}
    ].

nested_capability_objects_test() ->
    {ok, O} = damage_webdriver:options(profile(<<"http://localhost:9515">>)),
    Caps = maps:get(caps, O),
    ?assertMatch(#{<<"goog:chromeOptions">> := #{<<"args">> := [<<"--headless=new">>]}}, Caps),
    ?assertEqual(0, maps:get(<<"implicit">>, maps:get(<<"timeouts">>, Caps))).

appium_namespaces_are_preserved_test() ->
    Caps = damage_webdriver:capabilities([
        {platformName, <<"Android">>},
        {browserName, <<"Chrome">>},
        {'appium:automationName', <<"UiAutomator2">>},
        {'appium:noReset', false}
    ]),
    ?assertEqual(<<"UiAutomator2">>, maps:get(<<"appium:automationName">>, Caps)),
    ?assertEqual(false, maps:get(<<"appium:noReset">>, Caps)).

profile_requires_capabilities_test() ->
    ?assertMatch(
        {error, _},
        damage_webdriver:options([
            {capabilities, []}
            | proplists:delete(capabilities, profile(<<"http://localhost:9515">>))
        ])
    ).

profile_rejects_embedded_credentials_test() ->
    ?assertEqual(
        {error, invalid_webdriver_profile},
        damage_webdriver:options(profile(<<"http://user:password@localhost:9515">>))
    ).

profile_rejects_query_and_fragment_test() ->
    [
        ?assertMatch({error, _}, damage_webdriver:options(profile(URL)))
     || URL <- [
            <<"http://localhost:9515/?token=secret">>, <<"http://localhost:9515/#fragment">>
        ]
    ].

profile_rejects_unbounded_timeouts_test() ->
    ?assertMatch(
        {error, _}, damage_webdriver:options([{wait_ms, 0} | profile(<<"http://localhost">>)])
    ),
    ?assertMatch(
        {error, _}, damage_webdriver:options([{wait_ms, 999999} | profile(<<"http://localhost">>)])
    ).

profile_rejects_map_configuration_test() ->
    ?assertMatch({error, _}, damage_webdriver:options(#{endpoint => <<"http://localhost">>})).

profile_rejects_duplicate_capabilities_test() ->
    ?assertMatch(
        {error, _},
        damage_webdriver:options([
            {capabilities, [{browserName, <<"chrome">>}, {browserName, <<"firefox">>}]}
            | proplists:delete(capabilities, profile(<<"http://localhost">>))
        ])
    ).

profile_rejects_native_app_for_web_suite_test() ->
    ?assertMatch(
        {error, _},
        damage_webdriver:options([
            {capabilities, [
                {browserName, <<"Chrome">>}, {'appium:app', <<"/tmp/application.apk">>}
            ]}
            | proplists:delete(capabilities, profile(<<"http://localhost">>))
        ])
    ).

w3c_session_and_grid_prefix_test() ->
    Parent = self(),
    Handler = fun(Method, Path, Json) ->
        Parent ! {wire_request, Method, Path, Json},
        normal(Method, Path, Json)
    end,
    with_server(Handler, fun(URL) ->
        {ok, Pid} = damage_webdriver:start(profile(URL)),
        receive
            {wire_request, <<"POST">>, <<"/wd/hub/session">>, Payload} ->
                ?assertMatch(
                    #{
                        <<"capabilities">> := #{
                            <<"alwaysMatch">> := _,
                            <<"firstMatch">> := [#{}]
                        }
                    },
                    Payload
                ),
                ?assertNot(maps:is_key(<<"desiredCapabilities">>, Payload))
        after 2000 -> ?assert(false)
        end,
        ?assertEqual(ok, damage_webdriver:close(Pid)),
        receive
            {wire_request, <<"DELETE">>, <<"/wd/hub/session/", _/binary>>, _} -> ok
        after 2000 -> ?assert(false)
        end
    end).

protocol_errors_do_not_expose_remote_messages_test() ->
    with_server(
        fun(Method, Path, Json) ->
            case binary:match(Path, <<"execute/sync">>) of
                nomatch ->
                    normal(Method, Path, Json);
                _ ->
                    {500, #{
                        <<"error">> => <<"unknown error SENTINEL_SECRET">>,
                        <<"message">> => <<"SENTINEL_SECRET">>
                    }}
            end
        end,
        fun(URL) ->
            {ok, Pid} = damage_webdriver:start(profile(URL)),
            Result = damage_webdriver:perform(Pid, no_overflow, []),
            ?assertEqual({error, {webdriver_protocol, 500, <<"remote error">>}}, Result),
            ?assertEqual(nomatch, binary:match(term_to_binary(Result), <<"SENTINEL_SECRET">>)),
            ?assertEqual(ok, damage_webdriver:close(Pid))
        end
    ).

sessions_have_distinct_remote_ids_test() ->
    with_server(fun normal/3, fun(URL) ->
        {ok, A} = damage_webdriver:start(profile(URL)),
        {ok, B} = damage_webdriver:start(profile(URL)),
        ?assertNotEqual(maps:get(session, sys:get_state(A)), maps:get(session, sys:get_state(B))),
        ?assertEqual(ok, damage_webdriver:close(A)),
        ?assertEqual(ok, damage_webdriver:close(B))
    end).

wrong_process_cannot_use_or_close_a_session_test() ->
    with_server(fun normal/3, fun(URL) ->
        {ok, Pid} = damage_webdriver:start(profile(URL)),
        Parent = self(),
        spawn(fun() -> Parent ! {foreign, damage_webdriver:close(Pid)} end),
        receive
            {foreign, Reply} -> ?assertEqual({error, webdriver_wrong_owner}, Reply)
        after 2000 -> ?assert(false)
        end,
        ?assertEqual(ok, damage_webdriver:close(Pid))
    end).

owner_death_deletes_session_test() ->
    Parent = self(),
    with_server(
        fun(Method, Path, Json) ->
            case Method of
                <<"DELETE">> -> Parent ! deleted;
                _ -> ok
            end,
            normal(Method, Path, Json)
        end,
        fun(URL) ->
            Owner = spawn(fun() ->
                {ok, _} = damage_webdriver:start(profile(URL)),
                Parent ! ready,
                receive
                    stop -> ok
                end
            end),
            receive
                ready -> ok
            after 2000 -> ?assert(false)
            end,
            exit(Owner, kill),
            receive
                deleted -> ok
            after 3000 -> ?assert(false)
            end
        end
    ).

idle_session_is_reclaimed_test() ->
    Parent = self(),
    with_server(
        fun(Method, Path, Json) ->
            case Method of
                <<"DELETE">> -> Parent ! idle_deleted;
                _ -> ok
            end,
            normal(Method, Path, Json)
        end,
        fun(URL) ->
            {ok, _} = damage_webdriver:start([{idle_timeout_ms, 1000} | profile(URL)]),
            receive
                idle_deleted -> ok
            after 3000 -> ?assert(false)
            end
        end
    ).

fixture_controls_are_rejected_on_live_profiles_test() ->
    with_server(fun normal/3, fun(URL) ->
        P = [{fixture, false} | proplists:delete(fixture, profile(URL))],
        {ok, Pid} = damage_webdriver:start(P),
        ?assertEqual(
            {error, fixture_operation_forbidden_on_live_node},
            damage_webdriver:perform(Pid, fixture_mode, ["ok"])
        ),
        ?assertEqual(ok, damage_webdriver:close(Pid))
    end).

false_assertion_never_passes_test() ->
    with_server(
        fun(Method, Path, Json) ->
            case binary:match(Path, <<"execute/sync">>) of
                nomatch -> normal(Method, Path, Json);
                _ -> {200, false}
            end
        end,
        fun(URL) ->
            {ok, Pid} = damage_webdriver:start(profile(URL)),
            ?assertMatch({error, _}, damage_webdriver:perform(Pid, no_overflow, [])),
            ?assertEqual(ok, damage_webdriver:close(Pid))
        end
    ).

dry_run_never_starts_a_browser_test() ->
    C = #{public_key => <<"not-authorised">>},
    ?assertEqual(
        C,
        steps_webdriver:step_dry(
            [],
            C,
            <<"Given">>,
            1,
            ["I start the configured WebDriver browser"],
            <<>>
        )
    ),
    ?assertEqual(
        C,
        steps_webdriver:step_dry(
            [],
            C,
            <<"Then">>,
            2,
            ["the WebDriver element", "#missing", "should be", "visible"],
            <<>>
        )
    ).

runtime_admin_guard_test() ->
    ?assertMatch(
        #{fail := _},
        steps_webdriver:step(
            [],
            #{},
            <<"Given">>,
            1,
            ["I start the configured WebDriver browser"],
            <<>>
        )
    ).

step_failure_closes_browser_test() ->
    Parent = self(),
    Old = application:get_env(damage, node_admins),
    application:set_env(damage, node_admins, [<<"unit-test">>]),
    try
        with_server(
            fun(Method, Path, Json) ->
                case Method of
                    <<"DELETE">> -> Parent ! failed_step_deleted;
                    _ -> ok
                end,
                case binary:match(Path, <<"execute/sync">>) of
                    nomatch -> normal(Method, Path, Json);
                    _ -> {200, false}
                end
            end,
            fun(URL) ->
                C = steps_webdriver:step(
                    [{webdriver, profile(URL)}],
                    #{public_key => <<"unit-test">>},
                    <<"Given">>,
                    1,
                    ["I start the configured WebDriver browser"],
                    <<>>
                ),
                ?assert(maps:is_key(webdriver_session, C)),
                Failed = steps_webdriver:step(
                    [],
                    C,
                    <<"Then">>,
                    2,
                    ["the WebDriver page should have no horizontal overflow"],
                    <<>>
                ),
                ?assert(maps:is_key(fail, Failed)),
                ?assertNot(maps:is_key(webdriver_session, Failed)),
                receive
                    failed_step_deleted -> ok
                after 2000 -> ?assert(false)
                end
            end
        )
    after
        case Old of
            {ok, V} -> application:set_env(damage, node_admins, V);
            _ -> application:unset_env(damage, node_admins)
        end
    end.

feature_files_match_real_step_signatures_test() ->
    %% Needs egherkin plus the composer catalog/validator from the sidebar baseline.
    {ok, {steps_webdriver, [{abstract_code, {raw_abstract_v1, Forms}}]}} =
        beam_lib:chunks(code:which(steps_webdriver), [abstract_code]),
    Entries = damage_bdd_catalog:from_forms(<<"steps_webdriver">>, <<"test">>, Forms),
    Catalog = #{revision => <<"test">>, steps => Entries},
    Source = proplists:get_value(source, ?MODULE:module_info(compile)),
    Dir = filename:join(filename:dirname(Source), "damage_dashboard_webdriver_SUITE_data"),
    Files = filelib:wildcard(filename:join(Dir, "*.feature")),
    ?assert(Files =/= []),
    lists:foreach(
        fun(F) ->
            {ok, Text} = file:read_file(F),
            Result = damage_bdd_validator:validate(Text, Catalog),
            ?assertEqual({F, true, []}, {F, maps:get(valid, Result), maps:get(diagnostics, Result)})
        end,
        Files
    ).

%% Minimal local HTTP test server: a single response then Connection: close.
%% No protocol client behaviour is mocked; damage_webdriver sends actual HTTP.
with_server(Handler, Test) ->
    {ok, L} = gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true}, {ip, {127, 0, 0, 1}}]),
    {ok, {_, Port}} = inet:sockname(L),
    Pid = spawn_link(fun() -> accept_loop(L, Handler) end),
    URL = iolist_to_binary(["http://127.0.0.1:", integer_to_list(Port), "/wd/hub"]),
    try
        Test(URL)
    after
        gen_tcp:close(L),
        unlink(Pid),
        exit(Pid, shutdown)
    end.
accept_loop(L, Handler) ->
    case gen_tcp:accept(L) of
        {ok, S} ->
            try
                serve(S, Handler)
            after
                gen_tcp:close(S)
            end,
            accept_loop(L, Handler);
        {error, closed} ->
            ok
    end.
serve(S, Handler) ->
    {Head, Rest} = read_header(S, <<>>),
    [First | _] = binary:split(Head, <<"\r\n">>, [global]),
    [Method, Path, _Version] = binary:split(First, <<" ">>, [global]),
    Len =
        case re:run(Head, <<"(?i)content-length:\\s*([0-9]+)">>, [{capture, [1], binary}]) of
            {match, [B]} -> binary_to_integer(B);
            nomatch -> 0
        end,
    Body = read_body(S, Rest, Len),
    Json =
        case Body of
            <<>> -> #{};
            _ -> jsx:decode(Body, [return_maps])
        end,
    {Code, Value} = Handler(Method, Path, Json),
    Raw = jsx:encode(#{<<"value">> => Value}),
    ok = gen_tcp:send(S, [
        "HTTP/1.1 ",
        integer_to_list(Code),
        " Test\r\n",
        "Content-Type: application/json\r\nConnection: close\r\nContent-Length: ",
        integer_to_list(byte_size(Raw)),
        "\r\n\r\n",
        Raw
    ]).
read_header(S, B) ->
    case binary:split(B, <<"\r\n\r\n">>) of
        [Head, Rest] ->
            {Head, Rest};
        [_] when byte_size(B) < 65536 ->
            {ok, More} = gen_tcp:recv(S, 0, 2000),
            read_header(S, <<B/binary, More/binary>>)
    end.
read_body(_S, B, Len) when byte_size(B) >= Len -> binary:part(B, 0, Len);
read_body(S, B, Len) ->
    {ok, More} = gen_tcp:recv(S, Len - byte_size(B), 2000),
    <<B/binary, More/binary>>.
normal(<<"POST">>, <<"/wd/hub/session">>, _Json) ->
    Id = integer_to_binary(erlang:unique_integer([positive, monotonic])),
    {200, #{<<"sessionId">> => Id, <<"capabilities">> => #{}}};
normal(_Method, _Path, _Json) ->
    {200, null}.
