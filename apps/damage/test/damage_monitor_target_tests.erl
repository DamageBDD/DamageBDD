-module(damage_monitor_target_tests).
-include_lib("eunit/include/eunit.hrl").

canonical_url_test() ->
    ?assertMatch({ok, #{host := <<"node.example.com">>, origin := <<"https://node.example.com">>,
        path := <<"/health">>, port := 443}}, damage_monitor_target:parse_url(<<"https://Node.Example.com:443/health">>)),
    ?assertMatch({ok, #{origin := <<"http://[::1]:8080">>}}, damage_monitor_target:parse_url(<<"http://[::1]:8080/">>)),
    ?assertMatch({ok, #{origin := <<"http://127.0.0.1:8080">>}}, damage_monitor_target:parse_url(<<"http://127.0.0.1:8080/">>)).

unsafe_url_test() ->
    lists:foreach(fun(U) -> ?assertMatch({error, _}, damage_monitor_target:parse_url(U)) end, [
        <<>>, <<"https://2130706433/">>, <<"https://good.example\\@bad.example/">>,
        <<"https://node.example.com/%0d%0aHeader">>, <<"https://node.example.com/%22">>,
        <<"https://node.example.com/%7b%7bsecret%7d%7d">>, <<"https://node.example.com:0/">>,
        <<"https://node.example.com:65536/">>, <<"https://node.example.com/?token=secret">>,
        <<"https://node.example.com/#fragment">>, <<"ftp://node.example.com/">>
    ]).

address_policy_test() ->
    ?assert(damage_monitor_target:address_allowed({8,8,8,8}, false)),
    ?assert(damage_monitor_target:address_allowed({16#2606,16#4700,16#4700,0,0,0,0,16#1111}, false)),
    lists:foreach(fun(IP) ->
        ?assertNot(damage_monitor_target:address_allowed(IP, false)),
        ?assert(damage_monitor_target:address_allowed(IP, true))
    end, [{127,0,0,1}, {10,0,0,1}, {172,16,0,1}, {192,168,1,1}, {0,0,0,0,0,0,0,1},
        {16#fd01,0,0,0,0,0,0,1}]),
    lists:foreach(fun(IP) ->
        ?assertNot(damage_monitor_target:address_allowed(IP, false)),
        ?assertNot(damage_monitor_target:address_allowed(IP, true))
    end, [{0,0,0,0}, {169,254,169,254}, {100,100,100,200}, {168,63,129,16},
        {192,0,2,1}, {198,18,0,1}, {224,0,0,1}, {255,255,255,255},
        {16#fe80,0,0,0,0,0,0,1}, {0,0,0,0,0,16#ffff,16#7f00,1},
        {16#2001,16#db8,0,0,0,0,0,1}, {16#2002,0,0,0,0,0,0,1},
        {16#fd00,16#ec2,0,0,0,0,0,16#254}]).

owner_scoped_grant_test() ->
    Old = application:get_env(damage, monitor_targets),
    meck:new(damage_domains, [passthrough, no_link]),
    meck:expect(damage_domains, lookup_domain, fun(_, _) -> false end),
    try
        application:set_env(damage, monitor_targets, [{<<"ak_owner">>, <<"https://node.example.com:8443">>}]),
        {ok, T} = damage_monitor_target:parse_url(<<"https://node.example.com:8443/health">>),
        ?assertEqual(ok, damage_monitor_target:authorize(T, <<"ak_owner">>)),
        ?assertEqual({error, monitor_target_not_authorized}, damage_monitor_target:authorize(T, <<"ak_other">>)),
        {ok, OtherPort} = damage_monitor_target:parse_url(<<"https://node.example.com/health">>),
        ?assertEqual({error, monitor_target_not_authorized}, damage_monitor_target:authorize(OtherPort, <<"ak_owner">>))
    after
        meck:unload(damage_domains), restore(monitor_targets, Old)
    end.

private_pin_test() ->
    Old = application:get_env(damage, monitor_private_targets),
    try
        application:set_env(damage, monitor_private_targets, [{<<"ak_owner">>, <<"http://127.0.0.1:8080">>}]),
        {ok, T} = damage_monitor_target:parse_url(<<"http://127.0.0.1:8080/health">>),
        ?assertMatch({ok, #{ip := {127,0,0,1}}}, damage_monitor_target:pin(T, <<"ak_owner">>)),
        ?assertEqual({error, monitor_destination_blocked}, damage_monitor_target:pin(T, <<"ak_other">>))
    after restore(monitor_private_targets, Old) end.

restore(K, undefined) -> application:unset_env(damage, K);
restore(K, {ok, V}) -> application:set_env(damage, K, V).
