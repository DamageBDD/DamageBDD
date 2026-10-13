%%%-------------------------------------------------------------------
%%% EUnit coverage for the damage_http -> damage_context boundary.
%%%
%%% These cases verify identity forwarding and the exact runtime map passed to
%%% damage_context:prepare_run_context/1. They do not start Cowboy or contact any
%%% external service.
%%%-------------------------------------------------------------------
-module(damage_http_context_tests).

-include_lib("eunit/include/eunit.hrl").

feature_context_boundary_test_() ->
    {inorder, [
        ?_test(authenticated_state_overrides_request_identity()),
        ?_test(address_is_used_when_public_key_is_absent()),
        ?_test(missing_identity_is_explicit()),
        ?_test(optional_scopes_and_runtime_fields_are_forwarded()),
        ?_test(different_accounts_resolve_independently()),
        ?_test(context_builder_result_is_returned_unchanged())
    ]}.

authenticated_state_overrides_request_identity() ->
    Authenticated = account(<<"authenticated">>),
    Spoofed = account(<<"spoofed">>),
    Request = #{
        feature => <<"Feature: context">>,
        public_key => Spoofed,
        access_token => <<"request-token">>,
        request_value => <<"request">>
    },
    State = #{
        public_key => Authenticated,
        access_token => <<"authenticated-token">>,
        username => <<"owner@example.test">>
    },
    with_deps(
        #{
            context_builder => fun(Context) ->
                Context#{resolved_for => maps:get(public_key, Context)}
            end
        },
        fun(Ref) ->
            Result = damage_http:effective_context(Request, State),
            [ContextSeen] =
                prepared_inputs(Ref),
            ?assertEqual(Authenticated, maps:get(public_key, ContextSeen)),
            assert_no_transport_secrets(ContextSeen),
            assert_no_transport_secrets(Result),
            ?assertEqual(<<"request">>, maps:get(request_value, ContextSeen)),
            ?assertEqual(Authenticated, maps:get(resolved_for, Result))
        end
    ).

address_is_used_when_public_key_is_absent() ->
    Account = account(<<"address-only">>),
    Request = #{feature => <<"Feature: address">>, address => Account},
    with_deps(
        #{
            context_builder => fun(Context) ->
                Context#{resolved_for => maps:get(address, Context)}
            end
        },
        fun(Ref) ->
            Result = damage_http:effective_context(Request, #{}),
            [Forwarded] =
                prepared_inputs(Ref),
            ?assertEqual(Account, maps:get(address, Forwarded)),
            ?assertEqual(Account, maps:get(resolved_for, Result))
        end
    ).

