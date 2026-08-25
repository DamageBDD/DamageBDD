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

-type contract_source_status() :: missing | {ok, binary()} | {error, term()}.

-spec contract_secret_status(term()) -> contract_source_status().
contract_secret_status(Key) ->
    try secrets:retrieve_secret(Key) of
        [] ->
            missing;
        _Rows when is_list(_Rows) ->
            case secrets:retrieve_decrypt(Key) of
                {ok, CtId0} -> normalize_contract_source(secret, Key, CtId0);
                error -> {error, {contract_secret_unavailable, Key}};
                {error, Reason} -> {error, {contract_secret_unavailable, Key, Reason}};
                Other -> {error, {invalid_contract_secret_result, Key, Other}}
            end;
        Other ->
            {error, {invalid_contract_secret_rows, Key, Other}}
    catch
        Class:Reason:Stacktrace ->
            ?LOG_ERROR(
                "Contract secret lookup failed key=~p class=~p reason=~p stack=~p",
                [Key, Class, Reason, Stacktrace]
            ),
            {error, {contract_secret_lookup_failed, Key, Class, Reason}}
    end.

-spec configured_contract_status(atom()) -> contract_source_status().
configured_contract_status(Key) ->
    case application:get_env(damage, Key) of
        undefined -> missing;
        {ok, CtId0} -> normalize_contract_source(application_env, Key, CtId0)
    end.

normalize_contract_source(Source, Key, CtId0) ->
    case normalize_ct(CtId0) of
        <<"ct_", _/binary>> = CtId -> {ok, CtId};
        _ -> {error, {invalid_contract_id, Source, Key, CtId0}}
    end.

normalize_ct(<<"ct_", _/binary>> = Ct) -> Ct;
normalize_ct(Ct) when is_list(Ct) -> list_to_binary(Ct);
normalize_ct(Ct) when is_binary(Ct) -> Ct;
normalize_ct(_) -> invalid.

