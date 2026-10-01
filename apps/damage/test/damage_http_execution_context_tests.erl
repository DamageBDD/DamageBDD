%%%-------------------------------------------------------------------
%%% EUnit coverage for the current damage_http feature execution context
%%% orchestration.
%%%
%%% The production orchestrator is damage_http:execute_bdd/4. Tests mock the
%%% real module boundaries it uses today rather than a historical injected
%%% dependency map/check_execute_bdd/5 compatibility seam.
%%%-------------------------------------------------------------------
-module(damage_http_execution_context_tests).

-include_lib("eunit/include/eunit.hrl").

-define(SECRET, <<"feature-visible-account-secret">>).

feature_execution_context_test_() ->
    {inorder, [
        ?_test(dry_run_only_prepares_context_once()),
        ?_test(dry_run_failure_stops_before_balance_and_paid_run()),
        ?_test(insufficient_damage_returns_402_before_paid_run()),
        ?_test(paid_run_reuses_the_frozen_context_and_settles()),
        ?_test(balance_uses_authenticated_account_not_request_account()),
        ?_test(request_feature_body_is_used_for_both_executions()),
        ?_test(address_only_identity_is_used_for_balance()),
        ?_test(sensitive_context_is_available_to_feature_execution()),
        ?_test(auth_transport_secrets_are_removed_before_context_preparation()),
        ?_test(client_supplied_internal_context_is_removed_before_preparation()),
        ?_test(context_scope_failure_returns_503_before_execution())
    ]}.

%% -------------------------------------------------------------------
%% Orchestration behaviour
%% -------------------------------------------------------------------

dry_run_only_prepares_context_once() ->
    Account = account(<<"dry-only">>),
    DryRun = dry_success(7, <<"dry">>),
    with_mocks(
        Account,
        [{execute_results, [DryRun]}],
        fun(Trace, Request, State) ->
            {200, Response} = damage_http:execute_bdd(
                Request,
                State,
                test_req,
                [{dry_run, true}]
            ),
            ?assertEqual(<<"ok">>, maps:get(status, Response)),
            ?assertEqual(7, maps:get(cost, Response)),
            ?assertEqual(<<"dry">>, maps:get(report_hash, Response)),
            ?assertEqual(1, length(events(Trace, prepare_context))),
            ?assertEqual(1, length(events(Trace, execute_data))),
            ?assertEqual([], events(Trace, balance_check)),
            ?assertEqual([], events(Trace, confirm_spend)),
            [{_DryConfig, DryContext, Feature}] = events(Trace, execute_data),
            ?assertEqual(nostream, maps:get(stream, DryContext)),
            assert_scoped_values(Account, DryContext),
            ?assertEqual(maps:get(feature, Request), Feature)
        end
    ).

dry_run_failure_stops_before_balance_and_paid_run() ->
    Account = account(<<"dry-failure">>),
    DryFailure = #{
        fail => <<"step failed">>,
        failing_step => {<<"When">>, 3, ["the broken step"], <<>>}
    },
    with_mocks(
        Account,
        [{execute_results, [DryFailure]}],
        fun(Trace, Request, State) ->
            {400, Response} = damage_http:execute_bdd(Request, State, test_req, []),
            ?assertEqual(<<"notok">>, maps:get(status, Response)),
            ?assertEqual(<<"step failed">>, maps:get(reason, Response)),
            ?assertEqual(1, length(events(Trace, prepare_context))),
            ?assertEqual(1, length(events(Trace, execute_data))),
            ?assertEqual([], events(Trace, balance_check)),
            ?assertEqual([], events(Trace, confirm_spend)),
            ?assertEqual(1, length(events(Trace, get_config)))
        end
    ).

