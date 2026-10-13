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
    validate_production/1,
    state_dir/0,
    default_vault_path/0,
    default_audit_log/0,
    vault_mode/1
]).

-type secret_provider() :: local | aws_secrets_manager | term().

-spec load() -> map().
load() ->
    Raw =
        case application:get_env(damage, nsecbunker) of
            {ok, Value} -> Value;
            undefined -> #{}
        end,
    apply_defaults(normalize(Raw)).

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
    %% aws_secret is the canonical/current key.  Retain compatibility with
    %% aws_secret_bootstrap so existing production configuration and tests do
    %% not silently lose the deployment-specific AWS identifiers.
    Bootstrap = normalize(
        maps:get(aws_secret_bootstrap, Config, #{})
    ),
    AwsSecret = normalize(
        maps:get(aws_secret, Config, #{})
    ),
    %% Canonical aws_secret wins when both are present.
    maps:merge(Bootstrap, AwsSecret).

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
    Config = apply_defaults(normalize(Config0)),
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
    case vault_mode(Config) of
        open_existing -> ok;
        create_if_missing -> ok;
        Other -> {error, {invalid_vault_mode, Other}}
    end.

-spec vault_mode(term()) -> open_existing | create_if_missing | term().
vault_mode(Config0) ->
    Config = normalize(Config0),
    normalize_vault_mode(maps:get(vault_mode, Config, open_existing)).

normalize_vault_mode(open_existing) -> open_existing;
normalize_vault_mode(create_if_missing) -> create_if_missing;
normalize_vault_mode(<<"open_existing">>) -> open_existing;
normalize_vault_mode(<<"create_if_missing">>) -> create_if_missing;
normalize_vault_mode("open_existing") -> open_existing;
normalize_vault_mode("create_if_missing") -> create_if_missing;
normalize_vault_mode(Other) -> Other.

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

%% -------------------------------------------------------------------
%% State/path defaults
%% -------------------------------------------------------------------

-spec state_dir() -> file:filename().
state_dir() ->
    Raw =
        case application:get_env(damage, nsecbunker) of
            {ok, Value} -> normalize(Value);
            undefined -> #{}
        end,
    state_dir(Raw).

-spec default_vault_path() -> file:filename().
default_vault_path() ->
    filename:join([state_dir(), "keys", "nsecbunker", "node.vault"]).

-spec default_audit_log() -> file:filename().
default_audit_log() ->
    filename:join([state_dir(), "logs", "nsecbunker_audit.log"]).

apply_defaults(Config0) ->
    Root = state_dir(Config0),
    VaultDefault = filename:join([Root, "keys", "nsecbunker", "node.vault"]),
    AuditDefault = filename:join([Root, "logs", "nsecbunker_audit.log"]),
    VaultPath = resolve_vault_path(Config0, VaultDefault),
    AuditLog = normalize_path(maps:get(audit_log, Config0, AuditDefault)),
    Config1 = maybe_expand_home_path(crypto_backend_cmd, Config0),
    Mode0 =
        case maps:find(vault_mode, Config1) of
            {ok, ExplicitMode} ->
                normalize_vault_mode(ExplicitMode);
            error ->
                default_vault_mode(Config1, VaultPath)
        end,
    Config1#{
        vault_path => VaultPath,
        audit_log => AuditLog,
        vault_mode => Mode0
    }.

resolve_vault_path(Config, VaultDefault) ->
    case maps:find(vault_path, Config) of
        {ok, ExplicitPath} ->
            normalize_path(ExplicitPath);
        error ->
            case filelib:is_regular(VaultDefault) of
                true ->
                    normalize_path(VaultDefault);
                false ->
                    case existing_legacy_vault() of
                        {ok, LegacyPath} -> LegacyPath;
                        not_found -> normalize_path(VaultDefault)
                    end
            end
    end.

existing_legacy_vault() ->
    first_existing_file([
        "/var/lib/damage/nsecbunker/damagebdd_node_production.vault",
        "/var/lib/damage/nsecbunker/node.vault",
        "/var/lib/damage/nsecbunker/genesis.vault"
    ]).

first_existing_file([Path | Rest]) ->
    case filelib:is_regular(Path) of
        true -> {ok, Path};
        false -> first_existing_file(Rest)
    end;
first_existing_file([]) ->
    not_found.

default_vault_mode(Config, VaultPath) ->
    case secret_provider(Config) of
        local ->
            case filelib:is_regular(VaultPath) of
                true -> open_existing;
                false -> create_if_missing
            end;
        %% Managed production custody remains ceremony-driven unless explicitly
        %% configured otherwise.
        aws_secrets_manager ->
            open_existing;
        _ ->
            open_existing
    end.

state_dir(Config) ->
    case maps:get(state_dir, Config, undefined) of
        Dir when is_binary(Dir); is_list(Dir) ->
            normalize_path(Dir);
        _ ->
            damage_state_dir()
    end.

damage_state_dir() ->
    case application:get_env(damage, state_dir) of
        {ok, Dir} when is_binary(Dir); is_list(Dir) ->
            normalize_path(Dir);
        _ ->
            case application:get_env(damage, secrets_state_dir) of
                {ok, Dir} when is_binary(Dir); is_list(Dir) ->
                    normalize_path(Dir);
                _ ->
                    default_damage_state_dir()
            end
    end.

default_damage_state_dir() ->
    case os:getenv("XDG_STATE_HOME") of
        Xdg when is_list(Xdg), Xdg =/= "" ->
            Expanded = expand_home(Xdg),
            case filename:pathtype(Expanded) of
                absolute -> filename:join(Expanded, "damage");
                _ -> home_state_dir()
            end;
        _ ->
            home_state_dir()
    end.

home_state_dir() ->
    case os:getenv("HOME") of
        Home when is_list(Home), Home =/= "" ->
            filename:join([Home, ".local", "state", "damage"]);
        _ ->
            "/var/lib/damage"
    end.

maybe_expand_home_path(Key, Config) ->
    case maps:get(Key, Config, undefined) of
        Value when is_binary(Value) ->
            Config#{Key => unicode:characters_to_binary(expand_home(binary_to_list(Value)))};
        Value when is_list(Value) ->
            Config#{Key => expand_home(Value)};
        _ ->
            Config
    end.

normalize_path(Value) when is_binary(Value) ->
    normalize_path(binary_to_list(Value));
normalize_path(Value) when is_list(Value), Value =/= [] ->
    filename:absname(expand_home(Value));
normalize_path(Value) ->
    erlang:error({invalid_nsecbunker_path, Value}).

expand_home("~") ->
    require_home("~");
expand_home([$~, $/ | Rest] = Path) ->
    filename:join(require_home(Path), Rest);
expand_home(Path) ->
    Path.

require_home(Path) ->
    case os:getenv("HOME") of
        Home when is_list(Home), Home =/= "" -> Home;
        _ -> erlang:error({home_directory_unavailable, Path})
    end.

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
