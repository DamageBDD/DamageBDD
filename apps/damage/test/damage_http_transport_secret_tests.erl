%% HTTP context boundary tests. All values are disposable test data.
%% These test the HTTP sanitization boundary, not context-store internals.
-module(damage_http_transport_secret_tests).
-include_lib("eunit/include/eunit.hrl").

request_and_state_credentials_are_removed_test() ->
    Atoms = [
        access_token,
        authorization,
        private_key,
        password,
        sessionid,
        cookie,
        l402,
        l402_macaroon
    ],
    Keys = Atoms ++ [atom_to_binary(Key, utf8) || Key <- Atoms],
    RequestSecrets = maps:from_list([{Key, <<"client-sentinel">>} || Key <- Keys]),
    StateSecrets = maps:from_list([{Key, <<"state-sentinel">>} || Key <- Keys]),
    Request = RequestSecrets#{
        feature => <<"Feature: boundary">>,
        public_key => <<"ak_spoofed_fixture">>,
        user_value => <<"keep">>
    },
    State = StateSecrets#{public_key => <<"ak_authenticated_fixture">>, auth_type => oauth},
    Expected = #{
        feature => <<"Feature: boundary">>,
        user_value => <<"keep">>,
        public_key => <<"ak_authenticated_fixture">>,
        auth_type => oauth
    },
    with_prepare_mock(
        fun(Input) ->
            %% Assert at entry, not only on the eventual returned map.
            ?assertEqual(Expected, Input),
            Input#{fixture_prepared => true}
        end,
        fun() ->
            ?assertEqual(
                Expected#{fixture_prepared => true},
                damage_http:effective_context(Request, State)
            )
        end
    ).

scope_selection_survives_without_client_preparation_fields_test() ->
    Owner = <<"ak_authenticated_fixture">>,
    Scopes = [
        {wallet, Owner, <<"wallet-fixture">>},
        {agent, Owner, <<"agent-fixture">>}
    ],
    Request = #{
        context_scopes => Scopes,
        run_id => <<"run-fixture">>,
        damage_context_effective => forged,
        <<"context_proofs">> => forged,
        account_context => forged,
        node_context => forged
    },
    Expected = #{context_scopes => Scopes, run_id => <<"run-fixture">>, public_key => Owner},
    with_prepare_mock(
        fun(Input) ->
            ?assertEqual(Expected, Input),
            Input
        end,
        fun() ->
            ?assertEqual(Expected, damage_http:effective_context(Request, #{public_key => Owner}))
        end
    ).

l402_public_metadata_survives_test() ->
    State = #{
        public_key => <<"ak_authenticated_fixture">>,
        auth_type => l402,
        access_token => <<"state-token-sentinel">>,
        l402 => <<"state-proof-sentinel">>,
        l402_macaroon => <<"state-macaroon-sentinel">>,
        l402_payment_hash_hex => <<"public-payment-hash-fixture">>
    },
    Request = #{
        feature => <<"Feature: paid fixture">>,
        <<"l402_macaroon">> => <<"client-macaroon-sentinel">>
    },
    Expected = #{
        feature => <<"Feature: paid fixture">>,
        public_key => <<"ak_authenticated_fixture">>,
        auth_type => l402,
        l402_payment_hash_hex => <<"public-payment-hash-fixture">>
    },
    with_prepare_mock(
        fun(Input) ->
            ?assertEqual(Expected, Input),
            Input
        end,
        fun() ->
            ?assertEqual(Expected, damage_http:effective_context(Request, State))
        end
    ).

preparation_failure_is_not_suppressed_test() ->
    Failure = {context_scope_unavailable, node, fixture_unavailable},
    with_prepare_mock(fun(_Input) -> meck:exception(error, Failure) end, fun() ->
        ?assertError(
            Failure,
            damage_http:effective_context(
                #{},
                #{public_key => <<"ak_authenticated_fixture">>}
            )
        )
    end).

with_prepare_mock(Prepare, Test) ->
    %% Intentionally no passthrough and no non_strict: a changed/unexpected
    %% dependency call must fail instead of reaching the real wallet/store.
    {module, damage_context} = code:ensure_loaded(damage_context),
    ok = meck:new(damage_context),
    try
        ok = meck:expect(damage_context, prepare_run_context, Prepare),
        Test(),
        ?assertEqual(1, meck:num_calls(damage_context, prepare_run_context, 1)),
        ?assert(meck:validate(damage_context))
    after
        ok = meck:unload(damage_context)
    end.
