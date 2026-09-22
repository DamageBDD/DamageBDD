%%--------------------------------------------------------------------
%% damage_nsecbunker
%%
%% Public API and gen_server for the in-tree Damage NIP-46 signer.
%% Config is read from application:get_env(damage, nsecbunker).
%% sys.config input should be a normal Erlang proplist with strings.
%% This module canonicalises that to internal maps/binaries at runtime.
%% Fail-closed until an external crypto backend is configured.
%%--------------------------------------------------------------------
-module(damage_nsecbunker).

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-define(BOOTSTRAP_RETRY_MIN_MS, 1000).
-define(BOOTSTRAP_RETRY_MAX_MS, 30000).

-export([
    start_link/0,
    stop/0,
    config/0,
    enabled/0,
    policy/0,
    policy/1,
    status/0,
    reload/0,
    generate_identity/0,
    export_identity/0,
    bunker_uri_pattern/0,
    handle_nip46_event/1,
    handle_plain_request/1
]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {
    config = #{},
    policy = #{},
    vault = undefined,
    started_at = 0,
    ready = false,
    retry_ms = ?BOOTSTRAP_RETRY_MIN_MS,
    last_error = undefined
}).

%%====================================================================
%% API
%%====================================================================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

stop() ->
    call(stop).

config() ->
    damage_nsecbunker_config:load().

enabled() ->
    maps:get(enabled, config(), false) =:= true.

policy() ->
    policy(config()).

policy(Config0) ->
    Config = normalize_config(Config0),
    Default = damage_nsecbunker_policy:default_policy(),
    Limits = maps:get(limits, Config, #{}),
    Kind30023 = maps:get(kind_30023, Config, #{}),
    RateLimit = rate_limit(Config, Limits, Default),
    MaxEventBytes = max_event_bytes_map(
        maps:get(
            max_event_bytes,
            Config,
            #{
                1 => first_int([max_kind_1_bytes], Limits, 4096),
                30023 => first_int([max_kind_30023_bytes], Limits, 131072)
            }
        )
    ),
    RequiredTags = required_tags_map(
        maps:get(
            required_tags,
            Config,
            #{30023 => maps:get(require_tags, Kind30023, ["d", "title", "published_at"])}
        )
    ),
    Default#{
        bunker_pubkey_hex => bin(
            first_defined(
                [bunker_pubkey_hex, bunker_pubkey], Config, maps:get(bunker_pubkey_hex, Default)
            )
        ),
        contract_sha => bin(
            first_defined([contract_sha, bdd_contract_sha], Config, maps:get(contract_sha, Default))
        ),
        authorized_clients => bins(
            maps:get(authorized_clients, Config, maps:get(authorized_clients, Default))
        ),
        allowed_methods => method_bins(
            maps:get(allowed_methods, Config, maps:get(allowed_methods, Default))
        ),
        allowed_kinds => maps:get(allowed_kinds, Config, maps:get(allowed_kinds, Default)),
        created_at_skew_seconds => first_int(
            [created_at_skew_seconds, created_at_window_seconds],
            Limits,
            maps:get(created_at_skew_seconds, Default)
        ),
        max_event_bytes => MaxEventBytes,
        required_tags => RequiredTags,
        reject_active_content => maps:get(
            reject_active_content, Config, maps:get(reject_html, Kind30023, true)
        ),
        bunker_publishes => maps:get(bunker_publishes, Config, false),
        signing_timeout_ms => maps:get(
            signing_timeout_ms, Config, maps:get(signing_timeout_ms, Default)
        ),
        rate_limit => RateLimit
    }.

status() ->
    call(status).

reload() ->
    call(reload, 70000).

generate_identity() ->
    call(generate_identity).

export_identity() ->
    call(export_identity).

bunker_uri_pattern() ->
    call(bunker_uri_pattern).

handle_nip46_event(Event) when is_map(Event) ->
    call({nip46_event, Event}).

%% Test/BDD helper: execute a decrypted/normalized NIP-46 request without relay encryption.
handle_plain_request(Request) when is_map(Request) ->
    call({plain_request, Request}).

call(Request) ->
    call(Request, 30000).

call(Request, Timeout) ->
    case whereis(?MODULE) of
        undefined -> {error, nsecbunker_not_running};
        _Pid -> gen_server:call(?MODULE, Request, Timeout)
    end.

%%====================================================================
%% gen_server
%%====================================================================

