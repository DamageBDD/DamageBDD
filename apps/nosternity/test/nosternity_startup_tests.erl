-module(nosternity_startup_tests).
-include_lib("eunit/include/eunit.hrl").

disabled_app_test() ->
    %% Inactive options need not be valid, and pools must not be instantiated.
    with_env([{enabled, false}, {ip, invalid}, {http_enabled, invalid},
              {pools, [{nonexistent_pool, [], []}]}], fun() ->
        {ok, Sup} = nosternity_app:start(normal, []),
        unlink(Sup),
        try
            ?assertEqual([], supervisor:which_children(Sup)),
            ?assertEqual(ok, nosternity_app:start_phase(start_trails_http, normal, [])),
            ?assertEqual(ok, nosternity_app:start_phase(os_tune, normal, [])),
            ?assertEqual(undefined, whereis(nosternity_relay)),
            ?assertEqual(undefined, whereis(nosternity_event_store)),
            ?assertEqual(ok, nosternity_app:stop(undefined))
        after gen_server:stop(Sup, normal, 30000) end
    end).

invalid_listener_config_fails_start_test() ->
    with_env([{enabled, true}, {ip, "0.0.0.0"}], fun() ->
        ?assertEqual({error, {invalid_configuration, ip}},
            nosternity_app:start(normal, [])),
        ?assertEqual(undefined, whereis(nosternity_sup))
    end).

legacy_signer_gate_test() ->
    with_env([{enabled, true}, {nostr_clients_enabled, false}, {pools, []}], fun() ->
        {ok, {_, SearchOnly}} = nosternity_sup:init([]),
        ?assertEqual([nosternity_event_store, nosternity_relay], ids(SearchOnly)),
        application:set_env(nosternity, nostr_clients_enabled, true),
        {ok, {_, WithSigners}} = nosternity_sup:init([]),
        ?assertEqual([nosternity_event_store, nosternity_relay,
            nosternity_nostr, inglorious_nostr], ids(WithSigners))
    end).

http_disabled_keeps_relay_test() ->
    Dir = temp_dir("nosternity-startup-"),
    with_env([{enabled, true}, {http_enabled, false}, {nostr_clients_enabled, false},
              {pools, []}, {ae_event_store_enabled, false},
              {ae_event_store_rehydrate, false},
              {search_store_file, filename:join(Dir, "events.dets")}], fun() ->
        {ok, Sup} = nosternity_app:start(normal, []),
        unlink(Sup),
        try
            Children = supervisor:which_children(Sup),
            ?assertEqual(2, length(Children)),
            ?assert(is_pid(whereis(nosternity_relay))),
            ?assert(is_pid(whereis(nosternity_event_store))),
            ?assertEqual(undefined, whereis(nosternity_nostr)),
            ?assertEqual(undefined, whereis(inglorious_nostr)),
            ?assertEqual(ok, nosternity_app:start_phase(start_trails_http, normal, [])),
            ?assertMatch(#{events := 0}, nosternity_relay:status()),
            ?assertEqual(ok, nosternity_app:stop(undefined))
        after
            gen_server:stop(Sup, normal, 30000),
            file:del_dir_r(Dir)
        end
    end).

listener_options_and_lifecycle_test() ->
    {ok, _} = application:ensure_all_started(cowboy),
    {ok, _} = application:ensure_all_started(gun),
    with_env([{ip, {127, 0, 0, 1}}, {port, 0}, {http_num_acceptors, 2},
              {http_max_connections, 17}, {http_idle_timeout_ms, 12000},
              {http_request_timeout_ms, 7000}], fun() ->
        Dispatch = cowboy_router:compile([{'_', []}]),
        try
            ?assertEqual(ok, nosternity_app:start_listener(Dispatch)),
            Port = ranch:get_port(http_nosternity),
            ?assert(Port > 0),
            ?assertEqual({{127, 0, 0, 1}, Port}, ranch:get_addr(http_nosternity)),
            Transport = ranch:get_transport_options(http_nosternity),
            ?assertEqual(2, maps:get(num_acceptors, Transport)),
            ?assertEqual(1, maps:get(num_conns_sups, Transport)),
            ?assertEqual(17, maps:get(max_connections, Transport)),
            Protocol = ranch:get_protocol_options(http_nosternity),
            ?assertEqual(12000, maps:get(idle_timeout, Protocol)),
            ?assertEqual(7000, maps:get(request_timeout, Protocol)),
            ?assertEqual([cowboy_telemetry_h, cowboy_metrics_h, cowboy_stream_h],
                maps:get(stream_handlers, Protocol)),
            %% A repeated phase must not replace or stop the running listener.
            ?assertEqual(ok, nosternity_app:start_listener(Dispatch)),
            ?assertEqual(Port, ranch:get_port(http_nosternity)),
            ?assertEqual(ok, nosternity_app:stop(undefined)),
            ?assertEqual(ok, nosternity_app:stop(undefined)),
            ?assert(lists:keymember(gun, 1, application:which_applications()))
        after nosternity_app:stop(undefined) end
    end).

listener_bind_error_test() ->
    {ok, _} = application:ensure_all_started(cowboy),
    {ok, Socket} = gen_tcp:listen(0, [{ip, {127, 0, 0, 1}}]),
    {ok, {_, Port}} = inet:sockname(Socket),
    try
        with_env([{ip, {127, 0, 0, 1}}, {port, Port}], fun() ->
            Dispatch = cowboy_router:compile([{'_', []}]),
            ?assertMatch({error, {http_listener_start_failed, _}},
                nosternity_app:start_listener(Dispatch))
        end)
    after
        gen_tcp:close(Socket),
        nosternity_app:stop(undefined)
    end.

ipv6_listener_options_test() ->
    with_env([{ip, {0, 0, 0, 0, 0, 0, 0, 1}}, {port, 0}], fun() ->
        #{socket_opts := SocketOpts} = nosternity_app:transport_options(),
        ?assert(lists:member(inet6, SocketOpts)),
        ?assertEqual({0, 0, 0, 0, 0, 0, 0, 1}, proplists:get_value(ip, SocketOpts))
    end).

ids(Specs) -> [maps:get(id, Spec) || Spec <- Specs].

temp_dir(Prefix) ->
    Tmp = case os:getenv("TMPDIR") of false -> "/tmp"; Value -> Value end,
    filename:join(Tmp, Prefix ++ integer_to_list(erlang:unique_integer([positive, monotonic]))).

with_env(Values, Fun) ->
    Saved = [{K, application:get_env(nosternity, K)} || {K, _} <- Values],
    lists:foreach(fun({K, V}) -> application:set_env(nosternity, K, V) end, Values),
    try Fun()
    after
        lists:foreach(fun
            ({K, undefined}) -> application:unset_env(nosternity, K);
            ({K, {ok, V}}) -> application:set_env(nosternity, K, V)
        end, Saved)
    end.
