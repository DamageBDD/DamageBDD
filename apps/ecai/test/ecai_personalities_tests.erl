-module(ecai_personalities_tests).
-include_lib("eunit/include/eunit.hrl").

-define(BACKEND, ecai_personalities_test_backend).
-define(OWNER, <<"buyer-a">>).
-define(OTHER, <<"buyer-b">>).
-define(RECIPIENT, <<"ak_11111111111111111111111111111111273Yts">>).

%% These are coordinator tests with independent fake remote services. They do
%% not claim to validate a live invoice, compile Sophia, or submit transactions.

default_personality_needs_no_service_test() ->
    ?assertEqual(undefined, whereis(ecai_personalities)),
    ?assertMatch({ok, #{ref := <<"default">>, system_prompt := <<>>}},
        ecai_personalities:resolve_personality(undefined, <<"default">>)),
    Ref = <<"purchase:", (binary:copy(<<"a">>, 64))/binary>>,
    ?assertEqual({error, personality_unavailable},
        ecai_personalities:resolve_personality(?OWNER, Ref)).

personality_entitlement_requires_confirmed_account_purchase_test() ->
    with_service(fun(_) ->
        Order = pending_order(<<"conversation-entitlement">>),
        Id = maps:get(id, Order), Ref = <<"purchase:", Id/binary>>,
        ?assertMatch({ok, #{items := [#{ref := <<"default">>}]}},
            ecai_personalities:owned_personalities(?OWNER)),
        ?assertEqual({error, personality_not_owned},
            ecai_personalities:resolve_personality(?OWNER, Ref)),
        ok = ?BACKEND:settle(Id),
        {ok, _} = reconcile_due(Id),
        await_minted(Id),
        {ok, #{items := [Default, Choice]}} = ecai_personalities:owned_personalities(?OWNER),
        ?assertEqual(<<"default">>, maps:get(ref, Default)),
        ?assertEqual(Ref, maps:get(ref, Choice)),
        ?assertNot(maps:is_key(system_prompt, Choice)),
        ?assertNot(maps:is_key(package_data, Choice)),
        ?assertMatch({ok, #{system_prompt := <<"Test package">>}},
            ecai_personalities:resolve_personality(?OWNER, Ref)),
        ?assertEqual({error, personality_not_owned},
            ecai_personalities:resolve_personality(?OTHER, Ref)),
        ?assertMatch({ok, #{items := [#{ref := <<"default">>}]}},
            ecai_personalities:owned_personalities(?OTHER))
    end).

purchased_personality_survives_catalog_changes_and_restart_test() ->
    with_service(fun(Fixture) ->
        Order = pending_order(<<"conversation-snapshot">>),
        Id = maps:get(id, Order), Ref = <<"purchase:", Id/binary>>,
        ok = ?BACKEND:settle(Id), {ok, _} = reconcile_due(Id), await_minted(Id),
        {ok, Original} = ecai_personalities:resolve_personality(?OWNER, Ref),
        ok = file:write_file(maps:get(package_file, Fixture), <<"catalog replaced">>),
        application:set_env(ecai, personality_sales_enabled, false),
        application:set_env(ecai, personality_catalog, []),
        stop_service(), start_service(),
        ?assertEqual({ok, Original}, ecai_personalities:resolve_personality(?OWNER, Ref)),
        ?assertMatch({ok, #{items := [_, #{ref := Ref}]}},
            ecai_personalities:owned_personalities(?OWNER))
    end).

invalid_personality_refs_cannot_select_catalog_or_raw_prompt_test() ->
    lists:foreach(fun(Ref) ->
        ?assertEqual({error, invalid_personality},
            ecai_personalities:resolve_personality(?OWNER, Ref))
    end, [<<>>, <<"builder">>, <<"purchase:short">>,
        <<"purchase:", (binary:copy(<<"g">>, 64))/binary>>, undefined,
        #{system_prompt => <<"Unpurchased instructions">>}]).

damaged_purchased_snapshot_fails_closed_test() ->
    with_service(fun(_) ->
        Order = pending_order(<<"corrupt-conversation-package">>),
        Id = maps:get(id, Order), Ref = <<"purchase:", Id/binary>>,
        ok = ?BACKEND:settle(Id), {ok, _} = reconcile_due(Id), await_minted(Id),
        sys:replace_state(ecai_personalities, fun(S) ->
            Tab = maps:get(table, S), [{Id, O}] = dets:lookup(Tab, Id),
            ok = dets:insert(Tab, {Id, O#{package_data => <<"tampered bytes">>}}),
            ok = dets:sync(Tab), S
        end),
        ?assertEqual({error, personality_unavailable},
            ecai_personalities:resolve_personality(?OWNER, Ref)),
        ?assertMatch({ok, #{items := [#{ref := <<"default">>}]}},
            ecai_personalities:owned_personalities(?OWNER)),
        ?assertMatch({ok, #{system_prompt := <<>>}},
            ecai_personalities:resolve_personality(?OWNER, <<"default">>))
    end).

catalogue_does_not_publish_deliverable_bytes_test() ->
    with_service(fun(_) ->
        {ok, #{items := Products}} = ecai_personalities:catalogue(),
        ?assertEqual(2, length(Products)),
        lists:foreach(fun(P) ->
            ?assertNot(maps:is_key(package_data, P)),
            ?assertNot(maps:is_key(system_prompt, P)),
            ?assertEqual(64, byte_size(maps:get(package_sha256, P)))
        end, Products)
    end).

sales_disabled_does_not_create_invoice_test() ->
    with_service(fun(_) ->
        application:set_env(ecai, personality_sales_enabled, false),
        ?assertEqual({error, sales_disabled},
            ecai_personalities:create_order(?OWNER, body(<<"disabled-sales">>))),
        ?assertEqual([], ?BACKEND:calls(ensure_invoice))
    end).

account_scoping_test() ->
    with_service(fun(_) ->
        Order = new_order(?OWNER, <<"account-scope">>),
        Id = maps:get(id, Order),
        ?assertMatch({error, _}, ecai_personalities:get_order(?OTHER, Id)),
        ?assertMatch({error, _}, ecai_personalities:reconcile(?OTHER, Id)),
        ?assertMatch({error, _}, ecai_personalities:package(?OTHER, Id)),
        ?assertMatch({error, _}, ecai_personalities:package(?OWNER, Id)),
        {ok, OtherOrders} = ecai_personalities:list_orders(?OTHER),
        ?assertEqual([], order_list(OtherOrders)),
        ?assertEqual([], ?BACKEND:calls(mint))
    end).

idempotency_is_scoped_and_conflicts_are_rejected_test() ->
    with_service(fun(_) ->
        A = new_order(?OWNER, <<"retry-key">>),
        A2 = new_order(?OWNER, <<"retry-key">>),
        ?assertEqual(maps:get(id, A), maps:get(id, A2)),
        B = new_order(?OTHER, <<"retry-key">>),
        ?assertNotEqual(maps:get(id, A), maps:get(id, B)),
        Conflicting = (body(<<"retry-key">>))#{<<"personality_id">> => <<"skeptic">>},
        ?assertMatch({error, _}, ecai_personalities:create_order(?OWNER, Conflicting)),
        ?assertEqual([], ?BACKEND:calls(mint))
    end).

invalid_recipient_rejected_before_invoice_test() ->
    with_service(fun(_) ->
        lists:foreach(fun(Recipient) ->
            Invalid = (body(<<"invalid-recipient">>))#{<<"recipient">> => Recipient},
            ?assertMatch({error, _}, ecai_personalities:create_order(?OWNER, Invalid))
        end, [<<>>, <<"alice">>, <<"ak_11111111111111111111111111111111273Ytt">>,
              <<"ct_11111111111111111111111111111111273Yts">>]),
        ?assertEqual([], ?BACKEND:calls(ensure_invoice))
    end).

parallel_buyers_cannot_exceed_edition_limit_test() ->
    with_fixture(1, fun(_) ->
        start_service(),
        Parent = self(),
        [spawn(fun() ->
            Result = ecai_personalities:create_order(
                <<"buyer-", (integer_to_binary(N))/binary>>, body(integer_to_binary(N))),
            Parent ! {purchase_result, Result}
        end) || N <- lists:seq(1, 12)],
        Results = [receive {purchase_result, R} -> R after 5000 -> error(purchase_timeout) end
                   || _ <- lists:seq(1, 12)],
        ?assertEqual(1, length([ok || {ok, _} <- Results])),
        ?assertEqual(11, length([error || {error, _} <- Results])),
        ?assertEqual([], ?BACKEND:calls(mint))
    end).

uncertain_invoice_creation_keeps_edition_reserved_test() ->
    with_fixture(1, fun(_) ->
        start_service(),
        ?BACKEND:put(ensure_invoice, {error, invoice_creation_uncertain}),
        Order = new_order(?OWNER, <<"ambiguous-invoice">>),
        Id = maps:get(id, Order),
        await(fun() -> length(?BACKEND:calls(ensure_invoice)) =:= 1 end),
        await_quiet(),
        ?BACKEND:put(ready_nft, {error, collection_not_registered}),
        {ok, _} = reconcile_due(Id),
        await_quiet(),
        {ok, Retained} = ecai_personalities:get_order(?OWNER, Id),
        ?assertEqual(invoice_pending, maps:get(status, Retained)),
        ?assertEqual({error, sold_out},
            ecai_personalities:create_order(?OTHER, body(<<"new-buyer-after-uncertain">>))),
        ?assertEqual([], ?BACKEND:calls(mint))
    end).

failed_preflight_before_invoice_releases_edition_test() ->
    with_fixture(1, fun(_) ->
        start_service(),
        ?BACKEND:put(ready_nft, {error, collection_not_registered}),
        Order = new_order(?OWNER, <<"failed-before-invoice">>),
        Id = maps:get(id, Order),
        await(fun() ->
            {ok, Current} = ecai_personalities:get_order(?OWNER, Id),
            maps:get(status, Current) =:= cancelled
        end),
        ?assertEqual([], ?BACKEND:calls(ensure_invoice)),
        ?BACKEND:put(ready_nft, undefined),
        ?assertMatch({ok, _},
            ecai_personalities:create_order(?OTHER, body(<<"buyer-after-preflight-failure">>)))
    end).

untrusted_payment_notification_never_fulfills_test() ->
    with_service(fun(_) ->
        Order = pending_order(<<"forged-notification">>),
        Id = maps:get(id, Order),
        whereis(ecai_personalities) ! {invoice_paid, Id, #{status => paid}},
        whereis(ecai_personalities) ! {cln_event, invoice_paid, #{
            label => maps:get(label, Order, <<"forged">>), amount_received_msat => 999999999}},
        {ok, _} = reconcile_due(Id),
        await_quiet(),
        ?assertEqual([], ?BACKEND:calls(mint)),
        ?assertMatch({error, _}, ecai_personalities:package(?OWNER, Id))
    end).

settlement_must_match_saved_invoice_test() ->
    with_service(fun(_) ->
        Order = pending_order(<<"settlement-binding">>),
        Id = maps:get(id, Order),
        {ok, Invoice} = ?BACKEND:invoice(Id),
        Paid = Invoice#{status => paid,
                        amount_received_msat => maps:get(amount_msat, Invoice)},
        Invalid = [Paid#{label => <<"another-invoice">>},
                   Paid#{payment_hash => binary:copy(<<"f">>, 64)},
                   Paid#{amount_msat => maps:get(amount_msat, Paid) + 1000},
                   Paid#{amount_received_msat => maps:get(amount_msat, Paid) - 1}],
        lists:foreach(fun(Claim) ->
            ?BACKEND:put(lookup_invoice, {ok, Claim}),
            {ok, _} = reconcile_due(Id),
            await_quiet(),
            ?assertEqual([], ?BACKEND:calls(mint)),
            ?assertMatch({error, _}, ecai_personalities:package(?OWNER, Id))
        end, Invalid)
    end).

failed_mint_remains_retryable_test() ->
    with_service(fun(_) ->
        Order = pending_order(<<"retry-mint">>),
        Id = maps:get(id, Order),
        ?BACKEND:put(mint, {error, temporarily_unavailable}),
        ok = ?BACKEND:settle(Id),
        {ok, _} = reconcile_due(Id),
        await(fun() -> length(?BACKEND:calls(mint)) >= 1 end),
        await_quiet(),
        ?assertMatch({error, _}, ecai_personalities:package(?OWNER, Id)),
        ?BACKEND:put(mint, undefined),
        {ok, _} = reconcile_due(Id),
        await_minted(Id),
        ?assertMatch({ok, _}, ecai_personalities:package(?OWNER, Id))
    end).

minted_package_matches_purchased_bytes_test() ->
    with_service(fun(Fixture) ->
        Order = pending_order(<<"package-bytes">>),
        Id = maps:get(id, Order),
        ok = ?BACKEND:settle(Id),
        {ok, _} = reconcile_due(Id),
        await_minted(Id),
        {ok, Package} = ecai_personalities:package(?OWNER, Id),
        ?assertEqual(maps:get(bytes, Fixture), package_bytes(Package)),
        ok = file:write_file(maps:get(package_file, Fixture), <<"changed after purchase">>),
        %% Fulfillment may use immutable copied bytes or reject tampering. It must
        %% never silently deliver the replacement bytes under the original NFT.
        case ecai_personalities:package(?OWNER, Id) of
            {ok, Again} -> ?assertEqual(maps:get(bytes, Fixture), package_bytes(Again));
            {error, _} -> ok
        end
    end).

restart_after_remote_mint_recovers_without_second_mint_test() ->
    with_service(fun(_) ->
        Parent = self(),
        Order = pending_order(<<"crash-after-mint">>),
        Id = maps:get(id, Order),
        ?BACKEND:put(after_mint, fun(_, Receipt) ->
            Parent ! {remote_minted, self(), Receipt},
            receive resume -> {ok, Receipt} after 5000 -> {error, simulated_timeout} end
        end),
        ok = ?BACKEND:settle(Id),
        {ok, _} = reconcile_due(Id),
        Worker = receive {remote_minted, W, _} -> W after 2000 -> error(mint_not_started) end,
        WorkerRef = erlang:monitor(process, Worker),
        try
            crash_service(),
            assert_worker_killed(Worker, WorkerRef),
            ?BACKEND:put(after_mint, undefined),
            start_service(),
            {ok, _} = reconcile_due(Id),
            await_minted(Id),
            ?assertEqual(1, length(?BACKEND:calls(mint))),
            ?assertMatch({ok, _}, ecai_personalities:package(?OWNER, Id))
        after cleanup_worker(Worker, WorkerRef) end
    end).

restart_after_verified_payment_recovers_before_mint_test() ->
    with_service(fun(_) ->
        Parent = self(),
        Order = pending_order(<<"crash-after-payment">>),
        Id = maps:get(id, Order),
        ?BACKEND:put(lookup, fun(_) ->
            Parent ! {before_mint, self()},
            receive resume -> {ok, not_found} after 5000 -> {error, simulated_timeout} end
        end),
        ok = ?BACKEND:settle(Id),
        {ok, _} = reconcile_due(Id),
        Worker = receive {before_mint, W} -> W after 2000 -> error(mint_not_started) end,
        WorkerRef = erlang:monitor(process, Worker),
        try
            {ok, Before} = ecai_personalities:get_order(?OWNER, Id),
            ?assertEqual(mint_pending, maps:get(status, Before)),
            ?assertEqual([], ?BACKEND:calls(mint)),
            crash_service(),
            assert_worker_killed(Worker, WorkerRef),
            ?BACKEND:put(lookup, undefined),
            start_service(),
            {ok, _} = reconcile_due(Id),
            await_minted(Id),
            ?assertEqual(1, length(?BACKEND:calls(mint))),
            ?assertEqual(1, length(?BACKEND:calls(ensure_invoice)))
        after cleanup_worker(Worker, WorkerRef) end
    end).

submitted_transaction_is_not_package_fulfillment_test() ->
    with_service(fun(_) ->
        Order = pending_order(<<"await-confirmations">>),
        Id = maps:get(id, Order),
        ?BACKEND:put(mint, {pending, #{tx_hash => <<"th_unconfirmed">>}}),
        ok = ?BACKEND:settle(Id),
        {ok, _} = reconcile_due(Id),
        await_quiet(),
        {ok, Pending} = ecai_personalities:get_order(?OWNER, Id),
        ?assertEqual(mint_pending, maps:get(status, Pending)),
        ?assertMatch({error, _}, ecai_personalities:package(?OWNER, Id)),
        ?BACKEND:put(lookup, {ok, #{token_id => 42,
            contract_id => <<"ct_test_personalities_contract">>, confirmations => 3}}),
        {ok, _} = reconcile_due(Id),
        await_minted(Id),
        ?assertEqual(1, length(?BACKEND:calls(mint))),
        ?assertMatch({ok, _}, ecai_personalities:package(?OWNER, Id))
    end).

restart_keeps_invoice_and_order_target_snapshots_test() ->
    with_service(fun(_) ->
        Order = pending_order(<<"frozen-target">>),
        Id = maps:get(id, Order),
        [Original | _] = ?BACKEND:calls(ensure_invoice),
        application:set_env(ecai, personality_lightning,
            #{treasury_node => binary:copy(<<"b">>, 66), network => <<"bitcoin">>}),
        application:set_env(ecai, personality_nft,
            #{enabled => true, contract_id => <<"ct_other_contract">>, network => <<"ae_mainnet">>}),
        stop_service(),
        start_service(),
        ok = ?BACKEND:settle(Id),
        {ok, _} = reconcile_due(Id),
        await_minted(Id),
        [Minted] = ?BACKEND:calls(mint),
        ?assertEqual(maps:get(lightning_config, Original), maps:get(lightning_config, Minted)),
        ?assertEqual(maps:get(nft_config, Original), maps:get(nft_config, Minted)),
        ?assertEqual(maps:get(price_sats, Original), maps:get(price_sats, Minted)),
        ?assertEqual(1, length(?BACKEND:calls(ensure_invoice)))
    end).

body(Key) -> #{<<"personality_id">> => <<"builder">>, <<"recipient">> => ?RECIPIENT,
               <<"idempotency_key">> => <<"test-idempotency-", Key/binary>>}.

new_order(Owner, Key) ->
    {ok, Order} = ecai_personalities:create_order(Owner, body(Key)), Order.

pending_order(Key) ->
    Order = new_order(?OWNER, Key),
    Id = maps:get(id, Order),
    await(fun() ->
        case ecai_personalities:get_order(?OWNER, Id) of
            {ok, M} -> maps:get(bolt11, M, undefined) =/= undefined;
            _ -> false
        end
    end),
    {ok, Current} = ecai_personalities:get_order(?OWNER, Id), Current.

await_minted(Id) ->
    await(fun() ->
        case ecai_personalities:get_order(?OWNER, Id) of
            {ok, M} -> lists:member(maps:get(status, M), [minted, <<"minted">>]);
            _ -> false
        end
    end).

await(Fun) -> await(Fun, 200).
await(Fun, 0) -> ?assertEqual(true, Fun());
await(Fun, N) ->
    case Fun() of true -> ok; false -> timer:sleep(10), await(Fun, N - 1) end.

%% Coordinator callers can read while a worker is active. A small quiet period
%% is used only after negative checks, never to determine successful settlement.
await_quiet() ->
    await(fun() -> map_size(maps:get(workers, sys:get_state(ecai_personalities))) =:= 0 end).

%% Change only the persisted due timestamp to exercise retries without sleeping
%% through production backoff. All public state transitions still use the API.
reconcile_due(Id) ->
    await_quiet(),
    sys:replace_state(ecai_personalities, fun(S) ->
        Tab = maps:get(table, S),
        [{Id, Order}] = dets:lookup(Tab, Id),
        ok = dets:insert(Tab, {Id, Order#{next_check_at => 0}}),
        ok = dets:sync(Tab),
        S
    end),
    ecai_personalities:reconcile(?OWNER, Id).

order_list(Orders) when is_list(Orders) -> Orders;
order_list(#{orders := Orders}) -> Orders;
order_list(#{items := Orders}) -> Orders.

package_bytes(Bytes) when is_binary(Bytes) -> Bytes;
package_bytes(#{bytes := Bytes}) -> Bytes;
package_bytes(#{body := Bytes}) -> Bytes;
package_bytes(#{content := Bytes}) -> Bytes.

with_service(Fun) -> with_fixture(20, fun(Fixture) -> start_service(), Fun(Fixture) end).

with_fixture(Limit, Fun) ->
    stop_service(),
    ?BACKEND:reset(),
    Dir = filename:join("/tmp", "ecai-personalities-eunit-" ++
        integer_to_list(erlang:unique_integer([positive, monotonic]))),
    PackageDir = filename:join(Dir, "packages"),
    PackageFile = filename:join(PackageDir, "builder.json"),
    ok = filelib:ensure_dir(PackageFile),
    Bytes = <<"{\"schema\":\"ecai.personality.v1\",\"id\":\"builder\",\"version\":\"1.0.0\",\"system_prompt\":\"Test package\"}\n">>,
    ok = file:write_file(PackageFile, Bytes),
    ok = file:write_file(filename:join(PackageDir, "skeptic.json"),
        binary:replace(Bytes, <<"builder">>, <<"skeptic">>, [global])),
    Product = #{id => <<"builder">>, name => <<"The Builder">>, tagline => <<"Make it executable">>,
        description => <<"Test edition">>, version => <<"1.0.0">>, price_sats => 1000,
        edition_limit => Limit, traits => [<<"precise">>], license => <<"personal-use">>,
        package_file => <<"builder.json">>, manifest_uri => <<"ipfs://test-manifest">>},
    Env = [{personality_sales_enabled, true}, {personality_store_dir, filename:join(Dir, "store")},
        {personality_package_dir, PackageDir},
        {personality_catalog, [Product, Product#{id => <<"skeptic">>, name => <<"The Skeptic">>, package_file => <<"skeptic.json">>}]},
        {personality_lightning_backend, ?BACKEND}, {personality_nft_backend, ?BACKEND},
        {personality_lightning, #{treasury_node => binary:copy(<<"a">>, 66), network => <<"regtest">>}},
        {personality_nft, #{enabled => true, contract_id => <<"ct_test_personalities_contract">>,
                            network => <<"ae_dev">>, confirmations => 3}},
        {personality_poll_ms, 60000}],
    Previous = [{K, application:get_env(ecai, K)} || {K, _} <- Env],
    [application:set_env(ecai, K, V) || {K, V} <- Env],
    try Fun(#{dir => Dir, package_file => PackageFile, bytes => Bytes})
    after
        stop_service(),
        [case Old of {ok, V} -> application:set_env(ecai, K, V);
                     undefined -> application:unset_env(ecai, K) end || {K, Old} <- Previous],
        ets:delete(ecai_personalities_test_remote),
        file:del_dir_r(Dir)
    end.

start_service() ->
    {ok, Pid} = gen_server:start({local, ecai_personalities}, ecai_personalities, [], []),
    Pid.

stop_service() ->
    case whereis(ecai_personalities) of
        undefined -> ok;
        Pid -> gen_server:stop(Pid, normal, 3000)
    end.

crash_service() ->
    Pid = whereis(ecai_personalities),
    Ref = erlang:monitor(process, Pid),
    exit(Pid, kill),
    receive {'DOWN', Ref, process, Pid, killed} -> ok
    after 2000 -> error(coordinator_did_not_crash) end,
    await(fun() -> dets:info(ecai_personality_orders) =:= undefined end).

assert_worker_killed(Pid, Ref) ->
    %% No test-issued signal to the worker precedes this assertion: killing its
    %% coordinator must propagate automatically through the production link.
    receive {'DOWN', Ref, process, Pid, killed} -> ok
    after 1000 -> error(worker_outlived_coordinator_crash) end,
    ?assertNot(is_process_alive(Pid)).

cleanup_worker(Pid, Ref) ->
    erlang:demonitor(Ref, [flush]),
    %% Failure-only fixture cleanup; it cannot make the earlier assertion pass.
    case is_process_alive(Pid) of true -> exit(Pid, kill); false -> ok end.
