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
    deploy_account_registry/1
]).

-type keypair() :: #{public_key := binary() | list(), private_key := binary()}.
-type contract_id() :: binary() | list().
-type name() :: binary() | list().

-define(CONTRACT_PATH, "contracts/account_registry.aes").

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
    call_bool(
        KeyPair,
        RegistryId,
        "register_contract",
        [to_str(Name), to_str(ContractId)]
    ).

-spec update_contract(keypair(), contract_id(), name(), contract_id()) ->
    {ok, boolean()} | {error, term()}.
update_contract(KeyPair, RegistryId, Name, ContractId) ->
    call_bool(
        KeyPair,
        RegistryId,
        "update_contract",
        [to_str(Name), to_str(ContractId)]
    ).

%%--------------------------------------------------------------------
%% Read entrypoints (pure)
%%--------------------------------------------------------------------

-spec get_contract(keypair(), name()) ->
    {ok, contract_id()} | {error, term()}.
get_contract(KeyPair, Name) ->
    get_contract(KeyPair, ct_id(#{}), Name).

-spec get_contract(keypair(), contract_id(), name()) ->
    {ok, contract_id()} | {error, term()}.
get_contract(KeyPair, RegistryId, Name) ->
    {ok, {address, Address}} =
        call_value(
            KeyPair,
            RegistryId,
            "get_contract",
            [to_str(Name)]
        ),

    {ok, aeser_api_encoder:encode(contract_pubkey, Address)}.

-spec get_registered_names(keypair(), contract_id()) ->
    {ok, [string()]} | {error, term()}.
get_registered_names(KeyPair, RegistryId) ->
    call_value(
        KeyPair,
        RegistryId,
        "get_registered_names",
        []
    ).

-spec get_all_contracts(keypair(), contract_id()) ->
    {ok, map()} | {error, term()}.
get_all_contracts(KeyPair, RegistryId) ->
    call_value(
        KeyPair,
        RegistryId,
        "get_all_contracts",
        []
    ).

%%--------------------------------------------------------------------
%% Internal helpers
%%--------------------------------------------------------------------

%% Generic contract_call wrapper returning just {ok, Value} | {error, Reason}
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
            AeAccount,
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

%% Same as call_value but enforces boolean return
call_bool(KeyPair, RegistryId, Fun, Args) ->
    case call_value(KeyPair, RegistryId, Fun, Args) of
        {ok, true} -> {ok, true};
        {ok, false} -> {ok, false};
        {ok, Other} -> {error, {non_boolean_return, Other}};
        Error -> Error
    end.

%% Accept binaries or lists for all string / id args
to_str(B) when is_binary(B) -> binary_to_list(B);
to_str(L) when is_list(L) -> L.
