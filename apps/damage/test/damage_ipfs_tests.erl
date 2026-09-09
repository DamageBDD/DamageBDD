-module(damage_ipfs_tests).
-include_lib("eunit/include/eunit.hrl").

config_test() ->
    C = damage_ipfs_config:normalize([{client_concurrency, 2}]),
    ?assertEqual(2, maps:get(client_concurrency, C)),
    ?assertError(
        {invalid_ipfs_config, pin_poll_ms}, damage_ipfs_config:normalize([{pin_poll_ms, 0}])
    ),
    ?assertEqual(
        2,
        maps:get(
            client_concurrency,
            damage_ipfs_config:normalize(
                [{client_concurrency, 2}, {client_concurrency, 3}]
            )
        )
    ),
    ?assertError(
        {invalid_ipfs_config, expected_key_value_tuples},
        damage_ipfs_config:normalize([client_concurrency])
    ),
    ?assertEqual({error, invalid_cid}, damage_ipfs_config:cid(<<"cid/path">>)).

peer_normalization_test() ->
    A = <<"/ip4/127.0.0.1/tcp/4001/p2p/RemotePeer">>,
    ?assertEqual({ok, [A]}, damage_ipfs_peers:normalize([A, binary_to_list(A)])),
    ?assertEqual(
        {ok, [A]},
        damage_ipfs_peers:normalize([
            [{peer_id, <<"RemotePeer">>}, {addrs, [<<"/ip4/127.0.0.1/tcp/4001">>]}]
        ])
    ),
    ?assertEqual(
        <<"Target">>,
        damage_ipfs_peers:target_id(
            <<"/ip4/1.2.3.4/tcp/4001/p2p/Relay/p2p-circuit/p2p/Target">>
        )
    ),
    ?assertEqual({error, invalid_peer_spec}, damage_ipfs_peers:normalize([<<"/ip4/1.2.3.4">>])),
    ?assertEqual(
        {error, invalid_peer_spec},
        damage_ipfs_peers:normalize([
            [{peer_id, <<"Different">>}, {addrs, [A]}]
        ])
    ).

queue_test_() -> {timeout, 15, fun queue_checks/0}.
queue_checks() ->
    C = damage_ipfs_config:normalize([{request_timeout_ms, 250}]),
    {ok, Q} = damage_ipfs_queue:start_link(ipfs_test_queue, damage_ipfs_test_backend, 1, 1, C),
    unlink(Q),
    try
        ?assertEqual({ok, 42}, damage_ipfs_queue:request(ipfs_test_queue, {echo, 42})),
        Parent = self(),
        Caller1 = spawn(fun() ->
            Parent !
                {first,
                    damage_ipfs_queue:request(
                        ipfs_test_queue,
                        {sleep, 2000, Parent}
                    )}
        end),
        Worker =
            receive
                {backend_worker, W} -> W
            after 1000 -> error(no_worker)
            end,
        spawn(fun() ->
            Parent ! {second, damage_ipfs_queue:request(ipfs_test_queue, {echo, queued})}
        end),
        await(fun() ->
            #{queued := N} = damage_ipfs_queue:status(ipfs_test_queue),
            N =:= 1
        end),
        ?assertEqual(
            {error, overloaded}, damage_ipfs_queue:request(ipfs_test_queue, {echo, third})
        ),
        receive
            {first, R1} -> ?assertEqual({error, timeout}, R1)
        after 2000 -> error(no_timeout)
        end,
        receive
            {second, R2} -> ?assert(lists:member(R2, [{ok, queued}, {error, timeout}]))
        after 2000 -> error(no_second_reply)
        end,
        await(fun() -> not is_process_alive(Worker) andalso not is_process_alive(Caller1) end),
        ?assertMatch({error, {worker_down, _}}, damage_ipfs_queue:request(ipfs_test_queue, crash)),
        ?assert(is_process_alive(Q)),
        Caller2 = spawn(fun() ->
            damage_ipfs_queue:request(ipfs_test_queue, {sleep, 2000, Parent})
        end),
        Worker2 =
            receive
                {backend_worker, W2} -> W2
            after 1000 -> error(no_worker)
            end,
        exit(Caller2, kill),
        await(fun() -> not is_process_alive(Worker2) end),
        await(fun() ->
            #{active := A} = damage_ipfs_queue:status(ipfs_test_queue),
            A =:= 0
        end),
        ?assertEqual(
            {ok, recovered}, damage_ipfs_queue:request(ipfs_test_queue, {echo, recovered})
        ),
        Caller3 = spawn(fun() ->
            damage_ipfs_queue:request(ipfs_test_queue, {sleep, 2000, Parent})
        end),
        Worker3 =
            receive
                {backend_worker, W3} -> W3
            after 1000 -> error(no_worker)
            end,
        gen_server:stop(Q),
        await(fun() -> not is_process_alive(Worker3) andalso not is_process_alive(Caller3) end)
    after
        stop(Q)
    end.

