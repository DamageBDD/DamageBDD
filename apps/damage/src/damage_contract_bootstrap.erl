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
    case ensure_node_registry() of
        {ok, NodeRegistryCt} -> {ok, #{node_registry => NodeRegistryCt}};
        {error, _} = Error -> Error
    end.

bootstrap_node_admin(NodeAdminAccount) ->
    case ensure_node_registry() of
        {ok, _NodeRegistryCt} ->
            case ensure_admin_account_registry(NodeAdminAccount) of
                {ok, RegistryCt} ->
                    case ensure_named_contracts(NodeAdminAccount, RegistryCt) of
                        {ok, Contracts} ->
                            case damage_context:ensure_scope(node) of
                                {ok, ScopeSummary} ->
                                    {ok, Contracts#{
                                        node_context => ScopeSummary,
                                        account_registry => RegistryCt
                                    }};
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

-spec init_admin_contracts(binary()) -> {ok, map()} | {error, term()}.
init_admin_contracts(NodeAdminAccount) ->
    bootstrap_node_admin(NodeAdminAccount).

-spec secret_ct(atom()) -> {ok, binary()} | error.
secret_ct(Key) ->
    try secrets:retrieve_decrypt(Key) of
        {ok, <<"ct_", _/binary>> = CtId} -> {ok, CtId};
        {ok, CtId} when is_list(CtId) -> normalize_ct_result(CtId);
        _ -> error
    catch
        Class:Reason:Stacktrace ->
            ?LOG_WARNING(
                "Contract secret lookup failed key=~p class=~p reason=~p stack=~p",
                [Key, Class, Reason, Stacktrace]
            ),
            error
    end.

normalize_ct_result(CtId) ->
    case normalize_ct(CtId) of
        <<"ct_", _/binary>> = Ct -> {ok, Ct};
        _ -> error
    end.

normalize_ct(<<"ct_", _/binary>> = Ct) -> Ct;
normalize_ct(Ct) when is_list(Ct) -> list_to_binary(Ct);
normalize_ct(Ct) when is_binary(Ct) -> Ct.

-spec persist_ct(atom(), binary()) -> ok.
persist_ct(Key, CtId0) ->
    CtId = normalize_ct(CtId0),
    secrets:encrypt_store(Key, CtId).

ensure_node_registry() ->
    case secret_ct(node_registry_ct) of
        {ok, Ct} ->
            activate_node_registry(Ct);
        error ->
            case configured_ct(node_registry_ct) of
                {ok, Ct} ->
                    ok = persist_ct(node_registry_ct, Ct),
                    activate_node_registry(Ct);
                error ->
                    Ct = damage_node_registry:deploy_node_registry(),
                    ok = persist_ct(node_registry_ct, Ct),
                    activate_node_registry(Ct)
            end
    end.

activate_node_registry(Ct) ->
    ok = application:set_env(damage, node_registry_ct, Ct),
    ok = damage_node_registry:set_contract(Ct),
    {ok, Ct}.

ensure_admin_account_registry(NodeAdminAccount) ->
    damage_node_registry:ensure_account_registry(NodeAdminAccount, <<"node_admin">>).

configured_ct(Key) ->
    case application:get_env(damage, Key) of
        {ok, <<"ct_", _/binary>> = CtId} -> {ok, CtId};
        {ok, CtId} when is_list(CtId) -> normalize_ct_result(CtId);
        _ -> error
    end.

