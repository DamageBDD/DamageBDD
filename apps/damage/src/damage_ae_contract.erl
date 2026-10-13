%%--------------------------------------------------------------------
%% Generic application-owned Aeternity contract lifecycle helpers.
%%
%% Contract-specific schemas and business logic belong in the owning app.
%% This module only centralizes source-path resolution, configured/runtime
%% contract IDs, deployment, and direct/tracked calls through damage_ae.
%%--------------------------------------------------------------------
-module(damage_ae_contract).

-include_lib("kernel/include/logger.hrl").

-export([
    source/2,
    resolve/2,
    ensure/5,
    remember/3,
    forget/2,
    call/5,
    call_tracked/5,
    query/5,
    normalize_contract_id/1
]).

-type app() :: atom().
-type env_key() :: atom().
-type contract_id() :: binary().

-spec source(app(), term()) -> term().
source(App, Contract) ->
    damage_ae:contract_path(App, Contract).

-spec resolve(app(), env_key()) -> {ok, contract_id()} | {error, term()}.
resolve(App, EnvKey) ->
    RuntimeKey = runtime_key(App, EnvKey),
    case persistent_term:get(RuntimeKey, undefined) of
        undefined ->
            resolve_env(App, EnvKey);
        ContractId ->
            normalize_result(ContractId, App, EnvKey)
    end.

-spec remember(app(), env_key(), term()) -> {ok, contract_id()} | {error, term()}.
remember(App, EnvKey, ContractId0) ->
    case normalize_result(ContractId0, App, EnvKey) of
        {ok, ContractId} = Ok ->
            persistent_term:put(runtime_key(App, EnvKey), ContractId),
            Ok;
        Error ->
            Error
    end.

-spec forget(app(), env_key()) -> ok.
forget(App, EnvKey) ->
    persistent_term:erase(runtime_key(App, EnvKey)),
    ok.

%% Opt-in deployment.  The owning application decides whether auto deployment
%% is acceptable; callers should normally default it to false for production.
-spec ensure(app(), env_key(), term(), list(), map()) ->
    {ok, contract_id()} | {error, term()}.
ensure(App, EnvKey, ContractFile, InitArgs, Opts) when is_map(Opts) ->
    case resolve(App, EnvKey) of
        {ok, _} = Ok ->
            Ok;
        {error, {contract_not_configured, App, EnvKey}} ->
            case maps:get(auto_deploy, Opts, false) of
                true -> deploy_and_remember(App, EnvKey, ContractFile, InitArgs, Opts);
                false -> {error, {contract_not_configured, App, EnvKey}}
            end;
        Error ->
            Error
    end.

-spec call(app(), contract_id() | string(), term(), term(), list()) -> term().
call(App, ContractId0, ContractFile, Func, Args) ->
    ContractId = contract_arg(ContractId0),
    damage_ae:contract_call(
        ContractId,
        source(App, ContractFile),
        Func,
        Args
    ).

-spec call_tracked(app(), contract_id() | string(), term(), term(), list()) -> term().
call_tracked(App, ContractId0, ContractFile, Func, Args) ->
    ContractId = contract_arg(ContractId0),
    damage_ae:contract_call_tracked(
        secrets:node_keypair(),
        ContractId,
        source(App, ContractFile),
        Func,
        Args
    ).

-spec query(app(), contract_id() | string(), term(), term(), list()) -> term().
query(App, ContractId0, ContractFile, Func, Args) ->
    ContractId = contract_arg(ContractId0),
    damage_ae:contract_query(
        ContractId,
        source(App, ContractFile),
        Func,
        Args
    ).

normalize_contract_id(ContractId) when is_binary(ContractId) ->
    validate_contract_id(ContractId);
normalize_contract_id(ContractId) when is_list(ContractId) ->
    try
        validate_contract_id(unicode:characters_to_binary(ContractId))
    catch
        _:_ -> {error, {invalid_contract_id, ContractId}}
    end;
normalize_contract_id(Other) ->
    {error, {invalid_contract_id, Other}}.

%%--------------------------------------------------------------------
%% Internal
%%--------------------------------------------------------------------

runtime_key(App, EnvKey) ->
    {?MODULE, App, EnvKey}.

