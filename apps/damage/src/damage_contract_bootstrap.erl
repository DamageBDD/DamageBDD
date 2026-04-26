%% damage_contract_bootstrap.erl
-module(damage_contract_bootstrap).

-author("Steven Joseph <steven@stevenjoseph.in>").
-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").

-export([
    bootstrap_node_only/0,
    bootstrap_node_admin/1,
    ensure_node_registry/0,
    ensure_admin_account_registry/1,
    ensure_named_contracts/2,
    init_admin_contracts/1
]).
-export([
    bootstrap_user_account/1,
    ensure_user_account_registry/1,
    ensure_user_named_contracts/2
]).

-define(USER_REQUIRED_CONTRACTS, [
    {nwc_ledger, fun deploy_user_nwc_ledger/1}
]).

-define(ADMIN_REQUIRED_CONTRACTS, [
    {agent_registry, agent_registry_ct, fun deploy_agent_registry/1},
    {agent_policy, agent_policy_ct, fun deploy_agent_policy/1},
    {agent_treasury, agent_treasury_ct, fun deploy_agent_treasury/1},
    {agent_execution_ledger, agent_execution_ledger_ct, fun deploy_agent_execution_ledger/1},
    {nwc_session_registry, nwc_session_registry_ct, fun deploy_nwc_session_registry/1}
]).

