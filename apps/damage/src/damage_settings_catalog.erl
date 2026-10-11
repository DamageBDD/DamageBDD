%%%-------------------------------------------------------------------
%%% Node-admin configuration discovery and feature taxonomy.
%%% Names are extracted from source/configuration at build time, NEVER values.
%%% The catalog is informational only: only damage_settings_schema:field/2
%%% determines which keys may be read as values or mutated.
%%%-------------------------------------------------------------------
-module(damage_settings_catalog).
-export([known/1, group/2, groups/1, restriction/2]).

-spec known(atom()) -> [binary()].
known(App) when App =:= damage; App =:= ecai; App =:= nosternity;
                App =:= erm; App =:= bop ->
    case code:priv_dir(damage) of
        Priv when is_list(Priv) ->
            Path = filename:join([Priv, "config", "node-settings-catalog.json"]),
            case file:read_file(Path) of
                {ok, Raw} when byte_size(Raw) =< 131072 ->
                    try jsx:decode(Raw, [return_maps]) of
                        Doc when is_map(Doc) ->
                            case maps:get(atom_to_binary(App, utf8), Doc, []) of
                                Names when is_list(Names) ->
                                    [N || N <- Names, is_binary(N), byte_size(N) =< 128];
                                _ -> []
                            end;
                        _ -> []
                    catch _:_ -> [] end;
                _ -> []
            end;
        _ -> []
    end;
known(_) -> [].

%% Never infer mutability from names; restriction/2 only describes why a key
%% is not in the allowlist. No values are returned for these entries.
restriction(App, Name0) ->
    Name = key_binary(Name0),
    case sensitive_name(Name) orelse policy_key(App, Name) of
        true -> <<"protected">>;
        false -> <<"unmodeled">>
    end.

sensitive_name(Name) ->
    re:run(Name,
       <<"(secret|password|private|credential|keystore|_key($|_)|keyfile|certfile|"
         "_token($|_)|_auth|auth_|cookie|_admins|_accounts|_allowlist|_source|"
         "_command|_destinations|_sign|pqc_backend|api_key)">>,
       [{capture, none}]) =:= match.

policy_key(damage, <<"monero_allow_spend">>) -> true;
policy_key(damage, <<"monero_steps_require_admin">>) -> true;
policy_key(damage, <<"nwc_ledger_mode">>) -> true;
policy_key(damage, <<"bitcoin_http_enable_send">>) -> true;
policy_key(damage, <<"bitcoin_http_send_max_btc">>) -> true;
policy_key(damage, <<"quickstart_enabled">>) -> true;
policy_key(damage, <<"quickstart_trial_enabled">>) -> true;
policy_key(damage, <<"cln_keyfile">>) -> true;
policy_key(damage, <<"nsecbunker">>) -> true;
policy_key(ecai, <<"code_security_enabled">>) -> true;
policy_key(ecai, <<"code_admin_enabled">>) -> true;
policy_key(ecai, <<"code_review_push_enabled">>) -> true;
policy_key(ecai, <<"content_auto_publish">>) -> true;
policy_key(ecai, <<"private_corpora">>) -> true;
policy_key(erm, <<"display_manager">>) -> true;
policy_key(_, _) -> false.

-spec groups(atom()) -> [map()].
groups(damage) ->
    [g(<<"verification">>, <<"BDD & execution">>, <<"Runners, execution and generation limits">>),
     g(<<"aeternity">>, <<"Aeternity & contracts">>, <<"Chain connectivity, fees, caches and transaction tuning">>),
     g(<<"lightning">>, <<"Lightning & payments">>, <<"CLN, LND, NWC and L402 behaviour">>),
     g(<<"nostr">>, <<"Nostr & identities">>, <<"Relays, Nostr protocol and bunker services">>),
     g(<<"storage">>, <<"IPFS, Blossom & NIP-96">>, <<"Storage, gateways, uploads and retention limits">>),
     g(<<"release">>, <<"Builds & releases">>, <<"Release creation and artifact publishing">>),
     g(<<"integrations">>, <<"Integrations & messaging">>, <<"SMTP, webhooks, SSH and external services">>),
     g(<<"network">>, <<"HTTP & network">>, <<"Listeners, proxies and network limits">>),
     g(<<"observability">>, <<"Observability & lifecycle">>, <<"Logging, reload, telemetry and scheduling">>),
     g(<<"security">>, <<"Security & access policies">>, <<"Protected identity, credentials and authorization settings">>),
     g(<<"other">>, <<"Other node settings">>, <<"Additional application environment keys">>)];
groups(ecai) ->
    [g(<<"indexing">>, <<"Indexing & ingestion">>, <<"Jobs, ingestion WAL, Wikimedia and distributed indexing">>),
     g(<<"repair">>, <<"Code learning & repair">>, <<"Learning cycles, repair scans, verification and integration">>),
     g(<<"models">>, <<"Models & inference">>, <<"Model health, Ollama, providers and inference limits">>),
     g(<<"chat">>, <<"Chat & retrieval">>, <<"Search, chat contexts and response limits">>),
     g(<<"content">>, <<"Content & publishing">>, <<"Generated media and publication workflows">>),
     g(<<"marketplace">>, <<"Marketplace & rewards">>, <<"Market maker and index rewards">>),
     g(<<"network">>, <<"HTTP & node services">>, <<"Listeners and application pools">>),
     g(<<"security">>, <<"Security & permissions">>, <<"Protected administrative and private-model policies">>),
     g(<<"other">>, <<"Other ECAI settings">>, <<"Additional application environment keys">>)];
