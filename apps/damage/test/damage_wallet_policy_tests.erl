-module(damage_wallet_policy_tests).
-include_lib("eunit/include/eunit.hrl").

wallet_reads_test_() ->
    [?_assert(damage_wallet_policy:allowed(<<"GET">>,Path,wallet)) || Path <-
        [<<"/">>,<<"/accounts/balance">>,<<"/accounts/wallet/">>,<<"/accounts/session">>,<<"/ai/bdd/catalog">>]].
wallet_authoring_test_() ->
    [?_assert(damage_wallet_policy:allowed(<<"POST">>,Path,wallet)) || Path <-
        [<<"/ai/bdd/generate">>,<<"/ai/bdd/validate">>,<<"/ai/bdd/cancel">>]].
wallet_mutations_denied_test_() ->
    [?_assertNot(damage_wallet_policy:allowed(Method,Path,wallet)) || Method <- [<<"POST">>,<<"PUT">>,<<"DELETE">>],
        Path <- [<<"/execute_feature/">>,<<"/tx/">>,<<"/context">>,<<"/schedules">>,
                 <<"/api/nwc/mint">>,<<"/api/nwc/ledger/credit">>,<<"/invoices/">>,<<"/api/billing/invoices">>]].
wallet_hidden_custody_reads_denied_test_() ->
    [?_assertNot(damage_wallet_policy:allowed(<<"GET">>,Path,wallet)) || Path <-
        [<<"/context">>,<<"/schedules">>,<<"/api/nwc/sessions">>,<<"/api/node/balances">>]].
managed_path_preserved_test() ->
    ?assert(damage_wallet_policy:allowed(<<"POST">>,<<"/execute_feature/">>,custodial)).
unknown_wallet_route_denied_test() ->
    ?assertNot(damage_wallet_policy:allowed(<<"GET">>,<<"/new-admin-endpoint">>,wallet)).
wallet_not_spending_authority_test() ->
    C=damage_wallet_policy:capabilities(wallet),
    ?assertEqual(false,maps:get(execute,C)), ?assertEqual(false,maps:get(transfer,C)),
    ?assertEqual(false,maps:get(nwc,C)), ?assertEqual(true,maps:get(author_features,C)).
origin_test_() ->
    [?_assertEqual(<<"https://example.com">>,damage_browser_auth_http:origin("https://example.com/path/")),
     ?_assertEqual(<<"http://127.0.0.1:8080">>,damage_browser_auth_http:origin("http://127.0.0.1:8080/")),
     ?_assertEqual(<<"http://[::1]:8080">>,damage_browser_auth_http:origin("http://[::1]:8080/")),
     ?_assertException(error,_,damage_browser_auth_http:origin("http://public.example/")),
     ?_assertException(error,_,damage_browser_auth_http:origin("https://user:pass@example.com/"))].
malformed_api_token_test_() ->
    [?_assertEqual({error,badtoken},damage_access_token:verify_token(T)) || T <-
        [undefined,<<>>,<<"garbage">>,binary:copy(<<"x">>,16385)]].

invalid_payload_test_() ->
    Base = #{typ => <<"damage-access">>, v => 1, sub => <<"ak_fixture">>, iat => 1000,
        exp => 1100, nonce => <<"0123456789abcdef">>, aud => <<"https://example.invalid">>},
    [?_assertNot(damage_access_token:valid_payload(P, 1050)) || P <- [
        maps:remove(typ, Base), Base#{typ => <<"other-protocol">>}, Base#{v => 2},
        Base#{exp => <<"1100">>}, Base#{iat => 1200}, Base#{exp => 1000},
        Base#{exp => 90000}, Base#{nonce => <<"short">>}, Base#{nonce => binary:copy(<<"a">>,129)}
    ]].
