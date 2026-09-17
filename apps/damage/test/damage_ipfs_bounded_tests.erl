%% Real Gun + ephemeral loopback HTTP peer; no Kubo, chain or external network.
%% Run sequentially: the public-API tests temporarily set ipfs_runtime and
%% restore its previous value even when the check raises.
-module(damage_ipfs_bounded_tests).
-include_lib("eunit/include/eunit.hrl").

%% IPFS transport tests must not depend on release-domain fixture modules.
cid() -> <<"QmXsQVyTPVPgzHxinfiaj7Vzf9SrWVkkGNAHNfdm8RtJXS">>.
config(Port) -> #{ipfs_api => "http://127.0.0.1:" ++ integer_to_list(Port),
    request_timeout_ms => 1000}.
collect(Data, Acc) -> [Data | Acc].

%% Diagnose an incomplete refactor or a shadowing/stale BEAM explicitly.
%% Production helpers must be exported normally; the last three helpers are
%% deliberately visible only when rebar3 compiles the TEST profile.
api_contract_test() ->
    ensure_api().

ensure_api() ->
    case code:ensure_loaded(damage_ipfs) of
        {module, damage_ipfs} ->
            Required = [
                %% Existing facade entrypoints must remain available.
                {cat, 1}, {cat_binary, 1}, {get, 1}, {get, 2},
                {add, 1}, {pin, 1}, {fetch_to, 2}, {ensure_ipfs_asset, 2},
                %% Shared API used by release discovery and publication.
                {cat_binary, 2}, {cat_json, 2}, {cat_fold, 4}, {sha256, 2},
                {decode_json, 2}, {valid_cid, 1}, {valid_relative_path, 1},
                %% TEST-only entrypoints for the local HTTP fixture.
                {cat_fold_config, 5}, {local_endpoint, 1}, {cid_path, 1}
            ],
            Exports = damage_ipfs:module_info(exports),
            Missing = [FA || FA <- Required, not lists:member(FA, Exports)],
            case Missing of
                [] -> ok;
                _ -> error({missing_damage_ipfs_api, #{
                    beam => code:which(damage_ipfs),
                    compiled_source => proplists:get_value(source,
                        damage_ipfs:module_info(compile)),
                    test_beam => code:which(?MODULE),
                    candidates => beam_candidates(damage_ipfs),
                    missing_exports => Missing
                }})
            end;
        {error, Reason} ->
            error({damage_ipfs_not_loadable, Reason})
    end.

%% Diagnostic only: do not hot-load a different implementation to make a test
%% pass. The fresh-source runner builds and verifies its own isolated test VM.
beam_candidates(Module) ->
    Name = atom_to_list(Module) ++ ".beam",
    lists:usort([filename:absname(File) || Dir <- code:get_path(),
        File <- [filename:join(Dir, Name)], filelib:is_regular(File)]).

path_validation_test() ->
    Cid = cid(),
    Expected = <<Cid/binary, "/damage.deb">>,
    ?assertEqual(Expected, damage_ipfs:cid_path(<<"ipfs://", Expected/binary>>)),
    ?assertEqual(Expected, damage_ipfs:cid_path(<<"/ipfs/", Expected/binary>>)),
    ?assertEqual(Cid, damage_ipfs:cid_path(Cid)).

unsafe_path_test_() ->
    [?_assertThrow({ipfs_error, invalid_ipfs_path}, damage_ipfs:cid_path(P)) || P <- [
        <<>>, <<"https://gateway.example/ipfs/", (cid())/binary>>,
        <<(cid())/binary, "/../secret">>, <<(cid())/binary, "/%2e%2e/secret">>,
        <<(cid())/binary, "/dir//file">>, <<(cid())/binary, "/./file">>,
        <<(cid())/binary, "/file?x=y">>, <<(cid())/binary, "/">>
    ]].

