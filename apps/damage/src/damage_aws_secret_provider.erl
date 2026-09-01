%%--------------------------------------------------------------------
%% AWS Secrets Manager provider for the production nsecbunker vault.
%%
%% AWS support is part of the normal Damage build, but this module is invoked
%% only when secret_provider=aws_secrets_manager. /2 keeps external effects
%% injectable for EUnit without making production module selection configurable.
%%
%% Production callers MUST invoke this module from inside
%% damage_aws_runtime:with_runtime/2 and supply `imdsv2_metadata`.
%%--------------------------------------------------------------------
-module(damage_aws_secret_provider).

-export([
    fetch_vault_passphrase/2,
    credential_provider/1
]).

-define(AWS_OPTIONS, [
    {retry_options, {exponential_with_jitter, {5, 100, 2000}}}
]).

-define(VERSION_STAGE, <<"AWSCURRENT">>).
-define(CREDENTIAL_PROVIDER, aws_credentials_ec2).


-spec fetch_vault_passphrase(term(), map()) ->
    {ok, binary(), map()} | {error, term()}.
fetch_vault_passphrase(Config0, Dependencies0) ->
    Config = damage_nsecbunker_config:normalize(Config0),
    Dependencies = maps:merge(default_dependencies(), Dependencies0),
    case validate_config(Config) of
        ok ->
            fetch_validated(Config, Dependencies);
        {error, _} = Error ->
            Error
    end.

fetch_validated(Config, Dependencies) ->
    case forbidden_credential_sources(Dependencies) of
        [] ->
            case runtime_metadata(Config, Dependencies) of
                {ok, ImdsMetadata} ->
                    credentials(
                        Config,
                        ImdsMetadata,
                        Dependencies
                    );
                {error, _} = Error ->
                    Error
            end;
        Names ->
            {error, {forbidden_aws_credential_source, Names}}
    end.

%% Production calls arrive with IMDS already validated by
%% damage_aws_runtime:with_runtime/2. The secondary path exists only so unit
%% tests can inject their previous prepare/probe functions explicitly.
runtime_metadata(Config, Dependencies) ->
    case maps:get(imdsv2_metadata, Dependencies, undefined) of
        Metadata when is_map(Metadata) ->
            {ok, Metadata};
        undefined ->
            injected_runtime_metadata(Config, Dependencies);
        _ ->
            {error, invalid_imdsv2_metadata}
    end.

injected_runtime_metadata(Config, Dependencies) ->
    case
        {
            maps:find(prepare_runtime, Dependencies),
            maps:find(imdsv2_validate, Dependencies)
        }
    of
        {{ok, PrepareRuntime}, {ok, Imdsv2Validate}} when
            is_function(PrepareRuntime, 0),
            is_function(Imdsv2Validate, 1)
        ->
            case PrepareRuntime() of
                ok ->
                    ExpectedRole =
                        to_binary(maps:get(expected_role_name, Config)),
                    Imdsv2Validate(ExpectedRole);
                {error, Reason} ->
                    {error, {aws_runtime_start_failed, safe_reason(Reason)}}
            end;
        _ ->
            {error, aws_runtime_scope_required}
    end.

credentials(Config, ImdsMetadata, Dependencies) ->
    GetCredentials = maps:get(get_credentials, Dependencies),
    case GetCredentials() of
        Credentials when is_map(Credentials) ->
            validate_credentials(
                Credentials,
                Config,
                ImdsMetadata,
                Dependencies
            );
        undefined ->
            {error, instance_profile_credentials_unavailable};
        _ ->
            {error, invalid_instance_profile_credentials}
    end.

validate_credentials(Credentials, Config, ImdsMetadata, Dependencies) ->
    Provider = credential_provider(Credentials),
    AccessKeyId = maps:get(access_key_id, Credentials, undefined),
    SecretAccessKey = maps:get(secret_access_key, Credentials, undefined),
    Token = maps:get(
        token,
        Credentials,
        maps:get(session_token, Credentials, undefined)
    ),
    case
        {
            Provider,
            nonempty_binary(AccessKeyId),
            nonempty_binary(SecretAccessKey),
            nonempty_binary(Token)
        }
    of
        {?CREDENTIAL_PROVIDER, true, true, true} ->
            Region = to_binary(maps:get(region, Config)),
            MakeClient = maps:get(make_client, Dependencies),
            Client = MakeClient(
                AccessKeyId,
                SecretAccessKey,
                Token,
                Region
            ),
            verify_identity(
                Client,
                Config,
                ImdsMetadata,
                Dependencies
            );
        {undefined, _, _, _} ->
            {error, credential_provider_missing};
        {OtherProvider, _, _, _} when
            OtherProvider =/= ?CREDENTIAL_PROVIDER
        ->
            {error, {wrong_credential_provider, OtherProvider}};
        _ ->
            {error, invalid_instance_profile_credentials}
    end.

