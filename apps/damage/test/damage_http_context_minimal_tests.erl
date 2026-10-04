%% HTTP orchestration tests. Run in an isolated EUnit VM, not a live node.
%% Context preparation, execution, balance, and settlement are test doubles;
%% damage_http itself is real. No mock forwards to a node wallet or network.
-module(damage_http_context_minimal_tests).
-include_lib("eunit/include/eunit.hrl").

-define(ACCOUNT, <<"ak_authenticated_context_test">>).
-define(COST, 3).
-define(TX, <<"th_http_context_fixture">>).

effective_context_state_precedence_test() ->
    with_mocks(#{}, fun(Tab) ->
        Request = (request())#{
            public_key => <<"ak_spoofed_context_test">>,
            access_token => <<"request-token">>
        },
        Context = damage_http:effective_context(Request, state()),
        [{prepare, Input, Prepared}] = events(Tab, prepare),
        ?assertEqual(?ACCOUNT, maps:get(public_key, Input)),
        ?assertEqual(oauth, maps:get(auth_type, Input)),
        assert_no_transport_secrets(Input),
        ?assertEqual(Prepared, Context),
        assert_prepared_values(Context),
        assert_call_counts(1, 0, 0, 0)
    end).

effective_context_preserves_scope_selection_test() ->
    with_mocks(#{}, fun(Tab) ->
        Request = (request())#{
            run_id => <<"run-context-test">>,
            concurrency => 4,
            damage_context_effective => client_forgery,
            <<"context_proofs">> => #{client_forgery => true},
            account_context => #{client_forgery => true}
        },
        Context = damage_http:effective_context(Request, state()),
        [{prepare, Input, Prepared}] = events(Tab, prepare),
        ?assertEqual(scopes(), maps:get(context_scopes, Input)),
        ?assertEqual(<<"run-context-test">>, maps:get(run_id, Input)),
        ?assertEqual(4, maps:get(concurrency, Input)),
        ?assertNot(maps:is_key(damage_context_effective, Input)),
        ?assertNot(maps:is_key(<<"context_proofs">>, Input)),
        ?assertNot(maps:is_key(account_context, Input)),
        ?assertEqual(Prepared, Context),
        assert_prepared_values(Context),
        assert_call_counts(1, 0, 0, 0)
    end).