local_endpoint_test() ->
    ?assertEqual({{127,0,0,1}, 5001}, damage_ipfs:local_endpoint(config(5001))),
    ?assertEqual({{127,0,0,1}, 5001}, damage_ipfs:local_endpoint(
        #{ipfs_api => <<"http://127.0.0.1:5001/api/v0/">>})),
    ?assertThrow({ipfs_error, ipfs_api_must_be_loopback},
        damage_ipfs:local_endpoint(#{ipfs_api => <<"http://example.com:5001">>})),
    ?assertThrow({ipfs_error, invalid_ipfs_api},
        damage_ipfs:local_endpoint(#{ipfs_api => <<"http://user:secret@127.0.0.1:5001">>})),
    ?assertThrow({ipfs_error, invalid_ipfs_api},
        damage_ipfs:local_endpoint(#{ipfs_api => <<"http://127.0.0.1:5001/other">>})).

invalid_read_options_test() ->
    ?assertEqual({error, invalid_ipfs_limit}, damage_ipfs:cat_fold_config(
        cid(), fun collect/2, [], [{max_bytes, -1}], config(5001))),
    ?assertEqual({error, invalid_ipfs_timeout}, damage_ipfs:cat_fold_config(
        cid(), fun collect/2, [], [{timeout, infinity}], config(5001))),
    ?assertEqual({error, invalid_ipfs_read_options}, damage_ipfs:cat_fold_config(
        cid(), fun collect/2, [], [{max_bytes, 1}, {max_bytes, 2}], config(5001))),
    ?assertEqual({error, invalid_ipfs_read_options}, damage_ipfs:cat_fold_config(
        cid(), fun collect/2, [], [{proxy, direct}], config(5001))).

json_limits_test() ->
    ?assertEqual({ok, #{<<"x">> => 1}},
        damage_ipfs:decode_json(<<"{\"x\":1}">>, [{max_bytes, 7}])),
    ?assertEqual({error, ipfs_object_too_large},
        damage_ipfs:decode_json(<<"{\"x\":1}">>, [{max_bytes, 6}])),
    ?assertEqual({ok, [1,2]}, damage_ipfs:decode_json(<<"[1,2]">>, [])),
    ?assertEqual({error, invalid_ipfs_json}, damage_ipfs:decode_json(<<"{">>, [])).

shared_backend_json_test() ->
    %% A nested object and array must retain the backend's binary-key result.
    Json = <<"{\"x\":[1,{\"y\":true}],\"z\":null}">>,
    Expected = {ok, #{<<"x">> => [1, #{<<"y">> => true}], <<"z">> => null}},
    ?assertEqual(Expected, damage_ipfs_backend:decode_json(Json)),
    ?assertEqual(Expected, damage_ipfs:decode_json(Json, [])),
    ?assertEqual({error, invalid_json}, damage_ipfs_backend:decode_json(<<"{">>)),
    ?assertEqual({error, invalid_ipfs_json}, damage_ipfs:decode_json(<<"{">>, [])),
    ?assertEqual({error, ipfs_object_too_large},
        damage_ipfs:decode_json(Json, [{max_bytes, 1}])).

%% Exercise production exports through the actual shared config loader, not
%% only TEST helpers. The fixture never starts Damage or contacts real Kubo.
public_binary_test() ->
    with_peer(fun(Sock) ->
        gen_tcp:send(Sock, <<"HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\ntest">>)
    end, fun(Config, _, _) ->
        with_runtime_config(Config, fun() ->
            ?assertEqual({ok, <<"test">>}, damage_ipfs:cat_binary(
                cid(), [{max_bytes, 4}, {timeout, 1000}]))
        end)
    end).

public_json_test() ->
    with_peer(fun(Sock) ->
        gen_tcp:send(Sock, <<"HTTP/1.1 200 OK\r\nContent-Length: 7\r\n\r\n{\"x\":1}">>)
    end, fun(Config, _, _) ->
        with_runtime_config(Config, fun() ->
            ?assertEqual({ok, #{<<"x">> => 1}}, damage_ipfs:cat_json(
                cid(), [{max_bytes, 7}, {timeout, 1000}]))
        end)
    end).

public_sha256_test() ->
    with_peer(fun(Sock) ->
        gen_tcp:send(Sock, <<"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n",
            "2\r\nte\r\n2\r\nst\r\n0\r\n\r\n">>)
    end, fun(Config, _, _) ->
        with_runtime_config(Config, fun() ->
            Expected = string:lowercase(binary:encode_hex(crypto:hash(sha256, <<"test">>))),
            ?assertEqual({ok, Expected}, damage_ipfs:sha256(
                cid(), [{max_bytes, 4}, {timeout, 1000}]))
        end)
    end).

public_oversized_body_test() ->
    with_peer(fun(Sock) ->
        gen_tcp:send(Sock, <<"HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\ntests">>)
    end, fun(Config, _, _) ->
        with_runtime_config(Config, fun() ->
            ?assertEqual({error, ipfs_object_too_large}, damage_ipfs:cat_binary(
                cid(), [{max_bytes, 4}, {timeout, 1000}]))
        end)
    end).

public_error_trailer_test() ->
    with_peer(fun(Sock) ->
        gen_tcp:send(Sock, <<"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n",
            "Trailer: X-Stream-Error\r\n\r\n4\r\ntest\r\n0\r\n",
            "X-Stream-Error: failed\r\n\r\n">>)
    end, fun(Config, _, _) ->
        with_runtime_config(Config, fun() ->
            ?assertEqual({error, ipfs_read_failed}, damage_ipfs:sha256(
                cid(), [{max_bytes, 4}, {timeout, 1000}]))
        end)
    end).

runtime_config_restored_test() ->
    Before = application:get_env(damage, ipfs_runtime),
    ?assertError(expected_config_failure, with_runtime_config(config(5001),
        fun() -> error(expected_config_failure) end)),
    ?assertEqual(Before, application:get_env(damage, ipfs_runtime)).

with_runtime_config(Config, Check) ->
    Before = application:get_env(damage, ipfs_runtime),
    %% Public configuration remains a list of tuples, not a map.
    ok = application:set_env(damage, ipfs_runtime, maps:to_list(Config)),
    try Check()
    after
        case Before of
            {ok, Old} -> application:set_env(damage, ipfs_runtime, Old);
            undefined -> application:unset_env(damage, ipfs_runtime)
        end
    end.

bounded_read_test() ->
    with_peer(fun(Sock) ->
        gen_tcp:send(Sock, <<"HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\ntest">>)
    end, fun(Config, Peer, Tag) ->
        {ok, Chunks} = damage_ipfs:cat_fold_config(cid(), fun collect/2, [],
            [{max_bytes, 4}], Config),
        ?assertEqual(<<"test">>, iolist_to_binary(lists:reverse(Chunks))),
        receive {Tag, request, Peer, Req} ->
            ?assertNotEqual(nomatch, binary:match(Req, <<"POST /api/v0/cat?">>)),
            ?assertNotEqual(nomatch, binary:match(Req, <<"length=5">>))
        after 1000 -> error(missing_request) end
    end).

empty_body_test() ->
    with_peer(fun(Sock) ->
        gen_tcp:send(Sock, <<"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n">>)
    end, fun(Config, _, _) ->
        ?assertEqual({ok, []}, damage_ipfs:cat_fold_config(cid(), fun collect/2, [],
            [{max_bytes, 0}], Config))
    end).

oversized_body_test() ->
    with_peer(fun(Sock) ->
        gen_tcp:send(Sock, <<"HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\ntests">>)
    end, fun(Config, _, _) ->
        ?assertEqual({error, ipfs_object_too_large}, damage_ipfs:cat_fold_config(
            cid(), fun collect/2, [], [{max_bytes, 4}], Config))
    end).

streamed_digest_test() ->
    with_peer(fun(Sock) ->
        gen_tcp:send(Sock, <<"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n",
            "2\r\nte\r\n2\r\nst\r\n0\r\n\r\n">>)
    end, fun(Config, _, _) ->
        {ok, State} = damage_ipfs:cat_fold_config(cid(),
            fun(Data, Acc) -> crypto:hash_update(Acc, Data) end,
            crypto:hash_init(sha256), [{max_bytes, 4}], Config),
        ?assertEqual(crypto:hash(sha256, <<"test">>), crypto:hash_final(State))
    end).

error_trailer_test() ->
    with_peer(fun(Sock) ->
        gen_tcp:send(Sock, <<"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n",
            "Trailer: X-Stream-Error\r\n\r\n4\r\ntest\r\n0\r\n",
            "X-Stream-Error: failed\r\n\r\n">>)
    end, fun(Config, _, _) ->
        ?assertEqual({error, ipfs_read_failed}, damage_ipfs:cat_fold_config(
            cid(), fun collect/2, [], [{max_bytes, 4}], Config))
    end).

truncated_body_test() ->
    with_peer(fun(Sock) ->
        gen_tcp:send(Sock, <<"HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nab">>)
    end, fun(Config, _, _) ->
        ?assertEqual({error, ipfs_read_failed}, damage_ipfs:cat_fold_config(
            cid(), fun collect/2, [], [{max_bytes, 5}], Config))
    end).

redirect_is_not_followed_test() ->
    with_peer(fun(Sock) ->
        gen_tcp:send(Sock, <<"HTTP/1.1 302 Found\r\nContent-Length: 0\r\n",
            "Location: https://example.invalid/\r\n\r\n">>)
    end, fun(Config, _, _) ->
        ?assertEqual({error, ipfs_read_failed}, damage_ipfs:cat_fold_config(
            cid(), fun collect/2, [], [], Config))
    end).

finite_deadline_test() ->
    with_peer(fun(_Sock) -> receive never -> ok after 1000 -> ok end end,
    fun(Config, _, _) ->
        ?assertEqual({error, ipfs_timeout}, damage_ipfs:cat_fold_config(
            cid(), fun collect/2, [], [{timeout, 30}], Config))
    end).

%% Deadline regression: receiving the complete response does not give Fold/2
%% unlimited time. A final-chunk callback and an indefinitely blocked callback
%% must both be cancelled, with the socket closed and no callback surviving.
slow_final_callback_test_() ->
    {timeout, 10, fun() -> assert_callback_timeout(slow) end}.

blocked_callback_test_() ->
    {timeout, 10, fun() -> assert_callback_timeout(blocked) end}.

assert_callback_timeout(Mode) ->
    Parent = self(), Probe = make_ref(),
    FlagsBefore = process_info(self(), trap_exit),
    with_peer(fun(Sock) ->
        ok = gen_tcp:send(Sock,
            <<"HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\nx">>),
        Parent ! {Probe, socket_closed, gen_tcp:recv(Sock, 0, 3000)}
    end, fun(Config, _, _) ->
        Fold = fun(Data, Acc) ->
            Parent ! {Probe, callback, self()},
            case Mode of
                slow -> timer:sleep(5000);
                blocked -> receive never_resume -> ok end
            end,
            Parent ! {Probe, callback_survived},
            [Data | Acc]
        end,
        Started = erlang:monotonic_time(millisecond),
        ?assertEqual({error, ipfs_timeout}, damage_ipfs:cat_fold_config(
            cid(), Fold, [], [{timeout, 500}], Config)),
        ?assert(erlang:monotonic_time(millisecond) - Started < 2500),
        receive {Probe, callback, Worker} ->
            ?assertNotEqual(self(), Worker),
            ?assertNot(is_process_alive(Worker))
        after 1000 -> error(callback_not_started)
        end,
        receive {Probe, socket_closed, Closed} ->
            ?assertEqual({error, closed}, Closed)
        after 3500 -> error(socket_not_closed_after_timeout)
        end,
        receive {Probe, callback_survived} -> error(callback_not_cancelled)
        after 0 -> ok
        end,
        ?assertEqual(FlagsBefore, process_info(self(), trap_exit))
    end).

caller_exit_cancels_callback_test_() ->
    {timeout, 10, fun() ->
        Parent = self(), Probe = make_ref(),
        with_peer(fun(Sock) ->
            ok = gen_tcp:send(Sock,
                <<"HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\nx">>),
            Parent ! {Probe, socket_closed, gen_tcp:recv(Sock, 0, 3000)}
        end, fun(Config, _, _) ->
            {Caller, CallerMon} = spawn_monitor(fun() ->
                damage_ipfs:cat_fold_config(cid(), fun(_, _) ->
                    Parent ! {Probe, callback, self()},
                    receive never_resume -> ok end
                end, [], [{timeout, 5000}], Config)
            end),
            try
                receive {Probe, callback, Worker} ->
                    WorkerMon = erlang:monitor(process, Worker),
                    exit(Caller, kill),
                    receive {'DOWN', CallerMon, process, Caller, _} -> ok
                    after 1000 -> error(caller_not_stopped)
                    end,
                    receive {'DOWN', WorkerMon, process, Worker, _} -> ok
                    after 1500 ->
                        erlang:demonitor(WorkerMon, [flush]),
                        error(callback_orphaned)
                    end
                after 2000 -> error(callback_not_started)
                end,
                receive {Probe, socket_closed, Closed} ->
                    ?assertEqual({error, closed}, Closed)
                after 3500 -> error(socket_not_closed_after_caller_exit)
                end
            after
                exit(Caller, kill),
                erlang:demonitor(CallerMon, [flush])
            end
        end)
    end}.

callback_error_test() ->
    with_peer(fun(Sock) ->
        gen_tcp:send(Sock, <<"HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\nx">>)
    end, fun(Config, _, _) ->
        ?assertEqual({error, ipfs_read_failed}, damage_ipfs:cat_fold_config(
            cid(), fun(_, _) -> error(callback_failed) end, [], [], Config))
    end).

%% An exception in the client/check must not leave a blocked acceptor or
%% turn cleanup into an unrelated {badmatch,{error,closed}} error report.
cleanup_before_connection_test() ->
    assert_check_failure_cleanup(fun(_Config) -> ok end).

cleanup_after_request_test() ->
    assert_check_failure_cleanup(fun(Config) ->
        {ok, Chunks} = damage_ipfs:cat_fold_config(
            cid(), fun collect/2, [], [{max_bytes, 4}], Config),
        ?assertEqual(<<"test">>, iolist_to_binary(lists:reverse(Chunks)))
    end).

assert_check_failure_cleanup(BeforeFailure) ->
    Ref = make_ref(),
    ?assertError(expected_check_failure, with_peer(
        fun(Sock) ->
            gen_tcp:send(Sock, <<"HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\ntest">>)
        end,
        fun(Config, Peer, Tag) ->
            BeforeFailure(Config),
            self() ! {Ref, Peer, Tag},
            error(expected_check_failure)
        end)),
    receive
        {Ref, Peer, Tag} ->
            ?assertNot(is_process_alive(Peer)),
            assert_peer_mailbox_clean(Peer, Tag)
    after 1000 ->
        error(missing_peer_identity)
    end.

assert_peer_mailbox_clean(Peer, Tag) ->
    receive
        {Tag, request, Peer, _} -> error(peer_request_leaked);
        {'DOWN', _, process, Peer, _} -> error(peer_monitor_leaked)
    after 0 ->
        ok
    end.

with_peer(Respond, Check) ->
    %% Check the loaded API BEFORE starting Gun/listening: missing code is
    %% an integration error, not an HTTP error or an expected negative test.
    ensure_api(),
    {ok, _} = application:ensure_all_started(crypto),
    {ok, _} = application:ensure_all_started(gun),
    {ok, Listen} = gen_tcp:listen(0, [binary, {packet, raw}, {active, false},
        {reuseaddr, true}, {ip, {127,0,0,1}}]),
    {ok, {_, Port}} = inet:sockname(Listen),
    Parent = self(), Tag = make_ref(),
    {Peer, Monitor} = spawn_monitor(fun() ->
        serve_peer(Listen, Respond, Parent, Tag)
    end),
    try Check(config(Port), Peer, Tag)
    after
        %% Kill and join BEFORE closing the listener. Otherwise its acceptor
        %% can wake with {error,closed} while teardown is still in progress.
        exit(Peer, kill),
        receive {'DOWN', Monitor, process, Peer, _} -> ok after 2000 ->
            erlang:demonitor(Monitor, [flush]) end,
        gen_tcp:close(Listen),
        %% Request messages precede DOWN from this sender, so drain afterward.
        receive {Tag, request, Peer, _} -> ok after 0 -> ok end
    end.

serve_peer(Listen, Respond, Parent, Tag) ->
    case gen_tcp:accept(Listen, 2000) of
        {ok, Sock} ->
            try
                case request_headers(Sock, <<>>) of
                    {ok, Request} ->
                        Parent ! {Tag, request, self(), Request},
                        Respond(Sock);
                    {error, closed} ->
                        ok;
                    {error, Reason} ->
                        error({test_peer_receive_failed, Reason})
                end
            after
                gen_tcp:close(Sock)
            end;
        {error, closed} ->
            ok;
        {error, Reason} ->
            error({test_peer_accept_failed, Reason})
    end.

request_headers(Sock, Acc) ->
    case binary:match(Acc, <<"\r\n\r\n">>) of
        nomatch ->
            case gen_tcp:recv(Sock, 0, 2000) of
                {ok, More} -> request_headers(Sock, <<Acc/binary, More/binary>>);
                {error, _} = Error -> Error
            end;
        _ -> {ok, Acc}
    end.