-spec persist_ct(atom(), binary()) -> ok | {error, term()}.
persist_ct(Key, CtId0) ->
    CtId = normalize_ct(CtId0),
    case contract_secret_status(Key) of
        missing ->
            secrets:encrypt_store(Key, CtId);
        {ok, CtId} ->
            ok;
        {ok, Existing} ->
            {error, {contract_id_conflict, Key, #{secret => Existing, selected => CtId}}};
        {error, _} = Error ->
            Error
    end.

ensure_node_registry() ->
    case local_contract_candidate(<<"node_registry">>, node_registry_ct) of
        {ok, CtId} ->
            activate_node_registry(CtId);
        missing ->
            try damage_node_registry:deploy_node_registry() of
                <<"ct_", _/binary>> = CtId -> activate_node_registry(CtId);
                Other -> {error, {invalid_deployed_contract_id, <<"node_registry">>, Other}}
            catch
                Class:Reason:Stacktrace ->
                    ?LOG_ERROR(
                        "Node registry deployment failed class=~p reason=~p stack=~p",
                        [Class, Reason, Stacktrace]
                    ),
                    {error, {node_registry_deploy_failed, Class, Reason}}
            end;
        {error, _} = Error ->
            Error
    end.

activate_node_registry(CtId) ->
    case ensure_local_contract_sources(<<"node_registry">>, node_registry_ct, CtId) of
        ok ->
            ok = damage_node_registry:set_contract(CtId),
            {ok, CtId};
        {error, _} = Error ->
            Error
    end.

ensure_admin_account_registry(NodeAdminAccount) ->
    case reload_identity_keypair(NodeAdminAccount) of
        {ok, _KeyPair} ->
            damage_node_registry:ensure_account_registry(NodeAdminAccount, <<"node_admin">>);
        {error, _} = Error ->
            Error
    end.

ensure_named_contracts(NodeAdminAccount, RegistryCt) ->
    case reload_identity_keypair(NodeAdminAccount) of
        {ok, KeyPair} ->
            ensure_named_contracts(KeyPair, RegistryCt, ?ADMIN_REQUIRED_CONTRACTS, #{});
        {error, _} = Error ->
            Error
    end.

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
    case registered_contract(KeyPair, RegistryCt, NameBin) of
        {ok, CtId} ->
            case validate_contract(KeyPair, CtId, Validator) of
                true -> activate_registered_contract(NameBin, EnvKey, CtId);
                false -> {error, {registered_contract_validation_failed, NameBin, CtId}}
            end;
        missing ->
            resolve_unregistered_contract(
                KeyPair,
                RegistryCt,
                NameBin,
                EnvKey,
                DeployFun,
                Validator
            );
        {error, Reason} ->
            {error, {contract_registry_read_failed, NameBin, Reason}}
    end.

resolve_unregistered_contract(KeyPair, RegistryCt, NameBin, EnvKey, DeployFun, Validator) ->
    case local_contract_candidate(NameBin, EnvKey) of
        {ok, CtId} ->
            case validate_contract(KeyPair, CtId, Validator) of
                true -> register_and_activate_contract(KeyPair, RegistryCt, NameBin, EnvKey, CtId);
                false -> {error, {configured_contract_validation_failed, NameBin, CtId}}
            end;
        missing ->
            deploy_and_activate_contract(
                KeyPair,
                RegistryCt,
                NameBin,
                EnvKey,
                DeployFun,
                Validator
            );
        {error, _} = Error ->
            Error
    end.

registered_contract(KeyPair, RegistryCt, NameBin) ->
    ok = account_registry:invalidate_cache(RegistryCt, NameBin),
    case account_registry:get_contract(KeyPair, RegistryCt, NameBin) of
        {ok, <<"ct_", _/binary>> = CtId} ->
            {ok, CtId};
        {ok, Other} ->
            {error, {invalid_registered_contract_id, NameBin, Other}};
        {error, Reason} ->
            case contract_name_not_found(Reason) of
                true -> missing;
                false -> {error, Reason}
            end;
        Other ->
            {error, {unexpected_registry_contract_result, Other}}
    end.

local_contract_candidate(NameBin, EnvKey) ->
    Secret = contract_secret_status(EnvKey),
    Configured = configured_contract_status(EnvKey),
    case {Secret, Configured} of
        {{ok, CtId}, {ok, CtId}} ->
            {ok, CtId};
        {{ok, SecretCt}, {ok, ConfigCt}} ->
            {error, contract_conflict(NameBin, undefined, SecretCt, ConfigCt)};
        {{ok, CtId}, missing} ->
            {ok, CtId};
        {missing, {ok, CtId}} ->
            {ok, CtId};
        {missing, missing} ->
            missing;
        {{error, Reason}, _} ->
            {error, Reason};
        {_, {error, Reason}} ->
            {error, Reason}
    end.

activate_registered_contract(NameBin, EnvKey, CtId) ->
    case ensure_local_contract_sources(NameBin, EnvKey, CtId) of
        ok -> {ok, CtId};
        {error, _} = Error -> Error
    end.

ensure_local_contract_sources(NameBin, EnvKey, CtId) ->
    Secret = contract_secret_status(EnvKey),
    Configured = configured_contract_status(EnvKey),
    case ensure_source_matches(NameBin, CtId, Secret, Configured) of
        ok ->
            case persist_ct(EnvKey, CtId) of
                ok -> set_contract_env_if_missing(NameBin, EnvKey, CtId);
                {error, _} = Error -> Error
            end;
        {error, _} = Error ->
            Error
    end.

ensure_source_matches(NameBin, Selected, Secret, Configured) ->
    case {Secret, Configured} of
        {{error, Reason}, _} ->
            {error, Reason};
        {_, {error, Reason}} ->
            {error, Reason};
        {{ok, SecretCt}, _} when SecretCt =/= Selected ->
            {error, contract_conflict(NameBin, Selected, SecretCt, source_value(Configured))};
        {_, {ok, ConfigCt}} when ConfigCt =/= Selected ->
            {error, contract_conflict(NameBin, Selected, source_value(Secret), ConfigCt)};
        _ ->
            ok
    end.

source_value({ok, Value}) -> Value;
source_value(missing) -> missing;
source_value({error, Reason}) -> {error, Reason}.

contract_conflict(NameBin, RegistryCt, SecretCt, ConfiguredCt) ->
    {contract_id_conflict, NameBin, #{
        registry => RegistryCt,
        secret => SecretCt,
        configured => ConfiguredCt
    }}.

set_contract_env_if_missing(NameBin, EnvKey, CtId) ->
    case configured_contract_status(EnvKey) of
        missing ->
            application:set_env(damage, EnvKey, CtId);
        {ok, CtId} ->
            ok;
        {ok, Existing} ->
            {error,
                contract_conflict(
                    NameBin,
                    CtId,
                    source_value(contract_secret_status(EnvKey)),
                    Existing
                )};
        {error, _} = Error ->
            Error
    end.

register_and_activate_contract(KeyPair, RegistryCt, NameBin, EnvKey, CtId) ->
    case account_registry:register_contract(KeyPair, RegistryCt, NameBin, CtId) of
        {ok, true} ->
            activate_registered_contract(NameBin, EnvKey, CtId);
        {ok, false} ->
            verify_registered_contract(KeyPair, RegistryCt, NameBin, EnvKey, CtId);
        {error, Reason} ->
            case verify_registered_contract(KeyPair, RegistryCt, NameBin, EnvKey, CtId) of
                {ok, _} = Ok -> Ok;
                {error, {contract_id_conflict, _, _}} = Conflict -> Conflict;
                _ -> {error, {contract_registration_failed, NameBin, Reason}}
            end
    end.
verify_registered_contract(KeyPair, RegistryCt, NameBin, EnvKey, ExpectedCt) ->
    case registered_contract(KeyPair, RegistryCt, NameBin) of
        {ok, ExpectedCt} ->
            activate_registered_contract(NameBin, EnvKey, ExpectedCt);
        {ok, ExistingCt} ->
            {error,
                {contract_id_conflict, NameBin, #{
                    registry => ExistingCt,
                    selected => ExpectedCt,
                    configured => source_value(configured_contract_status(EnvKey))
                }}};
        missing ->
            {error, {contract_registration_not_visible, NameBin, ExpectedCt}};
        {error, Reason} ->
            {error, {contract_registration_verify_failed, NameBin, Reason}}
    end.

contract_name_not_found({unexpected_return_type, _Type, Info}) ->
    contract_name_not_found(Info);
contract_name_not_found({dry_run_contract_error, Reason}) ->
    contract_name_not_found(Reason);
contract_name_not_found({error, Reason}) ->
    contract_name_not_found(Reason);
contract_name_not_found(Value) when is_map(Value) ->
    Candidates = [
        maps:get("return_value", Value, undefined),
        maps:get(<<"return_value">>, Value, undefined),
        maps:get(return_value, Value, undefined),
        maps:get("reason", Value, undefined),
        maps:get(<<"reason">>, Value, undefined),
        maps:get(reason, Value, undefined)
    ],
    lists:any(fun contract_name_not_found/1, Candidates);
contract_name_not_found(Value) when is_tuple(Value) ->
    lists:any(fun contract_name_not_found/1, tuple_to_list(Value));
contract_name_not_found(Value) when is_binary(Value) ->
    Lower = list_to_binary(string:lowercase(binary_to_list(Value))),
    binary:match(Lower, <<"not found">>) =/= nomatch;
contract_name_not_found(Value) when is_list(Value) ->
    case io_lib:printable_unicode_list(Value) of
        true -> contract_name_not_found(unicode:characters_to_binary(Value));
        false -> lists:any(fun contract_name_not_found/1, Value)
    end;
contract_name_not_found(contract_name_not_found) ->
    true;
contract_name_not_found(_) ->
    false.

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

deploy_and_activate_contract(KeyPair, RegistryCt, NameBin, EnvKey, DeployFun, Validator) ->
    try DeployFun(KeyPair) of
        <<"ct_", _/binary>> = CtId ->
            case validate_deployed_contract(KeyPair, CtId, Validator) of
                true ->
                    register_and_activate_contract(KeyPair, RegistryCt, NameBin, EnvKey, CtId);
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
    case reload_identity_keypair(UserAccount) of
        {ok, _KeyPair} ->
            damage_node_registry:ensure_account_registry(UserAccount, <<"node">>);
        {error, _} = Error ->
            Error
    end.

ensure_user_named_contracts(UserAccount, RegistryCt) ->
    case reload_identity_keypair(UserAccount) of
        {ok, KeyPair} ->
            ensure_user_named_contracts(
                KeyPair,
                UserAccount,
                RegistryCt,
                ?USER_REQUIRED_CONTRACTS,
                #{}
            );
        {error, _} = Error ->
            Error
    end.

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

user_contract_secret_status(UserAccount, NameBin) ->
    contract_secret_status(user_contract_secret_key(UserAccount, NameBin)).

persist_user_ct(UserAccount, NameBin, <<"ct_", _/binary>> = CtId) ->
    Key = user_contract_secret_key(UserAccount, NameBin),
    case contract_secret_status(Key) of
        missing ->
            secrets:encrypt_store(Key, CtId);
        {ok, CtId} ->
            ok;
        {ok, Existing} ->
            {error,
                {user_contract_id_conflict, NameBin, #{
                    registry => CtId,
                    secret => Existing
                }}};
        {error, _} = Error ->
            Error
    end.

