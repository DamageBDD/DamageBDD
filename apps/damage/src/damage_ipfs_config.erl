%% Copyright Steven Joseph. SPDX-License-Identifier: Apache-2.0
-module(damage_ipfs_config).
-export([load/0, normalize/1, call/3, text/1, cid/1, now_ms/0]).

load() -> normalize(application:get_env(damage, ipfs, [])).

%% Public configuration is a list of {Key, Value} tuples. Normalize once at
%% the boundary; maps below are private runtime configuration/state.
normalize(Opts) when is_list(Opts) ->
    case
        lists:all(
            fun
                ({K, _}) when is_atom(K) -> true;
                (_) -> false
            end,
            Opts
        )
    of
        true ->
            %% Match proplists:get_value/3: the first occurrence wins.
            normalize(maps:from_list(lists:reverse(Opts)));
        false ->
            error({invalid_ipfs_config, expected_key_value_tuples})
    end;
normalize(Opts) when is_map(Opts) ->
    Defaults = [
        {ipfs_api, application:get_env(damage, ipfs_api, "http://127.0.0.1:5001")},
        {ipfs_peers, application:get_env(damage, ipfs_peers, [])},
        {peer_interval_ms, application:get_env(damage, ipfs_peer_retry_interval, 30000)},
        {backend, damage_ipfs_backend},
        {data_dir, "data/damage_ipfs"},
        {request_timeout_ms, 50000},
        {connect_timeout_ms, 5000},
        {http_timeout_ms, 15000},
        {client_concurrency, 8},
        {client_queue_limit, 64},
        {fetch_concurrency, 4},
        {fetch_queue_limit, 32},
        {max_request_bytes, 67108864},
        {max_response_bytes, 67108864},
        {max_intents, 100000},
        {pin_poll_ms, 1000},
        {retry_base_ms, 2000},
        {retry_max_ms, 300000},
        {health_interval_ms, 30000},
        {reconcile_interval_ms, 60000},
        {reconcile_batch, 32},
        {max_peers, 128},
        {loop_timeout_ms, 120000},
        {headers, []}
    ],
    C = maps:merge(maps:from_list(Defaults), Opts),
    lists:foreach(
        fun(K) ->
            V = maps:get(K, C),
            case is_integer(V) andalso V > 0 andalso V =< 16#ffffffff of
                true -> ok;
                false -> error({invalid_ipfs_config, K})
            end
        end,
        [
            request_timeout_ms,
            connect_timeout_ms,
            http_timeout_ms,
            client_concurrency,
            fetch_concurrency,
            max_request_bytes,
            max_response_bytes,
            max_intents,
            pin_poll_ms,
            retry_base_ms,
            retry_max_ms,
            health_interval_ms,
            reconcile_interval_ms,
            reconcile_batch,
            max_peers,
            loop_timeout_ms,
            peer_interval_ms
        ]
    ),
    lists:foreach(
        fun(K) ->
            V = maps:get(K, C),
            case is_integer(V) andalso V >= 0 of
                true -> ok;
                false -> error({invalid_ipfs_config, K})
            end
        end,
        [client_queue_limit, fetch_queue_limit]
    ),
    true = maps:get(retry_max_ms, C) >= maps:get(retry_base_ms, C),
    %% Background scans need room to complete at least one client call and
    %% checkpoint before their own deadline expires.
    true = maps:get(loop_timeout_ms, C) > maps:get(request_timeout_ms, C) + 2000,
    Api = string:trim(text(maps:get(ipfs_api, C)), trailing, "/"),
    #{scheme := Scheme, host := _} = Parsed = uri_string:parse(Api),
    true = (Scheme =:= "http" orelse Scheme =:= "https"),
    false = maps:is_key(query, Parsed),
    false = maps:is_key(fragment, Parsed),
    false = maps:is_key(userinfo, Parsed),
    true = is_atom(maps:get(backend, C)),
    C#{ipfs_api => Api, data_dir => text(maps:get(data_dir, C))};
normalize(_) ->
    error({invalid_ipfs_config, expected_key_value_tuples}).

call(Name, Request, Timeout) ->
    try gen_server:call(Name, Request, Timeout) of
        Reply -> Reply
    catch
        exit:{noproc, _} -> {error, not_started};
        exit:{timeout, _} -> {error, timeout};
        exit:{normal, _} -> {error, unavailable};
        exit:{shutdown, _} -> {error, unavailable};
        exit:Reason -> {error, {service_exit, Reason}}
    end.

text(B) when is_binary(B) -> binary_to_list(B);
text(L) when is_list(L) -> L.

%% Guard pin APIs against paths/options and unbounded keys. Kubo performs
%% cryptographic CID validation; this is deliberately NOT a CID decoder.
cid(C) when is_list(C) ->
    try
        cid(iolist_to_binary(C))
    catch
        error:_ -> {error, invalid_cid}
    end;
cid(C) when is_binary(C), byte_size(C) > 0, byte_size(C) =< 512 ->
    case re:run(C, "^[A-Za-z0-9]+$", [{capture, none}]) of
        match -> {ok, C};
        nomatch -> {error, invalid_cid}
    end;
cid(_) ->
    {error, invalid_cid}.

now_ms() -> erlang:system_time(millisecond).
