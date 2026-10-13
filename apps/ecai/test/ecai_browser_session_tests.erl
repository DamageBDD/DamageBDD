-module(ecai_browser_session_tests).
-include_lib("eunit/include/eunit.hrl").

admin_session_policy_test() ->
    with_config(fun() ->
        Base = #{authenticated => true, node_admin => true, public_key => <<"ak_admin">>},
        ?assert(ecai_node_admin:session_is_node_admin(Base#{auth_mode => custodial})),
        ?assert(ecai_node_admin:session_is_node_admin(Base)),
        ?assertNot(ecai_node_admin:session_is_node_admin(Base#{auth_mode => wallet})),
        ?assertNot(ecai_node_admin:session_is_node_admin(Base#{node_admin => false})),
        ?assertNot(ecai_node_admin:session_is_node_admin(Base#{authenticated => false})),
        ?assertNot(ecai_node_admin:session_is_node_admin(Base#{public_key => <<"ak_other">>})),
        ?assertNot(ecai_node_admin:session_is_node_admin(#{public_key => <<"ak_admin">>}))
    end).

wallet_metadata_cannot_elevate_configured_admin_test() ->
    with_config(fun() ->
        Auth = #{
            authenticated => true,
            auth_mode => wallet,
            node_admin => true,
            public_key => <<"ak_admin">>,
            access_token => <<"secret">>,
            private_key => <<"secret-key">>
        },
        M = ecai_auth_http:session_metadata(Auth),
        ?assertEqual(true, maps:get(authenticated, M)),
        ?assertEqual(wallet, maps:get(auth_mode, M)),
        ?assertEqual(false, maps:get(node_admin, M)),
        ?assertEqual(false, maps:get(code_admin, M)),
        ?assertNot(maps:is_key(access_token, M)),
        ?assertNot(maps:is_key(private_key, M))
    end).

managed_metadata_preserves_scoped_admin_test() ->
    with_config(fun() ->
        Auth = #{
            authenticated => true,
            auth_mode => custodial,
            node_admin => true,
            public_key => <<"ak_admin">>
        },
        M = ecai_auth_http:session_metadata(Auth),
        ?assertEqual(true, maps:get(node_admin, M)),
        ?assertEqual(true, maps:get(code_admin, M)),
        application:set_env(ecai, code_admin_accounts, [<<"ak_other">>]),
        ?assertEqual(false, maps:get(code_admin, ecai_auth_http:session_metadata(Auth)))
    end).

admin_json_preserves_boolean_gates_test() ->
    Value = ecai_code_admin_http:externalize(#{
        ok => true,
        publication_gate => #{eligible => false, blockers => [push_disabled]},
        publishing => undefined
    }),
    ?assertEqual(true, maps:get(<<"ok">>, Value)),
    Gate = maps:get(<<"publication_gate">>, Value),
    ?assertEqual(false, maps:get(<<"eligible">>, Gate)),
    ?assertEqual([<<"push_disabled">>], maps:get(<<"blockers">>, Gate)),
    ?assertEqual(null, maps:get(<<"publishing">>, Value)).

with_config(Fun) ->
    Values = [
        {damage, node_admins, [<<"ak_admin">>]},
        {ecai, code_admin_enabled, true},
        {ecai, code_admin_accounts, []}
    ],
    Old = [{App, Key, application:get_env(App, Key)} || {App, Key, _} <- Values],
    lists:foreach(fun({App, Key, V}) -> application:set_env(App, Key, V) end, Values),
    try
        Fun()
    after
        lists:foreach(
            fun
                ({App, Key, undefined}) -> application:unset_env(App, Key);
                ({App, Key, {ok, V}}) -> application:set_env(App, Key, V)
            end,
            Old
        )
    end.
