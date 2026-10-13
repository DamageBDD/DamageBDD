-module(ecai_mm_dashboard_http_tests).
-include_lib("eunit/include/eunit.hrl").

method_policy_test() ->
    ?assert(ecai_mm_dashboard_http:method_allowed(config, <<"GET">>)),
    ?assert(ecai_mm_dashboard_http:method_allowed(config, <<"POST">>)),
    ?assertNot(ecai_mm_dashboard_http:method_allowed(audit, <<"POST">>)),
    ?assertNot(ecai_mm_dashboard_http:method_allowed(control, <<"GET">>)).

node_admin_only_test() ->
    A = <<"ak_admin">>,
    B = #{
        authenticated => true,
        auth_mode => custodial,
        node_admin => true,
        public_key => A
    },
    ?assert(ecai_mm_dashboard_http:authorization_policy(B, true, [A], [])),
    ?assertNot(ecai_mm_dashboard_http:authorization_policy(B, false, [A], [])),
    ?assertNot(ecai_mm_dashboard_http:authorization_policy(B, true, [], [])),
    ?assertNot(ecai_mm_dashboard_http:authorization_policy(B, true, [A], [<<"ak_other">>])),
    ?assertNot(ecai_mm_dashboard_http:authorization_policy(B#{auth_mode => wallet}, true, [A], [])),
    ?assertNot(ecai_mm_dashboard_http:authorization_policy(B#{node_admin => false}, true, [A], [])).

control_whitelist_test() ->
    ?assertEqual(
        {ok, pause},
        ecai_mm_dashboard_http:validate_control(#{<<"action">> => <<"pause">>})
    ),
    ?assertEqual(
        {ok, poll},
        ecai_mm_dashboard_http:validate_control(#{<<"action">> => <<"poll">>})
    ),
    ?assertMatch(
        {error, _},
        ecai_mm_dashboard_http:validate_control(
            #{<<"action">> => <<"live">>}
        )
    ),
    ?assertMatch(
        {error, _},
        ecai_mm_dashboard_http:validate_control(
            #{<<"action">> => <<"resume">>, <<"mode">> => <<"live">>}
        )
    ).

history_bounded_test() ->
    ?assertEqual(500, ecai_mm_dashboard_http:history_limit([])),
    ?assertEqual(2000, ecai_mm_dashboard_http:history_limit([{<<"limit">>, <<"9999">>}])),
    ?assertEqual(500, ecai_mm_dashboard_http:history_limit([{<<"limit">>, <<"whoops">>}])).
