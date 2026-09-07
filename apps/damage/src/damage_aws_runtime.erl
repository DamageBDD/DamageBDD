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
%% missing-credential retry loop. Applications owned by this runtime are stopped
%% and unloaded after the bootstrap callback completes, so disabled/local nodes
%% do not retain AWS application state between bootstrap/reload operations.
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
    CredentialsLoaded = application_loaded(aws_credentials),
    AwsLoaded = application_loaded(aws),
    #{
        requested => Requested,
        active_config => active(Config),
        aws_application_loaded => AwsLoaded,
        aws_application_running => AwsRunning,
        aws_credentials_loaded => CredentialsLoaded,
        aws_credentials_running => CredentialsRunning,
        unexpected_aws_runtime =>
            not Requested andalso
                (AwsLoaded orelse
                    CredentialsLoaded orelse
                    AwsRunning orelse
                    CredentialsRunning),
        unexpected_credentials_service =>
            CredentialsRunning andalso not Requested,
        credential_providers =>
            app_env(aws_credentials, credential_providers),
        fail_if_unavailable =>
            app_env(aws_credentials, fail_if_unavailable)
    }.

%% Field-recovery helper. Safe only when AWS custody is not selected.
%% Stop and unload both AWS applications so a disabled/local node returns to
%% the same state it had at release boot.
-spec quiesce() -> ok | {error, term()}.
quiesce() ->
    Config = damage_nsecbunker_config:load(),
    case damage_nsecbunker_config:aws_requested(Config) of
        true ->
            {error, aws_provider_enabled};
        false ->
            cleanup_runtime(#{
                credentials_started => application_running(aws_credentials),
                aws_started => application_running(aws),
                credentials_loaded => application_loaded(aws_credentials),
                aws_loaded => application_loaded(aws)
            })
    end.

start_runtime() ->
    CredentialsWasRunning = application_running(aws_credentials),
    AwsWasRunning = application_running(aws),
    CredentialsWasLoaded = application_loaded(aws_credentials),
    AwsWasLoaded = application_loaded(aws),
    case {CredentialsWasRunning, AwsWasRunning} of
        {true, _} ->
            %% A release/supervisor has started this outside the controlled
            %% bootstrap scope. Do not reuse potentially default-provider state.
            {error, aws_credentials_started_outside_nsecbunker};
        {false, true} ->
            {error, aws_started_outside_nsecbunker};
        {false, false} ->
            case configure_credentials_application() of
                ok ->
                    %% Start the AWS client application first, then the
                    %% credential provider. Cleanup runs in reverse order.
                    case application:ensure_all_started(aws) of
                        {ok, _} ->
                            Ownership0 = #{
                                aws_started => true,
                                aws_loaded => not AwsWasLoaded,
                                credentials_started => false,
                                credentials_loaded => not CredentialsWasLoaded
                            },
                            case application:ensure_all_started(aws_credentials) of
                                {ok, _} ->
                                    {ok, Ownership0#{
                                        credentials_started => true
                                    }};
                                {error, Reason} ->
                                    StartError = {
                                        aws_credentials_start_failed,
                                        safe_reason(Reason)
                                    },
                                    failed_start(StartError, Ownership0)
                            end;
                        {error, Reason} ->
                            %% configure_credentials_application/0 may have
                            %% loaded aws_credentials before aws failed.
                            Ownership0 = #{
                                aws_started => false,
                                aws_loaded => not AwsWasLoaded,
                                credentials_started => false,
                                credentials_loaded => not CredentialsWasLoaded
                            },
                            StartError = {
                                aws_application_start_failed,
                                safe_reason(Reason)
                            },
                            failed_start(StartError, Ownership0)
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
    cleanup_runtime(Ownership).

failed_start(StartError, Ownership) ->
    case cleanup_runtime(Ownership) of
        ok ->
            {error, StartError};
        {error, CleanupReason} ->
            {error, {
                StartError,
                {cleanup_failed, CleanupReason}
            }}
    end.

cleanup_runtime(Ownership) ->
    %% Startup order is aws -> aws_credentials. Stop in reverse order, then
    %% unload only applications this runtime did not find loaded beforehand.
    Steps = [
        {
            stop_aws_credentials,
            maybe_stop(
                aws_credentials,
                maps:get(credentials_started, Ownership, false)
            )
        },
        {
            stop_aws,
            maybe_stop(
                aws,
                maps:get(aws_started, Ownership, false)
            )
        },
        {
            unload_aws_credentials,
            maybe_unload(
                aws_credentials,
                maps:get(credentials_loaded, Ownership, false)
            )
        },
        {
            unload_aws,
            maybe_unload(
                aws,
                maps:get(aws_loaded, Ownership, false)
            )
        }
    ],
    cleanup_result(Steps).

maybe_stop(_App, false) ->
    ok;
maybe_stop(App, true) ->
    stop_application(App).

maybe_unload(_App, false) ->
    ok;
maybe_unload(App, true) ->
    unload_application(App).

cleanup_result(Steps) ->
    Errors = [
        {Name, Error}
     || {Name, Error = {error, _}} <- Steps
    ],
    case Errors of
        [] ->
            ok;
        _ ->
            {error, {aws_runtime_shutdown_failed, Errors}}
    end.

ensure_loaded(App) ->
    case application:load(App) of
        ok -> ok;
        {error, {already_loaded, App}} -> ok;
        {error, Reason} -> {error, {application_load_failed, App, safe_reason(Reason)}}
    end.

application_running(App) ->
    lists:keymember(App, 1, application:which_applications()).

application_loaded(App) ->
    lists:keymember(App, 1, application:loaded_applications()).

stop_application(App) ->
    case application:stop(App) of
        ok -> ok;
        {error, {not_started, App}} -> ok;
        {error, Reason} -> {error, {application_stop_failed, App, safe_reason(Reason)}}
    end.

unload_application(App) ->
    case application:unload(App) of
        ok -> ok;
        {error, {not_loaded, App}} -> ok;
        {error, Reason} -> {error, {application_unload_failed, App, safe_reason(Reason)}}
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