resolve_env(App, EnvKey) ->
    case application:get_env(App, EnvKey) of
        {ok, Value} -> normalize_result(Value, App, EnvKey);
        undefined -> {error, {contract_not_configured, App, EnvKey}}
    end.

normalize_result(undefined, App, EnvKey) ->
    {error, {contract_not_configured, App, EnvKey}};
normalize_result(<<>>, App, EnvKey) ->
    {error, {contract_not_configured, App, EnvKey}};
normalize_result([], App, EnvKey) ->
    {error, {contract_not_configured, App, EnvKey}};
normalize_result(Value, _App, _EnvKey) ->
    normalize_contract_id(Value).

validate_contract_id(<<"ct_", _/binary>> = ContractId) when byte_size(ContractId) > 3 ->
    {ok, ContractId};
validate_contract_id(ContractId) ->
    {error, {invalid_contract_id, ContractId}}.

contract_arg(ContractId0) ->
    case normalize_contract_id(ContractId0) of
        {ok, ContractId} -> binary_to_list(ContractId);
        {error, Reason} -> error(Reason)
    end.

deploy_and_remember(App, EnvKey, ContractFile, InitArgs, Opts) ->
    Source = source(App, ContractFile),
    KeyPair = maps:get(keypair, Opts, secrets:node_keypair()),
    ?LOG_INFO("Deploying app-owned Aeternity contract app=~p key=~p source=~p", [
        App, EnvKey, Source
    ]),
    try damage_ae:contract_deploy(KeyPair, Source, InitArgs) of
        Reply ->
            case deployed_contract_id(Reply) of
                {ok, ContractId} ->
                    remember(App, EnvKey, ContractId);
                {pending, TxHash} ->
                    wait_deploy_and_remember(App, EnvKey, TxHash);
                {error, _} = Error ->
                    Error
            end
    catch
        Class:Reason:Stacktrace ->
            ?LOG_ERROR(
                "Aeternity contract deployment crashed app=~p key=~p class=~p reason=~p stack=~p",
                [App, EnvKey, Class, Reason, Stacktrace]
            ),
            {error, {contract_deploy_exception, Class, Reason}}
    end.

wait_deploy_and_remember(App, EnvKey, TxHash) ->
    case damage_ae:wait_tx(TxHash) of
        Mined when is_map(Mined) ->
            case find_contract_id(Mined) of
                {ok, ContractId} -> remember(App, EnvKey, ContractId);
                error -> {error, {contract_id_missing_after_deploy, TxHash, Mined}}
            end;
        Error ->
            {error, {contract_deploy_confirmation_failed, TxHash, Error}}
    end.

deployed_contract_id(Reply) when is_map(Reply) ->
    case find_contract_id(Reply) of
        {ok, _} = Ok ->
            Ok;
        error ->
            case find_tx_hash(Reply) of
                {ok, TxHash} -> {pending, TxHash};
                error -> {error, {unexpected_contract_deploy_reply, Reply}}
            end
    end;
deployed_contract_id({ok, Reply}) when is_map(Reply) ->
    deployed_contract_id(Reply);
deployed_contract_id({error, _} = Error) ->
    Error;
deployed_contract_id(Other) ->
    {error, {unexpected_contract_deploy_reply, Other}}.

find_contract_id(Map) when is_map(Map) ->
    case map_value([contract_id, <<"contract_id">>, "contract_id"], Map, undefined) of
        undefined -> find_contract_id_nested(maps:values(Map));
        ContractId -> normalize_contract_id(ContractId)
    end;
find_contract_id(_) ->
    error.

find_contract_id_nested([]) ->
    error;
find_contract_id_nested([Value | Rest]) when is_map(Value) ->
    case find_contract_id(Value) of
        {ok, _} = Ok -> Ok;
        _ -> find_contract_id_nested(Rest)
    end;
find_contract_id_nested([_ | Rest]) ->
    find_contract_id_nested(Rest).

find_tx_hash(Map) ->
    case map_value([tx_hash, <<"tx_hash">>, "tx_hash"], Map, undefined) of
        undefined -> error;
        TxHash -> {ok, TxHash}
    end.

map_value([], _Map, Default) ->
    Default;
map_value([Key | Keys], Map, Default) ->
    case maps:find(Key, Map) of
        {ok, Value} -> Value;
        error -> map_value(Keys, Map, Default)
    end.
