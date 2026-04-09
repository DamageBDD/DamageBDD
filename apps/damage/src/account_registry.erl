%% account_registry.erl
%% Thin wrapper around contracts/AccountRegistry.aes

-module(account_registry).

-include_lib("kernel/include/logger.hrl").

-export([
    register_contract/4,
    register_contract/3,
    update_contract/4,
    get_contract/2,
    get_contract/3,
    get_registered_names/2,
    get_all_contracts/2,
    deploy_account_registry/1,
    invalidate_cache/0,
    invalidate_cache/2,
    invalidate_registry_cache/1,
    cache_ttl/0
]).
-export([test/0]).
-import(damage_utils, [to_bin/1]).

-type keypair() :: #{public_key := binary() | list(), private_key := binary()}.
-type contract_id() :: binary() | list().
-type name() :: binary() | list().

-define(CONTRACT_PATH, "contracts/account_registry.aes").
-define(CACHE_TABLE, account_registry_cache).
-define(DEFAULT_CACHE_TTL_SECONDS, 3000).

-spec ct_id(map()) -> binary().
ct_id(Opts) ->
    case maps:get(ct, Opts, undefined) of
        <<"ct_", _/binary>> = Ct ->
            Ct;
        _ ->
            case application:get_env(damage, account_registry_ct) of
                {ok, C} -> C;
                _ -> error({missing_contract_id, account_registry_ct})
            end
    end.

cache_ttl() ->
    application:get_env(damage, account_registry_cache_ttl_seconds, ?DEFAULT_CACHE_TTL_SECONDS).

ensure_cache_table() ->
    case ets:info(?CACHE_TABLE) of
        undefined ->
            ets:new(?CACHE_TABLE, [named_table, public, set, {read_concurrency, true}]),
            ok;
        _ ->
            ok
    end.

cache_now() ->
    erlang:monotonic_time(second).

cache_key_get_contract(RegistryId, Name) ->
    {get_contract, to_bin(RegistryId), to_bin(Name)}.

cache_key_get_registered_names(RegistryId) ->
    {get_registered_names, to_bin(RegistryId)}.

cache_key_get_all_contracts(RegistryId) ->
    {get_all_contracts, to_bin(RegistryId)}.

cache_get(Key) ->
    ensure_cache_table(),
    Now = cache_now(),
    case ets:lookup(?CACHE_TABLE, Key) of
        [{Key, Value, ExpiresAt}] when ExpiresAt > Now ->
            {ok, Value};
        [{Key, _Value, _ExpiresAt}] ->
            ets:delete(?CACHE_TABLE, Key),
            miss;
        [] ->
            miss
    end.

cache_put(Key, Value) ->
    ensure_cache_table(),
    ExpiresAt = cache_now() + cache_ttl(),
    ets:insert(?CACHE_TABLE, {Key, Value, ExpiresAt}),
    ok.

invalidate_cache() ->
    ensure_cache_table(),
    ets:delete_all_objects(?CACHE_TABLE),
    ok.

invalidate_cache(RegistryId, Name) ->
    ensure_cache_table(),
    ets:delete(?CACHE_TABLE, cache_key_get_contract(RegistryId, Name)),
    ets:delete(?CACHE_TABLE, cache_key_get_registered_names(RegistryId)),
    ets:delete(?CACHE_TABLE, cache_key_get_all_contracts(RegistryId)),
    ok.

invalidate_registry_cache(RegistryId) ->
    ensure_cache_table(),
    ets:delete(?CACHE_TABLE, cache_key_get_registered_names(RegistryId)),
    ets:delete(?CACHE_TABLE, cache_key_get_all_contracts(RegistryId)),
    ok.

%%--------------------------------------------------------------------
%% Deployment helpers
%%--------------------------------------------------------------------

deploy_account_registry(AeAccount) when is_binary(AeAccount) ->
    Keypair =
        #{public_key := _PubKey, private_key := PrivateKey} =
        identity_server:get_account(AeAccount),
    damage_ae:set_private_key(AeAccount, PrivateKey),
    deploy_account_registry(Keypair);
deploy_account_registry(AccountKeypair) when is_map(AccountKeypair) ->
    #{"contract_id" := ContractId} = damage_ae:contract_deploy_for(
        AccountKeypair, damage_ae:contract_path(?CONTRACT_PATH), []
    ),
    ContractId.

%%--------------------------------------------------------------------
%% Write entrypoints (stateful)
%%--------------------------------------------------------------------

-spec register_contract(keypair(), name(), contract_id()) ->
    {ok, boolean()} | {error, term()}.
