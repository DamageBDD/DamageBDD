%% Runtime knobs for the listener and bounded search relay. Invalid settings
%% fail startup explicitly instead of quietly choosing a different interface,
%% capacity or policy. Error reasons deliberately exclude configuration values.
-module(nosternity_config).
-compile({no_auto_import, [get/1]}).
-export([get/1, validate/0]).

get(Key) ->
    {Default, Check} = spec(Key),
    Value = application:get_env(nosternity, Key, Default),
    case valid(Check, Value) of
        true -> Value;
        false -> error({invalid_configuration, Key})
    end.

validate() ->
    try
        case get(enabled) of
            false -> ok;
            true ->
                lists:foreach(fun get/1, keys()),
                case get(search_default_limit) =< get(search_max_limit) of
                    true -> ok;
                    false -> error({invalid_configuration, search_default_limit})
                end
        end
    catch error:{invalid_configuration, _} = Reason -> {error, Reason} end.

keys() ->
    [http_enabled, websocket_enabled, nostr_clients_enabled, ip, port,
     http_num_acceptors, http_max_connections, http_idle_timeout_ms,
     http_request_timeout_ms, websocket_idle_timeout_ms, max_subscriptions,
     max_total_subscriptions, max_filters, max_filter_values,
     search_default_limit, search_max_limit, search_max_events,
     websocket_messages_per_minute, subscriber_queue_max,
     ae_event_store_hydrate_page_size, ae_event_store_retry_ms].

spec(enabled) -> {true, boolean};
spec(http_enabled) -> {true, boolean};
spec(websocket_enabled) -> {true, boolean};
spec(nostr_clients_enabled) -> {true, boolean};
spec(ip) -> {{127, 0, 0, 1}, ip};
spec(port) -> {9001, {integer, 0, 65535}};
spec(http_num_acceptors) -> {10, {integer, 1, 100}};
spec(http_max_connections) -> {1024, {integer, 1, 100000}};
spec(http_idle_timeout_ms) -> {60000, {integer, 1000, 86400000}};
spec(http_request_timeout_ms) -> {10000, {integer, 1000, 86400000}};
spec(websocket_idle_timeout_ms) -> {120000, {integer, 1000, 86400000}};
spec(max_subscriptions) -> {32, {integer, 1, 1024}};
spec(max_total_subscriptions) -> {4096, {integer, 1, 100000}};
spec(max_filters) -> {8, {integer, 1, 64}};
spec(max_filter_values) -> {256, {integer, 1, 4096}};
spec(search_default_limit) -> {50, {integer, 1, 10000}};
spec(search_max_limit) -> {200, {integer, 1, 10000}};
spec(search_max_events) -> {10000, {integer, 1, 100000}};
spec(websocket_messages_per_minute) -> {120, {integer, 1, 100000}};
spec(subscriber_queue_max) -> {256, {integer, 1, 10000}};
spec(ae_event_store_hydrate_page_size) -> {25, {integer, 1, 100}};
spec(ae_event_store_retry_ms) -> {5000, {integer, 1000, 3600000}}.

valid(boolean, Value) -> is_boolean(Value);
valid({integer, Min, Max}, Value) ->
    is_integer(Value) andalso Value >= Min andalso Value =< Max;
valid(ip, Value) when is_tuple(Value), tuple_size(Value) =:= 4 ->
    lists:all(fun(N) -> valid({integer, 0, 255}, N) end, tuple_to_list(Value));
valid(ip, Value) when is_tuple(Value), tuple_size(Value) =:= 8 ->
    lists:all(fun(N) -> valid({integer, 0, 65535}, N) end, tuple_to_list(Value));
valid(ip, _) -> false.
