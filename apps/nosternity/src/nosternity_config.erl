%% Runtime knobs for the listener and bounded search relay. Invalid settings
%% fail startup explicitly instead of quietly choosing a different interface,
%% capacity or policy. Error reasons deliberately exclude configuration values.
-module(nosternity_config).
-compile({no_auto_import, [get/1]}).
-export([get/1, validate/0]).

get(Key) ->
    {Default, Check} = spec(Key),
    Raw = case application:get_env(nosternity, Key) of
        {ok, Configured} -> Configured;
        undefined when is_function(Default, 0) -> Default();
        undefined -> Default
    end,
    Value = normalize(Check, Raw),
    case valid(Check, Value) of
        true when Check =:= path ->
            try damage_config:normalize_path(unicode:characters_to_list(Value))
            catch error:_ -> error({invalid_configuration, Key}) end;
        true -> Value;
        false -> error({invalid_configuration, Key})
    end.

validate() ->
    try
        case get(enabled) of
            false ->
                ok;
            true ->
                lists:foreach(fun get/1, keys()),
                case get(search_default_limit) =< get(search_max_limit) of
                    true -> ok;
                    false -> error({invalid_configuration, search_default_limit})
                end
        end
    catch
        error:{invalid_configuration, _} = Reason -> {error, Reason}
    end.

keys() ->
    [
        data_dir,
        search_store_file,
        dashboard_enabled,
        auth_signup_enabled,
        auth_store_file,
        auth_challenge_ttl_seconds,
        auth_session_ttl_seconds,
        auth_max_challenges,
        auth_max_sessions,
        auth_max_accounts,
        auth_attempts_per_minute,
        http_enabled,
        websocket_enabled,
        nostr_clients_enabled,
        ip,
        port,
        http_num_acceptors,
        http_max_connections,
        http_idle_timeout_ms,
        http_request_timeout_ms,
        websocket_idle_timeout_ms,
        max_subscriptions,
        max_total_subscriptions,
        max_filters,
        max_filter_values,
        search_default_limit,
        search_max_limit,
        search_max_events,
        websocket_messages_per_minute,
        subscriber_queue_max,
        ae_event_store_hydrate_page_size,
        ae_event_store_retry_ms,
        node_name,
        node_title,
        node_description,
        node_logo_url,
        node_favicon_url,
        node_accent_color
    ].

spec(dashboard_enabled) ->
    {true, boolean};
spec(auth_signup_enabled) ->
    {true, boolean};
%% Durable state follows the shared Damage state root. Explicit per-file
%% overrides retain their meaning, including legacy relative paths.
spec(data_dir) ->
    {fun() -> filename:join([damage_config:state_dir(), "dets", "nosternity"]) end, path};
spec(search_store_file) ->
    {fun() -> filename:join(get(data_dir), "search.dets") end, path};
spec(auth_store_file) ->
    {fun() -> filename:join(get(data_dir), "accounts.dets") end, path};
spec(auth_challenge_ttl_seconds) ->
    {180, {integer, 30, 600}};
spec(auth_session_ttl_seconds) ->
    {3600, {integer, 60, 86400}};
spec(auth_max_challenges) ->
    {1000, {integer, 1, 10000}};
spec(auth_max_sessions) ->
    {10000, {integer, 1, 100000}};
spec(auth_max_accounts) ->
    {100000, {integer, 1, 1000000}};
spec(auth_attempts_per_minute) ->
    {120, {integer, 1, 1000}};
spec(enabled) ->
    {true, boolean};
spec(http_enabled) ->
    {true, boolean};
spec(websocket_enabled) ->
    {true, boolean};
spec(nostr_clients_enabled) ->
    {true, boolean};
spec(ip) ->
    {{127, 0, 0, 1}, ip};
spec(port) ->
    {9001, {integer, 0, 65535}};
spec(http_num_acceptors) ->
    {10, {integer, 1, 100}};
spec(http_max_connections) ->
    {1024, {integer, 1, 100000}};
spec(http_idle_timeout_ms) ->
    {60000, {integer, 1000, 86400000}};
spec(http_request_timeout_ms) ->
    {10000, {integer, 1000, 86400000}};
spec(websocket_idle_timeout_ms) ->
    {120000, {integer, 1000, 86400000}};
spec(max_subscriptions) ->
    {32, {integer, 1, 1024}};
spec(max_total_subscriptions) ->
    {4096, {integer, 1, 100000}};
spec(max_filters) ->
    {8, {integer, 1, 64}};
spec(max_filter_values) ->
    {256, {integer, 1, 4096}};
spec(search_default_limit) ->
    {50, {integer, 1, 10000}};
spec(search_max_limit) ->
    {200, {integer, 1, 10000}};
spec(search_max_events) ->
    {10000, {integer, 1, 100000}};
spec(websocket_messages_per_minute) ->
    {120, {integer, 1, 100000}};
spec(subscriber_queue_max) ->
    {256, {integer, 1, 10000}};
spec(ae_event_store_hydrate_page_size) ->
    {25, {integer, 1, 100}};