%% aws_credentials 1.0.4 documents credential_provider. provider_source is
%% accepted only as an upgrade-compatible field name; the required value never
%% changes.
-spec credential_provider(map()) -> term().
credential_provider(Credentials) when is_map(Credentials) ->
    maps:get(
        credential_provider,
        Credentials,
        maps:get(provider_source, Credentials, undefined)
    );
credential_provider(_) ->
    undefined.

verify_identity(Client, Config, ImdsMetadata, Dependencies) ->
    ExpectedAccount = to_binary(maps:get(expected_account_id, Config)),
    ExpectedRole = to_binary(maps:get(expected_role_name, Config)),
    StsIdentity = maps:get(sts_identity, Dependencies),
    case StsIdentity(Client) of
        {ok, Identity, _HttpResponse} when is_map(Identity) ->
            Account = maps:get(<<"Account">>, Identity, <<>>),
            Arn = maps:get(<<"Arn">>, Identity, <<>>),
            case
                Account =:= ExpectedAccount andalso
                    assumed_role_matches(
                        Arn,
                        ExpectedAccount,
                        ExpectedRole
                    )
            of
                true ->
                    get_secret(
                        Client,
                        Config,
                        ImdsMetadata#{
                            account_id => Account,
                            role_name => ExpectedRole
                        },
                        Dependencies
                    );
                false ->
                    {error,
                        {
                            unexpected_aws_identity,
                            #{
                                account_id => Account,
                                arn => Arn
                            }
                        }}
            end;
        {error, Reason} ->
            {error, {
                sts_identity_check_failed,
                safe_aws_error(Reason)
            }};
        _ ->
            {error, invalid_sts_identity_response}
    end.

