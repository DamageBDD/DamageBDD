%%--------------------------------------------------------------------
%% Canonical configuration ownership for the in-tree nsecbunker.
%%
%% AWS custody is opt-in. Existing/non-managed nodes default to the local
%% Damage secret store and retain the historical one-shot crypto backend.
%%
%% All provider configuration lives under application env:
%%
%%   {damage, [{nsecbunker, [...]}]}
%%
%% `secret_provider` selects the runtime custody path. AWS protocol and
%% credential requirements are implementation invariants, not config knobs.
%%--------------------------------------------------------------------
-module(damage_nsecbunker_config).

-export([
    load/0,
    normalize/1,
    enabled/1,
    production/1,
    secret_provider/1,
    aws_secret/1,
    managed_secret_owner/1,
    aws_requested/1,
    secure_aws/1,
    provider_change/2,
    validate_production/1
]).

-type secret_provider() :: local | aws_secrets_manager | term().

-spec load() -> map().
load() ->
    Raw =
        case application:get_env(damage, nsecbunker) of
            {ok, Value} -> Value;
            undefined -> #{}
        end,
    normalize(Raw).

-spec normalize(term()) -> map().
normalize(Config) when is_map(Config) ->
    normalize_map(Config);
normalize(Config) when is_list(Config) ->
    case is_kv_list(Config) of
        true -> normalize_map(maps:from_list(Config));
        false -> #{}
    end;
normalize(_) ->
    #{}.

-spec enabled(term()) -> boolean().
enabled(Config0) ->
    Config = normalize(Config0),
    maps:get(enabled, Config, false) =:= true.

-spec production(term()) -> boolean().
production(Config0) ->
    Config = normalize(Config0),
    lists:member(
        maps:get(mode, Config, undefined),
        [
            production,
            phase4b_damagebdd_production,
            <<"production">>,
            <<"phase4b_damagebdd_production">>,
            "production",
            "phase4b_damagebdd_production"
        ]
    ).

%% Provider selection is explicit. Omission preserves the pre-AWS local
%% behavior. Stale or partial AWS configuration does not activate AWS.
-spec secret_provider(term()) -> secret_provider().
secret_provider(Config0) ->
    Config = normalize(Config0),
    normalize_secret_provider(
        maps:get(secret_provider, Config, local)
    ).

-spec managed_secret_owner(term()) -> boolean().
managed_secret_owner(Config) ->
    secret_provider(Config) =:= aws_secrets_manager.

-spec aws_requested(term()) -> boolean().
aws_requested(Config0) ->
    Config = normalize(Config0),
    enabled(Config) andalso
        managed_secret_owner(Config).