register_contract(KeyPair, Name, ContractId) ->
    register_contract(KeyPair, ct_id(#{}), Name, ContractId).

-spec register_contract(keypair(), contract_id(), name(), contract_id()) ->
    {ok, boolean()} | {error, term()}.
register_contract(KeyPair, RegistryId, Name, ContractId) ->
    case
        call_bool(
            KeyPair,
            RegistryId,
            "register_contract",
            [to_str(Name), to_str(ContractId)]
        )
    of
        {ok, Bool} = Ok ->
            invalidate_cache(RegistryId, Name),
            Ok;
        Error ->
            Error
    end.

-spec update_contract(keypair(), contract_id(), name(), contract_id()) ->
    {ok, boolean()} | {error, term()}.
update_contract(KeyPair, RegistryId, Name, ContractId) ->
    case
        call_bool(
            KeyPair,
            RegistryId,
            "update_contract",
            [to_str(Name), to_str(ContractId)]
        )
    of
        {ok, Bool} = Ok ->
            invalidate_cache(RegistryId, Name),
            Ok;
        Error ->
            Error
    end.

%%--------------------------------------------------------------------
%% Read entrypoints (pure)
%%--------------------------------------------------------------------

-spec get_contract(keypair(), name()) ->
    {ok, contract_id()} | {error, term()}.
get_contract(KeyPair, Name) ->
    get_contract(KeyPair, ct_id(#{}), Name).

-spec get_contract(keypair(), contract_id(), name()) ->
    {ok, contract_id()} | {error, term()}.
get_contract(#{public_key := Pub0, private_key := Priv}, RegistryId, Name) ->
    CacheKey = cache_key_get_contract(RegistryId, Name),
    case cache_get(CacheKey) of
        {ok, ContractPubkey} ->
            {ok, ContractPubkey};
        miss ->
            case
                call_value(
                    #{public_key => to_bin(Pub0), private_key => Priv},
                    RegistryId,
                    "get_contract",
                    [to_str(Name)]
                )
            of
                {ok, {address, AddrBin}} ->
                    Encoded = aeser_api_encoder:encode(contract_pubkey, AddrBin),
                    cache_put(CacheKey, Encoded),
                    {ok, Encoded};
                Error ->
                    Error
            end
    end.

-spec get_registered_names(keypair(), contract_id()) ->
    {ok, [string()]} | {error, term()}.
get_registered_names(KeyPair, RegistryId) ->
    CacheKey = cache_key_get_registered_names(RegistryId),
    case cache_get(CacheKey) of
        {ok, Names} ->
            {ok, Names};
        miss ->
            case call_value(KeyPair, RegistryId, "get_registered_names", []) of
                {ok, Names} = Ok ->
                    cache_put(CacheKey, Names),
                    Ok;
                Error ->
                    Error
            end
    end.

-spec get_all_contracts(keypair(), contract_id()) ->
    {ok, map()} | {error, term()}.
get_all_contracts(KeyPair, RegistryId) ->
    CacheKey = cache_key_get_all_contracts(RegistryId),
    case cache_get(CacheKey) of
        {ok, Contracts} ->
            {ok, Contracts};
        miss ->
            case call_value(KeyPair, RegistryId, "get_all_contracts", []) of
                {ok, Contracts} = Ok ->
                    cache_put(CacheKey, Contracts),
                    Ok;
                Error ->
                    Error
            end
    end.

%%--------------------------------------------------------------------
%% Internal helpers
%%--------------------------------------------------------------------

call_value(#{public_key := AeAccount, private_key := PrivateKey} = KeyPair, RegistryId, Fun, Args) ->
    ContractIdStr = to_str(RegistryId),
    damage_ae:set_private_key(AeAccount, PrivateKey),
    ?LOG_DEBUG("call_value ~p ~p ~p ~p ~p", [
        KeyPair,
        ContractIdStr,
        damage_ae:contract_path(?CONTRACT_PATH),
        Fun,
        Args
    ]),
    case
        damage_ae:contract_call_payfor_user(
            to_bin(AeAccount),
            ContractIdStr,
            damage_ae:contract_path(?CONTRACT_PATH),
            Fun,
            Args
        )
    of
        #{"return_type" := "ok", "return_value" := Value} ->
            {ok, Value};
        #{"return_type" := Type} = Info ->
            ?LOG_WARNING(
                "Unexpected return_type ~p from ~p:~p/~p -> ~p",
                [Type, ?CONTRACT_PATH, Fun, length(Args), Info]
            ),
            {error, {unexpected_return_type, Type, Info}};
        {error, Reason} ->
            {error, Reason};
        Other ->
            {error, {unexpected_result, Other}}
    end.

call_bool(KeyPair, RegistryId, Fun, Args) ->
    case call_value(KeyPair, RegistryId, Fun, Args) of
        {ok, true} -> {ok, true};
        {ok, false} -> {ok, false};
        {ok, Other} -> {error, {non_boolean_return, Other}};
        Error -> Error
    end.

to_str(B) when is_binary(B) -> binary_to_list(B);
to_str(L) when is_list(L) -> L.

test() ->
    KP = identity_server:get_account(
        <<"ak_ag9FGrk8okPzGJZzWL7UuK21NYckM6Tsbtaapmv3iFM4Hn8dW">>
    ),
    get_contract(
        KP,
        "ct_xraS4aWmvMTxXcuWnaZMi3iQVdmtyC94xeeAnbLyynt1K5XgR",
        "nwc_ledger"
    ).