insufficient_damage_returns_402_before_paid_run() ->
    Account = account(<<"insufficient">>),
    DryRun = dry_success(10, <<"dry">>),
    with_mocks(
        Account,
        [
            {execute_results, [DryRun]},
            {balance_result, {error, insufficient_damage, 9, #{balance => 9}}}
        ],
        fun(Trace, Request, State) ->
            {402, Response} = damage_http:execute_bdd(Request, State, test_req, []),
            ?assertEqual(<<"notok">>, maps:get(status, Response)),
            ?assertEqual(9, maps:get(balance, Response)),
            ?assertEqual(10, maps:get(required, Response)),
            ?assertEqual(1, length(events(Trace, execute_data))),
            ?assertEqual([{Account, 10}], events(Trace, balance_check)),
            ?assertEqual([], events(Trace, confirm_spend)),
            ?assertEqual(1, length(events(Trace, get_config)))
        end
    ).

paid_run_reuses_the_frozen_context_and_settles() ->
    Account = account(<<"paid">>),
    DryRun = dry_success(5, <<"dry">>),
    PaidRun = paid_success(<<"paid">>),
    with_mocks(
        Account,
        [
            {execute_results, [DryRun, PaidRun]},
            {balance_result, {ok, 100, #{balance => 100}}},
            {settlement_result, {ok, 5, <<"th_paid">>}}
        ],
        fun(Trace, Request, State) ->
            {200, Response} = damage_http:execute_bdd(Request, State, test_req, []),
            ?assertEqual(<<"ok">>, maps:get(status, Response)),
            ?assertEqual(<<"success">>, maps:get(result, Response)),
            ?assertEqual(<<"paid">>, maps:get(report_hash, Response)),
            ?assertEqual(5, maps:get(cost, Response)),
            ?assertEqual(5, maps:get(spend, Response)),
            ?assertEqual(<<"th_paid">>, maps:get(tx_hash, Response)),
            ?assertEqual(Account, maps:get(public_key, Response)),

            ?assertEqual(1, length(events(Trace, prepare_context))),
            [
                {DryConfig, DryContext, DryFeature},
                {RunConfig, RunContext, RunFeature}
            ] = events(Trace, execute_data),
            ?assertEqual(nostream, maps:get(stream, DryContext)),
            ?assertEqual(maybe_stream, maps:get(stream, RunContext)),
            ?assertEqual(
                maps:remove(stream, RunContext),
                maps:remove(stream, DryContext)
            ),
            assert_scoped_values(Account, DryContext),
            assert_scoped_values(Account, RunContext),
            ?assertEqual(DryFeature, RunFeature),
            ?assertEqual(maps:get(feature, Request), RunFeature),
            ?assertEqual(true, proplists:get_value(dry_run, DryConfig)),
            ?assertEqual(false, proplists:get_value(dry_run, RunConfig, false)),
            ?assertEqual([{Account, 5}], events(Trace, balance_check)),
            ?assertEqual(1, length(events(Trace, confirm_spend))),
            [{ConfirmConfig, ConfirmResult}] = events(Trace, confirm_spend),
            ?assertEqual(true, proplists:get_value(defer_summary, ConfirmConfig, false)),
            ?assertEqual(<<"paid">>, maps:get(report_hash, ConfirmResult))
        end
    ).

balance_uses_authenticated_account_not_request_account() ->
    Authenticated = account(<<"authenticated">>),
    Spoofed = account(<<"spoofed">>),
    Request = (base_request(Authenticated))#{public_key => Spoofed},
    State = base_state(Authenticated),
    with_raw_mocks(
        [
            {execute_results, [dry_success(1, <<"dry">>), paid_success(<<"paid">>)]},
            {balance_result, {ok, 100, #{balance => 100}}},
            {settlement_result, {ok, 1, <<"th_auth">>}}
        ],
        fun(Trace) ->
            {200, Response} = damage_http:execute_bdd(Request, State, test_req, []),
            ?assertEqual(Authenticated, maps:get(public_key, Response)),
            [Forwarded] = events(Trace, prepare_context),
            ?assertEqual(Authenticated, maps:get(public_key, Forwarded)),
            ?assertEqual(false, maps:is_key(access_token, Forwarded)),
            ?assertEqual([{Authenticated, 1}], events(Trace, balance_check))
        end
    ).

request_feature_body_is_used_for_both_executions() ->
    Account = account(<<"feature-source">>),
    RequestFeature = <<"Feature: request body\n  Scenario: request">>,
    StateFeature = <<"Feature: stale state\n  Scenario: stale">>,
    Request = (base_request(Account))#{feature => RequestFeature},
    State = (base_state(Account))#{feature => StateFeature},
    with_raw_mocks(
        [
            {execute_results, [dry_success(0, <<"dry">>), paid_success(<<"paid">>)]},
            {balance_result, {ok, 0, #{balance => 0}}},
            {settlement_result, {ok, 0, <<"th_feature">>}}
        ],
        fun(Trace) ->
            {200, _Response} = damage_http:execute_bdd(Request, State, test_req, []),
            Features = [Feature || {_Config, _Context, Feature} <- events(Trace, execute_data)],
            ?assertEqual([RequestFeature, RequestFeature], Features),
            %% State is merged into the scoped runtime map, but must not replace
            %% the feature payload passed to the runner.
            [_Dry, {_RunConfig, RunContext, _RunFeature}] = events(Trace, execute_data),
            ?assertEqual(StateFeature, maps:get(feature, RunContext))
        end
    ).

address_only_identity_is_used_for_balance() ->
    Account = account(<<"address-balance">>),
    Request = #{
        feature => <<"Feature: address balance">>,
        address => Account,
        stream => maybe_stream,
        concurrency => 1
    },
    with_raw_mocks(
        [
            {execute_results, [dry_success(1, <<"dry">>), paid_success(<<"paid">>)]},
            {balance_result, {ok, 1, #{balance => 1}}},
            {settlement_result, {ok, 1, <<"th_address">>}}
        ],
        fun(Trace) ->
            {200, Response} = damage_http:execute_bdd(Request, #{}, test_req, []),
            ?assertEqual(Account, maps:get(public_key, Response)),
            ?assertEqual([{Account, 1}], events(Trace, balance_check))
        end
    ).

sensitive_context_is_available_to_feature_execution() ->
    Account = account(<<"secret">>),
    with_mocks(
        Account,
        [
            {execute_results, [dry_success(0, <<"dry">>), paid_success(<<"paid">>)]},
            {balance_result, {ok, 0, #{balance => 0}}},
            {settlement_result, {ok, 0, <<"th_secret">>}}
        ],
        fun(Trace, Request, State) ->
            {200, _Response} = damage_http:execute_bdd(Request, State, test_req, []),
            Contexts = [Context || {_Config, Context, _Feature} <- events(Trace, execute_data)],
            ?assertEqual(2, length(Contexts)),
            lists:foreach(
                fun(Context) ->
                    ?assertEqual(?SECRET, maps:get(api_token, Context)),
                    Entry = maps:get(<<"api_token">>, maps:get(account_context, Context)),
                    ?assertEqual(true, maps:get(sensitive, Entry)),
                    ?assertEqual(?SECRET, maps:get(value, Entry))
                end,
                Contexts
            )
        end
    ).

%% -------------------------------------------------------------------
%% Current effective-context boundary
%% -------------------------------------------------------------------

auth_transport_secrets_are_removed_before_context_preparation() ->
    Account = account(<<"auth-secrets">>),
    Request = base_request(Account),
    State = (base_state(Account))#{
        authorization => <<"Bearer secret">>,
        private_key => <<"private">>,
        password => <<"password">>,
        sessionid => <<"session">>,
        cookie => <<"cookie">>,
        l402 => <<"challenge-secret">>,
        l402_macaroon => <<"macaroon-secret">>,
        auth_type => l402,
        l402_payment_hash_hex => <<"payment-hash">>
    },
    with_raw_mocks(
        [{execute_results, [dry_success(0, <<"dry">>)]}],
        fun(Trace) ->
            {200, _} = damage_http:execute_bdd(Request, State, test_req, [{dry_run, true}]),
            [Forwarded] = events(Trace, prepare_context),
            lists:foreach(
                fun(Key) -> ?assertEqual(false, maps:is_key(Key, Forwarded)) end,
                [
                    access_token,
                    authorization,
                    private_key,
                    password,
                    sessionid,
                    cookie,
                    l402,
                    l402_macaroon
                ]
            ),
            ?assertEqual(l402, maps:get(auth_type, Forwarded)),
            ?assertEqual(<<"payment-hash">>, maps:get(l402_payment_hash_hex, Forwarded))
        end
    ).

client_supplied_internal_context_is_removed_before_preparation() ->
    Account = account(<<"internal-context">>),
    Request = (base_request(Account))#{
        damage_context_effective => #{spoofed => true},
        context_proofs => #{spoofed => true},
        context_ipfs_hash => <<"spoofed">>,
        context_ipfs_uri => <<"ipfs://spoofed">>,
        context_ipfs_url => <<"https://spoofed">>,
        context_url => <<"https://spoofed/context">>,
        account_context => #{<<"spoofed">> => true},
        node_context => #{<<"spoofed">> => true}
    },
    with_raw_mocks(
        [{execute_results, [dry_success(0, <<"dry">>)]}],
        fun(Trace) ->
            {200, _} = damage_http:execute_bdd(
                Request,
                base_state(Account),
                test_req,
                [{dry_run, true}]
            ),
            [Forwarded] = events(Trace, prepare_context),
            lists:foreach(
                fun(Key) -> ?assertEqual(false, maps:is_key(Key, Forwarded)) end,
                [
                    damage_context_effective,
                    context_proofs,
                    context_ipfs_hash,
                    context_ipfs_uri,
                    context_ipfs_url,
                    context_url,
                    account_context,
                    node_context
                ]
            )
        end
    ).

context_scope_failure_returns_503_before_execution() ->
    Account = account(<<"scope-failure">>),
    Scope = {wallet, Account, <<"missing-wallet">>},
    with_raw_mocks(
        [{prepare_error, {context_scope_unavailable, Scope, not_found}}],
        fun(Trace) ->
            {503, Response} = damage_http:execute_bdd(
                base_request(Account),
                base_state(Account),
                test_req,
                []
            ),
            ?assertEqual(<<"notok">>, maps:get(status, Response)),
            ?assertEqual(<<"CONTEXT_SCOPE_UNAVAILABLE">>, maps:get(error, Response)),
            ?assertEqual([], events(Trace, execute_data)),
            ?assertEqual([], events(Trace, balance_check)),
            ?assertEqual([], events(Trace, confirm_spend))
        end
    ).

%% -------------------------------------------------------------------
%% Mock harness for the current production boundaries
%% -------------------------------------------------------------------

with_mocks(Account, Overrides, TestFun) ->
    Request = base_request(Account),
    State = base_state(Account),
    with_raw_mocks(
        Overrides,
        fun(Trace) -> TestFun(Trace, Request, State) end
    ).

with_raw_mocks(Opts0, TestFun) when is_list(Opts0) ->
    %% Test configuration follows the same convention as DamageBDD runtime
    %% configuration: a tuple proplist, never a map.
    Opts = merge_opts(default_mock_opts(), Opts0),
    Trace = ets:new(?MODULE, [ordered_set, public]),
    Modules = [
        damage_context,
        damage,
        damage_config,
        damage_balance_cache,
        damage_ae,
        formatter,
        price_feed
    ],
    try
        mock_modules(Modules),
        install_expectations(Trace, Opts),
        TestFun(Trace)
    after
        lists:foreach(fun unload_mock/1, lists:reverse(Modules)),
        catch ets:delete(Trace)
    end.

default_mock_opts() ->
    [
        {balance_result, {ok, 1000000, #{balance => 1000000}}},
        {settlement_result, {ok, 0, <<"th_test">>}},
        {execution_balance, 1000000},
        {damage_to_sats, 1},
        {damage_to_ae, 0.0}
    ].

merge_opts(Defaults, Overrides) ->
    lists:foldl(
        fun({Key, Value}, Acc) ->
            lists:keystore(Key, 1, Acc, {Key, Value})
        end,
        Defaults,
        Overrides
    ).

mock_modules(Modules) ->
    lists:foreach(
        fun(Module) ->
            catch meck:unload(Module),
            ok = meck:new(Module, [passthrough, non_strict])
        end,
        Modules
    ).

unload_mock(Module) ->
    catch meck:unload(Module),
    ok.

install_expectations(Trace, Opts) ->
    meck:expect(
        damage_context,
        prepare_run_context,
        fun(RuntimeContext) ->
            record_event(Trace, prepare_context, RuntimeContext),
            case proplists:get_value(prepare_error, Opts, undefined) of
                undefined ->
                    PrepareFun = proplists:get_value(prepare_fun, Opts, fun frozen_context/1),
                    PrepareFun(RuntimeContext);
                Error ->
                    erlang:error(Error)
            end
        end
    ),
    meck:expect(
        damage_config,
        get_default_config,
        fun(Config) ->
            assert_config_proplist(Config),
            record_event(Trace, get_config, Config),
            Config
        end
    ),
    meck:expect(
        damage,
        execute_data,
        fun(Config, Context, Feature) ->
            assert_config_proplist(Config),
            Result = next_execute_result(Trace, proplists:get_value(execute_results, Opts, [])),
            record_event(Trace, execute_data, {Config, Context, Feature}),
            Result
        end
    ),
    meck:expect(
        damage_balance_cache,
        has_enough_damage,
        fun(Account, Charge) ->
            record_event(Trace, balance_check, {Account, Charge}),
            proplists:get_value(balance_result, Opts)
        end
    ),
    meck:expect(
        damage_balance_cache,
        execution_damage_balance,
        fun(Account) ->
            record_event(Trace, execution_balance, Account),
            proplists:get_value(execution_balance, Opts)
        end
    ),
    meck:expect(
        damage_ae,
        confirm_spend,
        fun(Config, Result) ->
            assert_config_proplist(Config),
            record_event(Trace, confirm_spend, {Config, Result}),
            proplists:get_value(settlement_result, Opts)
        end
    ),
    meck:expect(
        formatter,
        format,
        fun(Config, Kind, Data) ->
            assert_config_proplist(Config),
            record_event(Trace, formatter, {Config, Kind, Data}),
            ok
        end
    ),
    meck:expect(
        price_feed,
        damage_to_sats,
        fun(Damage) ->
            record_event(Trace, damage_to_sats, Damage),
            proplists:get_value(damage_to_sats, Opts)
        end
    ),
    meck:expect(
        price_feed,
        damage_to_ae,
        fun(Damage) ->
            record_event(Trace, damage_to_ae, Damage),
            proplists:get_value(damage_to_ae, Opts)
        end
    ),
    ok.

assert_config_proplist(Config) when is_list(Config) ->
    ?assert(
        lists:all(
            fun
                ({_Key, _Value}) -> true;
                (_) -> false
            end,
            Config
        )
    );
assert_config_proplist(Config) ->
    ?assertEqual(proplist_config_expected, {invalid_config, Config}).

next_execute_result(Trace, Results) ->
    Index = ets:update_counter(Trace, execute_index, 1, {execute_index, 0}),
    case lists:nthtail(Index - 1, Results) of
        [Result | _] ->
            Result;
        [] ->
            erlang:error({unexpected_execute_data_call, Index, Results})
    end.

record_event(Trace, Tag, Value) ->
    Seq = ets:update_counter(Trace, event_seq, 1, {event_seq, 0}),
    true = ets:insert(Trace, {{event, Seq}, Tag, Value}),
    ok.

events(Trace, Tag) ->
    [
        Value
     || {{event, _Seq}, EventTag, Value} <- ets:tab2list(Trace),
        EventTag =:= Tag
    ].

%% -------------------------------------------------------------------
%% Fixtures/assertions
%% -------------------------------------------------------------------

base_request(Account) ->
    #{
        feature => <<"Feature: HTTP context\n  Scenario: uses scoped values">>,
        public_key => account(<<"request-spoof">>),
        context_scopes => [
            {wallet, Account, <<"wallet-main">>},
            {agent, Account, <<"release-agent">>}
        ],
        stream => maybe_stream,
        concurrency => 1,
        request_runtime => <<"request-value">>
    }.

base_state(Account) ->
    #{
        public_key => Account,
        access_token => <<"authenticated-token">>,
        username => <<"owner@example.test">>
    }.

frozen_context(RuntimeContext) ->
    RuntimeContext#{
        node_default => <<"node-default">>,
        account_value => <<"account-value">>,
        wallet_value => <<"wallet-value">>,
        agent_value => <<"agent-value">>,
        shared_setting => <<"account-override">>,
        locked_setting => <<"node-locked">>,
        api_token => ?SECRET,
        account_context => #{
            <<"api_token">> => #{
                value => ?SECRET,
                sensitive => true,
                exposure => template,
                inheritance => none,
                locked => false,
                updated_at => 1
            }
        },
        node_context => #{
            <<"node_default">> => #{
                value => <<"node-default">>,
                sensitive => false,
                exposure => template,
                inheritance => default,
                locked => false,
                updated_at => 1
            }
        },
        context_proofs => #{
            node => #{version => 3, root => binary:copy(<<"a">>, 64)},
            account => #{version => 8, root => binary:copy(<<"b">>, 64)},
            scopes => [
                #{kind => wallet, version => 2, root => binary:copy(<<"c">>, 64)},
                #{kind => agent, version => 4, root => binary:copy(<<"d">>, 64)}
            ]
        }
    }.

dry_success(Cost, ReportHash) ->
    #{
        dry_run => true,
        report_hash => ReportHash,
        feature_hash => <<"feature-hash">>,
        cost => Cost
    }.

paid_success(ReportHash) ->
    #{
        report_hash => ReportHash,
        feature_hash => <<"feature-hash">>,
        result => <<"success">>
    }.

assert_scoped_values(Account, Context) ->
    ?assertEqual(Account, context_account(Context)),
    ?assertEqual(<<"node-default">>, maps:get(node_default, Context)),
    ?assertEqual(<<"account-value">>, maps:get(account_value, Context)),
    ?assertEqual(<<"wallet-value">>, maps:get(wallet_value, Context)),
    ?assertEqual(<<"agent-value">>, maps:get(agent_value, Context)),
    ?assertEqual(<<"account-override">>, maps:get(shared_setting, Context)),
    ?assertEqual(<<"node-locked">>, maps:get(locked_setting, Context)),
    ?assertEqual(?SECRET, maps:get(api_token, Context)),
    ?assert(maps:is_key(context_proofs, Context)),
    ?assertEqual(2, length(maps:get(context_scopes, Context))).

context_account(#{public_key := Account}) -> Account;
context_account(#{address := Account}) -> Account.

account(Label) ->
    <<"ak_http_exec_", Label/binary>>.