supervision_test_() -> {timeout, 30, fun supervision_checks/0}.
supervision_checks() ->
    Dir = temp_dir(),
    Opts = [
        {backend, damage_ipfs_test_backend},
        {data_dir, Dir},
        {pin_poll_ms, 20},
        {retry_base_ms, 20},
        {retry_max_ms, 100},
        {request_timeout_ms, 500},
        {health_interval_ms, 100},
        {reconcile_interval_ms, 100},
        {loop_timeout_ms, 5000}
    ],
    C = damage_ipfs_config:normalize(Opts),
    {ok, Fake} = damage_ipfs_test_backend:start_link(),
    unlink(Fake),
    ok = damage_ipfs_test_backend:mode(offline),
    {ok, Sup} = damage_ipfs_sup:start_link(Opts),
    unlink(Sup),
    try
        %% Offline Kubo never prevents any of the seven children starting.
        ?assertEqual(7, length(supervisor:which_children(Sup))),
        ?assertMatch({error, _}, damage_ipfs:cat(<<"FeatureCid">>)),
        ?assert(is_process_alive(Sup)),
        {ok, _} = damage_ipfs:pin_async(<<"PinA">>),
        await(fun() ->
            {ok, R} = damage_ipfs:pin_status(<<"PinA">>),
            maps:get(attempts, R) > 0
        end),
        ok = damage_ipfs_test_backend:mode(online),
        await(fun() -> applied(<<"PinA">>, pinned) end),
        ?assertEqual(true, damage_ipfs_test_backend:pinned(<<"PinA">>)),
        ?assertEqual({ok, <<"raw bytes">>}, damage_ipfs:get(<<"raw">>)),
        ?assertMatch(
            {ok, #{feature := _, user := override}},
            damage_ipfs:hydrate_feature_from_ipfs(
                #{feature_cid => <<"FeatureCid">>, user => override, vars => #{user => inner}}
            )
        ),
        %% Detect a pin removed outside DamageBDD and restore it.
        ok = damage_ipfs_test_backend:drop(<<"PinA">>),
        damage_ipfs_reconciler:reconcile(),
        await(fun() -> damage_ipfs_test_backend:pinned(<<"PinA">>) end),
        %% Older completion must not overwrite a newer desired state.
        {ok, #{revision := Old}} = damage_ipfs_store:desire(<<"RaceCid">>, pinned),
        {ok, _} = damage_ipfs_store:desire(<<"RaceCid">>, unpinned),
        ?assertEqual(
            {error, stale_revision}, damage_ipfs_store:complete(<<"RaceCid">>, Old, {ok, pinned})
        ),
        {ok, _} = damage_ipfs:unpin_async(<<"PinA">>),
        await(fun() -> applied(<<"PinA">>, unpinned) end),
        ?assertEqual(false, damage_ipfs_test_backend:pinned(<<"PinA">>)),
        %% Also repair an applied unpin after a delayed external pin completes.
        damage_ipfs_test_backend:execute({ensure_pin, <<"PinA">>}, C),
        damage_ipfs_reconciler:reconcile(),
        await(fun() -> not damage_ipfs_test_backend:pinned(<<"PinA">>) end),
        ok = damage_ipfs_store:put_metadata(<<"PinA">>, #{feature_cid => <<"FeatureCid">>}),
        OldStore = whereis(damage_ipfs_store),
        OldClient = whereis(damage_ipfs_client),
        exit(OldStore, kill),
        await(fun() ->
            new_pid(damage_ipfs_store, OldStore) andalso new_pid(damage_ipfs_client, OldClient) andalso
                is_pid(whereis(damage_ipfs_peers))
        end),
        ?assertMatch({ok, #{desired := unpinned}}, damage_ipfs:pin_status(<<"PinA">>)),
        ?assertEqual(
            {ok, #{feature_cid => <<"FeatureCid">>}}, damage_ipfs_store:get_metadata(<<"PinA">>)
        ),
        %% Restarting a late child must not disturb the client/store.
        Client = whereis(damage_ipfs_client),
        Peer = whereis(damage_ipfs_peers),
        exit(Peer, kill),
        await(fun() -> new_pid(damage_ipfs_peers, Peer) end),
        ?assertEqual(Client, whereis(damage_ipfs_client)),
        ?assertEqual(
            {ok, scheduled},
            damage_ipfs_peers:set_peers([
                <<"/ip4/127.0.0.1/tcp/4001/p2p/SelfPeer">>,
                <<"/ip4/127.0.0.2/tcp/4001/p2p/RemotePeer">>
            ])
        ),
        await(fun() ->
            lists:member(
                {connect, <<"/ip4/127.0.0.2/tcp/4001/p2p/RemotePeer">>},
                damage_ipfs_test_backend:calls()
            )
        end),
        ?assertNot(
            lists:member(
                {connect, <<"/ip4/127.0.0.1/tcp/4001/p2p/SelfPeer">>},
                damage_ipfs_test_backend:calls()
            )
        ),
        Asset = filename:join(Dir, "asset.feature"),
        ?assertMatch({error, _}, damage_ipfs:ensure_ipfs_asset(<<"missing">>, Asset)),
        ?assertNot(filelib:is_file(Asset)),
        ?assertEqual(ok, damage_ipfs:ensure_ipfs_asset(<<"FeatureCid">>, Asset)),
        ?assertMatch({ok, _}, file:read_file(Asset)),
        ok = file:delete(Asset)
    after
        stop(Sup),
        stop(Fake),
        clean_dir(Dir)
    end.

store_restart_test_() ->
    {timeout, 10, fun() ->
        Dir = temp_dir(),
        C = damage_ipfs_config:normalize([{data_dir, Dir}]),
        {ok, S} = damage_ipfs_store:start_link(C),
        unlink(S),
        {ok, #{revision := Rev}} = damage_ipfs_store:desire(<<"DurableCid">>, pinned),
        stop(S),
        {ok, S2} = damage_ipfs_store:start_link(C),
        unlink(S2),
        try
            ?assertMatch(
                {ok, <<"DurableCid">>, #{revision := Rev, status := pending}},
                damage_ipfs_store:next_pending()
            ),
            ?assertEqual(ok, damage_ipfs_store:complete(<<"DurableCid">>, Rev, {ok, done})),
            ?assertEqual(empty, damage_ipfs_store:next_pending())
        after
            stop(S2),
            clean_dir(Dir)
        end
    end}.

applied(Cid, Desired) ->
    case damage_ipfs:pin_status(Cid) of
        {ok, #{status := applied, desired := Desired}} -> true;
        _ -> false
    end.
new_pid(Name, Old) ->
    P = whereis(Name),
    is_pid(P) andalso P =/= Old.
await(F) -> await(F, erlang:monotonic_time(millisecond) + 5000).
await(F, Deadline) ->
    case F() of
        true ->
            ok;
        false ->
            case erlang:monotonic_time(millisecond) < Deadline of
                true ->
                    timer:sleep(10),
                    await(F, Deadline);
                false ->
                    error(await_timeout)
            end
    end.
stop(P) ->
    case is_process_alive(P) of
        false ->
            ok;
        true ->
            try
                gen_server:stop(P, normal, 5000)
            catch
                exit:_ -> ok
            end
    end.
temp_dir() ->
    Dir = filename:join(
        "/tmp",
        "damage-ipfs-test-" ++
            integer_to_list(erlang:unique_integer([positive, monotonic]))
    ),
    ok = file:make_dir(Dir),
    Dir.
clean_dir(Dir) ->
    %% Explicit test-owned files only; never recursively delete caller paths.
    _ = file:delete(filename:join(Dir, "pin_intents.dets")),
    _ = file:del_dir(Dir),
    ok.