dry_run_only_builds_context_once_test() ->
    with_mocks(#{}, fun(Tab) ->
        Request = request(),
        {200, Response} = damage_http:execute_bdd(
            Request, state(), test_req, [{dry_run, true}]
        ),
        [{prepare, _Input, Prepared}] = events(Tab, prepare),
        [{execute, dry, Config, Context, Feature}] = events(Tab, execute),
        ?assertEqual(maps:get(feature, Request), Feature),
        ?assertEqual(Prepared#{stream => nostream}, Context),
        ?assertEqual(true, proplists:get_value(dry_run, Config)),
        ?assertEqual(?ACCOUNT, proplists:get_value(public_key, Config)),
        ?assertEqual(<<"ok">>, maps:get(status, Response)),
        ?assertEqual(?COST, maps:get(cost, Response)),
        ?assertEqual(true, maps:get(dry_run, Response)),
        assert_prepared_values(Context),
        assert_call_counts(1, 1, 0, 0)
    end).

dry_run_failure_stops_before_balance_test() ->
    Failure = {parse_error, 3, <<"fixture parse failure">>},
    with_mocks(#{dry_result => Failure}, fun(Tab) ->
        {400, Response} = damage_http:execute_bdd(request(), state(), test_req, []),
        ?assertEqual(<<"notok">>, maps:get(status, Response)),
        ?assertEqual(3, maps:get(line, Response)),
        ?assertEqual(<<"fixture parse failure">>, maps:get(message, Response)),
        [{execute, dry, _Config, Context, _Feature}] = events(Tab, execute),
        assert_prepared_values(Context),
        assert_call_counts(1, 1, 0, 0)
    end).

insufficient_balance_stops_before_paid_run_test() ->
    Balance = {error, insufficient_damage, 0, #{fixture => true}},
    with_mocks(#{balance_result => Balance}, fun(Tab) ->
        {402, Response} = damage_http:execute_bdd(request(), state(), test_req, []),
        ?assertEqual(<<"notok">>, maps:get(status, Response)),
        ?assertEqual(0, maps:get(balance, Response)),
        ?assertEqual(?COST, maps:get(required, Response)),
        [{balance, Account, Charge}] = events(Tab, balance),
        ?assertEqual(?ACCOUNT, Account),
        ?assertEqual(?COST, Charge),
        [{execute, dry, _Config, Context, _Feature}] = events(Tab, execute),
        assert_prepared_values(Context),
        ?assertEqual([prepare, execute, balance], operation_order(Tab)),
        assert_call_counts(1, 1, 1, 0)
    end).

paid_run_reuses_frozen_context_test() ->
    with_mocks(#{}, fun(Tab) ->
        Request = (request())#{
            stream => maybe_stream,
            concurrency => 2,
            continue_on_fail => true
        },
        {200, Response} = damage_http:execute_bdd(Request, state(), test_req, []),
        [{prepare, _Input, Prepared}] = events(Tab, prepare),
        [
            {execute, dry, DryConfig, DryContext, DryFeature},
            {execute, paid, RunConfig, RunContext, RunFeature}
        ] = events(Tab, execute),
        ?assertEqual(maps:get(feature, Request), DryFeature),
        ?assertEqual(DryFeature, RunFeature),
        ?assertEqual(Prepared#{stream => nostream}, DryContext),
        ?assertEqual(Prepared, RunContext),
        %% Each preparation creates a new reference. A second preparation
        %% cannot accidentally satisfy this equality, even with equal values.
        ?assertEqual(
            maps:get(fixture_context_ref, DryContext),
            maps:get(fixture_context_ref, RunContext)
        ),
        ?assertEqual(true, proplists:get_value(dry_run, DryConfig)),
        ?assertEqual(false, proplists:get_value(dry_run, RunConfig, false)),
        ?assertEqual(true, proplists:get_value(defer_summary, RunConfig)),
        ?assertEqual(2, proplists:get_value(concurrency, RunConfig)),
        ?assertEqual(true, proplists:get_value(continue_on_fail, RunConfig)),
        [{confirm, SettlementConfig, Result}] = events(Tab, confirm),
        ?assertEqual(RunConfig, SettlementConfig),
        ?assertEqual(RunContext, maps:with(maps:keys(RunContext), Result)),
        assert_prepared_values(Result),
        ?assertEqual(<<"ok">>, maps:get(status, Response)),
        ?assertEqual(<<"success">>, maps:get(result, Response)),
        ?assertEqual(?ACCOUNT, maps:get(public_key, Response)),
        ?assertEqual(?TX, maps:get(tx_hash, Response)),
        ?assertEqual(?COST, maps:get(cost, Response)),
        ?assertEqual(?COST, maps:get(spend, Response)),
        ?assertEqual([prepare, execute, balance, execute, confirm], operation_order(Tab)),
        ?assertEqual(1, meck:num_calls(formatter, format, ['_', summary, '_'])),
        assert_call_counts(1, 2, 1, 1)
    end).

balance_uses_authenticated_account_test() ->
    with_mocks(#{}, fun(Tab) ->
        Request = (request())#{
            public_key => <<"ak_request_spoof">>,
            access_token => <<"spoofed-token">>
        },
        {200, Response} = damage_http:execute_bdd(Request, state(), test_req, []),
        [{balance, Account, Charge}] = events(Tab, balance),
        ?assertEqual(?ACCOUNT, Account),
        ?assertEqual(?COST, Charge),
        lists:foreach(
            fun({execute, _Stage, Config, Context, _Feature}) ->
                ?assertEqual(?ACCOUNT, proplists:get_value(public_key, Config)),
                ?assertEqual(?ACCOUNT, maps:get(public_key, Context)),
                assert_no_transport_secrets(Context)
            end,
            events(Tab, execute)
        ),
        ?assertEqual(?ACCOUNT, maps:get(public_key, Response)),
        assert_call_counts(1, 2, 1, 1)
    end).

address_identity_is_supported_test() ->
    with_mocks(#{}, fun(Tab) ->
        Address = <<"ak_address_only_context_test">>,
        Request = #{feature => feature(), stream => nostream, concurrency => 1},
        State = #{address => Address},
        {200, Response} = damage_http:execute_bdd(Request, State, test_req, []),
        [{prepare, Input, _Prepared}] = events(Tab, prepare),
        ?assertEqual(Address, maps:get(address, Input)),
        ?assertNot(maps:is_key(public_key, Input)),
        [{balance, Account, _Charge}] = events(Tab, balance),
        ?assertEqual(Address, Account),
        lists:foreach(
            fun({execute, _Stage, Config, Context, _Feature}) ->
                ?assertEqual(Address, proplists:get_value(public_key, Config)),
                ?assertEqual(Address, maps:get(address, Context))
            end,
            events(Tab, execute)
        ),
        ?assertEqual(Address, maps:get(public_key, Response)),
        assert_call_counts(1, 2, 1, 1)
    end).

l402_metadata_survives_context_test() ->
    with_mocks(#{}, fun(Tab) ->
        PaymentHash = <<"payment-hash-test">>,
        State = (state())#{
            auth_type => l402,
            l402_payment_hash_hex => PaymentHash,
            l402 => <<"private-l402-material">>,
            l402_macaroon => <<"private-macaroon">>
        },
        {200, Response} = damage_http:execute_bdd(request(), State, test_req, []),
        [{prepare, Input, _Prepared}] = events(Tab, prepare),
        ?assertEqual(l402, maps:get(auth_type, Input)),
        ?assertEqual(PaymentHash, maps:get(l402_payment_hash_hex, Input)),
        lists:foreach(
            fun({execute, _Stage, _Config, Context, _Feature}) ->
                ?assertEqual(l402, maps:get(auth_type, Context)),
                ?assertEqual(PaymentHash, maps:get(l402_payment_hash_hex, Context)),
                assert_no_transport_secrets(Context)
            end,
            events(Tab, execute)
        ),
        ?assertEqual(<<"l402">>, maps:get(payment_type, Response)),
        ?assertEqual(PaymentHash, maps:get(l402_payment_hash_hex, Response)),
        ?assertEqual(?ACCOUNT, maps:get(public_key, Response)),
        assert_no_transport_secrets(Response),
        assert_call_counts(1, 2, 1, 1)
    end).