groups(nosternity) ->
    [g(<<"listeners">>, <<"Listeners & connections">>, <<"HTTP and WebSocket listeners and capacities">>),
     g(<<"relay">>, <<"Relays & subscriptions">>, <<"Nostr clients, filters, subscription limits and message rates">>),
     g(<<"search">>, <<"Search & LLM">>, <<"Search storage, capacity and language-model integration">>),
     g(<<"event_store">>, <<"Aeternity event store">>, <<"On-chain event storage, queueing and rehydration">>),
     g(<<"identity">>, <<"Identity & authentication">>, <<"Node identity, sessions and abuse prevention">>),
     g(<<"other">>, <<"Other Nosternity settings">>, <<"Additional application environment keys">>)];
groups(erm) ->
    [g(<<"runtime">>, <<"Node services">>, <<"ERM lifecycle, HTTP endpoints and pools">>),
     g(<<"display">>, <<"Display & GTK">>, <<"Display management, GTK C-node and graphical backends">>),
     g(<<"media">>, <<"Media & playback">>, <<"MPV, media libraries and playlists">>),
     g(<<"voice">>, <<"Voice & TTS">>, <<"Speech, model pulling and voice activation">>),
     g(<<"lens">>, <<"Lens, maps & anatomy">>, <<"Native lens and interactive views">>),
     g(<<"logging">>, <<"Logging & diagnostics">>, <<"File logging and diagnostic limits">>),
     g(<<"other">>, <<"Other ERM settings">>, <<"Additional application environment keys">>)];
groups(bop) ->
    [g(<<"runtime">>, <<"HTTP & node services">>, <<"BOP listener and worker pools">>),
     g(<<"identity">>, <<"Nostr & identity">>, <<"Public node identity and protected keystore">>),
     g(<<"other">>, <<"Other BOP settings">>, <<"Additional application environment keys">>)];
groups(_) -> [].

g(Id, Label, Description) -> #{id => Id, label => Label, description => Description}.

-spec group(atom(), atom() | binary()) -> binary().
group(App, Key0) ->
    Key = key_binary(Key0),
    group_key(App, Key).

%% Damage: prefix-order matters for payment and networking keys.
group_key(damage, K) ->
    case true of
        _ when K =:= <<"node_admins">>; K =:= <<"cookie_secure">>;
               K =:= <<"quickstart_quota_secret">>; K =:= <<"nsecbunker">> -> <<"security">>;
        _ when K =:= <<"l402_account">>; K =:= <<"lnpay_host">> -> <<"lightning">>;
        _ when K =:= <<"ipfs">>; K =:= <<"ipfs_runtime">> -> <<"storage">>;
        _ when K =:= <<"proxy">>; K =:= <<"proxy_exclude">> -> <<"network">>;
        true ->
            first_prefix(K, [
                {<<"ae_">>, <<"aeternity">>}, {<<"balance_cache_">>, <<"aeternity">>},
                {<<"account_registry_">>, <<"aeternity">>}, {<<"node_registry_">>, <<"aeternity">>},
                {<<"l402_">>, <<"lightning">>}, {<<"cln_">>, <<"lightning">>},
                {<<"lnd_">>, <<"lightning">>}, {<<"nwc_">>, <<"lightning">>},
                {<<"nostr_">>, <<"nostr">>}, {<<"nip98_">>, <<"nostr">>},
                {<<"ipfs_">>, <<"storage">>}, {<<"kubo_">>, <<"storage">>},
                {<<"blossom_">>, <<"storage">>}, {<<"nip96_">>, <<"storage">>},
                {<<"build_release_">>, <<"release">>}, {<<"release_">>, <<"release">>},
                {<<"smtp_">>, <<"integrations">>}, {<<"discord_">>, <<"integrations">>},
                {<<"ssh_">>, <<"integrations">>}, {<<"monero_">>, <<"integrations">>},
                {<<"bitcoin_">>, <<"integrations">>},
                {<<"settings_">>, <<"observability">>}, {<<"ecai_log_">>, <<"observability">>},
                {<<"log_">>, <<"observability">>}, {<<"schedule_">>, <<"observability">>},
                {<<"quickstart_">>, <<"verification">>}, {<<"bdd_">>, <<"verification">>},
                {<<"webdriver">>, <<"verification">>},
                {<<"http_">>, <<"network">>}, {<<"tor_">>, <<"network">>},
                {<<"pqc_">>, <<"security">>}, {<<"secrets_">>, <<"security">>},
                {<<"context_">>, <<"security">>}
            ], other_damage(K))
    end;