ensure_named_contracts(NodeAdminAccount, RegistryCt) ->
    KeyPair = identity_server:get_account(NodeAdminAccount),
    ensure_named_contracts(KeyPair, RegistryCt, ?ADMIN_REQUIRED_CONTRACTS, #{}).

ensure_named_contracts(_KeyPair, _RegistryCt, [], Acc) ->
    {ok, Acc};
ensure_named_contracts(KeyPair, RegistryCt, [Spec | Rest], Acc) ->
    {Name, EnvKey, DeployFun, Validator} = normalize_admin_spec(Spec),
    NameBin = atom_to_binary(Name, utf8),
    case
        resolve_or_init_contract(
            KeyPair,
            RegistryCt,
            NameBin,
            EnvKey,
            DeployFun,
            Validator
        )
    of
        {ok, CtId} ->
            ensure_named_contracts(KeyPair, RegistryCt, Rest, Acc#{Name => CtId});
        {error, _} = Error ->
            Error
    end.

normalize_admin_spec({Name, EnvKey, DeployFun}) ->
    {Name, EnvKey, DeployFun, undefined};
normalize_admin_spec({Name, EnvKey, DeployFun, Validator}) ->
    {Name, EnvKey, DeployFun, Validator}.

resolve_or_init_contract(KeyPair, RegistryCt, NameBin, EnvKey, DeployFun, Validator) ->
    Candidates = contract_candidates(KeyPair, RegistryCt, NameBin, EnvKey),
    case first_valid_contract(KeyPair, Candidates, Validator) of
        {ok, CtId} ->
            activate_admin_contract(KeyPair, RegistryCt, NameBin, EnvKey, CtId);
        error ->
            deploy_and_activate_contract(
                KeyPair,
                RegistryCt,
                NameBin,
                EnvKey,
                DeployFun,
                Validator
            )
    end.

contract_candidates(KeyPair, RegistryCt, NameBin, EnvKey) ->
    RegistryCandidate =
        case account_registry:get_contract(KeyPair, RegistryCt, NameBin) of
            {ok, CtId} -> {ok, CtId};
            _ -> error
        end,
    Candidates = [secret_ct(EnvKey), RegistryCandidate, configured_ct(EnvKey)],
    unique_contract_candidates([
        CtId
     || {ok, <<"ct_", _/binary>> = CtId} <- Candidates
    ]).

unique_contract_candidates(Candidates) ->
    {_Seen, Reversed} = lists:foldl(
        fun(CtId, {Seen, Acc}) ->
            case maps:is_key(CtId, Seen) of
                true -> {Seen, Acc};
                false -> {maps:put(CtId, true, Seen), [CtId | Acc]}
            end
        end,
        {#{}, []},
        Candidates
    ),
    lists:reverse(Reversed).

first_valid_contract(_KeyPair, [], _Validator) ->
    error;
first_valid_contract(KeyPair, [CtId | Rest], Validator) ->
    case validate_contract(KeyPair, CtId, Validator) of
        true -> {ok, CtId};
        false -> first_valid_contract(KeyPair, Rest, Validator)
    end.

validate_contract(_KeyPair, _CtId, undefined) ->
    true;
validate_contract(KeyPair, CtId, Validator) when is_function(Validator, 2) ->
    try Validator(KeyPair, CtId) of
        true ->
            true;
        false ->
            false;
        Other ->
            ?LOG_WARNING("Contract validator returned ~p for ~p", [Other, CtId]),
            false
    catch
        Class:Reason:Stacktrace ->
            ?LOG_WARNING(
                "Contract validation failed ct=~p class=~p reason=~p stack=~p",
                [CtId, Class, Reason, Stacktrace]
            ),
            false
    end.

activate_admin_contract(KeyPair, RegistryCt, NameBin, EnvKey, CtId) ->
    case account_registry:upsert_contract(KeyPair, RegistryCt, NameBin, CtId) of
        {ok, true} ->
            ok = persist_ct(EnvKey, CtId),
            ok = application:set_env(damage, EnvKey, CtId),
            {ok, CtId};
        {error, _} = Error ->
            Error
    end.

deploy_and_activate_contract(KeyPair, RegistryCt, NameBin, EnvKey, DeployFun, Validator) ->
    try DeployFun(KeyPair) of
        <<"ct_", _/binary>> = CtId ->
            case validate_deployed_contract(KeyPair, CtId, Validator) of
                true ->
                    activate_admin_contract(KeyPair, RegistryCt, NameBin, EnvKey, CtId);
                false ->
                    {error, {deployed_contract_validation_failed, NameBin, CtId}}
            end;
        Other ->
            {error, {invalid_deployed_contract_id, NameBin, Other}}
    catch
        Class:Reason:Stacktrace ->
            ?LOG_ERROR(
                "Contract deployment failed name=~p class=~p reason=~p stack=~p",
                [NameBin, Class, Reason, Stacktrace]
            ),
            {error, {contract_deploy_failed, NameBin, Class, Reason}}
    end.



%% A mined deployment may only just have reached the latest microblock, and a
%% second configured node may be a little behind. Retry validation before
%% discarding a contract ID that was returned by a successful deployment.
validate_deployed_contract(KeyPair, CtId, Validator) ->
    Attempts = positive_env(ae_contract_validation_attempts, 8),
    DelayMs = positive_env(ae_contract_validation_delay_ms, 500),
    validate_deployed_contract(KeyPair, CtId, Validator, Attempts, DelayMs).

validate_deployed_contract(KeyPair, CtId, Validator, Attempts, DelayMs) ->
    case validate_contract(KeyPair, CtId, Validator) of
        true ->
            true;
        false when Attempts > 1 ->
            ?LOG_WARNING(
                "Post-deploy contract validation pending ct=~p attempts_left=~p",
                [CtId, Attempts - 1]
            ),
            timer:sleep(DelayMs),
            validate_deployed_contract(KeyPair, CtId, Validator, Attempts - 1, DelayMs);
        false ->
            false
    end.

positive_env(Key, Default) ->
    case application:get_env(damage, Key, Default) of
        Value when is_integer(Value), Value > 0 -> Value;
        _ -> Default
    end.


deploy_agent_registry(KeyPair) ->
    contract_id_from_deploy(
        agent_registry,
        damage_ae:contract_deploy_for(
            KeyPair,
            damage_ae:contract_path(damage, "contracts/agent_registry.aes"),
            []
        )
    ).

deploy_agent_policy(KeyPair) ->
    contract_id_from_deploy(
        agent_policy,
        damage_ae:contract_deploy_for(
            KeyPair,
            damage_ae:contract_path(damage, "contracts/agent_policy.aes"),
            []
        )
    ).

deploy_agent_treasury(KeyPair) ->
    contract_id_from_deploy(
        agent_treasury,
        damage_ae:contract_deploy_for(
            KeyPair,
            damage_ae:contract_path(damage, "contracts/agent_treasury.aes"),
            []
        )
    ).

deploy_agent_execution_ledger(KeyPair) ->
    contract_id_from_deploy(
        agent_execution_ledger,
        damage_ae:contract_deploy_for(
            KeyPair,
            damage_ae:contract_path(damage, "contracts/agent_execution_ledger.aes"),
            []
        )
    ).

deploy_nwc_session_registry(KeyPair) ->
    contract_id_from_deploy(
        nwc_session_registry,
        damage_ae:contract_deploy_for(
            KeyPair,
            damage_ae:contract_path(damage, "contracts/nwc_session_registry.aes"),
            []
        )
    ).

contract_id_from_deploy(_Name, #{"contract_id" := <<"ct_", _/binary>> = CtId}) ->
    CtId;
contract_id_from_deploy(_Name, #{<<"contract_id">> := <<"ct_", _/binary>> = CtId}) ->
    CtId;
contract_id_from_deploy(Name, #{"contract_id" := CtId}) when is_list(CtId) ->
    case normalize_ct(CtId) of
        <<"ct_", _/binary>> = ContractId -> ContractId;
        _ -> error({contract_deploy_failed, Name, CtId})
    end;
contract_id_from_deploy(Name, #{<<"contract_id">> := CtId}) when is_list(CtId) ->
    contract_id_from_deploy(Name, #{"contract_id" => CtId});
contract_id_from_deploy(Name, Result) ->
    error({contract_deploy_failed, Name, Result}).

bootstrap_user_account(UserAccount0) ->
    UserAccount = damage_utils:to_bin(UserAccount0),
    case ensure_node_registry() of
        {ok, _NodeRegistryCt} ->
            case ensure_user_account_registry(UserAccount) of
                {ok, RegistryCt} ->
                    case ensure_user_named_contracts(UserAccount, RegistryCt) of
                        {ok, Contracts0} ->
                            case
                                damage_context:ensure_scope(
                                    damage_context:account_scope(UserAccount)
                                )
                            of
                                {ok, ScopeSummary} ->
                                    {ok, Contracts0#{
                                        account_context => ScopeSummary,
                                        account_registry => RegistryCt
                                    }};
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
        {error, _} = Error ->
            Error
    end.

user_contract_secret_key(UserAccount, NameBin) ->
    binary_to_list(
        <<"user_ct__", NameBin/binary, "__",
            (base64:encode(crypto:hash(sha256, damage_utils:to_bin(UserAccount))))/binary>>
    ).

secret_user_ct(UserAccount, NameBin) ->
    try secrets:retrieve_decrypt(user_contract_secret_key(UserAccount, NameBin)) of
        {ok, <<"ct_", _/binary>> = CtId} -> {ok, CtId};
        {ok, CtId} when is_list(CtId) -> normalize_ct_result(CtId);
        _ -> error
    catch
        _:_ -> error
    end.

persist_user_ct(UserAccount, NameBin, <<"ct_", _/binary>> = CtId0) ->
    CtId = normalize_ct(CtId0),
    secrets:encrypt_store(user_contract_secret_key(UserAccount, NameBin), CtId).

resolve_or_init_user_contract(KeyPair, UserAccount, RegistryCt, NameBin, DeployFun) ->
    case secret_user_ct(UserAccount, NameBin) of
        {ok, CtId} ->
            case account_registry:upsert_contract(KeyPair, RegistryCt, NameBin, CtId) of
                {ok, true} -> {ok, CtId};
                {error, _} = Error -> Error
            end;
        error ->
            case account_registry:get_contract(KeyPair, RegistryCt, NameBin) of
                {ok, <<"ct_", _/binary>> = CtId} ->
                    ok = persist_user_ct(UserAccount, NameBin, CtId),
                    {ok, CtId};
                _ ->
                    try DeployFun(KeyPair) of
                        <<"ct_", _/binary>> = CtId ->
                            case
                                account_registry:upsert_contract(
                                    KeyPair, RegistryCt, NameBin, CtId
                                )
                            of
                                {ok, true} ->
                                    ok = persist_user_ct(UserAccount, NameBin, CtId),
                                    {ok, CtId};
                                {error, _} = Error ->
                                    Error
                            end;
                        Other ->
                            {error, {invalid_user_contract_id, NameBin, Other}}
                    catch
                        Class:Reason:Stacktrace ->
                            ?LOG_ERROR(
                                "User contract deployment failed name=~p class=~p reason=~p stack=~p",
                                [NameBin, Class, Reason, Stacktrace]
                            ),
                            {error, {user_contract_deploy_failed, NameBin, Class, Reason}}
                    end
            end
    end.

deploy_user_nwc_ledger(KeyPair) ->
    UserAk = damage_utils:to_bin(maps:get(public_key, KeyPair)),
    contract_id_from_deploy(
        nwc_ledger,
        damage_ae:contract_deploy_for(
            KeyPair,
            damage_ae:contract_path(damage, "contracts/nwc_ledger.aes"),
            [binary_to_list(UserAk)]
        )
    ).
