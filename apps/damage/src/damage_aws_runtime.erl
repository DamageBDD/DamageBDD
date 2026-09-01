%%--------------------------------------------------------------------
%% Short-lived AWS runtime for nsecbunker bootstrap.
%%
%% aws_credentials is deliberately NOT a long-running Damage service.
%% It is started only when:
%%   * nsecbunker.enabled = true
%%   * secret_provider = aws_secrets_manager
%%   * the configured AWS block is valid
%%   * an IMDSv2 probe confirms the expected EC2 role
%%
%% fail_if_unavailable=true prevents aws_credentials' built-in 5-second
%% missing-credential retry loop. The application is stopped again after the
%% bootstrap callback completes, so there is no background credential refresher
%% between vault bootstrap/reload operations.
%%--------------------------------------------------------------------
-module(damage_aws_runtime).

-export([
    active/0,
    active/1,
    probe/0,
    probe/1,
    with_runtime/2,
    status/0,
    quiesce/0
]).

-define(CREDENTIAL_PROVIDER, aws_credentials_ec2).

-spec active() -> boolean().
active() ->
    active(damage_nsecbunker_config:load()).

-spec active(term()) -> boolean().
active(Config0) ->
    Config = damage_nsecbunker_config:normalize(Config0),
    damage_nsecbunker_config:aws_requested(Config) andalso
        damage_nsecbunker_config:secure_aws(Config).

-spec probe() -> {ok, map()} | {error, term()}.
probe() ->
    probe(damage_nsecbunker_config:load()).

-spec probe(term()) -> {ok, map()} | {error, term()}.
probe(Config0) ->
    Config = damage_nsecbunker_config:normalize(Config0),
    case damage_nsecbunker_config:aws_requested(Config) of
        false ->
            {error, aws_provider_not_enabled};
        true ->
            case damage_nsecbunker_config:secure_aws(Config) of
                false ->
                    {error, invalid_aws_secret_provider_configuration};
                true ->
                    Aws = damage_nsecbunker_config:aws_secret(Config),
                    Role = maps:get(expected_role_name, Aws, undefined),
                    damage_aws_imdsv2:validate_role(Role)
            end
    end.

%% Fun is executed only while the AWS runtime is valid and receives safe IMDS
%% metadata.
%%
%% Any applications started by this call are stopped before a successful
%% callback result is returned. Callers may return short-lived bootstrap data
%% from Fun, but must consume secret material immediately and must not retain it
%% in long-lived OTP state.
-spec with_runtime(term(), fun((map()) -> term())) -> term().
with_runtime(Config0, Fun) when is_function(Fun, 1) ->
    Config = damage_nsecbunker_config:normalize(Config0),
    case probe(Config) of
        {ok, ImdsMetadata} ->
            case start_runtime() of
                {ok, Ownership} ->
                    try Fun(ImdsMetadata) of
                        Result ->
                            case stop_owned_runtime(Ownership) of
                                ok ->
                                    Result;
                                {error, _} = StopError ->
                                    StopError
                            end
                    catch
                        Class:Reason:Stack ->
                            %% Always attempt cleanup, but preserve the original
                            %% callback exception and stacktrace.
                            _ = stop_owned_runtime(Ownership),
                            erlang:raise(Class, Reason, Stack)
                    end;
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

-spec status() -> map().
status() ->
    Config = damage_nsecbunker_config:load(),
    Requested = damage_nsecbunker_config:aws_requested(Config),
    CredentialsRunning = application_running(aws_credentials),
    AwsRunning = application_running(aws),
    #{
        requested => Requested,
        active_config => active(Config),
        aws_application_running => AwsRunning,
        aws_credentials_running => CredentialsRunning,
        unexpected_credentials_service =>
            CredentialsRunning andalso not Requested,
        credential_providers =>
            app_env(aws_credentials, credential_providers),
        fail_if_unavailable =>
            app_env(aws_credentials, fail_if_unavailable)
    }.

