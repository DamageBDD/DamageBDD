-module(damage_ipfs_review_tests).
-include_lib("eunit/include/eunit.hrl").

legacy_and_runtime_config_test() ->
    Keys = [ipfs, ipfs_runtime, ipfs_api, ipfs_peers, ipfs_peer_retry_interval],
    Saved = [{K, application:get_env(damage, K)} || K <- Keys],
    try
        [application:unset_env(damage, K) || K <- Keys],
        Legacy = [{"Addresses.Gateway", "/ip4/0.0.0.0/tcp/8082"}],
        application:set_env(damage, ipfs, Legacy),
        application:set_env(damage, ipfs_api, "http://127.0.0.1:5002"),
        application:set_env(damage, ipfs_peer_retry_interval, 4321),
        C0 = damage_ipfs_config:load(),
        ?assertEqual("http://127.0.0.1:5002", maps:get(ipfs_api, C0)),
        ?assertEqual(4321, maps:get(peer_interval_ms, C0)),
        ?assertEqual({ok, Legacy}, application:get_env(damage, ipfs)),
        application:set_env(damage, ipfs_runtime, [
            {ipfs_api, "http://127.0.0.1:5003"}, {client_concurrency, 2}, {client_concurrency, 3}
        ]),
        C1 = damage_ipfs_config:load(),
        ?assertEqual("http://127.0.0.1:5003", maps:get(ipfs_api, C1)),
        ?assertEqual(2, maps:get(client_concurrency, C1)),
        ?assertEqual({ok, Legacy}, application:get_env(damage, ipfs)),
        application:unset_env(damage, ipfs_runtime),
        application:set_env(damage, ipfs, [{client_concurrency, 4}]),
        ?assertEqual(4, maps:get(client_concurrency, damage_ipfs_config:load())),
        application:set_env(damage, ipfs_runtime, [invalid]),
        ?assertError({invalid_ipfs_config, expected_key_value_tuples}, damage_ipfs_config:load()),
        ?assertError(
            {invalid_ipfs_config, reconcile_batch},
            damage_ipfs_config:normalize([{reconcile_batch, 1001}])
        )
    after
        [
            case V of
                undefined -> application:unset_env(damage, K);
                {ok, Value} -> application:set_env(damage, K, Value)
            end
         || {K, V} <- Saved
        ]
    end.

grouping_order_test() ->
    A = addr(<<"PeerA">>, tcp),
    B = addr(<<"PeerA">>, quic),
    C = addr(<<"PeerB">>, tcp),
    Specs = [A, C, [{peer_id, <<"PeerA">>}, {addrs, [B, A]}]],
    ?assertEqual(
        {ok, [
            #{peer_id => <<"PeerA">>, addrs => [A, B]},
            #{peer_id => <<"PeerB">>, addrs => [C]}
        ]},
        damage_ipfs_peers:normalize_groups(Specs)
    ),
    ?assertEqual({ok, [A, B, C]}, damage_ipfs_peers:normalize(Specs)),
    ?assertEqual(
        <<"Target">>,
        damage_ipfs_peers:target_id(
            <<"/ip4/127.0.0.1/tcp/4001/p2p/Relay/p2p-circuit/p2p/Target">>
        )
    ),
    ?assertEqual(
        {error, invalid_peer_spec},
        damage_ipfs_peers:normalize_groups([
            [{peer_id, <<"Wrong">>}, {addrs, [A]}]
        ])
    ).

