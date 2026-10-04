-module(ecai_repair_preflight).

-export([
    check/6,
    structural_snapshot_failure/1
]).

-ifdef(TEST).
-export([decision/3]).
-endif.

check(App, Module, Finding, Fingerprint, Version, Opts) when
    is_atom(App),
    is_atom(Module),
    is_map(Finding),
    is_binary(Fingerprint),
    is_binary(Version),
    is_map(Opts)
->
    case enabled(Opts) of
        false ->
            {allow, #{preflight => disabled}};
        true ->
            safe_check(
                App, Module, Finding, Fingerprint, Version, Opts
            )
    end.

safe_check(App, Module, Finding, Fingerprint, Version, Opts) ->
    try
        case ecai_learning_store:get_analysis(App, Module) of
            not_found ->
                {allow, #{preflight => analysis_not_found}};
            {ok, Analysis} when is_map(Analysis) ->
                CurrentVersion =
                    ecai_code_context:finding_version(
                        App, Module, Finding
                    ),
                Snapshot =
                    ecai_git_snapshot:check_analysis(
                        Analysis, snapshot_opts(Opts)
                    ),
                case decision(Version, CurrentVersion, Snapshot) of
                    allow ->
                        {allow, #{
                            preflight => passed,
                            finding_version => Version
                        }};
                    {superseded, Reason} ->
                        Repair = persist_superseded(
                            App,
                            Module,
                            Finding,
                            Fingerprint,
                            Version,
                            CurrentVersion,
                            Reason
                        ),
                        {superseded, Repair};
                    {blocked, Reason} ->
                        Repair = persist_blocked(
                            App,
                            Module,
                            Finding,
                            Fingerprint,
                            Version,
                            Reason
                        ),
                        {blocked, Repair}
                end;
            {ok, _Other} ->
                {allow, #{preflight => invalid_analysis}}
        end
    catch
        Class:Reason0 ->
            logger:warning(
                "ECAI repair preflight deferred app=~p module=~p "
                "fingerprint=~p class=~p reason=~p",
                [App, Module, Fingerprint, Class, Reason0]
            ),
            {allow, #{
                preflight => deferred,
                class => Class,
                reason => Reason0
            }}
    end.

decision(Version, CurrentVersion, _Snapshot) when
    is_binary(CurrentVersion),
    byte_size(CurrentVersion) > 0,
    Version =/= CurrentVersion
->
    {superseded, #{
        kind => stale_finding_version,
        finding_version => Version,
        current_finding_version => CurrentVersion
    }};
decision(_Version, _CurrentVersion, {ok, _Snapshot}) ->
    allow;
decision(_Version, _CurrentVersion, {error, Error}) ->
    case structural_snapshot_failure(Error) of
        true -> {blocked, Error};
        false -> allow
    end;
decision(_Version, _CurrentVersion, _Other) ->
    allow.

structural_snapshot_failure(Error) when is_map(Error) ->
    lists:member(
        maps:get(kind, Error, undefined),
        [
            source_not_in_base_commit,
            source_base_mismatch,
            source_outside_repository,
            source_name_missing
        ]
    );
structural_snapshot_failure(_) ->
    false.

persist_superseded(
    App,
    Module,
    Finding,
    Fingerprint,
    Version,
    CurrentVersion,
    Reason
) ->
    Existing = existing_repair(Fingerprint, Version),
    Now = now_iso8601(),
    Base = repair_base(
        Existing, App, Module, Finding, Fingerprint, Version
    ),
    Repair0 = maps:without(
        [
            worker_pid,
            worker_started_at,
            next_retry_at_ms,
            completed_at
        ],
        Base
    ),
    Repair = Repair0#{
        status => superseded,
        stage => preflight_superseded,
        retryable => false,
        failure_class => stale_finding_version,
        current_finding_version => CurrentVersion,
        error => {preflight_superseded, Reason},
        last_error => {preflight_superseded, Reason},
        updated_at => Now
    },
    ok = ecai_learning_store:put_repair(
        Fingerprint, Version, Repair
    ),
    logger:notice(
        "ECAI repair preflight superseded fingerprint=~p "
        "version=~p current_version=~p module=~p",
        [Fingerprint, Version, CurrentVersion, Module]
    ),
    Repair.

persist_blocked(
    App, Module, Finding, Fingerprint, Version, Reason
) ->
    Existing = existing_repair(Fingerprint, Version),
    Now = now_iso8601(),
    Base = repair_base(
        Existing, App, Module, Finding, Fingerprint, Version
    ),
    Repair0 = maps:without(
        [
            worker_pid,
            worker_started_at,
            next_retry_at_ms,
            completed_at
        ],
        Base
    ),
    Repair = Repair0#{
        status => blocked,
        stage => source_snapshot_blocked,
        retryable => false,
        failure_class => source_snapshot_blocked,
        blocked_base_commit =>
            map_value(base_commit, Reason),
        blocked_source_path =>
            map_value(source_path, Reason),
        blocked_source_sha256 =>
            map_value(learned_sha256, Reason),
        error => {source_snapshot_blocked, Reason},
        last_error => {source_snapshot_blocked, Reason},
        updated_at => Now
    },
    ok = ecai_learning_store:put_repair(
        Fingerprint, Version, Repair
    ),
    logger:notice(
        "ECAI repair preflight blocked fingerprint=~p "
        "version=~p module=~p kind=~p",
        [
            Fingerprint,
            Version,
            Module,
            map_value(kind, Reason)
        ]
    ),
    Repair.

repair_base(
    Existing, App, Module, Finding, Fingerprint, Version
) ->
    maps:merge(
        #{
            application => App,
            module => Module,
            finding => Finding,
            fingerprint => Fingerprint,
            finding_version => Version,
            attempt => 1,
            created_at => now_iso8601()
        },
        Existing
    ).

existing_repair(Fingerprint, Version) ->
    case
        ecai_learning_store:get_repair(
            Fingerprint, Version
        )
    of
        {ok, Repair} when is_map(Repair) -> Repair;
        _ -> #{}
    end.

snapshot_opts(Opts) ->
    maps:merge(
        Opts,
        maps:get(verifier, Opts, #{})
    ).

enabled(Opts) ->
    maps:get(
        preflight_source_snapshot,
        Opts,
        application:get_env(
            ecai,
            code_patch_preflight_source_snapshot,
            true
        )
    ) =:= true.

map_value(Key, Map) when is_map(Map) ->
    maps:get(Key, Map, undefined);
map_value(_Key, _Map) ->
    undefined.

now_iso8601() ->
    unicode:characters_to_binary(
        calendar:system_time_to_rfc3339(
            erlang:system_time(second),
            [{unit, second}, {offset, "Z"}]
        )
    ).
