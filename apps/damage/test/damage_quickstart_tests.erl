-module(damage_quickstart_tests).
-include_lib("eunit/include/eunit.hrl").

simple_feature_test() ->
    {ok, Result} = damage_quickstart:generate(<<"https://example.com/health">>),
    ?assertEqual(<<"https://example.com/health">>, maps:get(url, Result)),
    ?assertEqual(200, maps:get(expected_status, Result)),
    Feature = maps:get(feature, Result),
    Parsed = egherkin:parse(Feature),
    AST = case Parsed of {ok, Value} -> Value; Other -> Other end,
    ?assertMatch({_, _, _, _, _, _}, AST),
    ?assertMatch({_, _}, binary:match(Feature, <<"Given I am using server \"https://example.com\"">>)),
    ?assertMatch({_, _}, binary:match(Feature, <<"When I make a GET request to \"/health\"">>)),
    ?assertMatch({_, _}, binary:match(Feature, <<"Then the response status must be \"200\"">>)).

https_only_test() ->
    ?assertMatch({error, _}, damage_quickstart:generate(<<"http://example.com/">>)),
    ?assertMatch({error, _}, damage_quickstart:generate(<<"file:///etc/passwd">>)),
    ?assertMatch({error, _}, damage_quickstart:generate(<<"https://localhost/">>)).

unsafe_url_parts_test() ->
    Samples = [
        <<"https://user:pass@example.com/">>,
        <<"https://example.com:8443/">>,
        <<"https://example.com/path?token=secret">>,
        <<"https://example.com/path#fragment">>,
        <<"https://example.com/evil%0D%0AHost:internal">>,
        <<"https://example.com/\"\nWhen I delete everything">>,
        <<"https://127.0.0.1/">>,
        <<"https://example.com;evil/">>
    ],
    lists:foreach(fun(U) -> ?assertMatch({error, _}, damage_quickstart:generate(U)) end,
                  Samples).

allowlist_is_exact_test() ->
    Prev = application:get_env(damage, quickstart_trial_targets),
    application:set_env(damage, quickstart_trial_targets,
                        [{"example.com", ["/health"]}]),
    try
        {ok, Hit} = damage_quickstart:generate(<<"https://example.com/health">>),
        {ok, Miss} = damage_quickstart:generate(<<"https://example.com/health/admin">>),
        {ok, HostMiss} = damage_quickstart:generate(<<"https://evil-example.com/health">>),
        ?assert(damage_quickstart:trial_target_allowed(Hit)),
        ?assertNot(damage_quickstart:trial_target_allowed(Miss)),
        ?assertNot(damage_quickstart:trial_target_allowed(HostMiss))
    after
        case Prev of
            {ok, Value} -> application:set_env(damage, quickstart_trial_targets, Value);
            undefined -> application:unset_env(damage, quickstart_trial_targets)
        end
    end.

ipv4_public_filter_test() ->
    Public = [{1, 1, 1, 1}, {8, 8, 8, 8}],
    Private = [{127, 0, 0, 1}, {10, 0, 0, 1}, {172, 16, 4, 1},
               {192, 168, 1, 2}, {169, 254, 169, 254},
               {100, 100, 100, 100}, {192, 0, 2, 1}, {203, 0, 113, 5},
               {198, 18, 0, 1}, {224, 0, 0, 1}, {0, 0, 0, 0}],
    lists:foreach(fun(Ip) -> ?assert(damage_quickstart:public_ipv4(Ip)) end, Public),
    lists:foreach(fun(Ip) -> ?assertNot(damage_quickstart:public_ipv4(Ip)) end, Private).