init([]) ->
    Config = config(),
    StartedAt = erlang:system_time(second),
    RetryMs = bootstrap_retry_min_ms(Config),
    case bootstrap_attempt(Config) of
        {ok, RuntimeConfig, Policy, Vault} ->
            {ok, #state{
                config = RuntimeConfig,
                policy = Policy,
                vault = Vault,
                started_at = StartedAt,
                ready = true,
                retry_ms = RetryMs
            }};
        {wait, Reason} ->
            ?LOG_WARNING(
                "nsecbunker waiting for node secrets; Damage will continue booting "
                "and bunker initialization will retry in ~p ms reason=~p",
                [RetryMs, Reason]
            ),
            State0 = #state{
                config = Config,
                started_at = StartedAt,
                ready = false,
                retry_ms = RetryMs,
                last_error = Reason
            },
            {ok, schedule_bootstrap_retry(State0)};
        {error, Reason} ->
            {stop, Reason}
    end.

handle_call(
    status,
    _From,
    State = #state{
        config = Config,
        started_at = StartedAt,
        ready = false,
        retry_ms = RetryMs,
        last_error = LastError
    }
) ->
    Reply = #{
        enabled => true,
        running => true,
        ready => false,
        state => waiting_for_secrets,
        started_at => StartedAt,
        mode => maps:get(mode, Config, undefined),
        secret_provider => damage_nsecbunker_config:secret_provider(Config),
        retry_in_ms => RetryMs,
        last_error => LastError,
        vault => #{ready => false, guard_state => #{
            sealed => true,
            integrity => waiting_for_secrets,
            pubkey_hex => <<>>
        }},
        secure_owner => secure_owner_status(Config),
        relay_client_enabled => maps:get(relay_client_enabled, Config, false)
    },
    {reply, Reply, State};
handle_call(
    status,
    _From,
    State = #state{
        config = Config,
        policy = Policy,
        vault = Vault,
        started_at = StartedAt,
        ready = true
    }
) ->
    Reply = #{
        enabled => true,
        running => true,
        ready => true,
        state => ready,
        started_at => StartedAt,
        mode => maps:get(mode, Config, undefined),
        secret_provider => damage_nsecbunker_config:secret_provider(Config),
        policy => policy_summary(Policy),
        vault => damage_nsecbunker_vault:status(Vault),
        secure_owner => secure_owner_status(Config),
        relay_client_enabled => maps:get(relay_client_enabled, Config, false)
    },
    {reply, Reply, State};
handle_call(
    reload,
    _From,
    State = #state{ready = false, last_error = LastError}
) ->
    {reply, {error, {nsecbunker_not_ready, LastError}}, State};
handle_call(reload, _From, State = #state{config = CurrentConfig, ready = true}) ->
    CandidateConfig = config(),
    case validate_candidate_config(CandidateConfig) of
        ok ->
            case reload_secret_provider(CurrentConfig, CandidateConfig) of
                ok ->
                    case prepare_runtime(CandidateConfig) of
                        {ok, RuntimeConfig, CandidatePolicy, CandidateVault} ->
                            {reply, ok, State#state{
                                config = RuntimeConfig,
                                policy = CandidatePolicy,
                                vault = CandidateVault,
                                ready = true,
                                last_error = undefined,
                                retry_ms = bootstrap_retry_min_ms(RuntimeConfig)
                            }};
                        {error, _} = Error ->
                            {reply, Error, State}
                    end;
                {error, _} = Error ->
                    {reply, Error, State}
            end;
        {error, _} = Error ->
            {reply, Error, State}
    end;
handle_call(stop, _From, State) ->
    {stop, normal, ok, State};
handle_call(
    _Request,
    _From,
    State = #state{ready = false, last_error = LastError}
) ->
    {reply, {error, {nsecbunker_not_ready, LastError}}, State};
