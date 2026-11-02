-module(ecai_release_memory).

%% Deterministic release/change memory for ECAI code learning.
%%
%% Facts are derived from immutable Git objects.  Per-commit evidence is stored
%% in ecai_learning_store and release manuals are projections over a selected
%% baseline..HEAD range.  No LLM is required to decide whether an export/config
%% value changed; narrative release notes are derived from commit metadata and
%% the structured evidence.

-export([
    accumulate/0,
    accumulate/1,
    analyse_range/2,
    analyse_range/3,
    manual/0,
    manual/1,
    manual_between/2,
    manual_between/3,
    write_manual/0,
    write_manual/1,
    mark_deployed/2,
    mark_deployed/3,
    status/0,
    status/1,
    changes/0,
    baselines/0
]).

-define(SCHEMA, 1).
-define(DEFAULT_TIMEOUT_MS, 30000).
-define(DEFAULT_MAX_COMMITS, 5000).
-define(DEFAULT_MANUAL_COMMIT_LIMIT, 5000).

%%====================================================================
%% Public API
%%====================================================================

accumulate() ->
    accumulate(#{}).

accumulate(Opts) when is_map(Opts) ->
    case enabled() of
        false ->
            {ok, #{enabled => false}};
        true ->
            Repo = repo_root(Opts),
            case {head(Repo, Opts), branch(Repo, Opts)} of
                {{error, _} = Error, _} ->
                    Error;
                {_, {error, _} = Error} ->
                    Error;
                {{ok, Head}, {ok, Branch}} ->
                    Cursor0 = release_cursor(),
                    Previous = maps:get(head, Cursor0, undefined),
                    case accumulation_base(Repo, Previous, Head, Opts) of
                        {error, _} = Error ->
                            Error;
                        {ok, Base, HistoryRewritten} ->
                            case ensure_commit_evidence(Repo, Base, Head, Opts) of
                                {error, _} = Error ->
                                    Error;
                                {ok, Recorded} ->
                                    Cursor = #{
                                        schema_version => ?SCHEMA,
                                        head => Head,
                                        branch => Branch,
                                        previous_head => Previous,
                                        history_rewritten => HistoryRewritten,
                                        recorded_this_cycle => Recorded,
                                        recorded_commits =>
                                            maps:get(recorded_commits, Cursor0, 0) + Recorded,
                                        updated_at => now_iso8601()
                                    },
                                    case ecai_learning_store:put_checkpoint(release_memory, Cursor) of
                                        ok ->
                                            case write_manual(Opts) of
                                                {ok, Written} ->
                                                    FinalCursor = Cursor#{
                                                        recorded_commits => length(
                                                            ecai_learning_store:release_changes()
                                                        ),
                                                        manual => manual_write_summary(Written)
                                                    },
                                                    case ecai_learning_store:put_checkpoint(
                                                        release_memory,
                                                        FinalCursor
                                                    ) of
                                                        ok -> {ok, FinalCursor};
                                                        {error, _} = Error -> Error;
                                                        Other ->
                                                            {error, {
                                                                release_cursor_persist_failed,
                                                                Other
                                                            }}
                                                    end;
                                                {error, _} = Error ->
                                                    Error
                                            end;
                                        {error, _} = Error ->
                                            Error;
                                        Other ->
                                            {error, {release_cursor_persist_failed, Other}}
                                    end
                            end
                    end
            end
    end.