%% Fixtures -----------------------------------------------------------
%% Meck changes modules VM-wide. Do not run these tests concurrently with
%% another suite mocking the same modules. Each test owns/unloads its mocks.
with_mocks(Options, Test) ->
    Tab = ets:new(?MODULE, [ordered_set, public]),
    true = ets:insert(Tab, {sequence, 0}),
    try
        with_mocked_modules(
            [
                damage_context,
                damage,
                damage_config,
                damage_utils,
                damage_balance_cache,
                damage_ae,
                price_feed,
                formatter,
                damage_release
            ],
            fun() ->
                install_expectations(Tab, Options),
                Test(Tab)
            end
        )
    after
        ets:delete(Tab)
    end.

%% Nested try/after cleans up already-created mocks even when a later
%% meck:new/2 or expectation fails. Never unload somebody else's mock.
with_mocked_modules([], Test) ->
    Test();
with_mocked_modules([Module | Rest], Test) ->
    ok = meck:new(Module, mock_options(Module)),
    try
        Result = with_mocked_modules(Rest, Test),
        ?assert(meck:validate(Module)),
        Result
    after
        meck:unload(Module)
    end.

%% The HTTP code probes optional price conversion exports. Permit the fixed
%% test implementation of that optional API, but never enable passthrough.
mock_options(price_feed) -> [non_strict];
mock_options(_Module) -> [].