group_key(ecai, K) ->
    first_prefix(K, [
        {<<"index_">>, <<"indexing">>}, {<<"ingest_">>, <<"indexing">>},
        {<<"wikimedia_">>, <<"indexing">>}, {<<"shard_">>, <<"indexing">>},
        {<<"code_patch_">>, <<"repair">>}, {<<"code_learning_">>, <<"repair">>},
        {<<"code_integration_">>, <<"repair">>}, {<<"code_review_">>, <<"repair">>},
        {<<"code_repo_">>, <<"repair">>}, {<<"code_source_">>, <<"repair">>},
        {<<"code_repair_">>, <<"repair">>},
        {<<"vulnerability_">>, <<"repair">>},
        {<<"relation_">>, <<"indexing">>},
        {<<"code_ollama_">>, <<"models">>}, {<<"code_openai_">>, <<"models">>},
        {<<"code_model_">>, <<"models">>}, {<<"code_health_">>, <<"models">>},
        {<<"code_log_">>, <<"models">>}, {<<"ollama_">>, <<"models">>},
        {<<"private_llm_">>, <<"security">>},
        {<<"ecai_chat_">>, <<"chat">>}, {<<"search_">>, <<"chat">>},
        {<<"content_">>, <<"content">>}, {<<"market_">>, <<"marketplace">>},
        {<<"marketplace_">>, <<"marketplace">>},
        {<<"code_admin_">>, <<"security">>}, {<<"code_security_">>, <<"security">>},
        {<<"private_">>, <<"security">>}
    ], other_ecai(K));
group_key(nosternity, K) ->
    first_prefix(K, [
        {<<"ae_event_store_">>, <<"event_store">>}, {<<"search_">>, <<"search">>},
        {<<"max_subscriptions">>, <<"relay">>}, {<<"max_total_subscriptions">>, <<"relay">>},
        {<<"max_filters">>, <<"relay">>}, {<<"max_filter_values">>, <<"relay">>},
        {<<"subscriber_">>, <<"relay">>}, {<<"websocket_messages_">>, <<"relay">>},
        {<<"nostr_clients_">>, <<"relay">>}, {<<"relays">>, <<"relay">>},
        {<<"http_">>, <<"listeners">>}, {<<"websocket_">>, <<"listeners">>},
        {<<"auth_">>, <<"identity">>}, {<<"nostr_private_">>, <<"identity">>},
        {<<"browser_auth_">>, <<"identity">>}, {<<"dashboard_">>, <<"identity">>}
    ], other_nosternity(K));
group_key(erm, K) ->
    first_prefix(K, [
        {<<"display">>, <<"display">>}, {<<"gtknode4">>, <<"display">>},
        {<<"dm_">>, <<"display">>}, {<<"dpms">>, <<"display">>},
        {<<"media_">>, <<"media">>}, {<<"playlist_">>, <<"media">>},
        {<<"erm_mpv_">>, <<"media">>}, {<<"mpv_">>, <<"media">>},
        {<<"whisper_">>, <<"voice">>}, {<<"tts">>, <<"voice">>},
        {<<"model_pull">>, <<"voice">>},
        {<<"lens">>, <<"lens">>}, {<<"maps">>, <<"lens">>},
        {<<"anatomy">>, <<"lens">>}, {<<"log_">>, <<"logging">>},
        {<<"tray_logs">>, <<"logging">>}
    ], <<"runtime">>);
group_key(bop, <<"nostr_npub">>) -> <<"identity">>;
group_key(bop, <<"keystore">>) -> <<"identity">>;
group_key(bop, _K) -> <<"runtime">>;
group_key(_, _) -> <<"other">>.

other_damage(K) ->
    case lists:member(K, [<<"feature_dirs">>, <<"strict_no_catchall">>,
                          <<"concurrency">>, <<"chromedriver">>, <<"pools">>,
                          <<"abduco_workers">>, <<"runs_dir">>, <<"state_dir">>]) of
        true -> <<"verification">>;
        false ->
            case lists:member(K, [<<"api_url">>, <<"port">>, <<"ip">>,
                                  <<"cookie_secure">>]) of
                true -> <<"network">>;
                false -> <<"other">>
            end
    end.
other_ecai(K) ->
    case lists:member(K, [<<"top_k">>, <<"default_page">>,
                           <<"search_context_file">>]) of
        true -> <<"chat">>;
        false -> <<"network">>
    end.
other_nosternity(K) ->
    case lists:member(K, [<<"enabled">>, <<"port">>, <<"ip">>, <<"pools">>]) of
        true -> <<"listeners">>;
        false -> <<"other">>
    end.

first_prefix(_Key, [], Default) -> Default;
first_prefix(Key, [{Prefix, Group} | Rest], Default) ->
    case binary:match(Key, Prefix) of
        {0, _} -> Group;
        _ -> first_prefix(Key, Rest, Default)
    end.

key_binary(Key) when is_atom(Key) -> atom_to_binary(Key, utf8);
key_binary(Key) when is_binary(Key) -> Key;
key_binary(_) -> <<>>.
