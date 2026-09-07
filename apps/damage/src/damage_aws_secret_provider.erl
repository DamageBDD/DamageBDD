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
-include_lib("kernel/include/logger.hrl").

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
            ?LOG_INFO(
                "AWS credential response keys=~p provider=~p access_key_present=~p "
                "secret_key_present=~p session_token_present=~p",
                [
                    maps:keys(Credentials),
                    credential_provider(Credentials),
                    nonempty_binary(
                        maps:get(access_key_id, Credentials, undefined)
                    ),
                    nonempty_binary(
                        maps:get(secret_access_key, Credentials, undefined)
                    ),
                    nonempty_binary(
                        maps:get(
                            token,
                            Credentials,
                            maps:get(session_token, Credentials, undefined)
                        )
                    )
                ]
            ),
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
        {ok, Identity, HttpResponse} when is_map(Identity) ->
            IdentityKeyTree = aws_key_tree(Identity, 4),
            ?LOG_INFO(
                "AWS STS GetCallerIdentity ok response_shape=~p key_tree=~p http_shape=~p",
                [
                    term_shape(Identity),
                    IdentityKeyTree,
                    term_shape(HttpResponse)
                ]
            ),
            Account = to_binary(
                aws_field_deep(
                    Identity,
                    [
                        account,
                        'Account',
                        <<"account">>,
                        <<"Account">>
                    ],
                    <<>>
                )
            ),
            Arn = to_binary(
                aws_field_deep(
                    Identity,
                    [
                        arn,
                        'Arn',
                        <<"arn">>,
                        <<"Arn">>
                    ],
                    <<>>
                )
            ),
            ?LOG_INFO(
                "AWS STS identity extracted account=~p arn=~p expected_account=~p "
                "expected_role=~p account_match=~p role_match=~p",
                [
                    Account,
                    Arn,
                    ExpectedAccount,
                    ExpectedRole,
                    Account =:= ExpectedAccount,
                    assumed_role_matches(
                        Arn,
                        ExpectedAccount,
                        ExpectedRole
                    )
                ]
            ),
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
            SafeReason = safe_aws_error(Reason),
            ?LOG_ERROR(
                "AWS STS GetCallerIdentity failed reason=~p shape=~p",
                [SafeReason, term_shape(Reason)]
            ),
            {error, {
                sts_identity_check_failed,
                safe_aws_error(Reason)
            }};
        Other ->
            ?LOG_ERROR(
                "AWS STS GetCallerIdentity returned unexpected shape=~p",
                [term_shape(Other)]
            ),
            {error, invalid_sts_identity_response}
    end.

get_secret(
    Client,
    Config,
    IdentityMetadata,
    Dependencies
) ->
    SecretId =
        to_binary(
            maps:get(secret_id, Config)
        ),

    Stage = <<"AWSCURRENT">>,

    Input = #{
        <<"SecretId">> => SecretId,
        <<"VersionStage">> => Stage
    },

    GetSecret =
        maps:get(get_secret, Dependencies),
    ?LOG_INFO(
        "AWS Secrets Manager GetSecretValue begin secret_id_sha256=~p stage=~p",
        [sha256_hex(SecretId), Stage]
    ),

    case GetSecret(Client, Input) of
        {ok, Response, HttpResponse}
                when is_map(Response) ->
            ?LOG_INFO(
                "AWS Secrets Manager GetSecretValue ok key_tree=~p http_shape=~p",
                [
                    aws_key_tree(Response, 4),
                    term_shape(HttpResponse)
                ]
            ),
            handle_secret_response(
                Response,
                SecretId,
                Stage,
                IdentityMetadata
            );

        {error, Reason} ->
            SafeReason = safe_aws_error(Reason),
            ?LOG_ERROR(
                "AWS Secrets Manager GetSecretValue failed reason=~p shape=~p",
                [SafeReason, term_shape(Reason)]
            ),
            {error, {
                secrets_manager_get_failed,
                SafeReason
            }};

        Other ->
            ?LOG_ERROR(
                "AWS Secrets Manager GetSecretValue unexpected response shape=~p",
                [term_shape(Other)]
            ),
            {error,
                invalid_secrets_manager_response}
    end.