bootstrap_node_only() ->
    {ok, NodeRegistryCt} = ensure_node_registry(),
    {ok, #{node_registry => NodeRegistryCt}}.

bootstrap_node_admin(NodeAdminAccount) ->
    {ok, _NodeRegistryCt} = ensure_node_registry(),
    {ok, RegistryCt} = ensure_admin_account_registry(NodeAdminAccount),
    ensure_named_contracts(NodeAdminAccount, RegistryCt).
-spec secret_ct(atom()) -> {ok, binary()} | error.
secret_ct(Key) ->
    case secrets:retrieve_decrypt(Key) of
        {ok, <<"ct_", _/binary>> = CtId} ->
            {ok, CtId};
        {ok, CtId} when is_list(CtId) ->
            {ok, list_to_binary(CtId)};
        _ ->
            error
    end.

normalize_ct(<<"ct_", _/binary>> = Ct) -> Ct;
normalize_ct(Ct) when is_list(Ct) -> list_to_binary(Ct).

-spec persist_ct(atom(), binary()) -> ok.
persist_ct(Key, CtId0) ->
    CtId = normalize_ct(CtId0),
    secrets:encrypt_store(Key, CtId).

-spec init_admin_contracts(binary()) -> {ok, map()} | {error, term()}.
init_admin_contracts(NodeAdminAccount) ->
    damage_contract_bootstrap:bootstrap_node_admin(NodeAdminAccount).
ensure_node_registry() ->
    case secret_ct(node_registry_ct) of
        {ok, Ct} ->
            ok = application:set_env(damage, node_registry_ct, Ct),
            ok = damage_node_registry:set_contract(Ct),
            {ok, Ct};
        error ->
            case application:get_env(damage, node_registry_ct) of
                {ok, <<"ct_", _/binary>> = Ct} ->
                    ok = persist_ct(node_registry_ct, Ct),
                    ok = damage_node_registry:set_contract(Ct),
                    {ok, Ct};
                {ok, Ct} when is_list(Ct) ->
                    CtBin = list_to_binary(Ct),
                    ok = persist_ct(node_registry_ct, CtBin),
                    ok = application:set_env(damage, node_registry_ct, CtBin),
                    ok = damage_node_registry:set_contract(CtBin),
                    {ok, CtBin};
                _ ->
                    Ct = damage_node_registry:deploy_node_registry(),
                    ok = persist_ct(node_registry_ct, Ct),
                    ok = application:set_env(damage, node_registry_ct, Ct),
                    ok = damage_node_registry:set_contract(Ct),
                    {ok, Ct}
            end
    end.

ensure_admin_account_registry(NodeAdminAccount) ->
    damage_node_registry:ensure_account_registry(NodeAdminAccount, <<"node_admin">>).

ensure_named_contracts(NodeAdminAccount, RegistryCt) ->
    KeyPair = identity_server:get_account(NodeAdminAccount),
    ensure_named_contracts(KeyPair, RegistryCt, ?ADMIN_REQUIRED_CONTRACTS, #{}).

ensure_named_contracts(_KeyPair, _RegistryCt, [], Acc) ->
    {ok, Acc};
ensure_named_contracts(KeyPair, RegistryCt, [{Name, EnvKey, DeployFun} | Rest], Acc) ->
    NameBin = atom_to_binary(Name, utf8),
    case resolve_or_init_contract(KeyPair, RegistryCt, NameBin, EnvKey, DeployFun) of
        {ok, CtId} ->
            ensure_named_contracts(KeyPair, RegistryCt, Rest, Acc#{Name => CtId});
        Error ->
            Error
    end.

resolve_or_init_contract(KeyPair, RegistryCt, NameBin, EnvKey, DeployFun) ->
    case secret_ct(EnvKey) of
        {ok, CtId} ->
            _ = account_registry:register_contract(KeyPair, RegistryCt, NameBin, CtId),
            ok = application:set_env(damage, EnvKey, CtId),
            {ok, CtId};
        error ->
            case account_registry:get_contract(KeyPair, RegistryCt, NameBin) of
                {ok, <<"ct_", _/binary>> = CtId} ->
                    ok = persist_ct(EnvKey, CtId),
                    ok = application:set_env(damage, EnvKey, CtId),
                    {ok, CtId};
                _ ->
                    case application:get_env(damage, EnvKey) of
                        {ok, <<"ct_", _/binary>> = CtId} ->
                            _ = account_registry:register_contract(
                                KeyPair, RegistryCt, NameBin, CtId
                            ),
                            ok = persist_ct(EnvKey, CtId),
                            ok = application:set_env(damage, EnvKey, CtId),
                            {ok, CtId};
                        {ok, CtId} when is_list(CtId) ->
                            CtBin = list_to_binary(CtId),
                            _ = account_registry:register_contract(
                                KeyPair, RegistryCt, NameBin, CtBin
                            ),
                            ok = persist_ct(EnvKey, CtBin),
                            ok = application:set_env(damage, EnvKey, CtBin),
                            {ok, CtBin};
                        _ ->
                            CtId = DeployFun(KeyPair),
                            case
                                account_registry:register_contract(
                                    KeyPair, RegistryCt, NameBin, CtId
                                )
                            of
                                {ok, true} ->
                                    ok = persist_ct(EnvKey, CtId),
                                    ok = application:set_env(damage, EnvKey, CtId),
                                    {ok, CtId};
                                {ok, false} ->
                                    case
                                        account_registry:get_contract(KeyPair, RegistryCt, NameBin)
                                    of
                                        {ok, ResolvedCt} ->
                                            ok = persist_ct(EnvKey, ResolvedCt),
                                            ok = application:set_env(damage, EnvKey, ResolvedCt),
                                            {ok, ResolvedCt};
                                        Error ->
                                            Error
                                    end;
                                Error ->
                                    Error
                            end
                    end
            end
    end.

deploy_agent_registry(KeyPair) ->
    #{"contract_id" := CtId} =
        damage_ae:contract_deploy_for(
            KeyPair,
            damage_ae:contract_path(damage, "contracts/agent_registry.aes"),
            []
        ),
    CtId.

deploy_agent_policy(KeyPair) ->
    #{"contract_id" := CtId} =
        damage_ae:contract_deploy_for(
            KeyPair,
            damage_ae:contract_path(damage, "contracts/agent_policy.aes"),
            []
        ),
    CtId.

deploy_agent_treasury(KeyPair) ->
    #{"contract_id" := CtId} =
        damage_ae:contract_deploy_for(
            KeyPair,
            damage_ae:contract_path(damage, "contracts/agent_treasury.aes"),
            []
        ),
    CtId.

deploy_agent_execution_ledger(KeyPair) ->
    #{"contract_id" := CtId} =
        damage_ae:contract_deploy_for(
            KeyPair,
            damage_ae:contract_path(damage, "contracts/agent_execution_ledger.aes"),
            []
        ),
    CtId.

deploy_nwc_session_registry(KeyPair) ->
    #{"contract_id" := CtId} =
        damage_ae:contract_deploy_for(
            KeyPair,
            damage_ae:contract_path(damage, "contracts/nwc_session_registry.aes"),
            []
        ),
    CtId.

bootstrap_user_account(UserAccount) ->
    {ok, _NodeRegistryCt} = ensure_node_registry(),
    {ok, RegistryCt} = ensure_user_account_registry(UserAccount),
    ensure_user_named_contracts(UserAccount, RegistryCt).

ensure_user_account_registry(UserAccount) ->
    damage_node_registry:ensure_account_registry(UserAccount, <<"node">>).

ensure_user_named_contracts(UserAccount, RegistryCt) ->
    KeyPair = identity_server:get_account(UserAccount),
    ensure_user_named_contracts(KeyPair, UserAccount, RegistryCt, ?USER_REQUIRED_CONTRACTS, #{}).

ensure_user_named_contracts(_KeyPair, _UserAccount, _RegistryCt, [], Acc) ->
    {ok, Acc};
ensure_user_named_contracts(KeyPair, UserAccount, RegistryCt, [{Name, DeployFun} | Rest], Acc) ->
    NameBin = atom_to_binary(Name, utf8),
    case resolve_or_init_user_contract(KeyPair, UserAccount, RegistryCt, NameBin, DeployFun) of
        {ok, CtId} ->
            ensure_user_named_contracts(KeyPair, UserAccount, RegistryCt, Rest, Acc#{Name => CtId});
        Error ->
            Error
    end.
user_contract_secret_key(UserAccount, NameBin) ->
    binary_to_list(
        <<"user_ct__", NameBin/binary, "__",
            (base64:encode(crypto:hash(sha256, damage_utils:to_bin(UserAccount))))/binary>>
    ).

secret_user_ct(UserAccount, NameBin) ->
    case secrets:retrieve_decrypt(user_contract_secret_key(UserAccount, NameBin)) of
        {ok, <<"ct_", _/binary>> = CtId} ->
            {ok, CtId};
        {ok, CtId} when is_list(CtId) ->
            {ok, list_to_binary(CtId)};
        _ ->
            error
    end.

persist_user_ct(UserAccount, NameBin, <<"ct_", _/binary>> = CtId0) ->
    CtId = normalize_ct(CtId0),
    secrets:encrypt_store(user_contract_secret_key(UserAccount, NameBin), CtId).

resolve_or_init_user_contract(KeyPair, UserAccount, RegistryCt, NameBin, DeployFun) ->
    case secret_user_ct(UserAccount, NameBin) of
        {ok, CtId} ->
            _ = upsert_contract(KeyPair, RegistryCt, NameBin, CtId),
            {ok, CtId};
        error ->
            case account_registry:get_contract(KeyPair, RegistryCt, NameBin) of
                {ok, <<"ct_", _/binary>> = CtId} ->
                    ok = persist_user_ct(UserAccount, NameBin, CtId),
                    {ok, CtId};
                _ ->
                    CtId = DeployFun(KeyPair),
                    case upsert_contract(KeyPair, RegistryCt, NameBin, CtId) of
                        {ok, true} ->
                            ok = persist_user_ct(UserAccount, NameBin, CtId),
                            {ok, CtId};
                        {ok, false} ->
                            account_registry:get_contract(KeyPair, RegistryCt, NameBin);
                        Error ->
                            Error
                    end
            end
    end.

upsert_contract(KeyPair, RegistryCt, NameBin, CtId) ->
    case account_registry:update_contract(KeyPair, RegistryCt, NameBin, CtId) of
        {ok, true} ->
            {ok, true};
        {error, {unexpected_return_type, _, #{"return_value" := <<"Contract name not found">>}}} ->
            account_registry:register_contract(KeyPair, RegistryCt, NameBin, CtId);
        Other ->
            Other
    end.
deploy_user_nwc_ledger(KeyPair) ->
    UserAk = damage_utils:to_bin(maps:get(public_key, KeyPair)),
    #{"contract_id" := CtId} =
        damage_ae:contract_deploy_for(
            KeyPair,
            damage_ae:contract_path("contracts/nwc_ledger.aes"),
            [binary_to_list(UserAk)]
        ),
    CtId.