install_expectations(Tab, Options) ->
    ok = meck:expect(damage_context, prepare_run_context, fun(Input) ->
        assert_no_transport_secrets(Input),
        Prepared = prepared_context(Input),
        record(Tab, {prepare, Input, Prepared}),
        Prepared
    end),
    ok = meck:expect(damage_config, get_default_config, fun(Config) ->
        assert_config(Config),
        Config
    end),
    ok = meck:expect(damage_utils, get_concurrency_level, fun(N) -> N end),
    ok = meck:expect(damage_utils, to_bin, fun fixture_to_bin/1),
    ok = meck:expect(damage, execute_data, fun(Config, Context, Feature) ->
        assert_config(Config),
        assert_no_transport_secrets(Context),
        Stage =
            case proplists:get_value(dry_run, Config, false) of
                true -> dry;
                false -> paid
            end,
        record(Tab, {execute, Stage, Config, Context, Feature}),
        case Stage of
            dry ->
                maps:get(
                    dry_result,
                    Options,
                    #{dry_run => true, cost => ?COST, report_hash => <<"dry-report-fixture">>}
                );
            paid ->
                Context#{report_hash => <<"paid-report-fixture">>, result => <<"success">>}
        end
    end),
    ok = meck:expect(damage_balance_cache, has_enough_damage, fun(Account, Charge) ->
        record(Tab, {balance, Account, Charge}),
        maps:get(balance_result, Options, {ok, 100, #{fixture => true}})
    end),
    ok = meck:expect(damage_ae, confirm_spend, fun(Config, Result) ->
        assert_config(Config),
        assert_no_transport_secrets(Result),
        record(Tab, {confirm, Config, Result}),
        {ok, ?COST, ?TX}
    end),
    ok = meck:expect(price_feed, damage_to_sats, fun(_Damage) -> 1 end),
    ok = meck:expect(price_feed, damage_to_ae, fun(_Damage) -> 0.01 end),
    ok = meck:expect(formatter, format, fun(_Config, _Type, _Data) -> ok end),
    ok = meck:expect(damage_release, info, fun() ->
        #{
            version => <<"fixture">>,
            release_version => <<"fixture">>,
            git_sha => <<"fixture">>,
            release_origin => package,
            runtime_modified => false,
            runtime_code_hash => <<"fixture">>
        }
    end).

%% Fixed prepared values belong to this HTTP fixture. The real scope loading,
%% decryption, merging, and proof construction are tested in damage_context.
prepared_context(Input) ->
    Input#{
        fixture_context_ref => make_ref(),
        node_context => #{<<"node_value">> => <<"node-fixture">>},
        account_context => #{<<"account_value">> => <<"account-fixture">>},
        fixture_scoped_values => #{wallet => <<"wallet-fixture">>, agent => <<"agent-fixture">>},
        context_proofs => #{fixture => <<"prepared-proof">>}
    }.

assert_prepared_values(Context) ->
    ?assert(is_reference(maps:get(fixture_context_ref, Context))),
    ?assertEqual(#{<<"node_value">> => <<"node-fixture">>}, maps:get(node_context, Context)),
    ?assertEqual(
        #{<<"account_value">> => <<"account-fixture">>}, maps:get(account_context, Context)
    ),
    ?assertEqual(
        #{wallet => <<"wallet-fixture">>, agent => <<"agent-fixture">>},
        maps:get(fixture_scoped_values, Context)
    ),
    ?assertEqual(#{fixture => <<"prepared-proof">>}, maps:get(context_proofs, Context)),
    assert_no_transport_secrets(Context).

assert_no_transport_secrets(Context) ->
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
    ?assertEqual([], [Key || Key <- Keys, maps:is_key(Key, Context)]).

assert_config(Config) ->
    ?assert(is_list(Config)),
    ?assert(lists:all(fun(Item) -> is_tuple(Item) andalso tuple_size(Item) =:= 2 end, Config)).

assert_call_counts(Preparations, Executions, Balances, Settlements) ->
    ?assertEqual(Preparations, meck:num_calls(damage_context, prepare_run_context, 1)),
    ?assertEqual(Executions, meck:num_calls(damage, execute_data, 3)),
    ?assertEqual(Balances, meck:num_calls(damage_balance_cache, has_enough_damage, 2)),
    ?assertEqual(Settlements, meck:num_calls(damage_ae, confirm_spend, 2)).

record(Tab, Event) ->
    N = ets:update_counter(Tab, sequence, 1),
    true = ets:insert(Tab, {N, Event}),
    ok.

events(Tab, Tag) ->
    [Event || {N, Event} <- ets:tab2list(Tab), is_integer(N), element(1, Event) =:= Tag].

operation_order(Tab) ->
    [element(1, Event) || {N, Event} <- ets:tab2list(Tab), is_integer(N)].

fixture_to_bin(Value) when is_binary(Value) -> Value;
fixture_to_bin(Value) when is_list(Value) -> unicode:characters_to_binary(Value);
fixture_to_bin(Value) when is_atom(Value) -> atom_to_binary(Value, utf8);
fixture_to_bin(Value) when is_integer(Value) -> integer_to_binary(Value).

request() ->
    #{
        feature => feature(),
        stream => nostream,
        concurrency => 1,
        context_scopes => scopes(),
        request_runtime => <<"request-value">>
    }.

state() ->
    #{public_key => ?ACCOUNT, auth_type => oauth, access_token => <<"authenticated-token">>}.

scopes() ->
    [{wallet, ?ACCOUNT, <<"wallet-main">>}, {agent, ?ACCOUNT, <<"release-agent">>}].

feature() ->
    <<"Feature: HTTP context\n  Scenario: context reaches execution">>.