resolve_or_init_user_contract(KeyPair, UserAccount, RegistryCt, NameBin, DeployFun) ->
    case registered_contract(KeyPair, RegistryCt, NameBin) of
        {ok, RegistryCtId} ->
            case user_contract_secret_status(UserAccount, NameBin) of
                missing ->
                    case persist_user_ct(UserAccount, NameBin, RegistryCtId) of
                        ok -> {ok, RegistryCtId};
                        {error, _} = Error -> Error
                    end;
                {ok, RegistryCtId} ->
                    {ok, RegistryCtId};
                {ok, SecretCtId} ->
                    {error,
                        {user_contract_id_conflict, NameBin, #{
                            registry => RegistryCtId,
                            secret => SecretCtId
                        }}};
                {error, _} = Error ->
                    Error
            end;
        missing ->
            resolve_unregistered_user_contract(
                KeyPair,
                UserAccount,
                RegistryCt,
                NameBin,
                DeployFun
            );
        {error, Reason} ->
            {error, {user_contract_registry_read_failed, NameBin, Reason}}
    end.

resolve_unregistered_user_contract(KeyPair, UserAccount, RegistryCt, NameBin, DeployFun) ->
    case user_contract_secret_status(UserAccount, NameBin) of
        {ok, CtId} -> register_user_contract(KeyPair, UserAccount, RegistryCt, NameBin, CtId);
        missing -> deploy_user_contract(KeyPair, UserAccount, RegistryCt, NameBin, DeployFun);
        {error, _} = Error -> Error
    end.

