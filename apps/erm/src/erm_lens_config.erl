%%% Configuration validation before any optional Lens workers are started.
-module(erm_lens_config).
-export([normalize/1, integer/5, relay/1]).

normalize(C0) ->
    try
        C1 = case C0 of
            M when is_map(M) -> M;
            L when is_list(L) -> maps:from_list(L);
            undefined -> #{};
            _ -> throw({bad_lens_config, config})
        end,
        C = maps:merge(erm_lens:defaults(), C1),
        lists:foreach(fun({K, Min, Max}) ->
            V = maps:get(K, C),
            require(is_integer(V) andalso V >= Min andalso V =< Max, K)
        end, [
            {window_seconds, 1, 604800}, {refresh_ms, 30000, 3600000},
            {max_events, 1, 20000}, {max_store_bytes, 262144, 268435456},
            {page_size, 1, 12}, {relay_backoff_ms, 1000, 3600000},
            {relay_backoff_max_ms, 1000, 3600000}
        ]),
        lists:foreach(fun(K) ->
            require(is_boolean(maps:get(K, C)), K)
        end, [enabled, show_on_start, load_images, allow_mainnet]),
        require(maps:get(relay_backoff_max_ms, C) >= maps:get(relay_backoff_ms, C),
                relay_backoff_max_ms),
        Relays = maps:get(relays, C),
        require(is_list(Relays) andalso length(Relays) =< 32, relays),
        require(lists:all(fun relay/1, Relays), relays),
        lists:foreach(fun(K) ->
            Keys = maps:get(K, C, []),
            require(is_list(Keys) andalso length(Keys) =< 4096 andalso
                    lists:all(fun(P) -> erm_lens_nostr:is_hex(P, 64) end, Keys), K)
        end, [muted, following]),
        Hosts = maps:get(media_hosts, C, []),
        require(is_list(Hosts) andalso length(Hosts) =< 128 andalso
                lists:all(fun host_string/1, Hosts), media_hosts),
        lists:foreach(fun(K) -> require(path_string(maps:get(K, C)), K) end,
                      [media_script, cache_dir]),
        {ok, C}
    catch
        throw:{bad_lens_config, _} = Reason -> {error, Reason};
        _:_ -> {error, {bad_lens_config, config}}
    end.

require(true, _) -> ok;
require(false, Key) -> throw({bad_lens_config, Key}).

relay(B) when is_binary(B), byte_size(B) > 0, byte_size(B) =< 4096 ->
    try
        #{scheme := <<"wss">>, host := H} = U = uri_string:parse(B),
        P = maps:get(port, U, 443),
        byte_size(H) > 0 andalso byte_size(H) =< 253 andalso
        not maps:is_key(userinfo, U) andalso not maps:is_key(fragment, U) andalso
        is_integer(P) andalso P > 0 andalso P =< 65535 andalso
        lists:all(fun(X) -> X > 32 andalso X =/= 127 end, binary_to_list(B))
    catch _:_ -> false end;
relay(_) -> false.

%% Internal fallbacks protect individual workers started directly in tests or
%% development; public start/start_link reject invalid config instead.
integer(Key, C, Default, Min, Max) ->
    case maps:get(Key, C, Default) of
        N when is_integer(N), N >= Min, N =< Max -> N;
        _ -> Default
    end.

host_string(B) when is_binary(B), byte_size(B) > 0, byte_size(B) =< 253 -> true;
host_string(L) when is_list(L), length(L) > 0, length(L) =< 253 ->
    lists:all(fun(X) -> is_integer(X) andalso X > 0 end, L);
host_string(_) -> false.

path_string(B) when is_binary(B), byte_size(B) > 0, byte_size(B) =< 4096 ->
    binary:match(B, <<0>>) =:= nomatch andalso is_list(unicode:characters_to_list(B));
path_string(L) when is_list(L), length(L) > 0, length(L) =< 4096 ->
    lists:all(fun(X) -> is_integer(X) andalso X > 0 andalso X =< 16#10ffff end, L);
path_string(_) -> false.
