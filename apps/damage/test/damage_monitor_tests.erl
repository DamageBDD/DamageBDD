-module(damage_monitor_tests).
-include_lib("eunit/include/eunit.hrl").

target() -> #{scheme => <<"https">>, path => <<"/">>}.
response(Status, Body) -> {ok, #{status => Status, headers => [], body => Body, elapsed_ms => 20}}.
fetch(R) -> fun(_T, _Method, _Path, _Headers) -> R end.
check(P, R, O) -> damage_monitor:check(P, target(), O, fetch(R)).

uptime_and_content_test() ->
    {ok, O} = damage_monitor:options(<<"http-uptime">>, #{}),
    ?assertMatch(#{outcome := pass}, check(<<"http-uptime">>, response(200, <<>>), O)),
    ?assertMatch(#{outcome := fail}, check(<<"http-uptime">>, response(500, <<>>), O)),
    ?assertMatch(#{outcome := inconclusive}, check(<<"http-uptime">>, {error, timeout}, O)),
    {ok, Slow} = response(200, <<>>),
    ?assertMatch(#{outcome := fail}, check(<<"http-uptime">>, {ok, Slow#{elapsed_ms => 4000}}, O)),
    {ok, C} = damage_monitor:options(<<"content-canary">>, #{<<"contains">> => <<"Healthy">>}),
    ?assertMatch(#{outcome := pass}, check(<<"content-canary">>, response(200, <<"Healthy">>), C)),
    ?assertMatch(#{outcome := fail}, check(<<"content-canary">>, response(200, <<"Wrong page">>), C)).

exposure_is_fail_closed_test() ->
    lists:foreach(fun(Status) ->
        ?assertMatch(#{outcome := pass}, check(<<"node-exposure">>, response(Status, <<>>), #{}))
    end, [401,403,404,410]),
    lists:foreach(fun(Status) ->
        ?assertMatch(#{outcome := inconclusive}, check(<<"node-exposure">>, response(Status, <<"SPA homepage">>), #{}))
    end, [200,204,301,302,405,429,500,503]),
    ?assertMatch(#{outcome := inconclusive}, check(<<"node-exposure">>, {error, timeout}, #{})),
    ?assertMatch(#{outcome := inconclusive}, check(<<"docker-exposure">>, {error, econnrefused}, #{})),
    ?assertMatch(#{outcome := fail}, check(<<"docker-exposure">>, response(200, <<"{\"ApiVersion\":\"1.47\",\"Version\":\"27\"}">>), #{})).

baseline_probes_and_redaction_test() ->
    erase(probes),
    Secret = <<"SECRET_SENTINEL_MUST_NOT_BE_IN_REPORT">>,
    Fetch = fun(_T, Method, Path, _Headers) ->
        put(probes, [{Method, Path} | case get(probes) of undefined -> []; V -> V end]),
        case Path of
            <<"/.git/HEAD">> -> response(200, <<"ref: refs/heads/main\n">>);
            <<"/.env">> -> ?assertEqual(head, Method), response(200, Secret);
            <<"/api/v0/version">> -> ?assertEqual(post, Method), response(200, <<"{\"Version\":\"0.30\",\"Repo\":\"16\"}">>);
            <<"/debug/pprof/">> -> response(404, Secret)
        end
    end,
    Result = damage_monitor:check(<<"node-exposure">>, target(), #{}, Fetch),
    ?assertEqual(fail, maps:get(outcome, Result)),
    ?assertEqual(4, length(get(probes))),
    ?assertEqual(nomatch, binary:match(jsx:encode(Result), Secret)),
    ?assertEqual(nomatch, binary:match(jsx:encode(Result), <<"ref: refs/heads">>)),
    erase(probes).

nostr_and_auth_test() ->
    ?assertMatch(#{outcome := pass}, check(<<"nostr-relay">>, response(200, <<"{\"supported_nips\":[1,11]}">>), #{})),
    ?assertMatch(#{outcome := fail}, check(<<"nostr-relay">>, response(200, <<"<html>oops</html>">>), #{})),
    ?assertMatch(#{outcome := pass}, check(<<"auth-boundary">>, response(401, <<>>), #{})),
    ?assertMatch(#{outcome := fail}, check(<<"auth-boundary">>, response(302, <<>>), #{})).

headers_test() ->
    {ok, R} = response(200, <<>>),
    Headers = [{<<"Strict-Transport-Security">>, <<"max-age=31536000">>},
        {<<"x-content-type-options">>, <<"nosniff">>},
        {<<"content-security-policy">>, <<"default-src 'self'; frame-ancestors 'none'">>}],
    ?assertMatch(#{outcome := pass}, check(<<"security-headers">>, {ok, R#{headers => Headers}}, #{})),
    ?assertMatch(#{outcome := fail}, check(<<"security-headers">>, {ok, R}, #{})).

ipfs_range_test() ->
    {ok, O} = damage_monitor:options(<<"ipfs-content">>, #{}),
    {ok, R} = response(206, <<"data">>),
    ?assertMatch(#{outcome := pass}, check(<<"ipfs-content">>, {ok, R#{headers => [{<<"content-range">>, <<"bytes 0-3/4">>}]}}, O)),
    ?assertMatch(#{outcome := fail}, check(<<"ipfs-content">>, {ok, R}, O)).

invalid_options_test() ->
    ?assertMatch({error, _}, damage_monitor:options(<<"shell">>, #{})),
    ?assertMatch({error, _}, damage_monitor:options(<<"node-exposure">>, #{<<"command">> => <<"id">>})),
    ?assertEqual(4, damage_monitor:request_count(<<"node-exposure">>)),
    ?assertMatch({error, _}, damage_monitor:certificate_expiry(<<"not a certificate">>)).

transport_is_pinned_bounded_and_anonymous_test() ->
    Old = application:get_env(damage, monitor_private_targets),
    meck:new(damage_gun, [no_link]),
    meck:expect(damage_gun, request, fun(Method, Host, Port, _Path, Headers, Body, Opts) ->
        ?assert(lists:member(Method, [get, head, post])),
        ?assertEqual("127.0.0.1", Host),
        ?assertEqual(8080, Port),
        ?assertEqual(<<>>, Body),
        ?assertEqual(false, lists:keymember(<<"authorization">>, 1, Headers)),
        ?assertEqual(false, lists:keymember(<<"cookie">>, 1, Headers)),
        ?assertEqual({<<"host">>, <<"127.0.0.1:8080">>}, lists:keyfind(<<"host">>, 1, Headers)),
        ?assertEqual(direct, maps:get(proxy, Opts)),
        ?assertEqual(65536, maps:get(max_response_bytes, Opts)),
        ?assertEqual(0, maps:get(retry, Opts)),
        response(404, <<>>)
    end),
    try
        application:set_env(damage, monitor_private_targets, [{<<"ak_owner">>, <<"http://127.0.0.1:8080">>}]),
        ?assertMatch(#{outcome := pass}, damage_monitor:run(<<"node-exposure">>,
            <<"http://127.0.0.1:8080/">>, <<"ak_owner">>, #{})),
        ?assert(meck:validate(damage_gun))
    after
        meck:unload(damage_gun),
        case Old of undefined -> application:unset_env(damage, monitor_private_targets);
            {ok, V} -> application:set_env(damage, monitor_private_targets, V) end
    end.

dry_steps_are_specific_and_cost_probe_count_test() ->
    U = steps_monitor:step_dry([], #{}, <<"Given">>, 1,
        ["I monitor the authorized URL", "https://node.example.com/"], <<>>),
    One = maps:get(step_spend, U),
    B = steps_monitor:step_dry([], #{}, <<"When">>, 2,
        ["I run the", "node-exposure", "monitor with options"], <<"{}">>),
    ?assertEqual(4 * One, maps:get(step_spend, B)),
    ?assertNot(maps:is_key(monitor_result, B)),
    ?assertError(function_clause, steps_monitor:step_dry([], #{}, <<"When">>, 1,
        ["an unknown step"], <<>>)).