get_secret(Client, Config, IdentityMetadata, Dependencies) ->
    SecretId = to_binary(maps:get(secret_id, Config)),
    Input = #{
        <<"SecretId">> => SecretId,
        <<"VersionStage">> => ?VERSION_STAGE
    },
    GetSecret = maps:get(get_secret, Dependencies),
    case GetSecret(Client, Input) of
        {ok, #{<<"SecretString">> := Passphrase} = Response, _HttpResponse} when
            is_binary(Passphrase),
            byte_size(Passphrase) > 0
        ->
            VersionStages = maps:get(
                <<"VersionStages">>,
                Response,
                []
            ),
            case lists:member(?VERSION_STAGE, VersionStages) of
                true ->
                    {ok, Passphrase, IdentityMetadata#{
                        credential_provider => ?CREDENTIAL_PROVIDER,
                        imds_protocol => imdsv2,
                        secret_id_sha256 => sha256_hex(SecretId),
                        version_id => maps:get(
                            <<"VersionId">>,
                            Response,
                            undefined
                        ),
                        version_stages => VersionStages
                    }};
                false ->
                    {error, secret_is_not_awscurrent}
            end;
        {ok, #{<<"SecretString">> := <<>>}, _HttpResponse} ->
            {error, empty_secret_string};
        {ok, #{<<"SecretBinary">> := _}, _HttpResponse} ->
            {error, secret_binary_not_supported};
        {ok, _Response, _HttpResponse} ->
            {error, secret_string_missing};
        {error, Reason} ->
            {error, {
                secrets_manager_get_failed,
                safe_aws_error(Reason)
            }};
        _ ->
            {error, invalid_secrets_manager_response}
    end.

validate_config(Config) ->
    Required = [
        secret_id,
        region,
        expected_account_id,
        expected_role_name
    ],
    Missing = [
        Key
     || Key <- Required,
        not nonempty_binary(
            to_binary(maps:get(Key, Config, undefined))
        )
    ],
    case Missing of
        [] ->
            ok;
        _ ->
            {error, {missing_aws_secret_configuration, Missing}}
    end.

default_dependencies() ->
    #{
        os_getenv => fun os:getenv/1,
        get_credentials => fun aws_credentials:get_credentials/0,
        make_client => fun aws_client:make_temporary_client/4,
        sts_identity =>
            fun(Client) ->
                aws_sts:get_caller_identity(
                    Client,
                    #{},
                    ?AWS_OPTIONS
                )
            end,
        get_secret =>
            fun(Client, Input) ->
                aws_secrets_manager:get_secret_value(
                    Client,
                    Input,
                    ?AWS_OPTIONS
                )
            end
    }.

forbidden_credential_sources(Dependencies) ->
    GetEnv = maps:get(os_getenv, Dependencies),
    Names = [
        "AWS_ACCESS_KEY_ID",
        "AWS_SECRET_ACCESS_KEY",
        "AWS_SESSION_TOKEN",
        "AWS_SECURITY_TOKEN",
        "AWS_PROFILE",
        "AWS_DEFAULT_PROFILE",
        "AWS_SHARED_CREDENTIALS_FILE",
        "AWS_CONFIG_FILE",
        "AWS_CONTAINER_CREDENTIALS_RELATIVE_URI",
        "AWS_CONTAINER_CREDENTIALS_FULL_URI",
        "AWS_WEB_IDENTITY_TOKEN_FILE",
        "AWS_ROLE_ARN",
        "AWS_EC2_METADATA_SERVICE_ENDPOINT",
        "AWS_EC2_METADATA_SERVICE_ENDPOINT_MODE",
        "AWS_EC2_METADATA_DISABLED",
        "DAMAGE_NSECBUNKER_VAULT_PASSPHRASE"
    ],
    [
        Name
     || Name <- Names,
        environment_value_present(GetEnv(Name))
    ].

environment_value_present(false) -> false;
environment_value_present("") -> false;
environment_value_present(<<>>) -> false;
environment_value_present(_) -> true.

assumed_role_matches(Arn, Account, Role) when
    is_binary(Arn),
    is_binary(Account),
    is_binary(Role)
->
    Needle = <<
        ":sts::",
        Account/binary,
        ":assumed-role/",
        Role/binary,
        "/"
    >>,
    has_prefix(Arn, <<"arn:">>) andalso
        binary:match(Arn, Needle) =/= nomatch;
assumed_role_matches(_, _, _) ->
    false.

has_prefix(Value, Prefix) when
    is_binary(Value),
    is_binary(Prefix),
    byte_size(Value) >= byte_size(Prefix)
->
    binary:part(Value, 0, byte_size(Prefix)) =:= Prefix;
has_prefix(_, _) ->
    false.

nonempty_binary(Value) when is_binary(Value) ->
    byte_size(Value) > 0;
nonempty_binary(_) ->
    false.

to_binary(Value) when is_binary(Value) -> Value;
to_binary(Value) when is_list(Value) ->
    unicode:characters_to_binary(Value);
to_binary(Value) when is_atom(Value) ->
    atom_to_binary(Value, utf8);
to_binary(_) ->
    <<>>.

sha256_hex(Value) ->
    Hash = crypto:hash(sha256, Value),
    iolist_to_binary([
        [hex_digit(Byte bsr 4), hex_digit(Byte band 16#0f)]
     || <<Byte>> <= Hash
    ]).

hex_digit(N) when N < 10 -> $0 + N;
hex_digit(N) -> $a + N - 10.

safe_aws_error(#{<<"__type">> := Type}) -> Type;
safe_aws_error(#{type := Type}) -> Type;
safe_aws_error(#{code := Code}) -> Code;
safe_aws_error({http_error, Status, _Body}) -> {http_error, Status};
safe_aws_error(Reason) when is_atom(Reason) -> Reason;
safe_aws_error(_) -> aws_request_failed.

safe_reason({error, Reason}) ->
    safe_reason(Reason);
safe_reason(Reason) when is_atom(Reason) -> Reason;
safe_reason({Tag, Value}) when is_atom(Tag), is_atom(Value) ->
    {Tag, Value};
safe_reason({Tag, _}) when is_atom(Tag) -> Tag;
safe_reason(_) ->
    startup_failed.