%% Field-recovery helper. Safe only when AWS custody is not selected.
-spec quiesce() -> ok | {error, term()}.
quiesce() ->
    Config = damage_nsecbunker_config:load(),
    case damage_nsecbunker_config:aws_requested(Config) of
        true ->
            {error, aws_provider_enabled};
        false ->
            stop_application(aws_credentials)
    end.

start_runtime() ->
    CredentialsWasRunning = application_running(aws_credentials),
    AwsWasRunning = application_running(aws),
    case CredentialsWasRunning of
        true ->
            %% A release/supervisor has started this outside the controlled
            %% bootstrap scope. Do not reuse potentially default-provider state.
            {error, aws_credentials_started_outside_nsecbunker};
        false ->
            case configure_credentials_application() of
                ok ->
                    case application:ensure_all_started(aws_credentials) of
                        {ok, _} ->
                            case application:ensure_all_started(aws) of
                                {ok, _} ->
                                    {ok, #{
                                        credentials_started => true,
                                        aws_started => not AwsWasRunning
                                    }};
                                {error, Reason} ->
                                    _ = stop_application(aws_credentials),
                                    {error, {aws_application_start_failed, safe_reason(Reason)}}
                            end;
                        {error, Reason} ->
                            %% fail_if_unavailable=true means this failure is
                            %% terminal for this attempt; aws_credentials does
                            %% not stay alive retrying every five seconds.
                            {error, {aws_credentials_start_failed, safe_reason(Reason)}}
                    end;
                {error, _} = Error ->
                    Error
            end
    end.

configure_credentials_application() ->
    case ensure_loaded(aws_credentials) of
        ok ->
            ok = application:set_env(
                aws_credentials,
                credential_providers,
                [?CREDENTIAL_PROVIDER]
            ),
            ok = application:set_env(
                aws_credentials,
                fail_if_unavailable,
                true
            ),
            ok;
        {error, _} = Error ->
            Error
    end.

stop_owned_runtime(Ownership) ->
    %% Reverse the explicit startup order: aws first, credentials second.
    AwsResult =
        case maps:get(aws_started, Ownership, false) of
            true -> stop_application(aws);
            false -> ok
        end,
    CredentialsResult =
        case maps:get(credentials_started, Ownership, false) of
            true -> stop_application(aws_credentials);
            false -> ok
        end,
    shutdown_result(AwsResult, CredentialsResult).

shutdown_result(ok, ok) ->
    ok;
shutdown_result(AwsError = {error, _}, ok) ->
    {error, {aws_runtime_shutdown_failed, #{aws => AwsError}}};
shutdown_result(ok, CredentialsError = {error, _}) ->
    {error, {
        aws_runtime_shutdown_failed,
        #{aws_credentials => CredentialsError}
    }};
shutdown_result(
    AwsError = {error, _},
    CredentialsError = {error, _}
) ->
    {error, {
        aws_runtime_shutdown_failed,
        #{
            aws => AwsError,
            aws_credentials => CredentialsError
        }
    }}.

ensure_loaded(App) ->
    case application:load(App) of
        ok -> ok;
        {error, {already_loaded, App}} -> ok;
        {error, Reason} -> {error, {application_load_failed, App, safe_reason(Reason)}}
    end.

application_running(App) ->
    lists:keymember(App, 1, application:which_applications()).

stop_application(App) ->
    case application:stop(App) of
        ok -> ok;
        {error, {not_started, App}} -> ok;
        {error, Reason} -> {error, {application_stop_failed, App, safe_reason(Reason)}}
    end.

app_env(App, Key) ->
    case application:get_env(App, Key) of
        {ok, Value} -> Value;
        undefined -> undefined
    end.

safe_reason({error, Reason}) -> safe_reason(Reason);
safe_reason(Reason) when is_atom(Reason) -> Reason;
safe_reason({Tag, Value}) when is_atom(Tag), is_atom(Value) -> {Tag, Value};
safe_reason({Tag, _}) when is_atom(Tag) -> Tag;
safe_reason(_) -> aws_runtime_failure.
