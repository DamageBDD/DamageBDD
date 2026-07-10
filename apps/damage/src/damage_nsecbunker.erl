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
    vault = #{},
    started_at = 0
}).

%%====================================================================
%% API
%%====================================================================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

stop() ->
    call(stop).

config() ->
    Raw =
        case application:get_env(damage, nsecbunker) of
            {ok, Value} -> Value;
            undefined -> #{}
        end,
    normalize_config(Raw).

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
    call(reload).

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
    case whereis(?MODULE) of
        undefined -> {error, nsecbunker_not_running};
        _Pid -> gen_server:call(?MODULE, Request, 30000)
    end.

%%====================================================================
%% gen_server
%%====================================================================

init([]) ->
    Config = config(),
    Policy = policy(Config),
    Vault = damage_nsecbunker_vault:init(Config, Policy),
    ok = ensure_audit_path(Config),
    {ok, #state{
        config = Config, policy = Policy, vault = Vault, started_at = erlang:system_time(second)
    }}.

handle_call(
    status,
    _From,
    State = #state{config = Config, policy = Policy, vault = Vault, started_at = StartedAt}
) ->
    Reply = #{
        enabled => true,
        running => true,
        started_at => StartedAt,
        mode => maps:get(mode, Config, undefined),
        policy => policy_summary(Policy),
        vault => damage_nsecbunker_vault:status(Vault),
        relay_client_enabled => maps:get(relay_client_enabled, Config, false)
    },
    {reply, Reply, State};
handle_call(reload, _From, State) ->
    Config = config(),
    Policy = policy(Config),
    Vault = damage_nsecbunker_vault:init(Config, Policy),
    {reply, ok, State#state{config = Config, policy = Policy, vault = Vault}};
handle_call(generate_identity, _From, State = #state{vault = Vault}) ->
    Reply = damage_nsecbunker_vault:generate_identity(Vault),
    {reply, Reply, State};
handle_call(
    export_identity, _From, State = #state{vault = Vault, config = Config, policy = Policy}
) ->
    Reply = damage_nsecbunker_vault:export_identity(Vault, Config, Policy),
    {reply, Reply, State};
handle_call(bunker_uri_pattern, _From, State = #state{vault = Vault, config = Config}) ->
    Reply = damage_nsecbunker_vault:bunker_uri_pattern(Vault, Config),
    {reply, Reply, State};
handle_call({plain_request, Request0}, _From, State) ->
    Request = damage_nip46:normalize_request(Request0),
    Reply = route_plain_request(Request, State),
    {reply, Reply, State};
handle_call({nip46_event, Event}, _From, State = #state{vault = Vault}) ->
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
handle_call(stop, _From, State) ->
    {stop, normal, ok, State};
handle_call(Other, _From, State) ->
    {reply, {error, {unknown_call, Other}}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

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
    SignFun = fun() -> damage_nsecbunker_vault:sign_event(Vault, Event) end,
    case damage_nsecbunker_signing_guard:with_timeout(SignFun, TimeoutMs) of
        {ok, SignedEvent} ->
            {ok, damage_nip46:encode_response_map(Request, jsx:encode(SignedEvent), <<>>)};
        {error, Reason} ->
            {ok, damage_nip46:encode_response_map(Request, <<>>, damage_nip46:format_error(Reason))}
    end;
execute_request(Request, _State) ->
    {ok, damage_nip46:encode_response_map(Request, <<>>, <<"unsupported_method">>)}.

%%====================================================================
%% Helpers
%%====================================================================

normalize_config(Config) when is_map(Config) ->
    normalize_config_map(Config);
normalize_config(Config) when is_list(Config) ->
    case is_kv_list(Config) of
        true -> normalize_config_map(maps:from_list(Config));
        false -> #{}
    end;
normalize_config(_) ->
    #{}.

normalize_config_map(Map) when is_map(Map) ->
    maps:fold(
        fun(K, V, Acc) ->
            Acc#{normalize_config_key(K) => normalize_config_value(V)}
        end,
        #{},
        Map
    ).

normalize_config_value(Map) when is_map(Map) ->
    normalize_config_map(Map);
normalize_config_value(List) when is_list(List) ->
    case {is_string(List), is_kv_list(List)} of
        {true, _} -> List;
        {false, true} -> normalize_config_map(maps:from_list(List));
        {false, false} -> [normalize_config_value(V) || V <- List]
    end;
normalize_config_value(Value) ->
    Value.

normalize_config_key(Key) when is_binary(Key) ->
    try
        binary_to_existing_atom(Key, utf8)
    catch
        _:_ -> Key
    end;
normalize_config_key(Key) when is_list(Key) ->
    case is_string(Key) of
        true ->
            try
                list_to_existing_atom(Key)
            catch
                _:_ -> Key
            end;
        false ->
            Key
    end;
normalize_config_key(Key) ->
    Key.

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

ensure_audit_path(Config) ->
    Path = maps:get(audit_log, Config, "/var/log/damage/nsecbunker_audit.log"),
    filelib:ensure_dir(Path).

write_audit(Config, #{audit_line := AuditLine}) ->
    write_audit(Config, AuditLine);
write_audit(Config, AuditLine) when is_binary(AuditLine) ->
    Path = maps:get(audit_log, Config, "/var/log/damage/nsecbunker_audit.log"),
    _ = file:write_file(Path, AuditLine, [append]),
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