register_user_contract(KeyPair, UserAccount, RegistryCt, NameBin, CtId) ->
    case account_registry:register_contract(KeyPair, RegistryCt, NameBin, CtId) of
        {ok, true} ->
            case persist_user_ct(UserAccount, NameBin, CtId) of
                ok -> {ok, CtId};
                {error, _} = Error -> Error
            end;
        {ok, false} ->
            verify_user_contract(KeyPair, UserAccount, RegistryCt, NameBin, CtId);
        {error, Reason} ->
            case verify_user_contract(KeyPair, UserAccount, RegistryCt, NameBin, CtId) of
                {ok, _} = Ok -> Ok;
                {error, {user_contract_id_conflict, _, _}} = Conflict -> Conflict;
                _ -> {error, {user_contract_registration_failed, NameBin, Reason}}
            end
    end.

-spec verify_user_contract(map(), binary(), binary(), binary(), binary()) ->
    {ok, binary()} | {error, term()}.
verify_user_contract(KeyPair, UserAccount, RegistryCt, NameBin, ExpectedCt) ->
    case registered_contract(KeyPair, RegistryCt, NameBin) of
        {ok, ExpectedCt} ->
            case persist_user_ct(UserAccount, NameBin, ExpectedCt) of
                ok -> {ok, ExpectedCt};
                {error, _} = Error -> Error
            end;
        {ok, ExistingCt} ->
            {error,
                {user_contract_id_conflict, NameBin, #{
                    registry => ExistingCt,
                    selected => ExpectedCt
                }}};
        missing ->
            {error, {user_contract_registration_not_visible, NameBin, ExpectedCt}};
        {error, Reason} ->
            {error, {user_contract_registration_verify_failed, NameBin, Reason}}
    end.

-spec deploy_user_contract(map(), binary(), binary(), binary(), fun((map()) -> term())) ->
    {ok, binary()} | {error, term()}.
deploy_user_contract(KeyPair, UserAccount, RegistryCt, NameBin, DeployFun) ->
    try DeployFun(KeyPair) of
        <<"ct_", _/binary>> = CtId ->
            register_user_contract(KeyPair, UserAccount, RegistryCt, NameBin, CtId);
        Other ->
            {error, {invalid_user_contract_id, NameBin, Other}}
    catch
        Class:Reason:Stacktrace ->
            ?LOG_ERROR(
                "User contract deployment failed name=~p class=~p reason=~p stack=~p",
                [NameBin, Class, Reason, Stacktrace]
            ),
            {error, {user_contract_deploy_failed, NameBin, Class, Reason}}
    end.

-spec reload_identity_keypair(binary() | list()) -> {ok, map()} | {error, term()}.
reload_identity_keypair(AeAccount0) ->
    AeAccount = damage_utils:to_bin(AeAccount0),
    Result =
        try identity_server:reload_account(AeAccount) of
            Value -> Value
        catch
            Class:Reason:Stacktrace ->
                {error, {identity_reload_crashed, Class, Reason, Stacktrace}}
        end,
    case Result of
        #{public_key := Pub0, private_key := PrivateKey} = Account when
            is_binary(PrivateKey), PrivateKey =/= <<>>
        ->
            Pub = damage_utils:to_bin(Pub0),
            case Pub =:= AeAccount of
                true -> {ok, Account#{public_key := Pub}};
                false -> {error, {identity_account_mismatch, AeAccount, Pub}}
            end;
        notfound ->
            {error, {identity_not_found, AeAccount}};
        {error, Reason0} ->
            {error, {identity_reload_failed, AeAccount, Reason0}};
        Other ->
            {error, {invalid_identity_account, AeAccount, Other}}
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