handle_secret_response(
    Response,
    SecretId,
    Stage,
    IdentityMetadata
) ->
    SecretString =
        aws_field_deep(
            Response,
            [
                secret_string,
                'SecretString',
                <<"secret_string">>,
                <<"SecretString">>
            ],
            undefined
        ),

    SecretBinary =
        aws_field_deep(
            Response,
            [
                secret_binary,
                'SecretBinary',
                <<"secret_binary">>,
                <<"SecretBinary">>
            ],
            undefined
        ),

    VersionStages0 =
        aws_field_deep(
            Response,
            [
                version_stages,
                'VersionStages',
                <<"version_stages">>,
                <<"VersionStages">>
            ],
            []
        ),

    VersionStages =
        [
            to_binary(Value)
         || Value <- VersionStages0
        ],

    VersionId =
        aws_field_deep(
            Response,
            [
                version_id,
                'VersionId',
                <<"version_id">>,
                <<"VersionId">>
            ],
            undefined
        ),

    ?LOG_INFO(
        "AWS Secrets Manager response parsed secret_string_present=~p "
        "secret_string_bytes=~p secret_binary_present=~p "
        "version_id=~p version_stages=~p",
        [
            is_binary(SecretString) andalso byte_size(SecretString) > 0,
            secret_size(SecretString),
            SecretBinary =/= undefined,
            VersionId,
            VersionStages
        ]
    ),

    case {
        SecretString,
        SecretBinary
    } of
        {Passphrase, _}
                when is_binary(Passphrase),
                     byte_size(Passphrase) > 0 ->
            case lists:member(
                Stage,
                VersionStages
            ) of
                true ->
                    {ok,
                        Passphrase,
                        IdentityMetadata#{
                            credential_provider =>
                                aws_credentials_ec2,
                            imds_protocol =>
                                imdsv2,
                            secret_id_sha256 =>
                                sha256_hex(SecretId),
                            version_id =>
                                VersionId,
                            version_stages =>
                                VersionStages
                        }};

                false ->
                    {error,
                        secret_is_not_awscurrent}
            end;

        {<<>>, _} ->
            {error, empty_secret_string};

        {undefined, Binary}
                when Binary =/= undefined ->
            {error,
                secret_binary_not_supported};

        _ ->
            {error, secret_string_missing}
    end.
aws_field(_Map, [], Default) ->
    Default;
aws_field(Map, [Key | Rest], Default) when is_map(Map) ->
    case maps:find(Key, Map) of
        {ok, Value} ->
            Value;
        error ->
            aws_field(Map, Rest, Default)
    end;
aws_field(_Other, _Keys, Default) ->
    Default.

%% AWS Query/XML decoders may preserve response/result wrapper maps. Search
%% known response fields recursively rather than assuming the service-specific
%% fields are always top-level.
aws_field_deep(Term, Keys, Default) ->
    case aws_field_deep_find(Term, Keys) of
        {ok, Value} -> Value;
        error -> Default
    end.

aws_field_deep_find(Map, Keys) when is_map(Map) ->
    case aws_field(Map, Keys, '$damage_aws_missing') of
        '$damage_aws_missing' ->
            aws_field_deep_values(maps:values(Map), Keys);
        Value ->
            {ok, Value}
    end;
aws_field_deep_find(List, Keys) when is_list(List) ->
    aws_field_deep_values(List, Keys);
aws_field_deep_find(_Other, _Keys) ->
    error.

aws_field_deep_values([], _Keys) ->
    error;
aws_field_deep_values([Value | Rest], Keys) ->
    case aws_field_deep_find(Value, Keys) of
        {ok, _} = Found ->
            Found;
        error ->
            aws_field_deep_values(Rest, Keys)
    end.

%% Log key names and structure only. Values are deliberately omitted so this is
%% safe to use for STS and Secrets Manager responses.
aws_key_tree(_Term, Depth) when Depth =< 0 ->
    depth_limit;
aws_key_tree(Map, Depth) when is_map(Map) ->
    maps:from_list([
        {safe_key(Key), aws_key_tree(Value, Depth - 1)}
     || {Key, Value} <- maps:to_list(Map)
    ]);
aws_key_tree(List, Depth) when is_list(List) ->
    case is_string_like(List) of
        true ->
            string;
        false ->
            [aws_key_tree(Value, Depth - 1) || Value <- lists:sublist(List, 8)]
    end;
aws_key_tree(Binary, _Depth) when is_binary(Binary) ->
    {binary, byte_size(Binary)};
aws_key_tree(Value, _Depth) when is_atom(Value) ->
    atom;
aws_key_tree(Value, _Depth) when is_integer(Value) ->
    integer;
aws_key_tree(Value, _Depth) when is_tuple(Value) ->
    {tuple, tuple_size(Value)};
aws_key_tree(_Value, _Depth) ->
    other.

safe_key(Key) when is_atom(Key) ->
    Key;
safe_key(Key) when is_binary(Key), byte_size(Key) =< 128 ->
    Key;
safe_key(Key) when is_list(Key) ->
    try unicode:characters_to_binary(Key) of
        Bin when byte_size(Bin) =< 128 -> Bin;
        _ -> long_key
    catch
        _:_ -> invalid_key
    end;
safe_key(_) ->
    unknown_key.

is_string_like([]) ->
    true;
is_string_like(List) when is_list(List) ->
    lists:all(fun(C) -> is_integer(C) andalso C >= 0 andalso C =< 16#10FFFF end, List);
is_string_like(_) ->
    false.

term_shape(Map) when is_map(Map) ->
    {map, map_size(Map)};
term_shape(List) when is_list(List) ->
    case is_string_like(List) of
        true -> string;
        false -> {list, length(List)}
    end;
term_shape(Binary) when is_binary(Binary) ->
    {binary, byte_size(Binary)};
term_shape(Tuple) when is_tuple(Tuple) ->
    {tuple, tuple_size(Tuple)};
term_shape(Value) when is_atom(Value) ->
    Value;
term_shape(Value) when is_integer(Value) ->
    integer;
term_shape(_) ->
    other.

secret_size(Value) when is_binary(Value) ->
    byte_size(Value);
secret_size(_) ->
    0.

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
