%%%-------------------------------------------------------------------
%%% EUnit coverage for the public scoped damage_context API.
%%%-------------------------------------------------------------------
-module(damage_context_tests).

-include_lib("eunit/include/eunit.hrl").

-define(REDACTED, <<"XX-REDACTED-XX">>).

context_api_test_() ->
    [
        fixture(fun account_put_get_delete/1),
        fixture(fun account_scopes_are_isolated/1),
        fixture(fun sensitive_values_are_redacted_publicly/1),
        fixture(fun wallet_and_agent_scopes_are_isolated/1),
        fixture(fun atomic_changes_and_version_conflicts/1),
        fixture(fun protected_runtime_keys_are_rejected/1),
        fixture(fun clean_secrets_redacts_context_entries/1),
        fixture(fun compatibility_wrappers_use_account_scope/1)
    ].

fixture(TestFun) ->
    {setup, fun damage_context_test_support:setup_store/0,
        fun damage_context_test_support:cleanup_store/1, fun(Fixture) ->
            fun() -> TestFun(Fixture) end
        end}.

account_put_get_delete(_Fixture) ->
    Account = damage_context_test_support:account(<<"public-api">>),
    Scope = {account, Account},
    {ok, PutSummary} = damage_context:put(Scope, <<"server">>, <<"https://example.test">>),
    ?assertEqual(1, maps:get(version, PutSummary)),
    ?assertEqual({ok, <<"https://example.test">>}, damage_context:get(Scope, <<"server">>)),
    {ok, Entry} = damage_context:get_entry(Scope, <<"server">>),
    ?assertEqual(false, maps:get(sensitive, Entry)),
    ?assertEqual(template, maps:get(exposure, Entry)),
    {ok, DeleteSummary} = damage_context:delete(Scope, <<"server">>),
    ?assertEqual(2, maps:get(version, DeleteSummary)),
    assert_missing(damage_context:get(Scope, <<"server">>)).

account_scopes_are_isolated(_Fixture) ->
    AccountA = damage_context_test_support:account(<<"isolation-a">>),
    AccountB = damage_context_test_support:account(<<"isolation-b">>),
    ScopeA = {account, AccountA},
    ScopeB = {account, AccountB},
    {ok, _} = damage_context:put(ScopeA, <<"shared">>, <<"value-a">>),
    {ok, _} = damage_context:put(ScopeB, <<"shared">>, <<"value-b">>),
    ?assertEqual({ok, <<"value-a">>}, damage_context:get(ScopeA, <<"shared">>)),
    ?assertEqual({ok, <<"value-b">>}, damage_context:get(ScopeB, <<"shared">>)).

