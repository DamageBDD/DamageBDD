%%%-------------------------------------------------------------------
%%% Encrypted, versioned storage for DamageBDD context scopes.
%%%
%%% The store is deliberately unaware of HTTP and Aeternity. It owns one
%%% shared ETS hot cache and one DETS file. Every scope is encrypted with a
%%% distinct key derived from a node-vault master key and is bound to its
%%% scope/version through AES-GCM associated data.
%%%-------------------------------------------------------------------
-module(damage_context_store).

-author("Steven Joseph <steven@stevenjoseph.in>").
-license("Apache-2.0").

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").
-include_lib("damage.hrl").

-export([
    start_link/0,
    ensure_started/0,
    stop/0,
    ensure_scope/1,
    snapshot/1,
    freeze_snapshot/1,
    witness/3,
    register_redactions/1,
    redactions/1,
    release_redactions/1,
    reload/1,
    apply_changes/4,
    clear/1
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(ETS_TABLE, damage_context_cache).
-define(REDACTION_TABLE, damage_context_redactions).
-define(DETS_TABLE, damage_context_store_dets).
-define(SCHEMA_VERSION, 2).
-define(DEFAULT_MAX_CONTEXT_BYTES, 1048576).
-define(DEFAULT_REDACTION_TTL_SECONDS, 86400).
-define(MASTER_KEY_SECRET, damage_context_store_master_key).
-define(AES_KEY_BYTES, 32).
-define(AES_GCM_IV_BYTES, 12).

-type scope() :: #{
    kind := node | account | wallet | agent,
    owner := binary(),
    id := binary()
}.
-type entry() :: map().
-type snapshot() :: #{
    schema_version := pos_integer(),
    scope := scope(),
    version := non_neg_integer(),
    root := binary(),
    updated_at := non_neg_integer(),
    entries := #{binary() => entry()}
}.

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec ensure_started() -> ok | {error, term()}.
ensure_started() ->
    case whereis(?MODULE) of
        Pid when is_pid(Pid) ->
            ok;
        undefined ->
            case gen_server:start({local, ?MODULE}, ?MODULE, [], []) of
                {ok, _Pid} -> ok;
                {error, {already_started, _Pid}} -> ok;
                {error, Reason} -> {error, Reason}
            end
    end.

-spec stop() -> ok | term().
stop() ->
    case whereis(?MODULE) of
        undefined -> ok;
        Pid -> gen_server:call(Pid, stop)
    end.

-spec ensure_scope(scope()) -> {ok, map()} | {error, term()}.
ensure_scope(Scope) ->
    case snapshot(Scope) of
        {ok, Snapshot} -> {ok, snapshot_summary(Snapshot)};
        {error, _} = Error -> Error
    end.

-spec snapshot(scope()) -> {ok, snapshot()} | {error, term()}.
snapshot(Scope) ->
    case ensure_started() of
        ok ->
            StorageKey = scope_key(Scope),
            case ensure_loaded(StorageKey, Scope) of
                ok ->
                    case ets:lookup(?ETS_TABLE, StorageKey) of
                        [{StorageKey, Snapshot}] -> {ok, Snapshot};
                        [] -> {error, context_not_loaded}
                    end;
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

-spec freeze_snapshot(scope()) -> {ok, snapshot()} | {error, term()}.
freeze_snapshot(Scope) ->
    case ensure_started() of
        ok ->
            gen_server:call(
                ?MODULE,
                {freeze_snapshot, scope_key(Scope), Scope},
                ?AE_TIMEOUT
            );
        {error, _} = Error ->
            Error
    end.

-spec witness(scope(), non_neg_integer(), binary()) -> {ok, map()} | {error, term()}.
witness(Scope, Version, Root) when is_integer(Version), Version >= 0, is_binary(Root) ->
    case ensure_started() of
        ok ->
            gen_server:call(
                ?MODULE,
                {witness, scope_key(Scope), Scope, Version, Root},
                ?AE_TIMEOUT
            );
        {error, _} = Error ->
            Error
    end.

