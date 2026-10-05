%%%-------------------------------------------------------------------
%%% EUnit coverage for the encrypted scoped context store.
%%%-------------------------------------------------------------------
-module(damage_context_store_tests).

-include_lib("eunit/include/eunit.hrl").

store_test_() ->
    [
        fixture(fun initial_snapshot/1),
        fixture(fun mutation_and_snapshot/1),
        fixture(fun semantic_noop_keeps_version_and_root/1),
        fixture(fun optimistic_version_conflict/1),
        fixture(fun delete_and_clear/1),
        fixture(fun scopes_are_isolated/1),
        fixture(fun snapshot_survives_restart/1),
        fixture(fun persisted_envelope_contains_no_plaintext/1),
        fixture(fun tampered_root_is_rejected/1),
        fixture(fun maximum_snapshot_size_is_enforced/1)
    ].

fixture(TestFun) ->
    {setup, fun damage_context_test_support:setup_store/0,
        fun damage_context_test_support:cleanup_store/1, fun(Fixture) ->
            fun() -> TestFun(Fixture) end
        end}.

initial_snapshot(_Fixture) ->
    Scope = damage_context_test_support:account_scope(<<"initial">>),
    {ok, Snapshot} = damage_context_store:snapshot(Scope),
    ?assertEqual(2, maps:get(schema_version, Snapshot)),
    ?assertEqual(Scope, maps:get(scope, Snapshot)),
    ?assertEqual(0, maps:get(version, Snapshot)),
    ?assertEqual(#{}, maps:get(entries, Snapshot)),
    Root = maps:get(root, Snapshot),
    ?assertEqual(64, byte_size(Root)),
    ?assertMatch(match, re:run(Root, <<"^[0-9a-f]{64}$">>, [{capture, none}])).

mutation_and_snapshot(_Fixture) ->
    Scope = damage_context_test_support:account_scope(<<"mutation">>),
    Entry = damage_context_test_support:entry(<<"https://api.example.test">>),
    {ok, Summary} = damage_context_store:apply_changes(
        Scope,
        #{<<"server">> => Entry},
        [],
        0
    ),
    ?assertEqual(1, maps:get(version, Summary)),
    {ok, Snapshot} = damage_context_store:snapshot(Scope),
    ?assertEqual(Entry, maps:get(<<"server">>, maps:get(entries, Snapshot))),
    ?assertEqual(maps:get(root, Summary), maps:get(root, Snapshot)).

semantic_noop_keeps_version_and_root(_Fixture) ->
    Scope = damage_context_test_support:account_scope(<<"noop">>),
    First = damage_context_test_support:entry(<<"same-value">>, #{updated_at => 100}),
    {ok, FirstSummary} = damage_context_store:apply_changes(
        Scope,
        #{<<"key">> => First},
        [],
        0
    ),
    SameMeaning = First#{updated_at => 999999},
    {ok, SecondSummary} = damage_context_store:apply_changes(
        Scope,
        #{<<"key">> => SameMeaning},
        [],
        1
    ),
    ?assertEqual(1, maps:get(version, SecondSummary)),
    ?assertEqual(maps:get(root, FirstSummary), maps:get(root, SecondSummary)),
    {ok, Snapshot} = damage_context_store:snapshot(Scope),
    StoredEntry = maps:get(<<"key">>, maps:get(entries, Snapshot)),
    ?assertEqual(100, maps:get(updated_at, StoredEntry)).

optimistic_version_conflict(_Fixture) ->
    Scope = damage_context_test_support:account_scope(<<"conflict">>),
    {ok, _} = damage_context_store:apply_changes(
        Scope,
        #{<<"key">> => damage_context_test_support:entry(<<"v1">>)},
        [],
        0
    ),
    Result = damage_context_store:apply_changes(
        Scope,
        #{<<"key">> => damage_context_test_support:entry(<<"stale">>)},
        [],
        0
    ),
    ?assertEqual({error, {version_conflict, 1}}, Result),
    {ok, Snapshot} = damage_context_store:snapshot(Scope),
    Entry = maps:get(<<"key">>, maps:get(entries, Snapshot)),
    ?assertEqual(<<"v1">>, maps:get(value, Entry)).

delete_and_clear(_Fixture) ->
    Scope = damage_context_test_support:account_scope(<<"delete-clear">>),
    {ok, _} = damage_context_store:apply_changes(
        Scope,
        #{
            <<"one">> => damage_context_test_support:entry(1),
            <<"two">> => damage_context_test_support:entry(2)
        },
        [],
        0
    ),
    {ok, DeleteSummary} = damage_context_store:apply_changes(Scope, #{}, [<<"one">>], 1),
    ?assertEqual(2, maps:get(version, DeleteSummary)),
    {ok, AfterDelete} = damage_context_store:snapshot(Scope),
    ?assertEqual(false, maps:is_key(<<"one">>, maps:get(entries, AfterDelete))),
    ?assertEqual(true, maps:is_key(<<"two">>, maps:get(entries, AfterDelete))),
    {ok, ClearSummary} = damage_context_store:clear(Scope),
    ?assertEqual(3, maps:get(version, ClearSummary)),
    {ok, AfterClear} = damage_context_store:snapshot(Scope),
    ?assertEqual(#{}, maps:get(entries, AfterClear)).

scopes_are_isolated(_Fixture) ->
    AccountA = damage_context_test_support:account_scope(<<"account-a">>),
    AccountB = damage_context_test_support:account_scope(<<"account-b">>),
    WalletA = damage_context_test_support:wallet_scope(<<"account-a">>, <<"wallet-a">>),
    Key = <<"shared-key">>,
    {ok, _} = damage_context_store:apply_changes(
        AccountA,
        #{Key => damage_context_test_support:entry(<<"account-a">>)},
        [],
        0
    ),
    {ok, _} = damage_context_store:apply_changes(
        AccountB,
        #{Key => damage_context_test_support:entry(<<"account-b">>)},
        [],
        0
    ),
    {ok, _} = damage_context_store:apply_changes(
        WalletA,
        #{Key => damage_context_test_support:entry(<<"wallet-a">>)},
        [],
        0
    ),
    ?assertEqual(<<"account-a">>, value(AccountA, Key)),
    ?assertEqual(<<"account-b">>, value(AccountB, Key)),
    ?assertEqual(<<"wallet-a">>, value(WalletA, Key)).

snapshot_survives_restart(_Fixture) ->
    Scope = damage_context_test_support:account_scope(<<"restart">>),
    Secret = <<"persisted-secret">>,
    {ok, _} = damage_context_store:apply_changes(
        Scope,
        #{<<"secret">> => damage_context_test_support:entry(Secret, #{sensitive => true})},
        [],
        0
    ),
    {ok, Before} = damage_context_store:snapshot(Scope),
    ok = damage_context_test_support:restart_store(),
    {ok, After} = damage_context_store:snapshot(Scope),
    ?assertEqual(maps:get(version, Before), maps:get(version, After)),
    ?assertEqual(maps:get(root, Before), maps:get(root, After)),
    ?assertEqual(maps:get(entries, Before), maps:get(entries, After)).

persisted_envelope_contains_no_plaintext(Fixture) ->
    Scope = damage_context_test_support:account_scope(<<"ciphertext">>),
    Secret = <<"THIS-MUST-NOT-APPEAR-IN-DETS">>,
    {ok, _} = damage_context_store:apply_changes(
        Scope,
        #{<<"token">> => damage_context_test_support:entry(Secret, #{sensitive => true})},
        [],
        0
    ),
    ok = damage_context_test_support:stop_store(),
    StoreFile = damage_context_test_support:store_file(Fixture),
    {ok, damage_context_store_dets} = dets:open_file(
        damage_context_store_dets,
        [{file, StoreFile}, {type, set}]
    ),
    Key = scope_key(Scope),
    [{Key, Persisted}] = dets:lookup(damage_context_store_dets, Key),
    ?assertEqual(false, maps:is_key(entries, Persisted)),
    ?assertEqual(false, maps:is_key(scope, Persisted)),
    ?assertEqual(nomatch, binary:match(maps:get(ciphertext, Persisted), Secret)),
    ?assertEqual(64, byte_size(maps:get(root, Persisted))),
    ok = dets:close(damage_context_store_dets).

tampered_root_is_rejected(Fixture) ->
    Scope = damage_context_test_support:account_scope(<<"tamper">>),
    {ok, _} = damage_context_store:apply_changes(
        Scope,
        #{<<"key">> => damage_context_test_support:entry(<<"value">>)},
        [],
        0
    ),
    ok = damage_context_test_support:stop_store(),
    StoreFile = damage_context_test_support:store_file(Fixture),
    {ok, damage_context_store_dets} = dets:open_file(
        damage_context_store_dets,
        [{file, StoreFile}, {type, set}]
    ),
    Key = scope_key(Scope),
    [{Key, Persisted0}] = dets:lookup(damage_context_store_dets, Key),
    Persisted = Persisted0#{root => binary:copy(<<"0">>, 64)},
    ok = dets:insert(damage_context_store_dets, {Key, Persisted}),
    ok = dets:sync(damage_context_store_dets),
    ok = dets:close(damage_context_store_dets),
    ok = damage_context_store:ensure_started(),
    ?assertEqual({error, context_snapshot_root_mismatch}, damage_context_store:snapshot(Scope)).

maximum_snapshot_size_is_enforced(_Fixture) ->
    Scope = damage_context_test_support:account_scope(<<"maximum-size">>),
    ok = application:set_env(damage, context_max_bytes, 128),
    LargeValue = crypto:strong_rand_bytes(4096),
    Result = damage_context_store:apply_changes(
        Scope,
        #{<<"large">> => damage_context_test_support:entry(LargeValue)},
        [],
        0
    ),
    ?assertMatch({error, {context_too_large, _ActualBytes, 128}}, Result),
    {ok, Snapshot} = damage_context_store:snapshot(Scope),
    ?assertEqual(0, maps:get(version, Snapshot)),
    ?assertEqual(#{}, maps:get(entries, Snapshot)).

value(Scope, Key) ->
    {ok, Snapshot} = damage_context_store:snapshot(Scope),
    Entry = maps:get(Key, maps:get(entries, Snapshot)),
    maps:get(value, Entry).

scope_key(#{kind := Kind, owner := Owner, id := Id}) ->
    {Kind, Owner, Id}.