missing_identity_is_explicit() ->
    Request = #{feature => <<"Feature: anonymous">>},
    with_deps(
        #{},
        fun(Ref) ->
            Result = damage_http:effective_context(Request, #{}),
            [Forwarded] =
                prepared_inputs(Ref),
            ?assertEqual(<<"Feature: anonymous">>, maps:get(feature, Forwarded)),
            ?assertNot(maps:is_key(public_key, Forwarded)),
            ?assertNot(maps:is_key(address, Forwarded)),
            ?assertEqual(Request, Result)
        end
    ).

optional_scopes_and_runtime_fields_are_forwarded() ->
    Account = account(<<"scope-owner">>),
    Scopes = [
        {wallet, Account, <<"wallet-main">>},
        {agent, Account, <<"release-agent">>}
    ],
    Request = #{
        feature => <<"Feature: scoped">>,
        context_scopes => Scopes,
        concurrency => 4,
        stream => maybe_stream,
        run_id => <<"run-ctx-1">>,
        custom_runtime => #{region => <<"au-syd">>}
    },
    State = #{public_key => Account, access_token => <<"secret-token">>},
    with_deps(
        #{},
        fun(Ref) ->
            Result = damage_http:effective_context(Request, State),
            [Forwarded] =
                prepared_inputs(Ref),
            ?assertEqual(Account, maps:get(public_key, Forwarded)),
            assert_no_transport_secrets(Forwarded),
            ?assertEqual(Scopes, maps:get(context_scopes, Forwarded)),
            ?assertEqual(4, maps:get(concurrency, Forwarded)),
            ?assertEqual(maybe_stream, maps:get(stream, Forwarded)),
            ?assertEqual(<<"run-ctx-1">>, maps:get(run_id, Forwarded)),
            ?assertEqual(#{region => <<"au-syd">>}, maps:get(custom_runtime, Forwarded)),
            ?assertEqual(Forwarded, Result)
        end
    ).

different_accounts_resolve_independently() ->
    AccountA = account(<<"tenant-a">>),
    AccountB = account(<<"tenant-b">>),
    Builder = fun(Context) -> Context#{tenant_context => maps:get(public_key, Context)} end,
    with_deps(
        #{context_builder => Builder},
        fun(Ref) ->
            ResultA = damage_http:effective_context(
                #{feature => <<"Feature: A">>},
                #{public_key => AccountA}
            ),
            ResultB = damage_http:effective_context(
                #{feature => <<"Feature: B">>},
                #{public_key => AccountB}
            ),
            [InputA, InputB] = prepared_inputs(Ref),
            ?assertEqual(AccountA, maps:get(public_key, InputA)),
            ?assertEqual(AccountB, maps:get(public_key, InputB)),
            ?assertEqual(2, meck:num_calls(damage_context, prepare_run_context, 1)),
            ?assertEqual(AccountA, maps:get(tenant_context, ResultA)),
            ?assertEqual(AccountB, maps:get(tenant_context, ResultB)),
            ?assertNotEqual(maps:get(tenant_context, ResultA), maps:get(tenant_context, ResultB))
        end
    ).

context_builder_result_is_returned_unchanged() ->
    Account = account(<<"builder-result">>),
    Frozen = #{
        public_key => Account,
        node_default => <<"node-value">>,
        account_value => <<"account-value">>,
        wallet_value => <<"wallet-value">>,
        context_proof => #{
            node => #{version => 2, root => binary:copy(<<"a">>, 64)},
            account => #{version => 4, root => binary:copy(<<"b">>, 64)}
        }
    },
    with_deps(
        #{context_builder => fun(_Context) -> Frozen end},
        fun(Ref) ->
            Result = damage_http:effective_context(
                #{feature => <<"Feature: exact">>},
                #{public_key => Account}
            ),
            [_Input] = prepared_inputs(Ref),
            ?assertEqual(Frozen, Result)
        end
    ).

with_deps(Opts, Fun) ->
    Ref = make_ref(),
    Builder = maps:get(context_builder, Opts, fun(Context) -> Context end),
    %% No passthrough: this HTTP boundary test must never open a real wallet
    %% or context store. Do not unload another fixture's pre-existing mock.
    ok = meck:new(damage_context, []),
    put({?MODULE, Ref}, []),
    try
        ok = meck:expect(damage_context, prepare_run_context, fun(Context) ->
            %% Check the actual input; do not sanitize it inside the mock.
            assert_no_transport_secrets(Context),
            put({?MODULE, Ref}, [Context | get({?MODULE, Ref})]),
            Builder(Context)
        end),
        Result = Fun(Ref),
        ?assert(meck:validate(damage_context)),
        Result
    after
        erase({?MODULE, Ref}),
        ok = meck:unload(damage_context)
    end.

prepared_inputs(Ref) ->
    lists:reverse(get({?MODULE, Ref})).

assert_no_transport_secrets(Context) ->
    Keys = [
        access_token,
        authorization,
        private_key,
        password,
        sessionid,
        cookie,
        l402,
        l402_macaroon
    ],
    lists:foreach(
        fun(Key) ->
            ?assertNot(maps:is_key(Key, Context)),
            ?assertNot(maps:is_key(atom_to_binary(Key, utf8), Context))
        end,
        Keys
    ).

account(Label) ->
    <<"ak_http_context_", Label/binary>>.