sensitive_values_are_redacted_publicly(_Fixture) ->
    Account = damage_context_test_support:account(<<"redaction">>),
    Scope = {account, Account},
    Secret = <<"secret-visible-only-inside-run">>,
    {ok, _} = damage_context:put(Scope, <<"api_token">>, Secret, #{sensitive => true}),
    ?assertEqual({ok, Secret}, damage_context:get(Scope, <<"api_token">>)),
    {ok, Snapshot} = damage_context:public_snapshot(Scope),
    Entry = maps:get(<<"api_token">>, maps:get(entries, Snapshot)),
    ?assertEqual(true, maps:get(sensitive, Entry)),
    ?assertEqual(?REDACTED, maps:get(value, Entry)).

wallet_and_agent_scopes_are_isolated(_Fixture) ->
    Account = damage_context_test_support:account(<<"owned-subscopes">>),
    Wallet = {wallet, Account, <<"wallet-main">>},
    Agent = {agent, Account, <<"release-agent">>},
    AccountScope = {account, Account},
    Key = <<"limit">>,
    {ok, _} = damage_context:put(AccountScope, Key, 10),
    {ok, _} = damage_context:put(Wallet, Key, 20),
    {ok, _} = damage_context:put(Agent, Key, 30),
    ?assertEqual({ok, 10}, damage_context:get(AccountScope, Key)),
    ?assertEqual({ok, 20}, damage_context:get(Wallet, Key)),
    ?assertEqual({ok, 30}, damage_context:get(Agent, Key)),
    {ok, WalletSnapshot} = damage_context:snapshot(Wallet),
    {ok, AgentSnapshot} = damage_context:snapshot(Agent),
    ?assertNotEqual(
        maps:get(id, maps:get(scope, WalletSnapshot)),
        maps:get(id, maps:get(scope, AgentSnapshot))
    ).

atomic_changes_and_version_conflicts(_Fixture) ->
    Account = damage_context_test_support:account(<<"atomic">>),
    Scope = {account, Account},
    {ok, First} = damage_context:apply_changes(
        Scope,
        #{
            set => #{
                <<"one">> => 1,
                <<"secret">> => #{value => <<"hidden">>, sensitive => true}
            },
            delete => []
        },
        0
    ),
    ?assertEqual(1, maps:get(version, First)),
    Conflict = damage_context:apply_changes(
        Scope,
        #{set => #{<<"two">> => 2}, delete => []},
        0
    ),
    ?assertEqual({error, {version_conflict, 1}}, Conflict),
    {ok, Second} = damage_context:apply_changes(
        Scope,
        #{set => #{<<"two">> => 2}, delete => [<<"one">>]},
        1
    ),
    ?assertEqual(2, maps:get(version, Second)),
    assert_missing(damage_context:get(Scope, <<"one">>)),
    ?assertEqual({ok, 2}, damage_context:get(Scope, <<"two">>)).

protected_runtime_keys_are_rejected(_Fixture) ->
    Account = damage_context_test_support:account(<<"protected">>),
    Scope = {account, Account},
    ?assertMatch(
        {error, {reserved_context_key, _}},
        damage_context:put(Scope, <<"public_key">>, <<"ak_other">>)
    ),
    ?assertMatch(
        {error, {reserved_context_key, _}},
        damage_context:put(Scope, access_token, <<"not-allowed">>)
    ).

clean_secrets_redacts_context_entries(_Fixture) ->
    Secret = <<"context-secret-123">>,
    Password = <<"password-secret-456">>,
    Context = #{
        account_context => #{
            <<"api_token">> => #{
                value => Secret,
                sensitive => true,
                exposure => template,
                inheritance => none,
                locked => false,
                updated_at => 1
            }
        },
        nested => #{password => Password}
    },
    Body = <<"token=", Secret/binary, " password=", Password/binary>>,
    Args = <<Secret/binary, ":", Password/binary>>,
    {CleanBody, CleanArgs} = damage_context:clean_secrets(Context, Body, Args),
    ?assertEqual(nomatch, binary:match(CleanBody, Secret)),
    ?assertEqual(nomatch, binary:match(CleanBody, Password)),
    ?assertEqual(nomatch, binary:match(CleanArgs, Secret)),
    ?assertEqual(nomatch, binary:match(CleanArgs, Password)),
    ?assertNotEqual(nomatch, binary:match(CleanBody, ?REDACTED)),
    ?assertNotEqual(nomatch, binary:match(CleanArgs, ?REDACTED)).

compatibility_wrappers_use_account_scope(_Fixture) ->
    Account = damage_context_test_support:account(<<"compatibility">>),
    {ok, _} = damage_context:add_context(Account, <<"plain">>, <<"value">>),
    {ok, _} = damage_context:add_context(Account, <<"masked">>, <<"secret">>, masked),
    ?assertEqual({ok, <<"value">>}, damage_context:get({account, Account}, <<"plain">>)),
    {ok, MaskedEntry} = damage_context:get_entry({account, Account}, <<"masked">>),
    ?assertEqual(true, maps:get(sensitive, MaskedEntry)),
    Values = damage_context:get_context(Account),
    ?assertEqual(<<"value">>, maps:get(<<"plain">>, Values)),
    ?assertEqual(<<"secret">>, maps:get(<<"masked">>, Values)).

assert_missing(not_found) ->
    ok;
assert_missing({error, not_found}) ->
    ok;
assert_missing(Other) ->
    ?assertEqual(not_found, Other).