handle_call(generate_identity, _From, State = #state{vault = Vault, ready = true}) ->
    Reply = damage_nsecbunker_vault:generate_identity(Vault),
    {reply, Reply, State};
handle_call(
    export_identity,
    _From,
    State = #state{vault = Vault, config = Config, policy = Policy, ready = true}
) ->
    Reply = damage_nsecbunker_vault:export_identity(Vault, Config, Policy),
    {reply, Reply, State};
handle_call(
    bunker_uri_pattern,
    _From,
    State = #state{vault = Vault, config = Config, ready = true}
) ->
    Reply = damage_nsecbunker_vault:bunker_uri_pattern(Vault, Config),
    {reply, Reply, State};
handle_call({plain_request, Request0}, _From, State = #state{ready = true}) ->
    Request = damage_nip46:normalize_request(Request0),
    Reply = route_plain_request(Request, State),
    {reply, Reply, State};
handle_call(
    {nip46_event, Event},
    _From,
    State = #state{vault = Vault, ready = true}
) ->
    Reply =
        case
            damage_nip46:decode_event(Event, fun(ClientPubkey, Ciphertext) ->
                damage_nsecbunker_vault:nip44_decrypt(Vault, ClientPubkey, Ciphertext)
            end)
        of
            {ok, Request} ->
                route_encrypted_request(Request, State);
            {error, Reason} ->
                {error, Reason}
        end,
    {reply, Reply, State};
handle_call(Other, _From, State) ->
    {reply, {error, {unknown_call, Other}}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(
    bootstrap_retry,
    State = #state{ready = false, retry_ms = CurrentRetry}
) ->
    Config = config(),
    case bootstrap_attempt(Config) of
        {ok, RuntimeConfig, Policy, Vault} ->
            ?LOG_INFO(
                "nsecbunker initialization completed after node secrets became available "
                "vault_path=~p",
                [maps:get(vault_path, RuntimeConfig, undefined)]
            ),
            {noreply, State#state{
                config = RuntimeConfig,
                policy = Policy,
                vault = Vault,
                ready = true,
                retry_ms = bootstrap_retry_min_ms(RuntimeConfig),
                last_error = undefined
            }};
        {wait, Reason} ->
            NextRetry = next_bootstrap_retry_ms(Config, CurrentRetry),
            ?LOG_DEBUG(
                "nsecbunker still waiting for node secrets; retrying in ~p ms reason=~p",
                [NextRetry, Reason]
            ),
            State1 = State#state{
                config = Config,
                retry_ms = NextRetry,
                last_error = Reason
            },
            {noreply, schedule_bootstrap_retry(State1)};
        {error, Reason} ->
            ?LOG_ERROR(
                "nsecbunker bootstrap failed after secrets became available reason=~p",
                [Reason]
            ),
            {stop, {nsecbunker_bootstrap_failed, Reason}, State}
    end;
handle_info(bootstrap_retry, State = #state{ready = true}) ->
    %% A retry timer can race with an unlock/bootstrap success.
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%====================================================================
%% Request execution
%%====================================================================

route_plain_request(Request, State = #state{config = Config, policy = Policy, vault = Vault}) ->
    NowUnix = erlang:system_time(second),
    VaultState = damage_nsecbunker_vault:guard_state(Vault),
    case damage_nsecbunker_gate:preflight(Request, VaultState, Policy, NowUnix) of
        {ok, AuditHints} ->
            write_audit(Config, AuditHints),
            execute_request(Request, State);
        {duplicate_same_payload, AuditHints} ->
            write_audit(Config, AuditHints),
            execute_request(Request, State);
        {error, Reason, AuditLine} ->
            write_audit(Config, AuditLine),
            {ok, damage_nip46:encode_response_map(Request, <<>>, damage_nip46:format_error(Reason))}
    end.

route_encrypted_request(Request, State = #state{vault = Vault}) ->
    case route_plain_request(Request, State) of
        {ok, ResponseMap} ->
            ClientPubkey = maps:get(requester_pubkey, Request, <<>>),
            case damage_nip46:encode_encrypted_response(ResponseMap, ClientPubkey, Vault) of
                {ok, Ciphertext} ->
                    damage_nsecbunker_vault:sign_event(
                        Vault, damage_nostr_event:nip46_response_event(ClientPubkey, Ciphertext)
                    );
                {error, Reason} ->
                    {error, Reason}
            end;
        Error ->
            Error
    end.

execute_request(#{method := <<"connect">>} = Request, _State) ->
    {ok, damage_nip46:encode_response_map(Request, <<"ack">>, <<>>)};
execute_request(#{method := <<"ping">>} = Request, _State) ->
    {ok, damage_nip46:encode_response_map(Request, <<"pong">>, <<>>)};
execute_request(#{method := <<"get_public_key">>} = Request, #state{vault = Vault}) ->
    case damage_nsecbunker_vault:public_key(Vault) of
        {ok, Pubkey} ->
            {ok, damage_nip46:encode_response_map(Request, Pubkey, <<>>)};
        {error, Reason} ->
            {ok, damage_nip46:encode_response_map(Request, <<>>, damage_nip46:format_error(Reason))}
    end;
execute_request(#{method := <<"sign_event">>, event := Event} = Request, #state{
    vault = Vault, policy = Policy
}) ->
    TimeoutMs = maps:get(signing_timeout_ms, Policy, 10000),
    case damage_nsecbunker_vault:sign_event(Vault, Event, TimeoutMs) of
        {ok, SignedEvent} ->
            {ok, damage_nip46:encode_response_map(Request, jsx:encode(SignedEvent), <<>>)};
        {error, crypto_backend_timeout} ->
            {ok,
                damage_nip46:encode_response_map(
                    Request, <<>>, damage_nip46:format_error(signing_timeout)
                )};
        {error, Reason} ->
            {ok,
                damage_nip46:encode_response_map(
                    Request, <<>>, damage_nip46:format_error(Reason)
                )}
    end;
execute_request(Request, _State) ->
    {ok, damage_nip46:encode_response_map(Request, <<>>, <<"unsupported_method">>)}.

%%====================================================================
%% Helpers
%%====================================================================

normalize_config(Config) ->
    damage_nsecbunker_config:normalize(Config).

is_kv_list([]) ->
    false;
is_kv_list(List) when is_list(List) ->
    lists:all(
        fun
            ({K, _V}) when is_atom(K); is_integer(K); is_binary(K) -> true;
            (_) -> false
        end,
        List
    );
is_kv_list(_) ->
    false.

is_string([]) ->
    false;
is_string(List) when is_list(List) ->
    lists:all(fun(C) -> is_integer(C) andalso C >= 0 andalso C =< 16#10FFFF end, List);
is_string(_) ->
    false.

first_defined([], _Config, Default) ->
    Default;
first_defined([Key | Rest], Config, Default) ->
    case maps:get(Key, Config, undefined) of
        undefined -> first_defined(Rest, Config, Default);
        Value -> Value
    end.

first_int([], _Map, Default) ->
    Default;
first_int([Key | Rest], Map, Default) ->
    case maps:get(Key, Map, undefined) of
        Value when is_integer(Value) -> Value;
        _ -> first_int(Rest, Map, Default)
    end.

rate_limit(Config, Limits, Default) ->
    case maps:get(rate_limit, Config, undefined) of
        M when is_map(M) -> M;
        _ ->
            #{
                max_requests => maps:get(
                    rate_limit_per_minute,
                    Limits,
                    maps:get(max_requests, maps:get(rate_limit, Default), 30)
                ),
                window_seconds => maps:get(
                    rate_limit_window_seconds,
                    Limits,
                    maps:get(window_seconds, maps:get(rate_limit, Default), 60)
                )
            }
    end.

max_event_bytes_map(Map) when is_map(Map) ->
    maps:fold(
        fun(K, V, Acc) ->
            Acc#{event_kind_key(K) => int_or_default(V, 0)}
        end,
        #{},
        Map
    );
max_event_bytes_map(List) when is_list(List) ->
    case is_kv_list(List) of
        true -> max_event_bytes_map(maps:from_list(List));
        false -> #{}
    end;
max_event_bytes_map(_) ->
    #{}.

required_tags_map(Map) when is_map(Map) ->
    maps:fold(
        fun(K, V, Acc) ->
            Acc#{event_kind_key(K) => bins(V)}
        end,
        #{},
        Map
    );
required_tags_map(List) when is_list(List) ->
    case is_kv_list(List) of
        true -> required_tags_map(maps:from_list(List));
        false -> #{30023 => bins(List)}
    end;
required_tags_map(_) ->
    #{}.

event_kind_key(K) when is_integer(K) -> K;
event_kind_key(K) when is_binary(K) ->
    case catch binary_to_integer(K) of
        I when is_integer(I) -> I;
        _ -> K
    end;
event_kind_key(K) when is_list(K) ->
    case catch list_to_integer(K) of
        I when is_integer(I) -> I;
        _ -> K
    end;
event_kind_key(K) ->
    K.

int_or_default(I, _Default) when is_integer(I) -> I;
int_or_default(B, Default) when is_binary(B) ->
    case catch binary_to_integer(B) of
        I when is_integer(I) -> I;
        _ -> Default
    end;
int_or_default(L, Default) when is_list(L) ->
    case is_string(L) of
        true ->
            case catch list_to_integer(L) of
                I when is_integer(I) -> I;
                _ -> Default
            end;
        false ->
            Default
    end;
int_or_default(_, Default) ->
    Default.

method_bins(Methods) ->
    [method_bin(M) || M <- Methods].

method_bin(M) when is_binary(M) -> M;
method_bin(M) when is_atom(M) -> atom_to_binary(M, utf8);
method_bin(M) when is_list(M) -> unicode:characters_to_binary(M).

bins(Values) ->
    [bin(V) || V <- Values].

bin(undefined) -> <<>>;
bin(V) when is_binary(V) -> V;
bin(V) when is_atom(V) -> atom_to_binary(V, utf8);
bin(V) when is_list(V) -> unicode:characters_to_binary(V);
bin(V) when is_integer(V) -> integer_to_binary(V);
bin(V) -> unicode:characters_to_binary(io_lib:format("~p", [V])).

bootstrap_attempt(Config) ->
    case local_node_secrets_required(Config) of
        true ->
            case node_secrets_ready() of
                true -> normalize_bootstrap_result(prepare_runtime(Config));
                false -> {wait, node_secrets_locked}
            end;
        false ->
            normalize_bootstrap_result(prepare_runtime(Config))
    end.

normalize_bootstrap_result({ok, _, _, _} = Ok) ->
    Ok;
normalize_bootstrap_result({error, node_locked}) ->
    {wait, node_secrets_locked};
normalize_bootstrap_result({error, {local_vault_passphrase_unavailable, node_locked}}) ->
    {wait, node_secrets_locked};
normalize_bootstrap_result({error, _} = Error) ->
    Error.

local_node_secrets_required(Config) ->
    damage_nsecbunker_config:secret_provider(Config) =:= local.

node_secrets_ready() ->
    try secrets:has_node_password() of
        true -> true;
        _ -> false
    catch
        _:_ -> false
    end.

schedule_bootstrap_retry(State = #state{retry_ms = RetryMs}) ->
    _ = erlang:send_after(RetryMs, self(), bootstrap_retry),
    State.

bootstrap_retry_min_ms(Config) ->
    positive_retry_ms(
        maps:get(bootstrap_retry_min_ms, Config, ?BOOTSTRAP_RETRY_MIN_MS),
        ?BOOTSTRAP_RETRY_MIN_MS
    ).

bootstrap_retry_max_ms(Config) ->
    Max0 = positive_retry_ms(
        maps:get(bootstrap_retry_max_ms, Config, ?BOOTSTRAP_RETRY_MAX_MS),
        ?BOOTSTRAP_RETRY_MAX_MS
    ),
    erlang:max(bootstrap_retry_min_ms(Config), Max0).

next_bootstrap_retry_ms(Config, Current) ->
    erlang:min(bootstrap_retry_max_ms(Config), erlang:max(1, Current) * 2).

positive_retry_ms(Value, _Default) when is_integer(Value), Value > 0 ->
    Value;
positive_retry_ms(_Value, Default) ->
    Default.

prepare_runtime(Config0) ->
    case validate_runtime_config(Config0) of
        ok ->
            case ensure_runtime_paths(Config0) of
                ok ->
                    case ensure_local_bootstrap_secret(Config0) of
                        ok ->
                            Policy0 = policy(Config0),
                            Vault0 = damage_nsecbunker_vault:init(Config0, Policy0),
                            case damage_nsecbunker_vault:ensure_identity(Vault0) of
                                {ok, Pubkey} ->
                                    Config = runtime_identity_config(Config0, Pubkey),
                                    Policy = policy(Config),
                                    Vault = damage_nsecbunker_vault:init(Config, Policy),
                                    {ok, Config, Policy, Vault};
                                {error, _} = Error ->
                                    Error
                            end;
                        {error, _} = Error ->
                            Error
                    end;
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

runtime_identity_config(Config, Pubkey) ->
    case maps:get(bunker_pubkey_hex, Config, undefined) of
        Existing when is_binary(Existing), byte_size(Existing) =:= 64,
                      Existing =/= <<"BUNKER_PUBKEY_HEX">> ->
            Config;
        _ ->
            Config#{bunker_pubkey_hex => Pubkey}
    end.

ensure_runtime_paths(Config) ->
    VaultPath = maps:get(vault_path, Config),
    AuditPath = maps:get(audit_log, Config),
    case ensure_parent(VaultPath) of
        ok -> ensure_parent(AuditPath);
        {error, _} = Error -> Error
    end.

ensure_parent(Path0) ->
    Path = path_list(Path0),
    case filelib:ensure_dir(Path) of
        ok -> ok;
        {error, Reason} -> {error, {nsecbunker_directory_failed, filename:dirname(Path), Reason}}
    end.

ensure_local_bootstrap_secret(Config) ->
    case {
        damage_nsecbunker_config:secret_provider(Config),
        damage_nsecbunker_config:vault_mode(Config),
        filelib:is_regular(path_list(maps:get(vault_path, Config)))
    } of
        {local, create_if_missing, false} ->
            ensure_local_vault_passphrase(Config);
        _ ->
            ok
    end.

ensure_local_vault_passphrase(Config) ->
    SecretRef = maps:get(vault_passphrase, Config, nsecbunker_vault_passphrase),
    case secrets:retrieve_secret(SecretRef) of
        [] ->
            %% Fresh install only. Store a printable high-entropy passphrase in
            %% the already-encrypted Damage secret store; never expose it in logs.
            Passphrase = base64:encode(crypto:strong_rand_bytes(32)),
            case secrets:encrypt_store(SecretRef, Passphrase) of
                ok -> ok;
                {error, _} = Error -> Error;
                Other -> {error, {nsecbunker_passphrase_store_failed, Other}}
            end;
        [{SecretRef, _Encrypted}] ->
            case secrets:retrieve_decrypt(SecretRef) of
                {ok, Value} when Value =/= <<>>, Value =/= [] ->
                    ok;
                _ ->
                    {error, existing_nsecbunker_passphrase_unreadable}
            end;
        {error, Reason} ->
            {error, {nsecbunker_passphrase_lookup_failed, Reason}};
        Other ->
            {error, {invalid_nsecbunker_passphrase_record, Other}}
    end.

path_list(Path) when is_binary(Path) ->
    unicode:characters_to_list(Path);
path_list(Path) when is_list(Path) ->
    Path.

validate_runtime_config(Config) ->
    case damage_nsecbunker_config:validate_production(Config) of
        ok ->
            case damage_nsecbunker_config:managed_secret_owner(Config) of
                true ->
                    case damage_nsecbunker_secret_owner:ready() of
                        true -> ok;
                        false -> {error, secure_vault_owner_not_ready}
                    end;
                false ->
                    ok
            end;
        {error, _} = Error ->
            Error
    end.

%% A provider change changes the supervisor child set and therefore requires a
%% supervisor/application restart. Same-provider AWS reload remains
%% transactional; same-provider local reload retains the previous behavior.
validate_candidate_config(Config) ->
    damage_nsecbunker_config:validate_production(Config).

reload_secret_provider(CurrentConfig, CandidateConfig) ->
    case
        damage_nsecbunker_config:provider_change(
            CurrentConfig,
            CandidateConfig
        )
    of
        ok ->
            case damage_nsecbunker_config:secret_provider(CandidateConfig) of
                aws_secrets_manager ->
                    damage_nsecbunker_secret_owner:reload(
                        CandidateConfig
                    );
                local ->
                    ok
            end;
        {error, _} = Error ->
            Error
    end.

secure_owner_status(Config) ->
    case damage_nsecbunker_config:managed_secret_owner(Config) of
        true -> damage_nsecbunker_secret_owner:status();
        false -> #{enabled => false}
    end.

ensure_audit_path(Config) ->
    Path = maps:get(audit_log, Config, damage_nsecbunker_config:default_audit_log()),
    filelib:ensure_dir(path_list(Path)).

write_audit(Config, #{audit_line := AuditLine}) ->
    write_audit(Config, AuditLine);
write_audit(Config, AuditLine) when is_binary(AuditLine) ->
    Path = maps:get(audit_log, Config, damage_nsecbunker_config:default_audit_log()),
    _ = file:write_file(path_list(Path), AuditLine, [append]),
    ok;
write_audit(_Config, _Other) ->
    ok.

policy_summary(Policy) ->
    #{
        bunker_pubkey_hex => maps:get(bunker_pubkey_hex, Policy, <<>>),
        contract_sha => maps:get(contract_sha, Policy, <<>>),
        authorized_clients_count => length(maps:get(authorized_clients, Policy, [])),
        allowed_methods => maps:get(allowed_methods, Policy, []),
        allowed_kinds => maps:get(allowed_kinds, Policy, []),
        created_at_skew_seconds => maps:get(created_at_skew_seconds, Policy, undefined),
        max_event_bytes => maps:get(max_event_bytes, Policy, #{}),
        required_tags => maps:get(required_tags, Policy, #{}),
        reject_active_content => maps:get(reject_active_content, Policy, true),
        bunker_publishes => maps:get(bunker_publishes, Policy, false),
        rate_limit => maps:get(rate_limit, Policy, #{})
    }.