fallback_success_test_() ->
    {timeout, 10, fun() ->
        with_services(fun(C) ->
            A = addr(<<"PeerA">>, tcp),
            B = addr(<<"PeerA">>, quic),
            %% First succeeds: later broken transports must not be attempted.
            ok = damage_ipfs_review_backend:rules(#{{connect, B} => {error, unsupported_transport}}),
            {ok, S1, _} = damage_ipfs_peers:run(C, peer_state([A, B])),
            ?assertEqual(1, maps:get(connected, S1)),
            ?assertEqual(0, maps:get(failed, S1)),
            ?assertEqual([{connect, A}], connection_calls()),
            %% First fails: try the fallback and report a successful peer, not a failed pass.
            ok = damage_ipfs_review_backend:rules(#{{connect, A} => {error, refused}}),
            {ok, S2, _} = damage_ipfs_peers:run(C, peer_state([A, B])),
            ?assertEqual(1, maps:get(connected, S2)),
            ?assertEqual(0, maps:get(failed, S2)),
            ?assertEqual(1, maps:get(address_failures, S2)),
            ?assertEqual([{connect, A}, {connect, B}], connection_calls()),
            %% An exhausted peer is counted once, and does not stop the next peer.
            Next = addr(<<"PeerB">>, tcp),
            ok = damage_ipfs_review_backend:rules(#{
                {connect, A} => {error, refused},
                {connect, B} => {error, refused}
            }),
            {ok, S3, _} = damage_ipfs_peers:run(C, peer_state([A, B, Next])),
            ?assertEqual(1, maps:get(failed, S3)),
            ?assertEqual(1, maps:get(connected, S3)),
            ?assertEqual([{connect, A}, {connect, B}, {connect, Next}], connection_calls()),
            %% Self filtering applies to the peer, including every transport.
            ok = damage_ipfs_review_backend:rules(#{}),
            {ok, S4, _} = damage_ipfs_peers:run(
                C,
                peer_state([addr(<<"SelfPeer">>, tcp), addr(<<"SelfPeer">>, quic)])
            ),
            ?assertEqual(1, maps:get(skipped_self, S4)),
            ?assertEqual([], connection_calls())
        end)
    end}.

fallback_resume_test_() ->
    {timeout, 10, fun() ->
        with_services(fun(C0) ->
            %% With a 500ms client budget, this leaves 100ms for initiating a pass.
            C = C0#{loop_timeout_ms => 2600},
            A = addr(<<"PeerA">>, tcp),
            B = addr(<<"PeerA">>, quic),
            ok = damage_ipfs_review_backend:rules(#{{connect, A} => {delay, 180, {error, refused}}}),
            {ok, First, D1} = damage_ipfs_peers:run(C, peer_state([A, B])),
            ?assertEqual(true, maps:get(partial, First)),
            ?assertEqual(1, maps:get(addr_cursor, D1)),
            {ok, Second, D2} = damage_ipfs_peers:run(C0, D1),
            ?assertEqual(1, maps:get(connected, Second)),
            ?assertEqual(0, maps:get(addr_cursor, D2)),
            ?assertEqual([{connect, A}, {connect, B}], connection_calls())
        end)
    end}.

reconciliation_progress_test_() ->
    {timeout, 10, fun() ->
        with_services(fun(C0) ->
            C = C0#{reconcile_batch => 1},
            A = <<"ACid">>,
            B = <<"BCid">>,
            D = <<"CCid">>,
            RevA = seed(A),
            _ = seed(B),
            _ = seed(D),
            ok = damage_ipfs_review_backend:rules(#{
                {pin_check, A} => {error, broken_response},
                {pin_check, B} => {ok, false}
            }),
            {ok, First, Cursor1} = damage_ipfs_reconciler:run(C, start),
            ?assertEqual(A, Cursor1),
            ?assertEqual(1, maps:get(failed, First)),
            ?assertEqual(false, maps:get(backoff, First)),
            {ok, RA} = damage_ipfs_store:lookup(A),
            ?assertEqual(applied, maps:get(status, RA)),
            ?assertEqual(1, maps:get(verify_attempts, RA)),
            ?assert(maps:get(verify_next_at, RA) > damage_ipfs_config:now_ms()),
            {ok, Second, Cursor2} = damage_ipfs_reconciler:run(C, Cursor1),
            ?assertEqual(1, maps:get(missing, Second)),
            ?assertMatch({ok, #{status := pending}}, damage_ipfs_store:lookup(B)),
            {ok, Third, start} = damage_ipfs_reconciler:run(C, Cursor2),
            ?assertEqual(1, maps:get(checked, Third)),
            %% Failed A is deferred locally; it cannot abort the next sweep.
            {ok, Deferred, A} = damage_ipfs_reconciler:run(C, start),
            ?assertEqual(1, maps:get(deferred, Deferred)),
            ?assertEqual(
                1, length([ok || {pin_check, X} <- damage_ipfs_review_backend:calls(), X =:= A])
            ),
            %% An in-flight old check cannot overwrite a newer user decision.
            {ok, #{revision := Rev2}} = damage_ipfs_store:desire(A, unpinned),
            ?assertEqual(
                {error, stale_revision}, damage_ipfs_store:verification_result(A, RevA, ok)
            ),
            ?assertMatch(
                {ok, #{desired := unpinned, revision := Rev2, status := pending}},
                damage_ipfs_store:lookup(A)
            )
        end)
    end}.

verification_retry_persistence_test_() ->
    {timeout, 10, fun() ->
        with_services(fun(C) ->
            A = <<"DurableCid">>,
            Rev = seed(A),
            ok = damage_ipfs_store:verification_result(A, Rev, {error, temporarily_unavailable}),
            {ok, Before} = damage_ipfs_store:lookup(A),
            stop(whereis(damage_ipfs_store)),
            {ok, Store2} = damage_ipfs_store:start_link(C),
            unlink(Store2),
            try
                ?assertEqual({ok, Before}, damage_ipfs_store:lookup(A)),
                ok = damage_ipfs_store:verification_result(A, Rev, ok),
                ?assertMatch(
                    {ok, #{
                        verify_attempts := 0,
                        verify_next_at := 0,
                        last_verify_error := undefined
                    }},
                    damage_ipfs_store:lookup(A)
                )
            after
                stop(Store2)
            end
        end)
    end}.

per_item_backoff_keeps_scan_interval_test_() ->
    {timeout, 10, fun() ->
        C = config("unused"),
        {ok, P} = damage_ipfs_loop:start_link(
            damage_ipfs_review_loop,
            damage_ipfs_review_backend,
            1000,
            C,
            marker
        ),
        unlink(P),
        try
            await(fun() ->
                S = sys:get_state(P),
                maps:get(failures, S) > 0 andalso maps:get(running, S) =:= undefined
            end),
            S = sys:get_state(P),
            {Timer, _} = maps:get(timer, S),
            Remaining = erlang:read_timer(Timer),
            ?assert(is_integer(Remaining) andalso Remaining =< 1000),
            ?assertEqual(marker, damage_ipfs_loop:data(damage_ipfs_review_loop))
        after
            stop(P)
        end
    end}.

queue_cleanup_test_() ->
    {timeout, 10, fun() ->
        C = damage_ipfs_config:normalize([{request_timeout_ms, 250}]),
        {ok, Q} = damage_ipfs_queue:start_link(
            damage_ipfs_review_queue,
            damage_ipfs_review_backend,
            1,
            0,
            C
        ),
        unlink(Q),
        try
            ?assertMatch(
                {error, {worker_down, _}},
                damage_ipfs_queue:request(damage_ipfs_review_queue, crash)
            ),
            Parent = self(),
            Caller = spawn(fun() ->
                Parent !
                    {done,
                        damage_ipfs_queue:request(
                            damage_ipfs_review_queue,
                            {hold, 5000, Parent}
                        )}
            end),
            W =
                receive
                    {backend_worker, Worker} -> Worker
                after 1000 -> error(no_worker)
                end,
            ?assertEqual(
                {error, overloaded}, damage_ipfs_queue:request(damage_ipfs_review_queue, {echo, x})
            ),
            exit(Caller, kill),
            await(fun() -> not is_process_alive(W) end),
            await(fun() ->
                maps:get(active, damage_ipfs_queue:status(damage_ipfs_review_queue)) =:= 0
            end),
            spawn(fun() ->
                Parent !
                    {done,
                        damage_ipfs_queue:request(
                            damage_ipfs_review_queue,
                            {hold, 5000, Parent}
                        )}
            end),
            W2 =
                receive
                    {backend_worker, Worker2} -> Worker2
                after 1000 -> error(no_worker)
                end,
            receive
                {done, R} -> ?assertEqual({error, timeout}, R)
            after 2000 -> error(no_timeout)
            end,
            await(fun() -> not is_process_alive(W2) end),
            ?assertEqual(
                {ok, recovered},
                damage_ipfs_queue:request(damage_ipfs_review_queue, {echo, recovered})
            )
        after
            stop(Q)
        end
    end}.

config(Dir) ->
    damage_ipfs_config:normalize([
        {backend, damage_ipfs_review_backend},
        {data_dir, Dir},
        {request_timeout_ms, 500},
        {loop_timeout_ms, 5000},
        {retry_base_ms, 60000},
        {retry_max_ms, 60000}
    ]).
with_services(F) ->
    with_services(F, fun damage_ipfs_store:start_link/1,
        fun damage_ipfs_client:start_link/1).

%% Start functions are injectable only in this test fixture. They let tests
%% exercise acquisition failures without replacing registered production code.
with_services(F, StartStore, StartClient) ->
    %% Run this suite in an isolated VM, not against a running DamageBDD node.
    Dir = filename:join(
        "/tmp",
        "damage-ipfs-review-" ++ os:getpid() ++ "-" ++
            integer_to_list(erlang:unique_integer([positive, monotonic]))
    ),
    ok = file:make_dir(Dir),
    try
        C = config(Dir),
        with_started(fun damage_ipfs_review_backend:start_link/0, fun(_Backend) ->
            with_started(fun() -> StartStore(C) end, fun(_Store) ->
                with_started(fun() -> StartClient(C) end, fun(_Client) ->
                    F(C)
                end)
            end)
        end)
    after
        _ = file:delete(filename:join(Dir, "pin_intents.dets")),
        _ = file:del_dir(Dir)
    end.

with_started(Start, Use) ->
    {ok, Pid} = Start(),
    try
        unlink(Pid),
        Use(Pid)
    after
        stop(Pid)
    end.

store_start_failure_cleans_backend_test() ->
    Ref = make_ref(), Parent = self(),
    StartStore = fun(C) ->
        Parent ! {Ref, maps:get(data_dir, C), [whereis(damage_ipfs_review_backend)]},
        {error, forced_store_start_failure}
    end,
    ?assertError({badmatch, {error, forced_store_start_failure}},
        with_services(fun(_) -> error(unexpected_use) end, StartStore,
            fun damage_ipfs_client:start_link/1)),
    assert_failed_setup_clean(Ref).

client_start_failure_cleans_store_and_backend_test() ->
    Ref = make_ref(), Parent = self(),
    StartClient = fun(C) ->
        Parent ! {Ref, maps:get(data_dir, C),
            [whereis(damage_ipfs_review_backend), whereis(damage_ipfs_store)]},
        {error, forced_client_start_failure}
    end,
    ?assertError({badmatch, {error, forced_client_start_failure}},
        with_services(fun(_) -> error(unexpected_use) end,
            fun damage_ipfs_store:start_link/1, StartClient)),
    assert_failed_setup_clean(Ref).

client_start_exception_cleans_store_and_backend_test() ->
    Ref = make_ref(), Parent = self(),
    StartClient = fun(C) ->
        Parent ! {Ref, maps:get(data_dir, C),
            [whereis(damage_ipfs_review_backend), whereis(damage_ipfs_store)]},
        error(forced_client_start_exception)
    end,
    ?assertError(forced_client_start_exception,
        with_services(fun(_) -> error(unexpected_use) end,
            fun damage_ipfs_store:start_link/1, StartClient)),
    assert_failed_setup_clean(Ref).

assert_failed_setup_clean(Ref) ->
    receive
        {Ref, Dir, Pids} ->
            lists:foreach(fun(Pid) ->
                ?assert(is_pid(Pid)),
                ?assertNot(is_process_alive(Pid))
            end, Pids),
            ?assertNot(filelib:is_dir(Dir)),
            ?assertEqual(undefined, whereis(damage_ipfs_review_backend)),
            ?assertEqual(undefined, whereis(damage_ipfs_store)),
            ?assertEqual(undefined, whereis(damage_ipfs_client))
    after 1000 -> error(missing_setup_witness)
    end,
    %% The next fixture must be able to acquire the same registered services.
    with_services(fun(_) -> ok end).

seed(Cid) ->
    {ok, #{revision := Rev}} = damage_ipfs_store:desire(Cid, pinned),
    ok = damage_ipfs_store:complete(Cid, Rev, {ok, seeded}),
    Rev.
addr(Id, tcp) -> <<"/ip4/127.0.0.1/tcp/4001/p2p/", Id/binary>>;
addr(Id, quic) -> <<"/ip4/127.0.0.1/udp/4001/quic-v1/p2p/", Id/binary>>.
peer_state(Specs) ->
    {ok, Groups} = damage_ipfs_peers:normalize_groups(Specs),
    #{peers => Groups, cursor => 0, addr_cursor => 0}.
connection_calls() -> [R || {connect, _} = R <- damage_ipfs_review_backend:calls()].
stop(P) when is_pid(P) ->
    case is_process_alive(P) of
        true ->
            try
                gen_server:stop(P, normal, 5000)
            catch
                exit:_ -> ok
            end;
        false ->
            ok
    end.
await(F) -> await(F, erlang:monotonic_time(millisecond) + 3000).
await(F, Deadline) ->
    case F() of
        true ->
            ok;
        false ->
            case erlang:monotonic_time(millisecond) < Deadline of
                true ->
                    timer:sleep(5),
                    await(F, Deadline);
                false ->
                    error(await_timeout)
            end
    end.