spec(ae_event_store_retry_ms) ->
    {5000, {integer, 1000, 3600000}};
spec(node_name) ->
    {<<"Nosternity Search">>, {text, 1, 128}};
spec(node_title) ->
    {<<"Nosternity Search">>, {text, 1, 256}};
spec(node_description) ->
    {<<"DamageBDD verified events with ECAI text search. Public text kinds 0, 1, 30023. Single-node bounded storage.">>,
        {text, 0, 2048}};
spec(node_logo_url) ->
    {<<>>, url};
spec(node_favicon_url) ->
    {<<>>, url};
spec(node_accent_color) ->
    {<<"#6750a4">>, color}.

normalize({text, _, _}, Value) -> utf8(Value);
normalize(url, Value) -> utf8(Value);
normalize(color, Value) -> utf8(Value);
normalize(_, Value) -> Value.

utf8(Value) when is_binary(Value); is_list(Value) ->
    try unicode:characters_to_binary(Value) of
        Binary when is_binary(Binary) -> Binary;
        _ -> invalid
    catch
        _:_ -> invalid
    end;
utf8(_) ->
    invalid.

valid(path, Value) when is_binary(Value) ->
    case unicode:characters_to_list(Value) of
        List when is_list(List) -> valid(path, List);
        _ -> false
    end;
valid(path, Value) ->
    is_list(Value) andalso Value =/= [] andalso
        lists:all(fun(C) ->
            is_integer(C) andalso C > 0 andalso C =< 16#10ffff andalso
                not (C >= 16#d800 andalso C =< 16#dfff)
        end, Value);
valid(boolean, Value) ->
    is_boolean(Value);
valid({integer, Min, Max}, Value) ->
    is_integer(Value) andalso Value >= Min andalso Value =< Max;
valid(ip, Value) when is_tuple(Value), tuple_size(Value) =:= 4 ->
    lists:all(fun(N) -> valid({integer, 0, 255}, N) end, tuple_to_list(Value));
valid(ip, Value) when is_tuple(Value), tuple_size(Value) =:= 8 ->
    lists:all(fun(N) -> valid({integer, 0, 65535}, N) end, tuple_to_list(Value));
valid(ip, _) ->
    false;
valid({text, Min, Max}, Value) when is_binary(Value) ->
    Characters = unicode:characters_to_list(Value),
    Length = length(Characters),
    Length >= Min andalso Length =< Max andalso
        lists:all(fun printable/1, Characters);
valid({text, _, _}, _) ->
    false;
valid(url, <<>>) ->
    true;
valid(url, Value) when is_binary(Value), byte_size(Value) =< 2048 ->
    safe_url(Value);
valid(url, _) ->
    false;
valid(color, <<$#, Hex:6/binary>>) ->
    lists:all(
        fun(C) ->
            (C >= $0 andalso C =< $9) orelse
                (C >= $a andalso C =< $f) orelse
                (C >= $A andalso C =< $F)
        end,
        binary_to_list(Hex)
    );
valid(color, _) ->
    false.

printable(C) -> C >= 32 andalso not (C >= 127 andalso C =< 159).

%% These values become HTML attributes. In addition to template escaping,
%% constrain their schemes and URI structure before any listener is started.
safe_url(Value) ->
    try
        true = lists:all(fun url_character/1, unicode:characters_to_list(Value)),
        URI = uri_string:parse(Value),
        true = is_map(URI),
        false = maps:is_key(userinfo, URI),
        Path = maps:get(path, URI, <<>>),
        true = safe_path(Path),
        case Value of
            <<"//", _/binary>> ->
                false;
            <<"/", _/binary>> ->
                not maps:is_key(scheme, URI) andalso not maps:is_key(host, URI);
            _ ->
                Scheme = string:lowercase(maps:get(scheme, URI, <<>>)),
                Host = maps:get(host, URI, <<>>),
                Port = maps:get(port, URI, 80),
                (Scheme =:= <<"http">> orelse Scheme =:= <<"https">>) andalso
                    is_binary(Host) andalso byte_size(Host) > 0 andalso
                    valid({integer, 1, 65535}, Port)
        end
    catch
        _:_ -> false
    end.

url_character(C) ->
    printable(C) andalso C =/= 32 andalso
        not lists:member(C, [$\\, $<, $>, $", $`, ${, $}, $|, $^]).

safe_path(Path) ->
    %% Decode escapes before checking so /%2e%2e/ and /%5c cannot bypass the
    %% root-relative path policy. A malformed percent escape is rejected too.
    Decoded = uri_string:unquote(Path),
    is_binary(Decoded) andalso
        lists:all(
            fun(C) -> printable(C) andalso C =/= $\\ end,
            unicode:characters_to_list(Decoded)
        ) andalso
        case Decoded of
            <<"//", _/binary>> ->
                false;
            _ ->
                not lists:any(
                    fun(S) -> S =:= <<".">> orelse S =:= <<"..">> end,
                    binary:split(Decoded, <<"/">>, [global])
                )
        end.