%% Deployment-specific AWS identifiers. IMDSv2, the EC2 credential provider
%% and AWSCURRENT remain hard-coded security invariants in the AWS provider.
-spec aws_secret(term()) -> map().
aws_secret(Config0) ->
    Config = normalize(Config0),
    normalize(maps:get(aws_secret, Config, #{})).

%% Retained for callers that need a boolean readiness/configuration predicate.
%% This checks configuration only; runtime IMDS/STS/Secrets Manager validation
%% still belongs to damage_aws_secret_provider.
-spec secure_aws(term()) -> boolean().
secure_aws(Config0) ->
    Config = normalize(Config0),
    production(Config) andalso
        managed_secret_owner(Config) andalso
        validate_aws_config(aws_secret(Config)) =:= ok.

%% A provider switch changes the supervisor child set and must be performed by
%% restarting the nsecbunker subtree/application. Same-provider reload is safe.
-spec provider_change(term(), term()) -> ok | {error, term()}.
provider_change(CurrentConfig, CandidateConfig) ->
    case
        {
            secret_provider(CurrentConfig),
            secret_provider(CandidateConfig)
        }
    of
        {Provider, Provider} ->
            ok;
        {From, To} ->
            {error,
                {
                    secret_provider_change_requires_restart,
                    #{from => From, to => To}
                }}
    end.

%% The name is retained for API compatibility. Local preserves the historical
%% behavior. AWS is explicit, production-only, and fail-closed.
-spec validate_production(term()) -> ok | {error, term()}.
validate_production(Config0) ->
    Config = normalize(Config0),
    case validate_provider_selection(Config) of
        ok ->
            case production(Config) of
                true -> validate_production_config(Config);
                false -> validate_nonproduction_config(Config)
            end;
        {error, _} = Error ->
            Error
    end.

validate_production_config(Config) ->
    Required = [crypto_backend_cmd, vault_path],
    Missing = [Key || Key <- Required, missing(Key, Config)],
    case Missing of
        [] ->
            case validate_vault_mode(Config) of
                ok -> validate_selected_provider(Config);
                {error, _} = Error -> Error
            end;
        _ ->
            {error, {missing_production_nsecbunker_config, Missing}}
    end.

validate_nonproduction_config(Config) ->
    case secret_provider(Config) of
        local ->
            ok;
        aws_secrets_manager ->
            {error, invalid_aws_secret_provider_configuration}
    end.

validate_selected_provider(Config) ->
    case secret_provider(Config) of
        local ->
            ok;
        aws_secrets_manager ->
            validate_aws_config(aws_secret(Config));
        Other ->
            {error, {unsupported_nsecbunker_secret_provider, Other}}
    end.

validate_aws_config(Aws) ->
    Required = [
        region,
        secret_id,
        expected_account_id,
        expected_role_name
    ],
    Missing = [Key || Key <- Required, missing(Key, Aws)],
    case Missing of
        [] ->
            ok;
        _ ->
            {error, {missing_aws_secret_configuration, Missing}}
    end.

validate_provider_selection(Config) ->
    case secret_provider(Config) of
        local -> ok;
        aws_secrets_manager -> ok;
        Other -> {error, {unsupported_nsecbunker_secret_provider, Other}}
    end.

validate_vault_mode(Config) ->
    case maps:get(vault_mode, Config, open_existing) of
        open_existing -> ok;
        create_if_missing -> ok;
        <<"open_existing">> -> ok;
        <<"create_if_missing">> -> ok;
        "open_existing" -> ok;
        "create_if_missing" -> ok;
        Other -> {error, {invalid_vault_mode, Other}}
    end.

normalize_secret_provider(local) -> local;
normalize_secret_provider(local_secret) -> local;
normalize_secret_provider(damage_secret_store) -> local;
normalize_secret_provider(<<"local">>) -> local;
normalize_secret_provider(<<"local_secret">>) -> local;
normalize_secret_provider(<<"damage_secret_store">>) -> local;
normalize_secret_provider("local") -> local;
normalize_secret_provider("local_secret") -> local;
normalize_secret_provider("damage_secret_store") -> local;
normalize_secret_provider(aws) -> aws_secrets_manager;
normalize_secret_provider(aws_secrets_manager) -> aws_secrets_manager;
normalize_secret_provider(<<"aws">>) -> aws_secrets_manager;
normalize_secret_provider(<<"aws_secrets_manager">>) -> aws_secrets_manager;
normalize_secret_provider("aws") -> aws_secrets_manager;
normalize_secret_provider("aws_secrets_manager") -> aws_secrets_manager;
normalize_secret_provider(Value) -> Value.

missing(Key, Config) ->
    case maps:get(Key, Config, undefined) of
        undefined -> true;
        <<>> -> true;
        [] -> true;
        _ -> false
    end.

normalize_map(Map) ->
    maps:fold(
        fun(K, V, Acc) ->
            Acc#{normalize_key(K) => normalize_value(V)}
        end,
        #{},
        Map
    ).

normalize_value(Map) when is_map(Map) ->
    normalize_map(Map);
normalize_value(List) when is_list(List) ->
    case {is_string(List), is_kv_list(List)} of
        {true, _} -> List;
        {false, true} -> normalize_map(maps:from_list(List));
        {false, false} -> [normalize_value(V) || V <- List]
    end;
normalize_value(Value) ->
    Value.

normalize_key(Key) when is_binary(Key) ->
    try
        binary_to_existing_atom(Key, utf8)
    catch
        _:_ -> Key
    end;
normalize_key(Key) when is_list(Key) ->
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
normalize_key(Key) ->
    Key.

is_kv_list([]) ->
    false;
is_kv_list(List) when is_list(List) ->
    lists:all(
        fun
            ({K, _}) when is_atom(K); is_integer(K); is_binary(K) -> true;
            (_) -> false
        end,
        List
    );
is_kv_list(_) ->
    false.

is_string([]) ->
    false;
is_string(List) when is_list(List) ->
    lists:all(
        fun(C) ->
            is_integer(C) andalso
                C >= 0 andalso
                C =< 16#10FFFF
        end,
        List
    );
is_string(_) ->
    false.