-spec register_redactions([term()]) -> {ok, binary()} | {error, term()}.
register_redactions(Values) when is_list(Values) ->
    case ensure_started() of
        ok -> gen_server:call(?MODULE, {register_redactions, Values}, ?AE_TIMEOUT);
        {error, _} = Error -> Error
    end.

-spec redactions(binary()) -> {ok, [term()]} | {error, term()}.
redactions(Token) when is_binary(Token) ->
    case ensure_started() of
        ok ->
            Now = erlang:monotonic_time(second),
            Key = redaction_key(Token),
            try ets:lookup(?REDACTION_TABLE, Key) of
                [{Key, ExpiresAt, Values}] when ExpiresAt > Now, is_list(Values) ->
                    {ok, Values};
                [{Key, _ExpiresAt, _Values}] ->
                    {error, context_redactions_expired};
                [] ->
                    {error, context_redactions_not_found}
            catch
                error:badarg ->
                    {error, context_redaction_store_unavailable}
            end;
        {error, _} = Error ->
            Error
    end.

-spec release_redactions(binary()) -> ok | {error, term()}.
release_redactions(Token) when is_binary(Token) ->
    case ensure_started() of
        ok -> gen_server:call(?MODULE, {release_redactions, Token}, ?AE_TIMEOUT);
        {error, _} = Error -> Error
    end.

-spec reload(scope()) -> ok | {error, term()}.
reload(Scope) ->
    case ensure_started() of
        ok ->
            gen_server:call(?MODULE, {reload, scope_key(Scope), Scope}, ?AE_TIMEOUT);
        {error, _} = Error ->
            Error
    end.