analyse_range(BaseRef, HeadRef) ->
    analyse_range(BaseRef, HeadRef, #{}).

analyse_range(BaseRef0, HeadRef0, Opts) when is_map(Opts) ->
    Repo = repo_root(Opts),
    case resolve_optional_ref(Repo, BaseRef0, Opts) of
        {error, _} = Error ->
            Error;
        {ok, Base} ->
            case resolve_ref(Repo, HeadRef0, Opts) of
                {error, _} = Error ->
                    Error;
                {ok, Head} ->
                    analyse_resolved_range(Repo, Base, Head, Opts)
            end
    end.

manual() ->
    manual(#{}).

manual(Opts) when is_map(Opts) ->
    Repo = repo_root(Opts),
    case head(Repo, Opts) of
        {error, _} = Error ->
            Error;
        {ok, Head} ->
            case default_base(Repo, Head, Opts) of
                {error, _} = Error ->
                    Error;
                {ok, Base, BaseLabel, Source} ->
                    build_manual(Repo, Base, Head, BaseLabel, Source, Opts)
            end
    end;
manual(Environment) ->
    Repo = repo_root(#{}),
    case ecai_learning_store:get_release_baseline(Environment) of
        not_found ->
            {error, {release_baseline_not_found, normalize_name(Environment)}};
        {ok, Baseline} ->
            Base = maps:get(commit, Baseline),
            BaseLabel = maps:get(ref, Baseline, normalize_name(Environment)),
            case head(Repo, #{}) of
                {ok, Head} ->
                    build_manual(Repo, Base, Head, BaseLabel, deployment_baseline, #{});
                {error, _} = Error ->
                    Error
            end
    end.

manual_between(BaseRef, HeadRef) ->
    manual_between(BaseRef, HeadRef, #{}).

manual_between(BaseRef0, HeadRef0, Opts) when is_map(Opts) ->
    Repo = repo_root(Opts),
    case resolve_optional_ref(Repo, BaseRef0, Opts) of
        {error, _} = Error ->
            Error;
        {ok, Base} ->
            case resolve_ref(Repo, HeadRef0, Opts) of
                {error, _} = Error ->
                    Error;
                {ok, Head} ->
                    build_manual(
                        Repo,
                        Base,
                        Head,
                        printable_ref(BaseRef0),
                        explicit,
                        Opts
                    )
            end
    end.

write_manual() ->
    write_manual(#{}).

write_manual(Opts) when is_map(Opts) ->
    case manual(Opts) of
        {error, _} = Error ->
            Error;
        {ok, Manual} ->
            write_manual_files(Manual, Opts)
    end;
write_manual(Environment) ->
    case manual(Environment) of
        {error, _} = Error ->
            Error;
        {ok, Manual} ->
            write_manual_files(Manual, #{environment => Environment})
    end.

mark_deployed(Environment, Ref) ->
    mark_deployed(Environment, Ref, #{}).

mark_deployed(Environment, Ref, Opts) when is_map(Opts) ->
    Repo = repo_root(Opts),
    case resolve_ref(Repo, Ref, Opts) of
        {error, _} = Error ->
            Error;
        {ok, Commit} ->
            Baseline = #{
                schema_version => ?SCHEMA,
                environment => normalize_name(Environment),
                ref => printable_ref(Ref),
                commit => Commit,
                marked_at => now_iso8601()
            },
            case ecai_learning_store:put_release_baseline(Environment, Baseline) of
                ok -> {ok, Baseline};
                {error, _} = Error -> Error;
                Other -> {error, {release_baseline_persist_failed, Other}}
            end
    end.

status() ->
    status(#{}).

status(Opts) when is_map(Opts) ->
    Cursor = release_cursor(),
    Baselines = baselines(),
    Repo = repo_root(Opts),
    CurrentHead = value_or_undefined(head(Repo, Opts)),
    DefaultEnvironment = default_environment(),
    #{
        enabled => enabled(),
        schema_version => ?SCHEMA,
        head => CurrentHead,
        learned_head => maps:get(head, Cursor, undefined),
        branch => maps:get(branch, Cursor, undefined),
        recorded_commits => maps:get(recorded_commits, Cursor, 0),
        last_updated_at => maps:get(updated_at, Cursor, undefined),
        history_rewritten => maps:get(history_rewritten, Cursor, false),
        default_environment => DefaultEnvironment,
        baselines => Baselines,
        manual_paths => manual_paths(Opts)
    }.

changes() ->
    ecai_learning_store:release_changes().

baselines() ->
    ecai_learning_store:release_baselines().

%%====================================================================
%% Accumulation
%%====================================================================

release_cursor() ->
    case ecai_learning_store:get_checkpoint(release_memory) of
        {ok, Cursor} when is_map(Cursor) -> Cursor;
        _ -> #{}
    end.

accumulation_base(_Repo, Head, Head, _Opts) ->
    {ok, Head, false};
accumulation_base(Repo, undefined, Head, Opts) ->
    case first_parent(Repo, Head, Opts) of
        {ok, Parent} -> {ok, Parent, false};
        root -> {ok, undefined, false};
        {error, _} = Error -> Error
    end;
accumulation_base(Repo, Previous, Head, Opts) ->
    case is_ancestor(Repo, Previous, Head, Opts) of
        {ok, true} ->
            {ok, Previous, false};
        {ok, false} ->
            case merge_base(Repo, Previous, Head, Opts) of
                {ok, Base} -> {ok, Base, true};
                {error, _} = Error -> Error
            end;
        {error, _} = Error ->
            Error
    end.

ensure_commit_evidence(_Repo, Head, Head, _Opts) ->
    {ok, 0};
ensure_commit_evidence(Repo, Base, Head, Opts) ->
    case commits_between(Repo, Base, Head, Opts) of
        {error, _} = Error ->
            Error;
        {ok, Commits} ->
            Limit = positive_int(
                maps:get(
                    max_commits,
                    Opts,
                    application:get_env(ecai, code_release_memory_max_commits, ?DEFAULT_MAX_COMMITS)
                ),
                ?DEFAULT_MAX_COMMITS
            ),
            case length(Commits) =< Limit of
                false ->
                    {error, {release_range_too_large, length(Commits), Limit}};
                true ->
                    ensure_commit_evidence_list(Repo, Commits, Opts, 0)
            end
    end.

ensure_commit_evidence_list(_Repo, [], _Opts, Count) ->
    {ok, Count};
ensure_commit_evidence_list(Repo, [Commit | Rest], Opts, Count0) ->
    case ecai_learning_store:get_release_change(Commit) of
        {ok, _Existing} ->
            ensure_commit_evidence_list(Repo, Rest, Opts, Count0);
        not_found ->
            case analyse_commit(Repo, Commit, Opts) of
                {error, _} = Error ->
                    Error;
                {ok, Evidence} ->
                    case ecai_learning_store:put_release_change(Commit, Evidence) of
                        ok -> ensure_commit_evidence_list(Repo, Rest, Opts, Count0 + 1);
                        {error, _} = Error -> Error;
                        Other -> {error, {release_change_persist_failed, Commit, Other}}
                    end
            end
    end.

analyse_commit(Repo, Commit, Opts) ->
    case first_parent(Repo, Commit, Opts) of
        {error, _} = Error ->
            Error;
        root ->
            analyse_commit_with_parent(Repo, Commit, undefined, Opts);
        {ok, Parent} ->
            analyse_commit_with_parent(Repo, Commit, Parent, Opts)
    end.

analyse_commit_with_parent(Repo, Commit, Parent, Opts) ->
    case analyse_resolved_range(Repo, Parent, Commit, Opts) of
        {error, _} = Error ->
            Error;
        {ok, Range} ->
            case commit_metadata(Repo, Commit, Opts) of
                {error, _} = Error ->
                    Error;
                {ok, Meta} ->
                    Core = maps:without(
                        [commits, evidence_sha256, schema, schema_version],
                        Range
                    ),
                    Evidence0 = Core#{
                        schema => <<"ecai.release-change">>,
                        schema_version => ?SCHEMA,
                        commit => Commit,
                        parent => Parent,
                        authored_at => maps:get(authored_at, Meta, undefined),
                        subject => maps:get(subject, Meta, <<>>),
                        release_notes => notes_for_commit(Meta, Range)
                    },
                    Hash = evidence_hash(Evidence0),
                    {ok, Evidence0#{evidence_sha256 => Hash}}
            end
    end.

%%====================================================================
%% Range analysis
%%====================================================================

analyse_resolved_range(Repo, Base, Head, Opts) ->
    case changed_files(Repo, Base, Head, Opts) of
        {error, _} = Error ->
            Error;
        {ok, Changes} ->
            case commit_log(Repo, Base, Head, Opts) of
                {error, _} = Error ->
                    Error;
                {ok, Commits} ->
                    Semantic = semantic_changes(Repo, Base, Head, Changes, Opts),
                    case Semantic of
                        {error, _} = Error ->
                            Error;
                        {ok, SemanticMap} ->
                            Core0 = #{
                                schema => <<"ecai.release-range">>,
                                schema_version => ?SCHEMA,
                                base => Base,
                                head => Head,
                                changed_files => Changes,
                                commits => Commits,
                                config_changes => maps:get(config_changes, SemanticMap),
                                api_changes => maps:get(api_changes, SemanticMap),
                                breaking_changes => maps:get(breaking_changes, SemanticMap),
                                operator_actions => maps:get(operator_actions, SemanticMap),
                                component_changes => maps:get(component_changes, SemanticMap)
                            },
                            {ok, Core0#{evidence_sha256 => evidence_hash(Core0)}}
                    end
            end
    end.

semantic_changes(Repo, Base, Head, Changes, Opts) ->
    semantic_changes(Repo, Base, Head, Changes, Opts, empty_semantic()).

semantic_changes(_Repo, _Base, _Head, [], _Opts, Acc) ->
    {ok, normalize_semantic(Acc)};
semantic_changes(Repo, Base, Head, [Change | Rest], Opts, Acc0) ->
    case semantic_change(Repo, Base, Head, Change, Opts) of
        {error, _} = Error ->
            Error;
        {ok, Delta} ->
            Acc1 = merge_semantic(Acc0, Delta),
            semantic_changes(Repo, Base, Head, Rest, Opts, Acc1)
    end.

empty_semantic() ->
    #{
        config_changes => [],
        api_changes => [],
        breaking_changes => [],
        operator_actions => [],
        component_changes => []
    }.

semantic_change(Repo, Base, Head, Change, Opts) ->
    Path = maps:get(path, Change),
    Status = maps:get(status, Change, <<"?">>),
    Category = path_category(Path),
    Component = #{
        path => Path,
        status => Status,
        category => Category,
        from => maps:get(from, Change, undefined)
    },
    case file_versions(Repo, Base, Head, Change, Opts) of
        {error, _} = Error ->
            Error;
        {ok, Old, New} ->
            Config =
                case is_semantic_config(Path) of
                    true -> config_diff(Path, Old, New);
                    false -> []
                end,
            Api =
                case is_erlang_source(Path) of
                    true -> api_diff(Path, Old, New);
                    false -> []
                end,
            Breaking =
                breaking_for_change(Change, Category, Config, Api),
            Actions = operator_actions_for_change(Change, Category, Config, Api),
            {ok, #{
                config_changes => Config,
                api_changes => Api,
                breaking_changes => Breaking,
                operator_actions => Actions,
                component_changes => [Component]
            }}
    end.

file_versions(Repo, Base, Head, Change, Opts) ->
    Status = maps:get(status, Change, <<"?">>),
    NewPath = maps:get(path, Change),
    OldPath = maps:get(from, Change, NewPath),
    Old =
        case status_prefix(Status) of
            add -> not_found;
            _ -> git_blob_optional(Repo, Base, OldPath, Opts)
        end,
    New =
        case status_prefix(Status) of
            delete -> not_found;
            _ -> git_blob_optional(Repo, Head, NewPath, Opts)
        end,
    case {Old, New} of
        {{error, _} = Error, _} -> Error;
        {_, {error, _} = Error} -> Error;
        _ -> {ok, Old, New}
    end.

config_diff(Path, Old, New) ->
    OldMap = config_values(Path, Old),
    NewMap = config_values(Path, New),
    Keys = lists:usort(maps:keys(OldMap) ++ maps:keys(NewMap)),
    lists:foldl(
        fun(Key, Acc) ->
            OldValue = maps:get(Key, OldMap, '$missing'),
            NewValue = maps:get(Key, NewMap, '$missing'),
            case OldValue =:= NewValue of
                true -> Acc;
                false ->
                    Sensitive = sensitive_key(Key) orelse
                        sensitive_term(OldValue) orelse sensitive_term(NewValue),
                    Operation = config_operation(OldValue, NewValue),
                    [#{
                        path => Path,
                        key => Key,
                        operation => Operation,
                        old => safe_config_value(OldValue, Sensitive),
                        new => safe_config_value(NewValue, Sensitive),
                        sensitive => Sensitive,
                        reload_required => not is_app_src(Path),
                        release_rebuild_required => is_app_src(Path)
                    } | Acc]
            end
        end,
        [],
        Keys
    ).

config_values(_Path, not_found) -> #{};
config_values(Path, Bin) when is_binary(Bin) ->
    case parse_term(Bin) of
        {ok, {application, App, Props}} when is_atom(App), is_list(Props) ->
            case proplists:get_value(env, Props, undefined) of
                Env when is_list(Env) -> flatten_application_env(App, Env);
                _ -> #{}
            end;
        {ok, Term} ->
            flatten_config_term(Path, Term);
        {error, _} ->
            #{}
    end.

flatten_application_env(App, Env) ->
    lists:foldl(
        fun
            ({Key, Value}, Acc) -> maps:put(key_path([App, Key]), Value, Acc);
            (_, Acc) -> Acc
        end,
        #{},
        Env
    ).

flatten_config_term(_Path, Term) when is_list(Term) ->
    lists:foldl(
        fun
            ({Section, Values}, Acc) when is_list(Values) ->
                case looks_like_proplist(Values) of
                    true ->
                        lists:foldl(
                            fun
                                ({Key, Value}, A) ->
                                    maps:put(key_path([Section, Key]), Value, A);
                                (_, A) -> A
                            end,
                            Acc,
                            Values
                        );
                    false ->
                        maps:put(key_path([Section]), Values, Acc)
                end;
            ({Key, Value}, Acc) ->
                maps:put(key_path([Key]), Value, Acc);
            (_, Acc) ->
                Acc
        end,
        #{},
        Term
    );
flatten_config_term(_Path, _Term) ->
    #{}.

looks_like_proplist([]) -> false;
looks_like_proplist(List) ->
    lists:all(
        fun
            ({Key, _}) when is_atom(Key); is_binary(Key); is_list(Key) -> true;
            (_) -> false
        end,
        List
    ).

parse_term(Bin) ->
    try unicode:characters_to_list(Bin) of
        Chars ->
            case erl_scan:string(Chars) of
                {ok, Tokens, _} ->
                    case erl_parse:parse_term(Tokens) of
                        {ok, Term} -> {ok, Term};
                        {error, Reason} -> {error, {parse_term, Reason}}
                    end;
                {error, Reason, _} ->
                    {error, {scan_term, Reason}}
            end
    catch
        _:_ -> {error, invalid_unicode}
    end.

api_diff(Path, Old, New) ->
    OldExports = exported_functions(Old),
    NewExports = exported_functions(New),
    Removed = lists:subtract(OldExports, NewExports),
    Added = lists:subtract(NewExports, OldExports),
    [
        #{path => Path, operation => removed, function => Name, arity => Arity}
     || {Name, Arity} <- Removed
    ] ++
        [
            #{path => Path, operation => added, function => Name, arity => Arity}
         || {Name, Arity} <- Added
        ].

exported_functions(not_found) -> [];
exported_functions(Bin) when is_binary(Bin) ->
    Clean = strip_erlang_comments(Bin),
    case re:run(
        Clean,
        <<"(?s)-export\\s*\\(\\s*\\[(.*?)\\]\\s*\\)\\s*\\.">>,
        [global, {capture, [1], binary}]
    ) of
        nomatch -> [];
        {match, Matches} ->
            lists:usort(lists:append([export_entries(export_capture(M)) || M <- Matches]))
    end.

strip_erlang_comments(Bin) ->
    unicode:characters_to_binary(
        lists:reverse(strip_erlang_comments(binary_to_list(Bin), normal, []))
    ).

strip_erlang_comments([], _State, Acc) ->
    Acc;
strip_erlang_comments([$\n | Rest], comment, Acc) ->
    strip_erlang_comments(Rest, normal, [$\n | Acc]);
strip_erlang_comments([_ | Rest], comment, Acc) ->
    strip_erlang_comments(Rest, comment, Acc);
strip_erlang_comments([$\\, Next | Rest], double_quote, Acc) ->
    strip_erlang_comments(Rest, double_quote, [Next, $\\ | Acc]);
strip_erlang_comments([$" | Rest], double_quote, Acc) ->
    strip_erlang_comments(Rest, normal, [$" | Acc]);
strip_erlang_comments([C | Rest], double_quote, Acc) ->
    strip_erlang_comments(Rest, double_quote, [C | Acc]);
strip_erlang_comments([$\\, Next | Rest], single_quote, Acc) ->
    strip_erlang_comments(Rest, single_quote, [Next, $\\ | Acc]);
strip_erlang_comments([$' | Rest], single_quote, Acc) ->
    strip_erlang_comments(Rest, normal, [$' | Acc]);
strip_erlang_comments([C | Rest], single_quote, Acc) ->
    strip_erlang_comments(Rest, single_quote, [C | Acc]);
strip_erlang_comments([$$, Next | Rest], normal, Acc) ->
    strip_erlang_comments(Rest, normal, [Next, $$ | Acc]);
strip_erlang_comments([$% | Rest], normal, Acc) ->
    strip_erlang_comments(Rest, comment, Acc);
strip_erlang_comments([$" | Rest], normal, Acc) ->
    strip_erlang_comments(Rest, double_quote, [$" | Acc]);
strip_erlang_comments([$' | Rest], normal, Acc) ->
    strip_erlang_comments(Rest, single_quote, [$' | Acc]);
strip_erlang_comments([C | Rest], normal, Acc) ->
    strip_erlang_comments(Rest, normal, [C | Acc]).

export_capture([Bin]) -> Bin;
export_capture(Bin) when is_binary(Bin) -> Bin;
export_capture(_) -> <<>>.

export_entries(Bin) ->
    case re:run(
        Bin,
        <<"('(?:[^']|'')+'|[a-z][A-Za-z0-9_@]*)\\s*/\\s*([0-9]+)">>,
        [global, {capture, [1, 2], binary}]
    ) of
        nomatch -> [];
        {match, Matches} ->
            [
                {Name, binary_to_integer(Arity)}
             || [Name, Arity] <- Matches
            ]
    end.

breaking_for_change(Change, Category, Config, Api) ->
    Path = maps:get(path, Change),
    Status = maps:get(status, Change, <<"?">>),
    ApiBreaking = [
        #{
            severity => breaking,
            kind => exported_api_removed,
            path => Path,
            function => maps:get(function, Item),
            arity => maps:get(arity, Item),
            message => iolist_to_binary([
                <<"Export removed: ">>,
                maps:get(function, Item),
                <<"/">>,
                integer_to_binary(maps:get(arity, Item))
            ])
        }
     || Item <- Api,
        maps:get(operation, Item) =:= removed
    ],
    ConfigBreaking = [
        #{
            severity => potential_breaking,
            kind => config_key_removed,
            path => Path,
            key => maps:get(key, Item),
            message => <<"Configuration key removed; verify deployed sys.config and runtime defaults.">>
        }
     || Item <- Config,
        maps:get(operation, Item) =:= removed
    ],
    DeletedModule =
        case {status_prefix(Status), Category} of
            {delete, source} ->
                [#{
                    severity => potential_breaking,
                    kind => source_module_removed,
                    path => Path,
                    message => <<"Source module removed; verify callers and upgrade compatibility.">>
                }];
            _ -> []
        end,
    ApiBreaking ++ ConfigBreaking ++ DeletedModule.

operator_actions_for_change(Change, Category, Config, Api) ->
    Path = maps:get(path, Change),
    Actions0 =
        case {Config, Category, is_app_src(Path)} of
            {[], config, false} -> [action(
                review_configuration_file,
                pre_deploy,
                true,
                <<"Review and reconcile the changed configuration file; no semantic Erlang key diff was available.">>,
                Path
            )];
            {[], _, _} ->
                [];
            {_, _, true} -> [action(
                review_configuration_defaults,
                build,
                false,
                <<"Review changed application environment defaults in the release artifact.">>,
                Path
            )];
            {_, _, false} -> [action(
                apply_configuration,
                pre_deploy,
                true,
                <<"Review and apply configuration changes before activating the new release.">>,
                Path
            )]
        end,
    Actions1 =
        case [I || I <- Api, maps:get(operation, I) =:= removed] of
            [] -> Actions0;
            _ -> [action(
                migrate_callers,
                pre_deploy,
                true,
                <<"Update callers of removed exported Erlang APIs before deployment.">>,
                Path
            ) | Actions0]
        end,
    Actions2 =
        case Category of
            dependency -> [action(
                rebuild_dependencies,
                build,
                true,
                <<"Re-resolve/rebuild release dependencies and verify the resulting lock/build state.">>,
                Path
            ) | Actions1];
            native -> [action(
                rebuild_native,
                build,
                true,
                <<"Rebuild native/NIF components for the target release platform.">>,
                Path
            ) | Actions1];
            migration -> [action(
                verify_migration,
                pre_deploy,
                true,
                <<"Review persisted-data/schema compatibility and run the required migration procedure.">>,
                Path
            ) | Actions1];
            contract -> [action(
                review_contract_compatibility,
                pre_deploy,
                true,
                <<"Review smart-contract compatibility and deployment/migration requirements.">>,
                Path
            ) | Actions1];
            packaging -> [action(
                rebuild_package,
                build,
                false,
                <<"Rebuild and verify release packaging for the changed deployment definition.">>,
                Path
            ) | Actions1];
            _ -> Actions1
        end,
    case status_prefix(maps:get(status, Change, <<"?">>)) of
        delete when Category =:= config ->
            [action(
                remove_obsolete_configuration,
                pre_deploy,
                false,
                <<"Remove or reconcile obsolete configuration for the deleted config file.">>,
                Path
            ) | Actions2];
        _ -> Actions2
    end.

action(Id, Phase, Required, Description, Path) ->
    #{
        id => Id,
        phase => Phase,
        required => Required,
        description => Description,
        evidence_path => Path
    }.

merge_semantic(Acc, Delta) ->
    maps:map(
        fun(Key, Values) -> Values ++ maps:get(Key, Delta, []) end,
        Acc
    ).

normalize_semantic(Acc) ->
    Acc#{
        config_changes => sort_maps(maps:get(config_changes, Acc)),
        api_changes => sort_maps(maps:get(api_changes, Acc)),
        breaking_changes => unique_maps(maps:get(breaking_changes, Acc)),
        operator_actions => unique_actions(maps:get(operator_actions, Acc)),
        component_changes => sort_maps(maps:get(component_changes, Acc))
    }.

sort_maps(List) ->
    lists:sort(fun(A, B) -> term_to_binary(A, [deterministic]) =< term_to_binary(B, [deterministic]) end, List).

unique_maps(List) ->
    sort_maps(
        maps:values(
            maps:from_list([{term_to_binary(Item, [deterministic]), Item} || Item <- List])
        )
    ).

unique_actions(List) ->
    Map = lists:foldl(
        fun(Item, Acc) ->
            Id = {maps:get(id, Item), maps:get(evidence_path, Item, <<>>)},
            maps:put(Id, Item, Acc)
        end,
        #{},
        List
    ),
    sort_maps(maps:values(Map)).

%%====================================================================
%% Manual projection
%%====================================================================

default_base(Repo, Head, Opts) ->
    case maps:get(base, Opts, undefined) of
        undefined ->
            Env = maps:get(environment, Opts, default_environment()),
            case ecai_learning_store:get_release_baseline(Env) of
                {ok, Baseline} ->
                    {ok,
                        maps:get(commit, Baseline),
                        maps:get(ref, Baseline, normalize_name(Env)),
                        deployment_baseline};
                not_found ->
                    case latest_stable_tag(Repo, Head, Opts) of
                        {ok, Tag, Commit} -> {ok, Commit, Tag, latest_stable_tag};
                        not_found ->
                            case first_parent(Repo, Head, Opts) of
                                {ok, Parent} -> {ok, Parent, Parent, previous_commit};
                                root -> {ok, undefined, <<"<initial repository state>">>, initial};
                                {error, _} = Error -> Error
                            end;
                        {error, _} = Error -> Error
                    end
            end;
        Explicit ->
            case resolve_optional_ref(Repo, Explicit, Opts) of
                {ok, Commit} -> {ok, Commit, printable_ref(Explicit), explicit};
                {error, _} = Error -> Error
            end
    end.

build_manual(Repo, Base, Head, BaseLabel, Source, Opts) ->
    case ensure_commit_evidence(Repo, Base, Head, Opts) of
        {error, _} = Error ->
            Error;
        {ok, _} ->
            case analyse_resolved_range(Repo, Base, Head, Opts) of
                {error, _} = Error ->
                    Error;
                {ok, Range} ->
                    CommitEvidence = stored_commit_evidence(maps:get(commits, Range, [])),
                    ReleaseNotes = lists:append([
                        maps:get(release_notes, Change, []) || Change <- CommitEvidence
                    ]),
                    Core0 = Range#{
                        schema => <<"ecai.release-manual">>,
                        schema_version => ?SCHEMA,
                        repo_root => to_binary(Repo),
                        branch => value_or_undefined(branch(Repo, Opts)),
                        base_ref => BaseLabel,
                        base_source => Source,
                        release_notes => ReleaseNotes,
                        commit_evidence => [
                            maps:with(
                                [commit, parent, authored_at, subject, evidence_sha256],
                                Change
                            )
                         || Change <- CommitEvidence
                        ],
                        verification => verification_steps(),
                        rollback => rollback_guidance(Range)
                    },
                    Hash = evidence_hash(maps:without([evidence_sha256], Core0)),
                    Generated = Core0#{
                        evidence_sha256 => Hash,
                        generated_at => now_iso8601()
                    },
                    {ok, Generated#{markdown => render_markdown(Generated)}}
            end
    end.

stored_commit_evidence(Commits) ->
    lists:foldl(
        fun(CommitMeta, Acc) ->
            Commit = maps:get(hash, CommitMeta),
            case ecai_learning_store:get_release_change(Commit) of
                {ok, Evidence} -> Acc ++ [Evidence];
                not_found -> Acc
            end
        end,
        [],
        Commits
    ).

notes_for_commit(Meta, Range) ->
    Subject = maps:get(subject, Meta, <<>>),
    Type = subject_type(Subject),
    Base = [#{type => Type, summary => Subject}],
    ConfigNotes = [
        #{
            type => configuration,
            summary => iolist_to_binary([
                config_operation_name(maps:get(operation, C)),
                <<" config ">>,
                maps:get(key, C)
            ]),
            path => maps:get(path, C)
        }
     || C <- maps:get(config_changes, Range, [])
    ],
    ApiNotes = [
        #{
            type => api,
            summary => iolist_to_binary([
                operation_name(maps:get(operation, A)),
                <<" export ">>,
                maps:get(function, A),
                <<"/">>,
                integer_to_binary(maps:get(arity, A))
            ]),
            path => maps:get(path, A)
        }
     || A <- maps:get(api_changes, Range, [])
    ],
    Base ++ ConfigNotes ++ ApiNotes.

subject_type(Subject) ->
    Lower = lower(Subject),
    subject_type_lower(Lower).

subject_type_lower(<<"feat", _/binary>>) -> feature;
subject_type_lower(<<"fix", _/binary>>) -> fix;
subject_type_lower(<<"security", _/binary>>) -> security;
subject_type_lower(<<"perf", _/binary>>) -> performance;
subject_type_lower(<<"docs", _/binary>>) -> documentation;
subject_type_lower(<<"refactor", _/binary>>) -> refactor;
subject_type_lower(_) -> change.

verification_steps() ->
    [
        <<"ecai_codebase_learning:status().">>,
        <<"ecai_codebase_learning:release_manual().">>,
        <<"ecai_patch_manager:status().">>,
        <<"ecai_codebase_learning:health_check().">>
    ].

rollback_guidance(Range) ->
    Breaking = maps:get(breaking_changes, Range, []),
    Migration = [
        C || C <- maps:get(component_changes, Range, []),
        lists:member(maps:get(category, C), [migration, contract])
    ],
    case {Breaking, Migration} of
        {[], []} ->
            <<"Rollback to the comparison baseline after restoring its configuration and verifying service health.">>;
        _ ->
            <<"Breaking or persistence/contract changes are present. Verify backward data/config compatibility before rollback; restore the comparison baseline and its matching configuration as one unit.">>
    end.

write_manual_files(Manual, Opts) ->
    case ecai_code_paths:state_root(Opts) of
        {error, _} = Error ->
            Error;
        {ok, Root} ->
            Suffix = manual_suffix(Opts),
            MdName = "release_manual" ++ Suffix ++ ".md",
            JsonName = "release_manual" ++ Suffix ++ ".json",
            MdPath = ecai_code_paths:log_file(Root, MdName),
            JsonPath = ecai_code_paths:log_file(Root, JsonName),
            Json = jsx:encode(json_safe(maps:remove(markdown, Manual))),
            case atomic_write(MdPath, maps:get(markdown, Manual)) of
                ok ->
                    case atomic_write(JsonPath, Json) of
                        ok ->
                            {ok, #{
                                markdown_path => to_binary(MdPath),
                                json_path => to_binary(JsonPath),
                                evidence_sha256 => maps:get(evidence_sha256, Manual),
                                base => maps:get(base, Manual),
                                head => maps:get(head, Manual)
                            }};
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end
    end.

manual_write_summary(Written) ->
    maps:with([markdown_path, json_path, evidence_sha256, base, head], Written).

manual_paths(Opts) ->
    case ecai_code_paths:state_root(Opts) of
        {ok, Root} ->
            Suffix = manual_suffix(Opts),
            #{
                markdown => to_binary(ecai_code_paths:log_file(Root, "release_manual" ++ Suffix ++ ".md")),
                json => to_binary(ecai_code_paths:log_file(Root, "release_manual" ++ Suffix ++ ".json"))
            };
        {error, Reason} ->
            #{error => Reason}
    end.

manual_suffix(Opts) ->
    case maps:get(environment, Opts, undefined) of
        undefined -> "";
        Env -> "-" ++ safe_filename(normalize_name(Env))
    end.

atomic_write(Path, Data) ->
    Tmp = Path ++ ".tmp",
    case file:write_file(Tmp, Data) of
        ok ->
            case file:rename(Tmp, Path) of
                ok -> ok;
                {error, Reason} -> {error, {release_manual_rename_failed, Path, Reason}}
            end;
        {error, Reason} ->
            {error, {release_manual_write_failed, Path, Reason}}
    end.

render_markdown(Manual) ->
    Base = printable(maps:get(base_ref, Manual, maps:get(base, Manual, undefined))),
    Head = printable(maps:get(head, Manual)),
    Commits = maps:get(commits, Manual, []),
    Breaking = maps:get(breaking_changes, Manual, []),
    Config = maps:get(config_changes, Manual, []),
    Actions = maps:get(operator_actions, Manual, []),
    Components = maps:get(component_changes, Manual, []),
    Notes = maps:get(release_notes, Manual, []),
    iolist_to_binary([
        <<"# ECAI Release Manual\n\n">>,
        <<"Generated: ">>, printable(maps:get(generated_at, Manual)), <<"\n\n">>,
        <<"From: `">>, Base, <<"`\n\n">>,
        <<"To: `">>, Head, <<"`\n\n">>,
        <<"Evidence SHA-256: `">>, maps:get(evidence_sha256, Manual), <<"`\n\n">>,
        <<"## Release Summary\n\n">>, release_note_lines(Notes), <<"\n">>,
        <<"## Breaking Changes\n\n">>, breaking_lines(Breaking), <<"\n">>,
        <<"## Configuration Changes\n\n">>, config_lines(Config), <<"\n">>,
        <<"## Operator Actions\n\n">>, action_lines(Actions), <<"\n">>,
        <<"## Changed Components\n\n">>, component_lines(Components), <<"\n">>,
        <<"## Commit History\n\n">>, commit_lines(Commits), <<"\n">>,
        <<"## Verification\n\n">>, verification_lines(maps:get(verification, Manual, [])), <<"\n">>,
        <<"## Rollback\n\n">>, maps:get(rollback, Manual), <<"\n\n">>,
        <<"## Evidence\n\n">>,
        <<"- Commits: ">>, integer_to_binary(length(Commits)), <<"\n">>,
        <<"- Changed files: ">>, integer_to_binary(length(maps:get(changed_files, Manual, []))), <<"\n">>,
        <<"- Breaking changes: ">>, integer_to_binary(length(Breaking)), <<"\n">>,
        <<"- Configuration changes: ">>, integer_to_binary(length(Config)), <<"\n">>
    ]).

release_note_lines([]) -> <<"- No commit-level release notes in this range.\n">>;
release_note_lines(Notes) ->
    [
        [<<"- **">>, atom_to_binary(maps:get(type, N, change), utf8), <<"** — ">>,
            markdown_text(maps:get(summary, N, <<"change">>)), <<"\n">>]
     || N <- dedupe_notes(Notes)
    ].

breaking_lines([]) -> <<"- No deterministic breaking changes detected.\n">>;
breaking_lines(Items) ->
    [
        [<<"- **">>, atom_to_binary(maps:get(severity, I, potential_breaking), utf8),
            <<"** `">>, markdown_text(maps:get(path, I, <<"">>)), <<"` — ">>,
            markdown_text(maps:get(message, I, maps:get(kind, I, <<"change">>))), <<"\n">>]
     || I <- Items
    ].

config_lines([]) -> <<"- No semantic Erlang configuration changes detected.\n">>;
config_lines(Items) ->
    [
        [<<"- `">>, maps:get(key, I), <<"` — ">>,
            atom_to_binary(maps:get(operation, I), utf8),
            <<" (`">>, markdown_text(maps:get(path, I)), <<"`) — `">>,
            markdown_text(maps:get(old, I)), <<"` → `">>, markdown_text(maps:get(new, I)), <<"`\n">>]
     || I <- Items
    ].

action_lines([]) -> <<"- No mandatory operator actions detected.\n">>;
action_lines(Items) ->
    [
        [<<"- [">>, case maps:get(required, I, false) of true -> <<"REQUIRED">>; false -> <<"review">> end,
            <<"] **">>, atom_to_binary(maps:get(phase, I), utf8), <<"** — ">>,
            markdown_text(maps:get(description, I)), <<" (`">>,
            markdown_text(maps:get(evidence_path, I, <<"">>)), <<"`)\n">>]
     || I <- Items
    ].

component_lines([]) -> <<"- No files changed.\n">>;
component_lines(Items) ->
    [
        [<<"- `">>, markdown_text(maps:get(path, I)), <<"` — ">>,
            markdown_text(maps:get(status, I)), <<" / ">>,
            atom_to_binary(maps:get(category, I), utf8), <<"\n">>]
     || I <- Items
    ].

commit_lines([]) -> <<"- No commits after comparison base.\n">>;
commit_lines(Commits) ->
    [
        [<<"- `">>, short_hash(maps:get(hash, C)), <<"` ">>,
            markdown_text(maps:get(subject, C, <<"">>)), <<"\n">>]
     || C <- Commits
    ].

verification_lines(Steps) ->
    [[<<"- `">>, Step, <<"`\n">>] || Step <- Steps].

dedupe_notes(Notes) ->
    sort_maps(
        maps:values(maps:from_list([
            {{maps:get(type, N, change), maps:get(summary, N, <<>>), maps:get(path, N, undefined)}, N}
         || N <- Notes
        ]))
    ).

%%====================================================================
%% Git helpers
%%====================================================================

head(Repo, Opts) ->
    git_one(Repo, ["rev-parse", "--verify", "HEAD^{commit}"], Opts).

branch(Repo, Opts) ->
    git_one(Repo, ["rev-parse", "--abbrev-ref", "HEAD"], Opts).

resolve_optional_ref(_Repo, undefined, _Opts) -> {ok, undefined};
resolve_optional_ref(_Repo, <<>>, _Opts) -> {ok, undefined};
resolve_optional_ref(Repo, Ref, Opts) -> resolve_ref(Repo, Ref, Opts).

resolve_ref(Repo, Ref0, Opts) ->
    Ref = printable_ref(Ref0),
    case valid_ref(Ref) of
        false -> {error, {invalid_git_ref, Ref}};
        true -> git_one(Repo, ["rev-parse", "--verify", binary_to_list(Ref) ++ "^{commit}"], Opts)
    end.

valid_ref(Ref) when is_binary(Ref), byte_size(Ref) > 0 ->
    case Ref of
        <<"-", _/binary>> -> false;
        _ ->
            re:run(Ref, <<"^[A-Za-z0-9._/@+-]+$">>, [{capture, none}]) =:= match
    end;
valid_ref(_) -> false.

first_parent(Repo, Commit, Opts) ->
    case git_one(Repo, ["rev-list", "--parents", "-n", "1", Commit], Opts) of
        {error, _} = Error ->
            Error;
        {ok, Line} ->
            case [Part || Part <- binary:split(Line, <<" ">>, [global]), Part =/= <<>>] of
                [_Commit] -> root;
                [_Commit, Parent | _] -> {ok, Parent};
                _ -> {error, {invalid_parent_record, Commit, Line}}
            end
    end.

is_ancestor(Repo, Base, Head, Opts) ->
    Args = ["merge-base", "--is-ancestor", Base, Head],
    case git_raw(Repo, Args, Opts) of
        {ok, _} -> {ok, true};
        {error, {git_exit, 1, _}} -> {ok, false};
        {error, Reason} -> git_error(Args, Reason)
    end.

merge_base(Repo, A, B, Opts) ->
    git_one(Repo, ["merge-base", A, B], Opts).

commits_between(Repo, Base, Head, Opts) ->
    Args =
        case Base of
            undefined -> ["rev-list", "--reverse", "--first-parent", Head];
            _ -> ["rev-list", "--reverse", "--first-parent", <<Base/binary, "..", Head/binary>>]
        end,
    git_lines(Repo, Args, Opts).

changed_files(Repo, undefined, Head, Opts) ->
    case git_lines(
        Repo,
        ["diff-tree", "--root", "--no-commit-id", "--name-status", "-r", "--find-renames", Head, "--"],
        Opts
    ) of
        {ok, Lines} -> {ok, [parse_change(Line) || Line <- Lines]};
        {error, _} = Error -> Error
    end;
changed_files(Repo, Base, Head, Opts) ->
    case git_lines(
        Repo,
        ["diff", "--name-status", "--find-renames", Base, Head, "--"],
        Opts
    ) of
        {ok, Lines} -> {ok, [parse_change(Line) || Line <- Lines]};
        {error, _} = Error -> Error
    end.

parse_change(Line) ->
    case binary:split(Line, <<"\t">>, [global]) of
        [Status, Path] -> #{status => Status, path => Path};
        [Status, From, Path] -> #{status => Status, from => From, path => Path};
        _ -> #{status => <<"?">>, path => Line}
    end.

commit_log(Repo, Base, Head, Opts) ->
    Limit = positive_int(
        maps:get(commit_limit, Opts, ?DEFAULT_MANUAL_COMMIT_LIMIT),
        ?DEFAULT_MANUAL_COMMIT_LIMIT
    ),
    Range =
        case Base of
            undefined -> Head;
            _ -> <<Base/binary, "..", Head/binary>>
        end,
    Args = [
        "log",
        "--first-parent",
        "--reverse",
        "--max-count=" ++ integer_to_list(Limit),
        "--format=%H%x09%aI%x09%s",
        Range
    ],
    case git_lines(Repo, Args, Opts) of
        {ok, Lines} -> {ok, [parse_commit(Line) || Line <- Lines]};
        {error, _} = Error -> Error
    end.

parse_commit(Line) ->
    case binary:split(Line, <<"\t">>, [global]) of
        [Hash, AuthoredAt, Subject] ->
            #{hash => Hash, authored_at => AuthoredAt, subject => Subject};
        [Hash, Subject] ->
            #{hash => Hash, subject => Subject};
        _ ->
            #{hash => <<>>, subject => Line}
    end.

commit_metadata(Repo, Commit, Opts) ->
    case git_one(
        Repo,
        ["show", "-s", "--format=%H%x09%aI%x09%s", Commit],
        Opts
    ) of
        {ok, Line} -> {ok, parse_commit(Line)};
        {error, _} = Error -> Error
    end.

git_blob_optional(_Repo, undefined, _Path, _Opts) ->
    not_found;
git_blob_optional(Repo, Commit, Path, Opts) ->
    Spec = <<Commit/binary, ":", Path/binary>>,
    Args = ["cat-file", "blob", Spec],
    case git_raw(Repo, Args, Opts) of
        {ok, Bin} -> Bin;
        {error, {git_exit, 128, _}} -> not_found;
        {error, Reason} -> git_error(Args, Reason)
    end.

latest_stable_tag(Repo, Head, Opts) ->
    case git_lines(Repo, ["tag", "--merged", Head, "--list"], Opts) of
        {error, _} = Error ->
            Error;
        {ok, Tags} ->
            Stable = lists:sort(
                fun stable_gt/2,
                [Parsed || Tag <- Tags, Parsed <- parse_stable_tag(Tag)]
            ),
            latest_stable_tag_before_head(Repo, Head, Stable, Opts)
    end.

latest_stable_tag_before_head(_Repo, _Head, [], _Opts) ->
    not_found;
latest_stable_tag_before_head(Repo, Head, [#{tag := Tag} | Rest], Opts) ->
    case resolve_ref(Repo, Tag, Opts) of
        {ok, Head} -> latest_stable_tag_before_head(Repo, Head, Rest, Opts);
        {ok, Commit} -> {ok, Tag, Commit};
        {error, _} = Error -> Error
    end.

parse_stable_tag(Tag) ->
    Pattern = <<"^(v?)([0-9]+)\\.([0-9]+)\\.([0-9]+)$">>,
    case re:run(Tag, Pattern, [{capture, [2, 3, 4], binary}]) of
        {match, [A, B, C]} -> [#{tag => Tag, version => {binary_to_integer(A), binary_to_integer(B), binary_to_integer(C)}}];
        nomatch -> []
    end.

stable_gt(A, B) -> maps:get(version, A) > maps:get(version, B).

git_lines(Repo, Args, Opts) ->
    case git(Repo, Args, Opts) of
        {ok, Bin} -> {ok, lines(Bin)};
        {error, _} = Error -> Error
    end.

git_one(Repo, Args, Opts) ->
    case git_lines(Repo, Args, Opts) of
        {ok, [One | _]} -> {ok, One};
        {ok, []} -> {error, empty_git_output};
        {error, _} = Error -> Error
    end.

git(Repo, Args, Opts) ->
    case git_raw(Repo, Args, Opts) of
        {ok, _} = Ok -> Ok;
        {error, Reason} -> git_error(Args, Reason)
    end.

git_raw(Repo, Args, Opts) ->
    Timeout = positive_int(
        maps:get(
            command_timeout_ms,
            Opts,
            application:get_env(ecai, code_patch_command_timeout_ms, ?DEFAULT_TIMEOUT_MS)
        ),
        ?DEFAULT_TIMEOUT_MS
    ),
    ecai_repair_git:run(Repo, Args, Timeout).

git_error(Args, Reason) ->
    {error, {git_command_failed, #{
        args => [to_binary(A) || A <- Args],
        reason => Reason
    }}}.

%%====================================================================
%% Classification / formatting helpers
%%====================================================================

path_category(Path) ->
    Lower = lower(Path),
    path_category_checks(Path, Lower).

path_category_checks(Path, Lower) ->
    Checks = [
        {suffix(Lower, <<"rebar.lock">>) orelse suffix(Lower, <<"rebar.config">>), dependency},
        {is_config_path(Path), config},
        {contains(Lower, <<"dockerfile">>) orelse contains(Lower, <<"containerfile">>) orelse contains(Lower, <<"packaging/">>), packaging},
        {contains(Lower, <<"c_src/">>) orelse suffix(Lower, <<".c">>) orelse suffix(Lower, <<".so">>), native},
        {contains(Lower, <<"migration">>) orelse contains(Lower, <<"schema">>), migration},
        {contains(Lower, <<"priv/contracts/">>) orelse suffix(Lower, <<".aes">>), contract},
        {contains(Lower, <<"/test/">>) orelse contains(Lower, <<"/tests/">>), test},
        {contains(Lower, <<"/doc/">>) orelse suffix(Lower, <<".md">>) orelse suffix(Lower, <<".org">>), documentation},
        {contains(Lower, <<"priv/static/">>) orelse contains(Lower, <<"priv/templates/">>), ui},
        {is_erlang_source(Path), source}
    ],
    first_category(Checks).

first_category([{true, Category} | _]) -> Category;
first_category([{false, _} | Rest]) -> first_category(Rest);
first_category([]) -> other.

is_semantic_config(Path) ->
    Lower = lower(Path),
    case suffix(Lower, <<"rebar.config">>) of
        true -> false;
        false ->
            suffix(Lower, <<"sys.config">>) orelse
                suffix(Lower, <<"sys.config.sample">>) orelse
                suffix(Lower, <<".app.src">>) orelse
                suffix(Lower, <<".config">>) orelse
                suffix(Lower, <<".config.sample">>)
    end.

is_config_path(Path) ->
    Lower = lower(Path),
    is_semantic_config(Path) orelse
        has_prefix(Lower, <<"config/">>) orelse
        contains(Lower, <<"/config/">>) orelse
        suffix(Lower, <<".yaml">>) orelse
        suffix(Lower, <<".yml">>) orelse
        suffix(Lower, <<".toml">>) orelse
        suffix(Lower, <<".ini">>) orelse
        suffix(Lower, <<".env">>).

is_app_src(Path) ->
    suffix(lower(Path), <<".app.src">>).

is_erlang_source(Path) ->
    Lower = lower(Path),
    suffix(Lower, <<".erl">>) andalso contains(Lower, <<"/src/">>).

status_prefix(<<"A", _/binary>>) -> add;
status_prefix(<<"D", _/binary>>) -> delete;
status_prefix(<<"R", _/binary>>) -> rename;
status_prefix(<<"M", _/binary>>) -> modify;
status_prefix(_) -> unknown.

config_operation('$missing', _New) -> added;
config_operation(_Old, '$missing') -> removed;
config_operation(_Old, _New) -> changed.

safe_config_value('$missing', _Sensitive) -> <<"<absent>">>;
safe_config_value(_Value, true) -> <<"<redacted>">>;
safe_config_value(Value, false) -> bounded_term(Value, 512).

sensitive_key(Key) ->
    Lower = lower(Key),
    lists:any(
        fun(Needle) -> contains(Lower, Needle) end,
        [
            <<"password">>, <<"passwd">>, <<"secret">>, <<"token">>,
            <<"api_key">>, <<"apikey">>, <<"private_key">>, <<"credential">>,
            <<"authorization">>, <<"bearer">>, <<"access_token">>, <<"refresh_token">>,
            <<"client_secret">>, <<"signing_key">>, <<"mnemonic">>, <<"seed">>
        ]
    ).

sensitive_term(Map) when is_map(Map) ->
    lists:any(
        fun({Key, Value}) -> sensitive_key(to_binary(Key)) orelse sensitive_term(Value) end,
        maps:to_list(Map)
    );
sensitive_term({Key, Value}) ->
    sensitive_key(to_binary(Key)) orelse sensitive_term(Value);
sensitive_term(Tuple) when is_tuple(Tuple) ->
    lists:any(fun sensitive_term/1, tuple_to_list(Tuple));
sensitive_term(List) when is_list(List) ->
    lists:any(fun sensitive_term/1, List);
sensitive_term(_) ->
    false.

key_path(Parts) ->
    iolist_to_binary(lists:join(<<".">>, [to_binary(P) || P <- Parts])).

bounded_term(Value, Limit) ->
    Bin = iolist_to_binary(io_lib:format("~tp", [Value])),
    case byte_size(Bin) > Limit of
        true -> <<(binary:part(Bin, 0, Limit))/binary, "…">>;
        false -> Bin
    end.

operation_name(added) -> <<"Added">>;
operation_name(removed) -> <<"Removed">>;
operation_name(changed) -> <<"Changed">>;
operation_name(Other) -> to_binary(Other).

config_operation_name(added) -> <<"Added">>;
config_operation_name(removed) -> <<"Removed">>;
config_operation_name(changed) -> <<"Changed">>.

evidence_hash(Map) ->
    lower(binary:encode_hex(crypto:hash(sha256, term_to_binary(Map, [deterministic])))).

repo_root(Opts) ->
    Root0 = maps:get(
        repo_root,
        Opts,
        application:get_env(ecai, code_repo_root, ".")
    ),
    filename:absname(path_to_list(Root0)).

enabled() ->
    application:get_env(ecai, code_release_memory_enabled, true) =:= true.

default_environment() ->
    application:get_env(ecai, code_release_memory_default_environment, production).

normalize_name(Value) when is_binary(Value) -> Value;
normalize_name(Value) when is_atom(Value) -> atom_to_binary(Value, utf8);
normalize_name(Value) when is_list(Value) -> unicode:characters_to_binary(Value);
normalize_name(Value) -> to_binary(Value).

printable_ref(undefined) -> <<"<initial repository state>">>;
printable_ref(Value) -> to_binary(Value).

printable(undefined) -> <<"unavailable">>;
printable(Value) -> to_binary(Value).

value_or_undefined({ok, Value}) -> Value;
value_or_undefined(_) -> undefined.

safe_filename(Bin) ->
    [
        case C of
            X when (X >= $a andalso X =< $z) orelse (X >= $A andalso X =< $Z) orelse
                (X >= $0 andalso X =< $9) orelse X =:= $- orelse X =:= $_ -> X;
            _ -> $_
        end
     || C <- binary_to_list(Bin)
    ].

markdown_text(Value) ->
    Bin = to_binary(Value),
    binary:replace(
        binary:replace(Bin, <<"\r">>, <<" ">>, [global]),
        <<"\n">>,
        <<" ">>,
        [global]
    ).

short_hash(Hash) when is_binary(Hash), byte_size(Hash) > 12 -> binary:part(Hash, 0, 12);
short_hash(Hash) -> to_binary(Hash).

lines(Bin) ->
    [Line || Part <- binary:split(Bin, <<"\n">>, [global]), Line <- [trim(Part)], Line =/= <<>>].

trim(Bin) ->
    unicode:characters_to_binary(string:trim(binary_to_list(Bin))).

lower(Bin) when is_binary(Bin) ->
    unicode:characters_to_binary(string:lowercase(binary_to_list(Bin)));
lower(List) when is_list(List) -> lower(unicode:characters_to_binary(List));
lower(Atom) when is_atom(Atom) -> lower(atom_to_binary(Atom, utf8)).

contains(Haystack, Needle) -> binary:match(Haystack, Needle) =/= nomatch.
suffix(Bin, Suffix) when byte_size(Bin) >= byte_size(Suffix) ->
    binary:part(Bin, byte_size(Bin) - byte_size(Suffix), byte_size(Suffix)) =:= Suffix;
suffix(_, _) -> false.
has_prefix(Bin, Prefix) when byte_size(Bin) >= byte_size(Prefix) ->
    binary:part(Bin, 0, byte_size(Prefix)) =:= Prefix;
has_prefix(_, _) -> false.

positive_int(N, _Default) when is_integer(N), N > 0 -> N;
positive_int(_, Default) -> Default.

now_iso8601() ->
    unicode:characters_to_binary(
        calendar:system_time_to_rfc3339(
            erlang:system_time(second), [{unit, second}, {offset, "Z"}]
        )
    ).

json_safe(Map) when is_map(Map) ->
    maps:from_list([{json_key(K), json_safe(V)} || {K, V} <- maps:to_list(Map)]);
json_safe(List) when is_list(List) -> [json_safe(V) || V <- List];
json_safe(Tuple) when is_tuple(Tuple) -> [json_safe(V) || V <- tuple_to_list(Tuple)];
json_safe(true) -> true;
json_safe(false) -> false;
json_safe(undefined) -> null;
json_safe(null) -> null;
json_safe(Atom) when is_atom(Atom) -> atom_to_binary(Atom, utf8);
json_safe(Bin) when is_binary(Bin) -> Bin;
json_safe(Number) when is_number(Number) -> Number;
json_safe(Other) -> to_binary(Other).

json_key(K) when is_binary(K) -> K;
json_key(K) when is_atom(K) -> atom_to_binary(K, utf8);
json_key(K) when is_list(K) -> unicode:characters_to_binary(K);
json_key(K) -> to_binary(K).

path_to_list(Value) when is_list(Value) -> Value;
path_to_list(Value) when is_binary(Value) -> unicode:characters_to_list(Value).

to_binary(Value) when is_binary(Value) -> Value;
to_binary(Value) when is_list(Value) -> unicode:characters_to_binary(Value);
to_binary(Value) when is_atom(Value) -> atom_to_binary(Value, utf8);
to_binary(Value) when is_integer(Value) -> integer_to_binary(Value);
to_binary(Value) -> iolist_to_binary(io_lib:format("~p", [Value])).
