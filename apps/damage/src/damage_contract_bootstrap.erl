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

-define(ADMIN_REQUIRED_CONTRACTS, [
    {nwc_ledger, nwc_ledger_ct, fun deploy_nwc_ledger/1},
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

-spec init_admin_contracts(binary()) -> {ok, map()} | {error, term()}.
init_admin_contracts(NodeAdminAccount) ->
    damage_contract_bootstrap:bootstrap_node_admin(NodeAdminAccount).
ensure_node_registry() ->
    case application:get_env(damage, node_registry_ct) of
        {ok, <<"ct_", _/binary>> = Ct} ->
            ok = damage_node_registry:set_contract(Ct),
            {ok, Ct};
        {ok, Ct} when is_list(Ct) ->
            CtBin = list_to_binary(Ct),
            ok = damage_node_registry:set_contract(CtBin),
            {ok, CtBin};
        _ ->
            Ct = damage_node_registry:deploy_node_registry(),
            ok = application:set_env(damage, node_registry_ct, Ct),
            ok = damage_node_registry:set_contract(Ct),
            {ok, Ct}
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
    case account_registry:get_contract(KeyPair, RegistryCt, NameBin) of
        {ok, <<"ct_", _/binary>> = CtId} ->
            ok = application:set_env(damage, EnvKey, CtId),
            {ok, CtId};
        _ ->
            case application:get_env(damage, EnvKey) of
                {ok, <<"ct_", _/binary>> = CtId} ->
                    _ = account_registry:register_contract(KeyPair, RegistryCt, NameBin, CtId),
                    ok = application:set_env(damage, EnvKey, CtId),
                    {ok, CtId};
                {ok, CtId} when is_list(CtId) ->
                    CtBin = list_to_binary(CtId),
                    _ = account_registry:register_contract(KeyPair, RegistryCt, NameBin, CtBin),
                    ok = application:set_env(damage, EnvKey, CtBin),
                    {ok, CtBin};
                _ ->
                    CtId = DeployFun(KeyPair),
                    case account_registry:register_contract(KeyPair, RegistryCt, NameBin, CtId) of
                        {ok, true} ->
                            ok = application:set_env(damage, EnvKey, CtId),
                            {ok, CtId};
                        {ok, false} ->
                            account_registry:get_contract(KeyPair, RegistryCt, NameBin);
                        Error ->
                            Error
                    end
            end
    end.

%% ---- deploy helpers ----
deploy_nwc_ledger(KeyPair) ->
    #{"contract_id" := CtId} =
        damage_ae:contract_deploy_for(
            KeyPair,
            damage_ae:contract_path("contracts/nwc_ledger.aes"),
            []
        ),
    CtId.

deploy_agent_registry(KeyPair) ->
    #{"contract_id" := CtId} =
        damage_ae:contract_deploy_for(
            KeyPair,
            damage_ae:contract_path("contracts/agent_registry.aes"),
            []
        ),
    CtId.

deploy_agent_policy(KeyPair) ->
    #{"contract_id" := CtId} =
        damage_ae:contract_deploy_for(
            KeyPair,
            damage_ae:contract_path("contracts/agent_policy.aes"),
            []
        ),
    CtId.

deploy_agent_treasury(KeyPair) ->
    #{"contract_id" := CtId} =
        damage_ae:contract_deploy_for(
            KeyPair,
            damage_ae:contract_path("contracts/agent_treasury.aes"),
            []
        ),
    CtId.

deploy_agent_execution_ledger(KeyPair) ->
    #{"contract_id" := CtId} =
        damage_ae:contract_deploy_for(
            KeyPair,
            damage_ae:contract_path("contracts/agent_execution_ledger.aes"),
            []
        ),
    CtId.

deploy_nwc_session_registry(KeyPair) ->
    #{"contract_id" := CtId} =
        damage_ae:contract_deploy_for(
            KeyPair,
            damage_ae:contract_path("contracts/nwc_session_registry.aes"),
            []
        ),
    CtId.