-spec apply_changes(scope(), #{binary() => entry()}, [binary()], undefined | non_neg_integer()) ->
    {ok, map()} | {error, term()}.
apply_changes(Scope, SetEntries, DeleteKeys, ExpectedVersion) when
    is_map(SetEntries), is_list(DeleteKeys)
->
    case ensure_started() of
        ok ->
            gen_server:call(
                ?MODULE,
                {
                    apply_changes,
                    scope_key(Scope),
                    Scope,
                    SetEntries,
                    DeleteKeys,
                    ExpectedVersion
                },
                ?AE_TIMEOUT
            );
        {error, _} = Error ->
            Error
    end.

-spec clear(scope()) -> {ok, map()} | {error, term()}.
clear(Scope) ->
    case ensure_started() of
        ok ->
            gen_server:call(?MODULE, {clear, scope_key(Scope), Scope}, ?AE_TIMEOUT);
        {error, _} = Error ->
            Error
    end.

init([]) ->
    process_flag(trap_exit, true),
    _ = ensure_ets_table(),
    _ = ensure_redaction_table(),
    StoreFile = context_store_file(),
    ok = filelib:ensure_dir(StoreFile),
    case dets:open_file(?DETS_TABLE, [{file, StoreFile}, {type, set}]) of
        {ok, ?DETS_TABLE} ->
            case load_master_key() of
                {ok, MasterKey} ->
                    {ok, #{store_file => StoreFile, master_key => MasterKey}};
                {error, Reason} ->
                    _ = safe_dets_close(),
                    {stop, {context_master_key_failed, Reason}}
            end;
        {error, Reason} ->
            {stop, {context_store_open_failed, StoreFile, Reason}}
    end.

handle_call(stop, _From, State) ->
    {stop, normal, ok, State};
handle_call({ensure_loaded, StorageKey, Scope}, _From, #{master_key := MasterKey} = State) ->
    {reply, ensure_scope_loaded(StorageKey, Scope, MasterKey), State};
handle_call({freeze_snapshot, StorageKey, Scope}, _From, #{master_key := MasterKey} = State) ->
    {reply, freeze_snapshot_locked(StorageKey, Scope, MasterKey), State};
handle_call({witness, StorageKey, Scope, Version, Root}, _From, State) ->
    {reply, load_snapshot_witness(StorageKey, Scope, Version, Root), State};
handle_call({register_redactions, Values}, _From, State) ->
    {reply, register_redactions_locked(Values), State};
handle_call({release_redactions, Token}, _From, State) ->
    true = ets:delete(?REDACTION_TABLE, redaction_key(Token)),
    {reply, ok, State};
handle_call({reload, StorageKey, Scope}, _From, #{master_key := MasterKey} = State) ->
    true = ets:delete(?ETS_TABLE, StorageKey),
    {reply, ensure_scope_loaded(StorageKey, Scope, MasterKey), State};
handle_call(
    {apply_changes, StorageKey, Scope, SetEntries, DeleteKeys, ExpectedVersion},
    _From,
    #{master_key := MasterKey} = State
) ->
    Reply = mutate_scope(
        StorageKey,
        Scope,
        SetEntries,
        DeleteKeys,
        ExpectedVersion,
        MasterKey
    ),
    {reply, Reply, State};
handle_call({clear, StorageKey, Scope}, _From, #{master_key := MasterKey} = State) ->
    Reply = clear_scope(StorageKey, Scope, MasterKey),
    {reply, Reply, State};
handle_call(Other, _From, State) ->
    ?LOG_WARNING("Unhandled damage_context_store call ~p", [Other]),
    {reply, {error, unsupported_call}, State}.

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    _ = safe_dets_sync(),
    _ = safe_dets_close(),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

ensure_loaded(StorageKey, Scope) ->
    case ets:lookup(?ETS_TABLE, StorageKey) of
        [{StorageKey, _Snapshot}] ->
            ok;
        [] ->
            gen_server:call(?MODULE, {ensure_loaded, StorageKey, Scope}, ?AE_TIMEOUT)
    end.

freeze_snapshot_locked(StorageKey, Scope, MasterKey) ->
    case ensure_scope_loaded(StorageKey, Scope, MasterKey) of
        ok ->
            case ets:lookup(?ETS_TABLE, StorageKey) of
                [{StorageKey, Snapshot}] ->
                    Version = maps:get(version, Snapshot, 0),
                    Root = maps:get(root, Snapshot, <<>>),
                    case ensure_snapshot_witness_retained(
                        StorageKey,
                        Scope,
                        Version,
                        Root
                    ) of
                        ok -> {ok, Snapshot};
                        {error, _} = Error -> Error
                    end;
                [] ->
                    {error, context_not_loaded}
            end;
        {error, _} = Error ->
            Error
    end.

register_redactions_locked(Values0) ->
    Now = erlang:monotonic_time(second),
    prune_expired_redactions(Now),
    Token = crypto:strong_rand_bytes(32),
    ExpiresAt = Now + redaction_ttl_seconds(),
    Values = lists:usort(Values0),
    true = ets:insert(?REDACTION_TABLE, {redaction_key(Token), ExpiresAt, Values}),
    {ok, Token}.

prune_expired_redactions(Now) ->
    _ = ets:foldl(
        fun
            ({{context_redactions, _Token} = Key, ExpiresAt, _Values}, ok) when
                ExpiresAt =< Now
            ->
                true = ets:delete(?REDACTION_TABLE, Key),
                ok;
            (_Row, ok) ->
                ok
        end,
        ok,
        ?REDACTION_TABLE
    ),
    ok.

redaction_key(Token) ->
    {context_redactions, Token}.

redaction_ttl_seconds() ->
    env_pos_int(context_redaction_ttl_seconds, ?DEFAULT_REDACTION_TTL_SECONDS).

ensure_scope_loaded(StorageKey, Scope, MasterKey) ->
    case ets:lookup(?ETS_TABLE, StorageKey) of
        [{StorageKey, _Snapshot}] ->
            ok;
        [] ->
            case dets:lookup(?DETS_TABLE, StorageKey) of
                [] ->
                    true = ets:insert(?ETS_TABLE, {StorageKey, empty_snapshot(Scope)}),
                    ok;
                [{StorageKey, Persisted}] ->
                    case decode_persisted_snapshot(StorageKey, Scope, Persisted, MasterKey) of
                        {ok, Snapshot} ->
                            true = ets:insert(?ETS_TABLE, {StorageKey, Snapshot}),
                            ok;
                        {error, _} = Error ->
                            Error
                    end;
                Other ->
                    {error, {invalid_context_store_row, Other}}
            end
    end.

mutate_scope(StorageKey, Scope, SetEntries, DeleteKeys, ExpectedVersion, MasterKey) ->
    case ensure_scope_loaded(StorageKey, Scope, MasterKey) of
        ok ->
            [{StorageKey, Current}] = ets:lookup(?ETS_TABLE, StorageKey),
            CurrentVersion = maps:get(version, Current, 0),
            case version_matches(ExpectedVersion, CurrentVersion) of
                false ->
                    {error, {version_conflict, CurrentVersion}};
                true ->
                    CurrentEntries = maps:get(entries, Current, #{}),
                    EntriesWithoutDeleted = maps:without(DeleteKeys, CurrentEntries),
                    UpdatedEntries = merge_set_entries(SetEntries, EntriesWithoutDeleted),
                    case UpdatedEntries =:= CurrentEntries of
                        true ->
                            {ok, snapshot_summary(Current)};
                        false ->
                            Now = erlang:system_time(second),
                            Candidate = #{
                                schema_version => ?SCHEMA_VERSION,
                                scope => Scope,
                                version => CurrentVersion + 1,
                                updated_at => Now,
                                entries => UpdatedEntries
                            },
                            case persist_snapshot(StorageKey, Candidate, MasterKey) of
                                {ok, Snapshot} ->
                                    true = ets:insert(?ETS_TABLE, {StorageKey, Snapshot}),
                                    {ok, snapshot_summary(Snapshot)};
                                {error, _} = Error ->
                                    Error
                            end
                    end
            end;
        {error, _} = Error ->
            Error
    end.

clear_scope(StorageKey, Scope, MasterKey) ->
    case ensure_scope_loaded(StorageKey, Scope, MasterKey) of
        ok ->
            [{StorageKey, Snapshot}] = ets:lookup(?ETS_TABLE, StorageKey),
            Keys = maps:keys(maps:get(entries, Snapshot, #{})),
            mutate_scope(StorageKey, Scope, #{}, Keys, undefined, MasterKey);
        {error, _} = Error ->
            Error
    end.

merge_set_entries(SetEntries, Entries0) ->
    maps:fold(
        fun(Key, NewEntry, Acc) ->
            case maps:find(Key, Acc) of
                {ok, OldEntry} ->
                    case entry_semantically_equal(OldEntry, NewEntry) of
                        true -> Acc;
                        false -> maps:put(Key, NewEntry, Acc)
                    end;
                error ->
                    maps:put(Key, NewEntry, Acc)
            end
        end,
        Entries0,
        SetEntries
    ).

entry_semantically_equal(OldEntry, NewEntry) ->
    maps:remove(updated_at, OldEntry) =:= maps:remove(updated_at, NewEntry).

version_matches(undefined, _Current) -> true;
version_matches(Expected, Current) -> Expected =:= Current.

persist_snapshot(StorageKey, Snapshot0, MasterKey) ->
    Payload = maps:without([root], Snapshot0),
    Plaintext = term_to_binary(Payload, [compressed]),
    MaxBytes = env_pos_int(context_max_bytes, ?DEFAULT_MAX_CONTEXT_BYTES),
    case byte_size(Plaintext) =< MaxBytes of
        false ->
            {error, {context_too_large, byte_size(Plaintext), MaxBytes}};
        true ->
            try
                Version = maps:get(version, Payload),
                IV = crypto:strong_rand_bytes(?AES_GCM_IV_BYTES),
                AAD = snapshot_aad(StorageKey, Version),
                DataKey = derive_scope_key(MasterKey, StorageKey),
                {Ciphertext, Tag} = crypto:crypto_one_time_aead(
                    aes_256_gcm,
                    DataKey,
                    IV,
                    Plaintext,
                    AAD,
                    true
                ),
                Root = sha256_hex(<<IV/binary, Tag/binary, Ciphertext/binary>>),
                Persisted = #{
                    schema_version => ?SCHEMA_VERSION,
                    version => Version,
                    updated_at => maps:get(updated_at, Payload),
                    root => Root,
                    iv => IV,
                    tag => Tag,
                    ciphertext => Ciphertext
                },
                HistoryKey = snapshot_history_key(StorageKey, Version),
                case dets:insert(
                    ?DETS_TABLE,
                    [
                        {StorageKey, Persisted},
                        {HistoryKey, Persisted}
                    ]
                ) of
                    ok ->
                        ok = maybe_sync_store(),
                        {ok, Payload#{root => Root}};
                    {error, Reason} ->
                        {error, {context_store_write_failed, Reason}}
                end
            catch
                Class:Reason0:Stacktrace ->
                    ?LOG_ERROR(
                        "Context snapshot persistence failed class=~p reason=~p stack=~p",
                        [Class, Reason0, Stacktrace]
                    ),
                    {error, {context_encrypt_failed, Class, Reason0}}
            end
    end.

ensure_snapshot_witness_retained(_StorageKey, Scope, 0, Root) ->
    EmptySnapshot = empty_snapshot(Scope),
    case secure_equal(Root, maps:get(root, EmptySnapshot)) of
        true -> ok;
        false -> {error, context_snapshot_root_mismatch}
    end;
ensure_snapshot_witness_retained(StorageKey, _Scope, Version, Root) when Version > 0 ->
    case lookup_persisted_snapshot(StorageKey, Version, Root) of
        {ok, _Persisted} -> ok;
        {error, _} = Error -> Error
    end.

load_snapshot_witness(StorageKey, Scope, 0, Root) ->
    case ensure_snapshot_witness_retained(StorageKey, Scope, 0, Root) of
        ok ->
            Preimage = term_to_binary(
                {?SCHEMA_VERSION, StorageKey, 0, []},
                [deterministic]
            ),
            {ok, #{
                format => <<"empty-context-v1">>,
                schema_version => ?SCHEMA_VERSION,
                version => 0,
                root => Root,
                preimage_b64 => base64:encode(Preimage)
            }};
        {error, _} = Error ->
            Error
    end;
load_snapshot_witness(StorageKey, _Scope, Version, Root) when Version > 0 ->
    case lookup_persisted_snapshot(StorageKey, Version, Root) of
        {ok, Persisted} ->
            persisted_witness(StorageKey, Version, Root, Persisted);
        {error, _} = Error ->
            Error
    end.

lookup_persisted_snapshot(StorageKey, Version, Root) ->
    HistoryKey = snapshot_history_key(StorageKey, Version),
    case dets:lookup(?DETS_TABLE, HistoryKey) of
        [{HistoryKey, Persisted}] ->
            validate_persisted_snapshot(Version, Root, Persisted);
        [] ->
            %% Backfill installations created before versioned witness rows.
            case dets:lookup(?DETS_TABLE, StorageKey) of
                [{StorageKey, Persisted}] ->
                    case validate_persisted_snapshot(Version, Root, Persisted) of
                        {ok, Persisted} = Ok ->
                            case dets:insert(?DETS_TABLE, {HistoryKey, Persisted}) of
                                ok ->
                                    ok = maybe_sync_store(),
                                    Ok;
                                {error, Reason} ->
                                    {error, {context_witness_backfill_failed, Reason}}
                            end;
                        {error, _} = Error ->
                            Error
                    end;
                [] ->
                    {error, {context_snapshot_witness_not_found, Version}};
                Other ->
                    {error, {invalid_context_store_row, Other}}
            end;
        Other ->
            {error, {invalid_context_witness_row, Other}}
    end.

validate_persisted_snapshot(Version, Root, Persisted) when is_map(Persisted) ->
    PersistedVersion = maps:get(version, Persisted, undefined),
    PersistedRoot = maps:get(root, Persisted, <<>>),
    case PersistedVersion =:= Version andalso secure_equal(PersistedRoot, Root) of
        true ->
            IV = maps:get(iv, Persisted),
            Tag = maps:get(tag, Persisted),
            Ciphertext = maps:get(ciphertext, Persisted),
            ActualRoot = sha256_hex(<<IV/binary, Tag/binary, Ciphertext/binary>>),
            case secure_equal(ActualRoot, Root) of
                true -> {ok, Persisted};
                false -> {error, context_snapshot_root_mismatch}
            end;
        false ->
            {error, {
                context_snapshot_witness_mismatch,
                #{
                    expected_version => Version,
                    actual_version => PersistedVersion,
                    expected_root => Root,
                    actual_root => PersistedRoot
                }
            }}
    end;
validate_persisted_snapshot(_Version, _Root, Other) ->
    {error, {invalid_context_snapshot, Other}}.

persisted_witness(StorageKey, Version, Root, Persisted) ->
    IV = maps:get(iv, Persisted),
    Tag = maps:get(tag, Persisted),
    Ciphertext = maps:get(ciphertext, Persisted),
    {ok, #{
        format => <<"aes-256-gcm-v1">>,
        schema_version => maps:get(schema_version, Persisted, ?SCHEMA_VERSION),
        version => Version,
        root => Root,
        iv_b64 => base64:encode(IV),
        tag_b64 => base64:encode(Tag),
        ciphertext_b64 => base64:encode(Ciphertext),
        aad_b64 => base64:encode(snapshot_aad(StorageKey, Version))
    }}.

snapshot_history_key(StorageKey, Version) ->
    {context_snapshot, StorageKey, Version}.

decode_persisted_snapshot(StorageKey, Scope, Persisted, MasterKey) when is_map(Persisted) ->
    try
        Version = maps:get(version, Persisted),
        IV = maps:get(iv, Persisted),
        Tag = maps:get(tag, Persisted),
        Ciphertext = maps:get(ciphertext, Persisted),
        StoredRoot = maps:get(root, Persisted),
        ActualRoot = sha256_hex(<<IV/binary, Tag/binary, Ciphertext/binary>>),
        case secure_equal(StoredRoot, ActualRoot) of
            false ->
                {error, context_snapshot_root_mismatch};
            true ->
                AAD = snapshot_aad(StorageKey, Version),
                DataKey = derive_scope_key(MasterKey, StorageKey),
                Plaintext = crypto:crypto_one_time_aead(
                    aes_256_gcm,
                    DataKey,
                    IV,
                    Ciphertext,
                    AAD,
                    Tag,
                    false
                ),
                Payload = binary_to_term(Plaintext, [safe]),
                validate_loaded_payload(Scope, Payload, ActualRoot)
        end
    catch
        Class:Reason:Stacktrace ->
            ?LOG_ERROR(
                "Context snapshot load failed scope=~p class=~p reason=~p stack=~p",
                [Scope, Class, Reason, Stacktrace]
            ),
            {error, {context_snapshot_decode_failed, Class, Reason}}
    end;
decode_persisted_snapshot(_StorageKey, _Scope, Other, _MasterKey) ->
    {error, {invalid_context_snapshot, Other}}.

validate_loaded_payload(
    Scope,
    #{
        schema_version := ?SCHEMA_VERSION,
        scope := Scope,
        version := Version,
        updated_at := UpdatedAt,
        entries := Entries
    } = Payload,
    Root
) when is_integer(Version), Version >= 0, is_integer(UpdatedAt), is_map(Entries) ->
    {ok, Payload#{root => Root}};
validate_loaded_payload(Scope, Payload, _Root) ->
    {error, {invalid_context_payload, Scope, Payload}}.

empty_snapshot(Scope) ->
    Payload = #{
        schema_version => ?SCHEMA_VERSION,
        scope => Scope,
        version => 0,
        updated_at => 0,
        entries => #{}
    },
    Root = sha256_hex(
        term_to_binary(
            {?SCHEMA_VERSION, scope_key(Scope), 0, []},
            [deterministic]
        )
    ),
    Payload#{root => Root}.

snapshot_summary(Snapshot) ->
    maps:with([schema_version, scope, version, root, updated_at], Snapshot).

snapshot_aad(StorageKey, Version) ->
    term_to_binary(
        {damage_context, ?SCHEMA_VERSION, StorageKey, Version},
        [deterministic]
    ).

derive_scope_key(MasterKey, StorageKey) ->
    crypto:mac(
        hmac,
        sha256,
        MasterKey,
        term_to_binary(
            {damage_context_scope_key, ?SCHEMA_VERSION, StorageKey},
            [deterministic]
        )
    ).

scope_key(#{kind := Kind, owner := Owner, id := Id}) ->
    {Kind, Owner, Id}.

load_master_key() ->
    case application:get_env(damage, context_store_master_key) of
        {ok, Configured} ->
            normalize_master_key(Configured);
        _ ->
            load_or_create_master_key()
    end.

load_or_create_master_key() ->
    case master_key_secret_status() of
        present ->
            load_existing_master_key();
        absent ->
            case context_store_has_rows() of
                true ->
                    {error, master_key_missing_for_existing_context_store};
                false ->
                    create_master_key()
            end;
        {error, Reason} ->
            {error, {master_key_lookup_failed, Reason}}
    end.

master_key_secret_status() ->
    try secrets:retrieve_secret(?MASTER_KEY_SECRET) of
        [] ->
            absent;
        [{?MASTER_KEY_SECRET, {_IV, _CipherText, _Tag}}] ->
            present;
        Other ->
            {error, {invalid_master_key_secret_row, Other}}
    catch
        Class:Reason:Stacktrace ->
            ?LOG_ERROR(
                "Context master key presence check failed class=~p reason=~p stack=~p",
                [Class, Reason, Stacktrace]
            ),
            {error, {Class, Reason}}
    end.

load_existing_master_key() ->
    try secrets:retrieve_decrypt(?MASTER_KEY_SECRET) of
        {ok, Stored} ->
            normalize_master_key(Stored);
        error ->
            {error, master_key_unavailable};
        {error, Reason} ->
            {error, {master_key_unavailable, Reason}};
        Other ->
            {error, {invalid_master_key_lookup_result, Other}}
    catch
        Class:Reason:Stacktrace ->
            ?LOG_ERROR(
                "Context master key decrypt failed class=~p reason=~p stack=~p",
                [Class, Reason, Stacktrace]
            ),
            {error, {master_key_decrypt_failed, Class, Reason}}
    end.

context_store_has_rows() ->
    case dets:info(?DETS_TABLE, size) of
        Size when is_integer(Size), Size > 0 -> true;
        _ -> false
    end.

create_master_key() ->
    MasterKey = crypto:strong_rand_bytes(?AES_KEY_BYTES),
    try secrets:encrypt_store(?MASTER_KEY_SECRET, MasterKey) of
        ok -> {ok, MasterKey};
        {ok, _} -> {ok, MasterKey};
        Other -> {error, {master_key_store_failed, Other}}
    catch
        Class:Reason:Stacktrace ->
            ?LOG_ERROR(
                "Context master key creation failed class=~p reason=~p stack=~p",
                [Class, Reason, Stacktrace]
            ),
            {error, {master_key_store_failed, Class, Reason}}
    end.

normalize_master_key(Value0) ->
    Value = to_binary(Value0),
    case byte_size(Value) of
        ?AES_KEY_BYTES -> {ok, Value};
        0 -> {error, empty_context_master_key};
        _ -> {ok, crypto:hash(sha256, Value)}
    end.

ensure_ets_table() ->
    case ets:info(?ETS_TABLE) of
        undefined ->
            ets:new(?ETS_TABLE, [
                named_table,
                protected,
                set,
                {read_concurrency, true},
                {write_concurrency, true}
            ]);
        _ ->
            ?ETS_TABLE
    end.

ensure_redaction_table() ->
    case ets:info(?REDACTION_TABLE) of
        undefined ->
            ets:new(?REDACTION_TABLE, [
                named_table,
                protected,
                set,
                {read_concurrency, true},
                {write_concurrency, true}
            ]);
        _ ->
            ?REDACTION_TABLE
    end.

context_store_file() ->
    case application:get_env(damage, context_store_file) of
        {ok, File} when is_binary(File) -> binary_to_list(File);
        {ok, File} when is_list(File) -> File;
        _ ->
            DataDir =
                case application:get_env(damage, context_data_dir) of
                    {ok, Dir} when is_binary(Dir) -> binary_to_list(Dir);
                    {ok, Dir} when is_list(Dir) -> Dir;
                    _ -> "data"
                end,
            filename:join(DataDir, "damage_context_v2.dets")
    end.

maybe_sync_store() ->
    case application:get_env(damage, context_sync_writes, true) of
        false -> ok;
        {ok, false} -> ok;
        _ -> dets:sync(?DETS_TABLE)
    end.

safe_dets_sync() ->
    try dets:sync(?DETS_TABLE) of
        Result -> Result
    catch
        _:_ -> ok
    end.

safe_dets_close() ->
    try dets:close(?DETS_TABLE) of
        Result -> Result
    catch
        _:_ -> ok
    end.

sha256_hex(Data) ->
    lower_hex(crypto:hash(sha256, Data)).

lower_hex(Bin) ->
    list_to_binary(string:lowercase(binary_to_list(binary:encode_hex(Bin)))).

secure_equal(A0, B0) ->
    A = to_binary(A0),
    B = to_binary(B0),
    case byte_size(A) =:= byte_size(B) of
        false -> false;
        true -> secure_equal_bytes(A, B, 0) =:= 0
    end.

secure_equal_bytes(<<>>, <<>>, Acc) ->
    Acc;
secure_equal_bytes(<<A, ARest/binary>>, <<B, BRest/binary>>, Acc) ->
    secure_equal_bytes(ARest, BRest, Acc bor (A bxor B)).

env_pos_int(Key, Default) ->
    case application:get_env(damage, Key) of
        {ok, Value} when is_integer(Value), Value > 0 ->
            Value;
        {ok, Value} when is_binary(Value) ->
            parse_pos_int(Value, Default);
        {ok, Value} when is_list(Value) ->
            parse_pos_int(Value, Default);
        _ ->
            Default
    end.

parse_pos_int(Value, Default) ->
    try list_to_integer(binary_to_list(to_binary(Value))) of
        Integer when Integer > 0 -> Integer;
        _ -> Default
    catch
        _:_ -> Default
    end.

to_binary(Value) when is_binary(Value) -> Value;
to_binary(Value) when is_list(Value) -> unicode:characters_to_binary(Value);
to_binary(Value) when is_atom(Value) -> atom_to_binary(Value, utf8);
to_binary(Value) -> unicode:characters_to_binary(io_lib:format("~p", [Value])).
