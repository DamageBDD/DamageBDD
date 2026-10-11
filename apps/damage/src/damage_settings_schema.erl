%%%-------------------------------------------------------------------
%%% Explicit, non-secret, operator-administered dashboard config schema.
%%% Never accept arbitrary application names or create atoms from JSON.
%%%-------------------------------------------------------------------
-module(damage_settings_schema).

-export([apps/0, normalize_app/1, fields/1, field/2,
         decode_changes/2, decode_existing/3, public_value/2,
         validate_effective/1]).

-define(B(K, L, A), #{key => K, label => L, type => boolean, apply => A}).
-define(I(K, L, Min, Max, A), #{key => K, label => L, type => integer,
                              min => Min, max => Max, apply => A}).
-define(S(K, L, A), #{key => K, label => L, type => string, apply => A}).
-define(P(K, L, Min, Max, A), #{key => K, label => L, type => parallelism,
                                min => Min, max => Max, apply => A}).
-define(SL(K, L, A), #{key => K, label => L, type => string_list, apply => A}).

apps() -> [damage, ecai, nosternity, erm, bop].

normalize_app(damage) -> {ok, damage};
normalize_app(ecai) -> {ok, ecai};
normalize_app(nosternity) -> {ok, nosternity};
normalize_app(erm) -> {ok, erm};
normalize_app(bop) -> {ok, bop};
normalize_app(<<"damage">>) -> {ok, damage};
normalize_app(<<"ecai">>) -> {ok, ecai};
normalize_app(<<"nosternity">>) -> {ok, nosternity};
normalize_app(<<"erm">>) -> {ok, erm};
normalize_app(<<"bop">>) -> {ok, bop};
normalize_app("damage") -> {ok, damage};
normalize_app("ecai") -> {ok, ecai};
normalize_app("nosternity") -> {ok, nosternity};
normalize_app("erm") -> {ok, erm};
normalize_app("bop") -> {ok, bop};
normalize_app(_) -> {error, unknown_application}.

%% HOT means the relevant existing call sites read application:get_env at runtime.
%% RESTART is conservative: settings are published to application env, but a
%% process/listener may have cached the old value and still needs a restart.
%% Every editable setting gets an explicit type and a feature group. The
%% discovery catalog NEVER grants write access by itself.
fields(App) ->
    [F#{group => damage_settings_catalog:group(App, maps:get(key, F))}
     || F <- base_fields(App)].

base_fields(damage) ->
    [
        ?B(strict_no_catchall, <<"Require matching BDD steps">>, hot),
        ?I(ae_fee_multiplier, <<"Aeternity fee multiplier">>, 1, 100, hot),
        ?I(ae_gas_multiplier, <<"Aeternity gas multiplier">>, 1, 100, hot),
        ?I(ae_gas_price_multiplier, <<"Aeternity gas price multiplier">>, 1, 100, hot),
        ?SL(proxy_exclude, <<"Hosts bypassing the proxy">>, hot),
        ?I(nwc_balance_cache_ttl_ms, <<"NWC balance cache TTL (ms)">>, 100, 3600000, restart),
        ?I(l402_price_msat, <<"L402 price (millisatoshis)">>, 0, 100000000000, restart),
        ?I(l402_min_sats, <<"L402 minimum sats">>, 0, 1000000000, restart),
        ?I(l402_invoice_expiry, <<"L402 invoice expiry (seconds)">>, 1, 604800, restart),
        ?I(l402_uses, <<"L402 token uses">>, 1, 100000, restart),
        ?B(cln_enabled, <<"Core Lightning integration">>, restart),
        ?B(cln_websocket_enabled, <<"CLN WebSocket connection">>, restart),
        ?I(cln_restart_backoff_ms, <<"CLN restart backoff (ms)">>, 100, 3600000, restart),
        ?B(managed_kubo, <<"Manage Kubo process">>, restart),
        ?B(kubo_gc, <<"Kubo garbage collection">>, restart),
        ?B(build_release_require_installation, <<"Require release installation">>, restart),
        ?B(build_release_announce_oracle, <<"Announce releases to oracle">>, restart),
        ?I(blossom_max_bytes, <<"Blossom maximum upload bytes">>, 1, 1073741824, restart),
        ?I(blossom_upload_timeout_ms, <<"Blossom upload timeout (ms)">>, 100, 3600000, restart),
        ?I(blossom_max_serve_bytes, <<"Maximum Blossom download (bytes)">>, 1, 1073741824, restart),
        ?B(blossom_pin_uploads, <<"Pin Blossom uploads">>, restart),
        ?I(nip96_max_bytes, <<"NIP-96 maximum upload bytes">>, 1, 1073741824, restart),
        ?I(nip96_max_records, <<"NIP-96 maximum records">>, 1, 10000000, restart),
        ?I(nip96_upload_timeout_ms, <<"NIP-96 upload timeout (ms)">>, 100, 3600000, restart),
        ?B(nip96_pin_uploads, <<"Pin NIP-96 uploads">>, restart),
        ?I(http_stream_heartbeat_ms, <<"HTTP stream heartbeat (ms)">>, 1000, 600000, hot),
        ?I(bitcoin_rpc_timeout, <<"Bitcoin RPC timeout (ms)">>, 100, 3600000, hot),
        ?I(monero_poll_interval_ms, <<"Monero poll interval (ms)">>, 1000, 3600000, hot),
        ?I(quickstart_max_inflight, <<"Quickstart maximum concurrent requests">>, 1, 128, hot),
        ?I(quickstart_max_generations_per_peer_hour, <<"Quickstart generations per peer/hour">>, 1, 100000, hot),
        ?I(quickstart_max_peer_per_hour, <<"Quickstart requests per peer/hour">>, 1, 100000, hot),
        ?I(settings_poll_interval_ms, <<"Configuration file poll interval (ms)">>, 500, 60000, restart),
        ?I(ecai_log_recent_limit, <<"ECAI log learning recent entries">>, 1, 1024, restart),
        ?I(ecai_log_pending_limit, <<"ECAI log learning pending limit">>, 1, 100000, restart),
        ?I(ecai_log_flush_interval_ms, <<"ECAI log learning flush interval (ms)">>, 100, 3600000, restart),
        ?I(ecai_log_max_text_bytes, <<"ECAI log learning text limit (bytes)">>, 128, 1048576, restart)
    ];
base_fields(ecai) ->
    [
        ?I(top_k, <<"Retrieval top K">>, 1, 1000, restart),
        ?B(index_jobs_enabled, <<"Enable indexing jobs">>, restart),
        ?I(index_jobs_max_concurrency, <<"Indexing concurrency">>, 1, 1024, restart),
        ?I(index_jobs_max_pending, <<"Maximum pending indexing jobs">>, 1, 1000000, restart),
        ?I(index_jobs_max_pending_per_owner, <<"Pending jobs per owner">>, 1, 100000, restart),
        ?B(ingest_wal_enabled, <<"Ingestion write-ahead log">>, restart),
        ?I(ingest_wal_max_batch_events, <<"Ingestion WAL batch events">>, 1, 100000, restart),
        ?I(code_learning_interval_ms, <<"Code learning interval (ms)">>, 1000, 86400000, restart),
        ?I(code_patch_scan_interval_ms, <<"Repair scan interval (ms)">>, 1000, 86400000, restart),
        ?B(code_patch_verify, <<"Verify repair patches">>, restart),
        ?B(code_patch_run_eunit, <<"Run EUnit during repairs">>, restart),
        ?I(code_patch_max_attempts, <<"Repair attempts">>, 1, 100, restart),
        ?I(code_patch_max_concurrent, <<"Concurrent repairs">>, 1, 128, restart),
        ?I(code_patch_retry_max_attempts, <<"Repair retry attempts">>, 1, 100, restart),
        ?B(code_integration_run_eunit, <<"EUnit before integration">>, restart),
        ?B(code_integration_run_ct, <<"Common Test before integration">>, restart),
        ?P(code_learning_parallelism, <<"Code learning parallelism (or auto)">>, 1, 128, restart),
        ?I(code_model_health_interval_ms, <<"Model health interval (ms)">>, 1000, 86400000, restart),
        ?I(code_model_health_timeout_ms, <<"Model health timeout (ms)">>, 100, 3600000, restart),
        ?I(code_model_failure_threshold, <<"Model failure threshold">>, 1, 1000, restart),
        ?I(code_model_queue_timeout_ms, <<"Model queue timeout (ms)">>, 100, 3600000, restart),
        ?S(code_ollama_model, <<"Code model name">>, restart),
        ?I(code_ollama_timeout_ms, <<"Ollama request timeout (ms)">>, 100, 3600000, restart),
        ?S(ollama_model, <<"General-purpose model name">>, restart),
        ?I(ingest_wal_max_batch_bytes, <<"Ingestion WAL batch bytes">>, 1024, 1073741824, restart),
        ?I(ingest_max_source_bytes, <<"Maximum ingestion source bytes">>, 1024, 1073741824, restart),
        ?I(ingest_max_source_chunks, <<"Maximum ingestion source chunks">>, 1, 1000000, restart),
        ?I(code_patch_command_timeout_ms, <<"Repair command timeout (ms)">>, 1000, 86400000, restart),
        ?I(code_patch_retry_tick_ms, <<"Repair retry tick (ms)">>, 100, 3600000, restart),
        ?I(code_patch_retry_base_ms, <<"Repair retry base delay (ms)">>, 100, 3600000, restart),
        ?I(code_patch_retry_max_ms, <<"Repair retry maximum delay (ms)">>, 100, 86400000, restart),
        ?I(code_integration_interval_ms, <<"Integration cycle interval (ms)">>, 1000, 86400000, restart),
        ?I(code_integration_command_timeout_ms, <<"Integration command timeout (ms)">>, 1000, 86400000, restart),
        ?I(code_ollama_connect_timeout_ms, <<"Ollama connect timeout (ms)">>, 100, 3600000, restart),
        ?I(code_model_cluster_attempts, <<"Model cluster attempts">>, 1, 50, restart),
        ?B(code_health_monitor_enabled, <<"Enable code model health monitor">>, restart),
        ?B(code_repair_feedback_enabled, <<"Enable repair feedback">>, restart),
        ?I(code_repair_feedback_replay_limit, <<"Repair feedback replay limit">>, 1, 100000, restart),
        ?I(ecai_chat_max_body, <<"Chat maximum request bytes">>, 1024, 10485760, restart),
        ?I(ecai_chat_top_k, <<"Chat retrieval top K">>, 1, 1000, restart),
        ?B(relation_benchmark_enabled, <<"Enable relation benchmarking">>, restart),
        ?I(vulnerability_scan_interval_ms, <<"Vulnerability scan interval (ms)">>, 1000, 86400000, restart)
    ];
base_fields(nosternity) ->
    [
        ?B(enabled, <<"Enable Nosternity">>, restart),
        ?B(http_enabled, <<"HTTP listener">>, restart),
        ?B(websocket_enabled, <<"Nostr WebSocket listener">>, restart),
        ?I(http_num_acceptors, <<"HTTP acceptors">>, 1, 100, restart),
        ?I(http_max_connections, <<"Maximum HTTP connections">>, 1, 100000, restart),
        ?I(http_idle_timeout_ms, <<"HTTP idle timeout (ms)">>, 1000, 86400000, restart),
        ?I(http_request_timeout_ms, <<"HTTP request timeout (ms)">>, 1000, 86400000, restart),
        ?I(websocket_idle_timeout_ms, <<"WebSocket idle timeout (ms)">>, 1000, 86400000, restart),
        ?B(nostr_clients_enabled, <<"Enable Nostr clients">>, restart),
        ?I(search_max_events, <<"Search event capacity">>, 1, 100000, restart),
        ?I(search_default_limit, <<"Default search limit">>, 1, 10000, restart),
        ?I(search_max_limit, <<"Maximum search limit">>, 1, 10000, restart),
        ?I(max_subscriptions, <<"Subscriptions per connection">>, 1, 1024, restart),
        ?I(max_total_subscriptions, <<"Total subscriptions">>, 1, 100000, restart),
        ?I(max_filters, <<"Filters per subscription">>, 1, 64, restart),
        ?I(max_filter_values, <<"Values per filter">>, 1, 4096, restart),
        ?I(websocket_messages_per_minute, <<"WebSocket messages/minute">>, 1, 100000, restart),
        ?I(subscriber_queue_max, <<"Subscriber queue limit">>, 1, 10000, restart),
        ?B(search_llm_enabled, <<"LLM-assisted search">>, restart),
        ?B(ae_event_store_enabled, <<"Aeternity event storage">>, restart),
        ?B(ae_event_store_auto_deploy, <<"Auto-deploy event-store contract">>, restart),
        ?I(ae_event_store_max_event_bytes, <<"Maximum event-store bytes">>, 1, 104857600, restart),
        ?I(ae_event_store_queue_max, <<"Event-store queue limit">>, 1, 1000000, restart),
        ?I(ae_event_store_batch_size, <<"Event-store batch size">>, 1, 100000, restart),
        ?I(ae_event_store_flush_ms, <<"Event-store flush interval (ms)">>, 100, 86400000, restart),
        ?I(ae_event_store_retry_ms, <<"Event-store retry interval (ms)">>, 1000, 3600000, restart),
        ?B(ae_event_store_rehydrate, <<"Rehydrate event-store on start">>, restart),
        ?B(ae_event_store_confirm_writes, <<"Confirm event-store writes">>, restart),
        ?B(dashboard_enabled, <<"Enable Nosternity dashboard">>, restart),
        ?I(auth_challenge_ttl_seconds, <<"Login challenge TTL (seconds)">>, 30, 600, restart),
        ?I(auth_session_ttl_seconds, <<"Session TTL (seconds)">>, 60, 86400, restart),
        ?I(auth_max_challenges, <<"Maximum active login challenges">>, 1, 10000, restart),
        ?I(auth_max_sessions, <<"Maximum active sessions">>, 1, 100000, restart),
        ?I(auth_max_accounts, <<"Maximum accounts">>, 1, 1000000, restart),
        ?I(auth_attempts_per_minute, <<"Login attempts per minute">>, 1, 1000, restart),
        ?I(ae_event_store_hydrate_page_size, <<"Event-store rehydration page size">>, 1, 100, restart)
    ];
base_fields(erm) ->
    [
        ?B(enabled, <<"Enable ERM services">>, restart),
        ?B(http_enabled, <<"Enable ERM HTTP API">>, restart),
        ?B(http_required, <<"Require successful HTTP start">>, restart),
        ?B(media_enabled, <<"Enable media service">>, restart),
        ?B(mpv_survive_beam, <<"Allow MPV to survive BEAM restarts">>, restart),
        ?B(mpv_takeover_external, <<"Take over an existing MPV process">>, restart),
        ?B(log_to_file, <<"Enable file logging">>, restart),
        ?I(log_max_no_bytes, <<"Maximum log file size (bytes)">>, 1024, 1073741824, restart),
        ?I(log_max_no_files, <<"Retained log files">>, 1, 100, restart),
        ?I(playlist_latest_window, <<"Recent playlist window">>, 1, 100000, restart)
    ];
base_fields(bop) ->
    [
        ?I(port, <<"BOP HTTP port">>, 1, 65535, restart)
    ];
base_fields(_) -> [].

field(App, Name) ->
    case normalize_app(App) of
        {ok, ValidApp} ->
            case [F || F <- fields(ValidApp),
                       atom_to_binary(maps:get(key, F), utf8) =:= to_name(Name)] of
                [F] -> {ok, F};
                _ -> {error, not_editable}
            end;
        Error -> Error
    end.

%% JSON keys MUST be UTF-8 binaries. Atom-creation is never allowed.
decode_changes(App, Changes) when is_map(Changes), map_size(Changes) =< 100 ->
    case normalize_app(App) of
        {ok, ValidApp} -> decode_pairs(ValidApp, maps:to_list(Changes), []);
        Error -> Error
    end;
decode_changes(_App, _Changes) -> {error, invalid_changes}.

decode_pairs(_App, [], Acc) -> {ok, lists:reverse(Acc)};
decode_pairs(App, [{Name, Raw} | Rest], Acc) when is_binary(Name) ->
    case field(App, Name) of
        {ok, F} ->
            case decode(F, Raw) of
                {ok, Value} -> decode_pairs(App, Rest, [{maps:get(key, F), Value} | Acc]);
                {error, Why} -> {error, {invalid_value, Name, Why}}
            end;
        {error, _} -> {error, {not_editable, Name}}
    end;
decode_pairs(_App, [{_Name, _} | _], _Acc) -> {error, invalid_key_type}.

%% Reuse the exact same validation on existing sys.config/overlay Erlang values.
decode_existing(App, Key, Existing) ->
    case field(App, Key) of
        {ok, F} ->
            case public_value(F, Existing) of
                {ok, JSON} -> decode(F, JSON);
                {error, Why} -> {error, {invalid_existing_value, Key, Why}}
            end;
        Error -> Error
    end.

public_value(#{type := parallelism}, auto) -> {ok, <<"auto">>};
public_value(#{type := parallelism}, N) when is_integer(N) -> {ok, N};
public_value(#{type := boolean}, B) when is_boolean(B) -> {ok, B};
public_value(#{type := integer}, I) when is_integer(I) -> {ok, I};
public_value(#{type := string}, B) when is_binary(B) -> {ok, B};
public_value(#{type := string}, L) when is_list(L) ->
    try {ok, unicode:characters_to_binary(L)} catch _:_ -> {error, not_string} end;
public_value(#{type := string_list}, L) when is_list(L) ->
    try {ok, [unicode:characters_to_binary(S) || S <- L]} catch _:_ -> {error, not_string_list} end;
public_value(_, _) -> {error, wrong_type}.

decode(#{type := parallelism}, <<"auto">>) -> {ok, auto};
decode(#{type := parallelism, min := Min, max := Max}, N)
  when is_integer(N), N >= Min, N =< Max -> {ok, N};
decode(#{type := boolean}, B) when is_boolean(B) -> {ok, B};
decode(#{type := integer, min := Min, max := Max}, I)
  when is_integer(I), I >= Min, I =< Max -> {ok, I};
decode(#{type := string}, B) when is_binary(B), byte_size(B) =< 512, byte_size(B) > 0 ->
    try
        S = unicode:characters_to_list(B),
        case lists:member(0, S) of
            true -> {error, contains_nul};
            false -> {ok, S}
        end
    catch _:_ -> {error, invalid_utf8} end;
decode(#{type := string_list}, L) when is_list(L), length(L) =< 64 ->
    case lists:all(fun(S) -> is_binary(S) andalso byte_size(S) > 0 andalso
                                byte_size(S) =< 256 end, L) of
        true ->
            try
                Strings = [unicode:characters_to_list(B) || B <- L],
                case lists:any(fun(S) -> lists:member(0, S) end, Strings) of
                    true -> {error, contains_nul};
                    false -> {ok, Strings}
                end
            catch _:_ -> {error, invalid_utf8} end;
        false -> {error, invalid_list_item}
    end;
decode(_F, _V) -> {error, wrong_type_or_range}.

to_name(Name) when is_binary(Name) -> Name;
to_name(Name) when is_atom(Name) -> atom_to_binary(Name, utf8);
to_name(_) -> undefined.

%% Cross-field validation for the Nosternity bounds enforced at startup.
%% Does not create atoms, examine secrets, or mutate application environment.
validate_effective(All) when is_map(All) ->
    N = maps:get(nosternity, All, #{}),
    Default = maps:get(search_default_limit, N, 50),
    Max = maps:get(search_max_limit, N, 200),
    case Default =< Max of
        true -> ok;
        false -> {error, {invalid_setting_combination, nosternity,
                          search_default_limit, search_max_limit}}
    end;
validate_effective(_) -> {error, invalid_configuration}.
