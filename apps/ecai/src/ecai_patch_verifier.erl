-module(ecai_patch_verifier).

-export([
    verify/1,
    verify/2,
    verify_patchset/1,
    verify_patchset/2,
    validate_patch/1,
    normalize_patch/1,
    patch_paths/1,
    cleanup_stale/0,
    cleanup_stale/1
]).

-ifdef(TEST).
-export([
    capture_integrity_snapshot/3,
    compare_integrity_snapshots/2,
    patchset_disposition/1,
    candidate_neutral_validation_failure/1,
    validation_failure_signature/3,
    same_validation_failure/5
]).
-endif.

-define(ALLOWED_PREFIXES, ["apps/damage/", "apps/ecai/", "apps/erm/"]).
-define(MAX_OUTPUT_BYTES, 300000).
-define(MAX_SOURCE_BYTES, 65536).

verify(A1) ->
    ExistingResult = verify_without_ecai_capsule(A1),
    ecai_repair_bridge:post_verify([A1], ExistingResult).

verify(A1, A2) ->
    ExistingResult = verify_without_ecai_capsule(A1, A2),
    ecai_repair_bridge:post_verify([A1, A2], ExistingResult).

verify_without_ecai_capsule(PatchFile) -> verify(PatchFile, #{}).

cleanup_stale() -> cleanup_stale(#{}).

cleanup_stale(Opts) ->
    Keep = maps:get(
        keep_worktree,
        Opts,
        application:get_env(ecai, code_patch_keep_worktree, false)
    ),
    case Keep of
        true ->
            {ok, #{skipped => keep_worktree_enabled}};
        false ->
            RepoRoot = repo_root(Opts),
            case repo_available(RepoRoot) of
                false ->
                    {error, {git_repository_not_found, RepoRoot}};
                true ->
                    case ecai_code_paths:state_root(Opts) of
                        {error, _} = Error ->
                            Error;
                        {ok, StateRoot} ->
                            WorkRoot = ecai_code_paths:worktree_root(StateRoot),
                            RepairResults = cleanup_stale_dirs(
                                RepoRoot, WorkRoot, "repair-", Opts
                            ),
                            BaselineResults = cleanup_stale_dirs(
                                RepoRoot, WorkRoot, "baseline-", Opts
                            ),
                            Prune = run(
                                "git",
                                ["-C", RepoRoot, "worktree", "prune"],
                                RepoRoot,
                                command_timeout(Opts)
                            ),
                            {ok, #{
                                worktrees => RepairResults ++ BaselineResults,
                                prune => Prune
                            }}
                    end
            end
    end.

verify_without_ecai_capsule(PatchFile0, Opts) when is_map(Opts) ->
    PatchFile = filename:absname(path_to_list(PatchFile0)),
    Preapply = [
        filename:absname(path_to_list(P))
     || P <- maps:get(preapply_patch_files, Opts, [])
    ],
    verify_patchset(Preapply ++ [PatchFile], Opts#{candidate_patch_file => PatchFile}).

verify_patchset(PatchFiles) -> verify_patchset(PatchFiles, #{}).

verify_patchset([], _Opts) ->
    {error, no_patch_files};
verify_patchset(PatchFiles0, Opts) when is_list(PatchFiles0), is_map(Opts) ->
    PatchFiles = dedupe_preserve([filename:absname(path_to_list(P)) || P <- PatchFiles0]),
    case validate_patch_files(PatchFiles) of
        ok -> verify_valid_patchset(PatchFiles, Opts);
        {error, _} = Error -> Error
    end.

validate_patch(Patch0) when is_binary(Patch0) ->
    Patch = normalize_patch(Patch0),
    case byte_size(Patch) of
        0 ->
            {error, empty_patch};
        _ ->
            case has_binary_patch(Patch) of
                true ->
                    {error, binary_patches_not_allowed};
                false ->
                    case binary:match(Patch, <<"diff --git ">>) of
                        {0, _} ->
                            case validate_paths(patch_paths(Patch)) of
                                ok -> validate_patch_structure(Patch);
                                {error, _} = Error -> Error
                            end;
                        _ ->
                            {error, missing_git_diff_header}
                    end
            end
    end.

validate_patch_structure(Patch) ->
    Lines = binary:split(Patch, <<"\n">>, [global]),
    case patch_diff_sections(Lines, [], []) of
        [] -> {error, missing_git_diff_header};
        Sections -> validate_diff_sections(Sections, 1)
    end.

patch_diff_sections([], [], Acc) ->
    lists:reverse(Acc);
patch_diff_sections([], Current, Acc) ->
    lists:reverse([lists:reverse(Current) | Acc]);
patch_diff_sections(
    [Line = <<"diff --git ", _/binary>> | Rest], [], Acc
) ->
    patch_diff_sections(Rest, [Line], Acc);
patch_diff_sections(
    [Line = <<"diff --git ", _/binary>> | Rest], Current, Acc
) ->
    patch_diff_sections(
        Rest,
        [Line],
        [lists:reverse(Current) | Acc]
    );
patch_diff_sections([Line | Rest], Current, Acc) ->
    patch_diff_sections(Rest, [Line | Current], Acc).

validate_diff_sections([], _Index) ->
    ok;
validate_diff_sections([Lines | Rest], Index) ->
    case validate_diff_section(Lines, Index) of
        ok -> validate_diff_sections(Rest, Index + 1);
        {error, _} = Error -> Error
    end.

validate_diff_section(Lines, Index) ->
    case has_file_header_pair(Lines) of
        false ->
            {error, {missing_patch_file_headers, Index}};
        true ->
            case validate_index_lines(Lines, Index) of
                ok -> validate_hunks(Lines, Index);
                {error, _} = Error -> Error
            end
    end.

has_file_header_pair(Lines) ->
    HasOld = lists:any(fun is_old_file_header/1, Lines),
    HasNew = lists:any(fun is_new_file_header/1, Lines),
    HasOld andalso HasNew.

is_old_file_header(<<"--- a/", _/binary>>) -> true;
is_old_file_header(<<"--- /dev/null", _/binary>>) -> true;
is_old_file_header(_) -> false.

is_new_file_header(<<"+++ b/", _/binary>>) -> true;
is_new_file_header(<<"+++ /dev/null", _/binary>>) -> true;
is_new_file_header(_) -> false.

validate_index_lines(Lines, Index) ->
    IndexLines = [Line || Line <- Lines, is_index_line(Line)],
    case lists:all(fun valid_index_line/1, IndexLines) of
        true -> ok;
        false -> {error, {invalid_patch_index, Index}}
    end.

is_index_line(<<"index ", _/binary>>) -> true;
is_index_line(_) -> false.

valid_index_line(<<"index ", Rest/binary>>) ->
    Token = hd(binary:split(Rest, <<" ">>, [])),
    case binary:split(Token, <<"..">>, []) of
        [Old, New] -> valid_hex_object_id(Old) andalso valid_hex_object_id(New);
        _ -> false
    end;
valid_index_line(_) ->
    true.

valid_hex_object_id(Bin) when is_binary(Bin), byte_size(Bin) > 0 ->
    lists:all(fun is_hex_char/1, binary_to_list(Bin));
valid_hex_object_id(_) ->
    false.

is_hex_char(C) when C >= $0, C =< $9 -> true;
is_hex_char(C) when C >= $a, C =< $f -> true;
is_hex_char(C) when C >= $A, C =< $F -> true;
is_hex_char(_) -> false.

validate_hunks(Lines, Index) ->
    HunkHeaders = [Line || Line <- Lines, is_hunk_header(Line)],
    case HunkHeaders of
        [] ->
            {error, {missing_patch_hunk, Index}};
        _ ->
            case lists:all(fun valid_hunk_header/1, HunkHeaders) of
                false ->
                    {error, {invalid_patch_hunk_header, Index}};
                true ->
                    case lists:any(fun is_change_line/1, Lines) of
                        true -> ok;
                        false -> {error, {patch_hunk_without_changes, Index}}
                    end
            end
    end.

is_hunk_header(<<"@@ ", _/binary>>) -> true;
is_hunk_header(_) -> false.

valid_hunk_header(Line) ->
    case
        re:run(
            Line,
            <<"^@@ -[0-9]+(,[0-9]+)? [+][0-9]+(,[0-9]+)? @@( .*)?$">>,
            [{capture, none}]
        )
    of
        match -> true;
        nomatch -> false
    end.

is_change_line(<<"+++", _/binary>>) -> false;
is_change_line(<<"---", _/binary>>) -> false;
is_change_line(<<"+", _/binary>>) -> true;
is_change_line(<<"-", _/binary>>) -> true;
is_change_line(_) -> false.

%% Canonicalize common model-output wrappers without changing diff semantics.
%% The patch worker persists this normalized form, so verification and later
%% integration see the same bytes. Hunk line counts are handled independently
%% by git apply --recount below.
normalize_patch(Patch0) when is_binary(Patch0) ->
    Patch1 = strip_utf8_bom(Patch0),
    Patch2 = binary:replace(Patch1, <<"\r\n">>, <<"\n">>, [global]),
    Patch3 = binary:replace(Patch2, <<"\r">>, <<"\n">>, [global]),
    Patch5 = strip_outer_markdown_fence(Patch3),
    Patch6 =
        case binary:match(Patch5, <<"diff --git ">>) of
            nomatch -> Patch5;
            {Pos, _Len} -> binary:part(Patch5, Pos, byte_size(Patch5) - Pos)
        end,
    Patch7 = strip_trailing_markdown_fence(Patch6),
    ensure_final_newline(Patch7).

patch_paths(Patch) when is_binary(Patch) ->
    Lines = binary:split(Patch, <<"\n">>, [global]),
    lists:usort(lists:append([paths_from_line(Line) || Line <- Lines])).

validate_patch_files([]) ->
    ok;
validate_patch_files([PatchFile | Rest]) ->
    case file:read_file(PatchFile) of
        {error, Reason} ->
            {error, {cannot_read_patch, PatchFile, Reason}};
        {ok, Patch} ->
            case validate_patch(Patch) of
                ok -> validate_patch_files(Rest);
                {error, Reason} -> {error, {invalid_patch_file, PatchFile, Reason}}
            end
    end.

verify_valid_patchset(PatchFiles, Opts) ->
    RepoRoot = repo_root(Opts),
    case repo_available(RepoRoot) of
        false ->
            {error, {git_repository_not_found, RepoRoot}};
        true ->
            case resolve_base_commit(RepoRoot, Opts) of
                {error, _} = Error ->
                    Error;
                {ok, BaseCommit} ->
                    case ecai_code_paths:state_root(Opts) of
                        {error, _} = Error ->
                            Error;
                        {ok, StateRoot} ->
                            WorkRoot0 = maps:get(
                                worktree_root,
                                Opts,
                                ecai_code_paths:worktree_root(StateRoot)
                            ),
                            WorkRoot = path_to_list(WorkRoot0),
                            ok = ensure_dir(WorkRoot),
                            Prefix = path_to_list(maps:get(worktree_prefix, Opts, "repair")),
                            Id =
                                integer_to_list(erlang:system_time(microsecond)) ++ "-" ++
                                    integer_to_list(erlang:unique_integer([positive, monotonic])),
                            Worktree = filename:join(WorkRoot, Prefix ++ "-" ++ Id),
                            run_verification(
                                RepoRoot,
                                Worktree,
                                BaseCommit,
                                PatchFiles,
                                StateRoot,
                                Opts
                            )
                    end
            end
    end.

run_verification(RepoRoot, Worktree, BaseCommit, PatchFiles, _StateRoot, Opts) ->
    Started = now_iso8601(),
    Add = run(
        "git",
        [
            "-C",
            RepoRoot,
            "worktree",
            "add",
            "--detach",
            Worktree,
            binary_to_list(BaseCommit)
        ],
        RepoRoot,
        command_timeout(Opts)
    ),
    case step_ok(Add) of
        false ->
            {error, {cannot_create_worktree, BaseCommit, Add}};
        true ->
            Steps0 = [#{step => worktree_add, result => Add}],
            {Status, Steps1, Failure} = apply_patchset(
                Worktree,
                PatchFiles,
                1,
                command_timeout(Opts),
                Steps0
            ),
            PatchDisposition = patchset_disposition(Steps1),
            {FinalStatus, Steps, FinalFailure} =
                case Status of
                    failed ->
                        {failed, Steps1, Failure};
                    applied ->
                        verify_applied_worktree(
                            Worktree, PatchFiles, Opts, Steps1, PatchDisposition
                        )
                end,
            FailureSources =
                case FinalStatus of
                    failed -> capture_failure_sources(Worktree, FinalFailure, PatchFiles);
                    validated -> []
                end,
            Keep = maps:get(
                keep_worktree,
                Opts,
                application:get_env(ecai, code_patch_keep_worktree, false)
            ),
            Cleanup =
                case Keep of
                    true -> #{kept => true, path => to_binary(Worktree)};
                    false -> cleanup_worktree(RepoRoot, Worktree, Opts)
                end,
            Result = #{
                status => FinalStatus,
                patch_disposition => PatchDisposition,
                validation_warnings => validation_warnings(Steps),
                base_commit => BaseCommit,
                patch_files => [to_binary(P) || P <- PatchFiles],
                candidate_patch_file => maybe_binary(
                    maps:get(candidate_patch_file, Opts, undefined)
                ),
                worktree => to_binary(Worktree),
                started_at => Started,
                completed_at => now_iso8601(),
                steps => Steps,
                failure => FinalFailure,
                failure_sources => FailureSources,
                cleanup => Cleanup
            },
            {ok, Result}
    end.

apply_patchset(_Worktree, [], _Index, _Timeout, Steps) ->
    {applied, Steps, undefined};
apply_patchset(Worktree, [PatchFile | Rest], Index, Timeout, Steps0) ->
    Check = run(
        "git",
        ["-C", Worktree, "apply", "--recount", "--check", PatchFile],
        Worktree,
        Timeout
    ),
    CheckStep = #{
        step => patch_apply_check,
        patch_index => Index,
        patch_file => to_binary(PatchFile),
        result => Check
    },
    Steps1 = Steps0 ++ [CheckStep],
    case step_ok(Check) of
        false ->
            %% A repair may already have been committed to the selected base.
            %% Treat an exact reverse-applicable patch as already present rather
            %% than as an integration conflict.
            Reverse = run(
                "git",
                ["-C", Worktree, "apply", "--recount", "--reverse", "--check", PatchFile],
                Worktree,
                Timeout
            ),
            ReverseStep = #{
                step => patch_reverse_check,
                patch_index => Index,
                patch_file => to_binary(PatchFile),
                result => Reverse
            },
            Steps2 = Steps1 ++ [ReverseStep],
            case step_ok(Reverse) of
                true ->
                    PresentStep = #{
                        step => patch_already_present,
                        patch_index => Index,
                        patch_file => to_binary(PatchFile),
                        result => #{ok => true}
                    },
                    apply_patchset(
                        Worktree,
                        Rest,
                        Index + 1,
                        Timeout,
                        Steps2 ++ [PresentStep]
                    );
                false ->
                    {failed, Steps2, #{
                        phase => patch_apply_check,
                        patch_index => Index,
                        patch_file => to_binary(PatchFile),
                        result => Check,
                        reverse_check => Reverse
                    }}
            end;
        true ->
            Apply = run(
                "git", ["-C", Worktree, "apply", "--recount", PatchFile], Worktree, Timeout
            ),
            ApplyStep = #{
                step => patch_apply,
                patch_index => Index,
                patch_file => to_binary(PatchFile),
                result => Apply
            },
            Steps2 = Steps1 ++ [ApplyStep],
            case step_ok(Apply) of
                true ->
                    apply_patchset(Worktree, Rest, Index + 1, Timeout, Steps2);
                false ->
                    {failed, Steps2, #{
                        phase => patch_apply,
                        patch_index => Index,
                        patch_file => to_binary(PatchFile),
                        result => Apply
                    }}
            end
    end.

verify_applied_worktree(Worktree, PatchFiles, Opts, Steps0, PatchDisposition) ->
    Timeout = command_timeout(Opts),
    case capture_integrity_snapshot(Worktree, PatchFiles, Timeout) of
        {error, Failure} ->
            Step = #{
                step => post_apply_integrity,
                result => #{ok => false, failure => Failure}
            },
            {failed, Steps0 ++ [Step], Failure};
        {ok, Before} ->
            Step0 = #{
                step => post_apply_integrity,
                result => integrity_step_result(Before)
            },
            Steps1 = Steps0 ++ [Step0],
            case maps:get(unexpected_paths, Before, []) of
                [] ->
                    case run_validation_steps(Worktree, Opts, Steps1) of
                        {failed, Steps2, Failure} ->
                            case
                                candidate_neutral_validation_failure(
                                    PatchDisposition
                                )
                            of
                                true ->
                                    Warning = baseline_validation_warning(
                                        Failure, PatchDisposition
                                    ),
                                    verify_final_integrity(
                                        Worktree,
                                        PatchFiles,
                                        Before,
                                        Timeout,
                                        Steps2 ++ [Warning]
                                    );
                                false ->
                                    case
                                        differential_baseline_validation(
                                            Worktree,
                                            Failure,
                                            Opts,
                                            PatchDisposition
                                        )
                                    of
                                        {neutral, Evidence} ->
                                            CompareStep = #{
                                                step => baseline_validation_compare,
                                                result => Evidence#{
                                                    ok => true,
                                                    candidate_neutral => true
                                                }
                                            },
                                            Warning = baseline_validation_warning(
                                                Failure, PatchDisposition, Evidence
                                            ),
                                            verify_final_integrity(
                                                Worktree,
                                                PatchFiles,
                                                Before,
                                                Timeout,
                                                Steps2 ++ [CompareStep, Warning]
                                            );
                                        {regression, Evidence} ->
                                            CompareStep = #{
                                                step => baseline_validation_compare,
                                                result => Evidence#{
                                                    ok => false,
                                                    candidate_neutral => false
                                                }
                                            },
                                            {failed, Steps2 ++ [CompareStep],
                                                attach_baseline_comparison(Failure, Evidence)};
                                        not_applicable ->
                                            {failed, Steps2, Failure}
                                    end
                            end;
                        {validated, Steps2, undefined} ->
                            verify_final_integrity(
                                Worktree,
                                PatchFiles,
                                Before,
                                Timeout,
                                Steps2
                            )
                    end;
                Unexpected ->
                    Failure = #{
                        phase => repository_integrity,
                        stage => post_apply,
                        reason => patchset_changed_unexpected_paths,
                        unexpected_paths => Unexpected,
                        allowed_paths => maps:get(
                            allowed_paths, Before, []
                        ),
                        actual_paths => maps:get(
                            actual_paths, Before, []
                        )
                    },
                    Step1 = #{
                        step => repository_integrity,
                        result => #{
                            ok => false,
                            failure => Failure
                        }
                    },
                    {failed, Steps1 ++ [Step1], Failure}
            end
    end.

verify_final_integrity(
    Worktree, PatchFiles, Before, Timeout, Steps0
) ->
    DiffCheck = run(
        "git",
        ["-C", Worktree, "diff", "--check"],
        Worktree,
        Timeout
    ),
    DiffStep = #{step => final_diff_check, result => DiffCheck},
    Steps1 = Steps0 ++ [DiffStep],
    case step_ok(DiffCheck) of
        false ->
            {failed, Steps1, #{
                phase => final_diff_check,
                result => DiffCheck
            }};
        true ->
            case
                capture_integrity_snapshot(
                    Worktree, PatchFiles, Timeout
                )
            of
                {error, Failure} ->
                    Step = #{
                        step => post_validation_integrity,
                        result => #{
                            ok => false,
                            failure => Failure
                        }
                    },
                    {failed, Steps1 ++ [Step], Failure};
                {ok, After} ->
                    case compare_integrity_snapshots(Before, After) of
                        ok ->
                            Step = #{
                                step => post_validation_integrity,
                                result => integrity_step_result(After)
                            },
                            {validated, Steps1 ++ [Step], undefined};
                        {error, Failure} ->
                            Step = #{
                                step => post_validation_integrity,
                                result => #{
                                    ok => false,
                                    failure => Failure,
                                    snapshot =>
                                        integrity_step_result(After)
                                }
                            },
                            {failed, Steps1 ++ [Step], Failure}
                    end
            end
    end.

capture_integrity_snapshot(Worktree, PatchFiles, Timeout) when
    is_list(PatchFiles), is_integer(Timeout), Timeout > 0
->
    Allowed = lists:usort([
        to_binary(Path)
     || Path <- patchset_paths(PatchFiles)
    ]),
    case worktree_changed_paths(Worktree, Timeout) of
        {error, _} = Error ->
            Error;
        {ok, Actual} ->
            Unexpected = list_subtract(Actual, Allowed),
            case path_states(Worktree, Actual) of
                {error, Reason} ->
                    {error, #{
                        phase => repository_integrity,
                        stage => inspect_paths,
                        reason => Reason,
                        actual_paths => Actual
                    }};
                {ok, States} ->
                    Fingerprint = sha256_hex(
                        term_to_binary(
                            {Actual, States},
                            [deterministic]
                        )
                    ),
                    {ok, #{
                        allowed_paths => Allowed,
                        actual_paths => Actual,
                        unexpected_paths => Unexpected,
                        path_states => States,
                        fingerprint => Fingerprint
                    }}
            end
    end.

compare_integrity_snapshots(Before, After) when
    is_map(Before), is_map(After)
->
    Unexpected = maps:get(unexpected_paths, After, []),
    BeforeStates = maps:get(path_states, Before, #{}),
    AfterStates = maps:get(path_states, After, #{}),
    Delta = integrity_delta(BeforeStates, AfterStates),
    BeforeFingerprint = maps:get(
        fingerprint, Before, undefined
    ),
    AfterFingerprint = maps:get(
        fingerprint, After, undefined
    ),
    case
        {
            Unexpected,
            BeforeFingerprint =:= AfterFingerprint
        }
    of
        {[], true} ->
            ok;
        _ ->
            {error, #{
                phase => repository_integrity,
                stage => post_validation,
                reason => repository_mutated_during_validation,
                unexpected_paths => Unexpected,
                allowed_paths => maps:get(
                    allowed_paths, After, []
                ),
                before_paths => maps:get(
                    actual_paths, Before, []
                ),
                after_paths => maps:get(
                    actual_paths, After, []
                ),
                added_paths => maps:get(
                    added_paths, Delta, []
                ),
                removed_paths => maps:get(
                    removed_paths, Delta, []
                ),
                modified_paths => maps:get(
                    modified_paths, Delta, []
                ),
                before_fingerprint => BeforeFingerprint,
                after_fingerprint => AfterFingerprint
            }}
    end.

integrity_step_result(Snapshot) ->
    (maps:without([path_states], Snapshot))#{
        ok => maps:get(unexpected_paths, Snapshot, []) =:= []
    }.

worktree_changed_paths(Worktree, Timeout) ->
    Tracked = run(
        "git",
        [
            "-C",
            Worktree,
            "diff",
            "--name-only",
            "-z",
            "HEAD",
            "--"
        ],
        Worktree,
        Timeout
    ),
    case step_ok(Tracked) of
        false ->
            {error, #{
                phase => repository_integrity,
                stage => tracked_paths,
                reason => cannot_list_tracked_changes,
                result => Tracked
            }};
        true ->
            Untracked = run(
                "git",
                [
                    "-C",
                    Worktree,
                    "ls-files",
                    "--others",
                    "--exclude-standard",
                    "-z",
                    "--"
                ],
                Worktree,
                Timeout
            ),
            case step_ok(Untracked) of
                false ->
                    {error, #{
                        phase => repository_integrity,
                        stage => untracked_paths,
                        reason => cannot_list_untracked_changes,
                        result => Untracked
                    }};
                true ->
                    TrackedPaths = nul_paths(
                        maps:get(output, Tracked, <<>>)
                    ),
                    UntrackedPaths = nul_paths(
                        maps:get(output, Untracked, <<>>)
                    ),
                    {ok,
                        lists:usort(
                            TrackedPaths ++ UntrackedPaths
                        )}
            end
    end.

nul_paths(<<>>) ->
    [];
nul_paths(Bin) when is_binary(Bin) ->
    [
        Path
     || Path <- binary:split(Bin, <<0>>, [global]),
        Path =/= <<>>
    ].

path_states(Worktree, Paths) ->
    path_states(Worktree, Paths, #{}).

path_states(_Worktree, [], Acc) ->
    {ok, Acc};
path_states(Worktree, [Path | Rest], Acc0) ->
    RelPath = path_to_list(Path),
    FullPath = filename:join(Worktree, RelPath),
    case file:read_file(FullPath) of
        {ok, Bytes} ->
            State = #{
                state => present,
                sha256 => sha256_hex(Bytes),
                size => byte_size(Bytes)
            },
            path_states(
                Worktree, Rest, Acc0#{Path => State}
            );
        {error, enoent} ->
            path_states(
                Worktree,
                Rest,
                Acc0#{Path => #{state => deleted}}
            );
        {error, eisdir} ->
            path_states(
                Worktree,
                Rest,
                Acc0#{Path => #{state => directory}}
            );
        {error, Reason} ->
            {error, {
                cannot_hash_changed_path,
                Path,
                Reason
            }}
    end.

integrity_delta(BeforeStates, AfterStates) ->
    BeforeKeys = lists:usort(maps:keys(BeforeStates)),
    AfterKeys = lists:usort(maps:keys(AfterStates)),
    Common = [
        Path
     || Path <- BeforeKeys,
        maps:is_key(Path, AfterStates)
    ],
    #{
        added_paths => list_subtract(
            AfterKeys, BeforeKeys
        ),
        removed_paths => list_subtract(
            BeforeKeys, AfterKeys
        ),
        modified_paths => [
            Path
         || Path <- Common,
            maps:get(Path, BeforeStates) =/=
                maps:get(Path, AfterStates)
        ]
    }.

list_subtract(Left, Right) ->
    RightSet = maps:from_list([{Item, true} || Item <- Right]),
    [
        Item
     || Item <- Left,
        not maps:is_key(Item, RightSet)
    ].

patchset_disposition(Steps) when is_list(Steps) ->
    Applied = lists:any(
        fun(Step) -> maps:get(step, Step, undefined) =:= patch_apply end,
        Steps
    ),
    Present = lists:any(
        fun(Step) -> maps:get(step, Step, undefined) =:= patch_already_present end,
        Steps
    ),
    case {Applied, Present} of
        {true, true} -> mixed;
        {true, false} -> applied;
        {false, true} -> already_present;
        {false, false} -> unknown
    end;
patchset_disposition(_) ->
    unknown.

candidate_neutral_validation_failure(already_present) -> true;
candidate_neutral_validation_failure(_) -> false.

%% An applied repair can encounter a repository-wide validation failure that
%% already exists at the pinned base commit.  Do not attribute that failure to
%% the candidate unless a clean baseline succeeds or fails differently.  This
%% comparison is deliberately conservative: only built-in validation phases are
%% eligible, the same command is rerun in a second detached worktree at HEAD,
%% and the stable failure signatures must match exactly.
differential_baseline_validation(Worktree, Failure, Opts, PatchDisposition) when
    PatchDisposition =:= applied; PatchDisposition =:= mixed
->
    Phase = maps:get(phase, Failure, undefined),
    case validation_phase_spec(Phase) of
        undefined ->
            not_applicable;
        {Exe, Args} ->
            CandidateResult = maps:get(result, Failure, #{}),
            Timeout = command_timeout(Opts),
            BaselineWorktree = baseline_worktree_path(Worktree),
            Add = run(
                "git",
                [
                    "-C",
                    Worktree,
                    "worktree",
                    "add",
                    "--detach",
                    BaselineWorktree,
                    "HEAD"
                ],
                Worktree,
                Timeout
            ),
            case step_ok(Add) of
                false ->
                    {regression, #{
                        phase => Phase,
                        reason => baseline_worktree_failed,
                        worktree_add => compact_command_result(Add)
                    }};
                true ->
                    BaselineResult = run(Exe, Args, BaselineWorktree, Timeout),
                    Equivalent =
                        (not step_ok(BaselineResult)) andalso
                            same_validation_failure(
                                Phase,
                                CandidateResult,
                                Worktree,
                                BaselineResult,
                                BaselineWorktree
                            ),
                    Cleanup = cleanup_worktree(
                        Worktree, BaselineWorktree, Opts
                    ),
                    Evidence = #{
                        phase => Phase,
                        equivalent_failure => Equivalent,
                        candidate_signature => validation_failure_signature(
                            Phase, CandidateResult, Worktree
                        ),
                        baseline_signature => validation_failure_signature(
                            Phase, BaselineResult, BaselineWorktree
                        ),
                        baseline_result => compact_command_result(BaselineResult),
                        worktree_add => compact_command_result(Add),
                        cleanup => Cleanup
                    },
                    case Equivalent of
                        true -> {neutral, Evidence};
                        false -> {regression, Evidence}
                    end
            end
    end;
differential_baseline_validation(_Worktree, _Failure, _Opts, _Disposition) ->
    not_applicable.

validation_phase_spec(compile) -> {"rebar3", ["compile"]};
validation_phase_spec(eunit) -> {"rebar3", ["eunit"]};
validation_phase_spec(ct) -> {"rebar3", ["ct"]};
validation_phase_spec(_) -> undefined.

baseline_worktree_path(Worktree) ->
    Root = filename:dirname(Worktree),
    Id =
        integer_to_list(erlang:system_time(microsecond)) ++ "-" ++
            integer_to_list(erlang:unique_integer([positive, monotonic])),
    filename:join(Root, "baseline-" ++ Id).

attach_baseline_comparison(Failure, Evidence) when is_map(Failure) ->
    Failure#{baseline_comparison => Evidence};
attach_baseline_comparison(Failure, Evidence) ->
    #{failure => Failure, baseline_comparison => Evidence}.

same_validation_failure(
    Phase,
    CandidateResult,
    CandidateCwd,
    BaselineResult,
    BaselineCwd
) ->
    validation_failure_signature(Phase, CandidateResult, CandidateCwd) =:=
        validation_failure_signature(Phase, BaselineResult, BaselineCwd).

validation_failure_signature(Phase, Result, Cwd) when is_map(Result) ->
    Output = maps:get(output, Result, <<>>),
    #{
        phase => Phase,
        exit_status => maps:get(exit_status, Result, undefined),
        error => maps:get(error, Result, undefined),
        args => maps:get(args, Result, []),
        failure_paths => lists:sort(paths_from_output(Output)),
        failure_markers => stable_failure_lines(Output, Cwd)
    };
validation_failure_signature(Phase, Result, _Cwd) ->
    #{phase => Phase, result => Result}.

stable_failure_lines(Output0, Cwd0) when is_binary(Output0) ->
    Output1 = strip_ansi(Output0),
    Cwd = to_binary(Cwd0),
    Output =
        case Cwd of
            <<>> -> Output1;
            _ -> binary:replace(Output1, Cwd, <<"<worktree>">>, [global])
        end,
    Lines = [trim_binary(Line) || Line <- binary:split(Output, <<"\n">>, [global])],
    Marked = [
        truncate_binary(Line, 2048)
     || Line <- Lines,
        Line =/= <<>>,
        stable_failure_line(Line)
    ],
    case Marked of
        [] ->
            lists:sublist(
                lists:reverse([
                    truncate_binary(Line, 2048)
                 || Line <- Lines, Line =/= <<>>
                ]),
                20
            );
        _ ->
            lists:sublist(Marked, 80)
    end;
stable_failure_lines(_Output, _Cwd) ->
    [].

stable_failure_line(Line) ->
    Lower = string:lowercase(binary_to_list(Line)),
    lists:any(
        fun(Marker) -> string:str(Lower, Marker) > 0 end,
        [
            "*failed*",
            "failed:",
            "error:",
            "exception",
            "assert",
            "badmatch",
            "function_clause",
            "case_clause",
            "test failed",
            "crash",
            "undef"
        ]
    ).

strip_ansi(Bin) when is_binary(Bin) ->
    Pattern = <<27, "\\[[0-9;]*[A-Za-z]">>,
    case
        re:replace(
            Bin,
            Pattern,
            <<>>,
            [global, {return, binary}]
        )
    of
        Result when is_binary(Result) -> Result;
        _ -> Bin
    end.

compact_command_result(Result) when is_map(Result) ->
    Output0 = maps:get(output, Result, <<>>),
    Output =
        case Output0 of
            Bin when is_binary(Bin) -> truncate_binary(Bin, 8192);
            Other -> Other
        end,
    (maps:with([ok, exit_status, executable, args, error], Result))#{
        output => Output
    };
compact_command_result(Result) ->
    Result.

baseline_validation_warning(Failure, PatchDisposition) ->
    baseline_validation_warning(Failure, PatchDisposition, undefined).

baseline_validation_warning(Failure, PatchDisposition, Evidence) ->
    Result0 = #{
        ok => true,
        candidate_neutral => true,
        patch_disposition => PatchDisposition,
        warning => compact_validation_failure(Failure)
    },
    Result =
        case Evidence of
            undefined -> Result0;
            _ -> Result0#{baseline_comparison => Evidence}
        end,
    #{
        step => baseline_validation_warning,
        result => Result
    }.

compact_validation_failure(Failure) when is_map(Failure) ->
    Phase = maps:get(phase, Failure, undefined),
    Result0 = maps:get(result, Failure, #{}),
    Result =
        case Result0 of
            R when is_map(R) ->
                Output0 = maps:get(output, R, <<>>),
                Output =
                    case Output0 of
                        Bin when is_binary(Bin) -> truncate_binary(Bin, 8192);
                        Other -> Other
                    end,
                (maps:with([ok, exit_status, executable, args], R))#{
                    output => Output
                };
            _ ->
                Result0
        end,
    #{phase => Phase, result => Result};
compact_validation_failure(Failure) ->
    Failure.

validation_warnings(Steps) when is_list(Steps) ->
    [
        maps:get(warning, Result)
     || #{step := baseline_validation_warning, result := Result} <- Steps,
        is_map(Result),
        maps:is_key(warning, Result)
    ];
validation_warnings(_) ->
    [].

run_validation_steps(Worktree, Opts, Steps0) ->
    Timeout = command_timeout(Opts),
    Specs0 = [
        {diff_check, "git", ["-C", Worktree, "diff", "--check"]},
        {compile, "rebar3", ["compile"]}
    ],
    Specs1 =
        case
            maps:get(
                run_eunit,
                Opts,
                application:get_env(ecai, code_patch_run_eunit, true)
            )
        of
            true -> Specs0 ++ [{eunit, "rebar3", ["eunit"]}];
            false -> Specs0
        end,
    Specs2 =
        case
            maps:get(
                run_ct,
                Opts,
                application:get_env(ecai, code_patch_run_ct, false)
            )
        of
            true -> Specs1 ++ [{ct, "rebar3", ["ct"]}];
            false -> Specs1
        end,
    Extra = maps:get(extra_commands, Opts, []),
    run_specs(Specs2 ++ normalize_extra_commands(Extra), Worktree, Timeout, Steps0).

run_specs([], _Cwd, _Timeout, Steps) ->
    {validated, Steps, undefined};
run_specs([{Name, Exe, Args} | Rest], Cwd, Timeout, Steps0) ->
    Result = run(Exe, Args, Cwd, Timeout),
    Step = #{step => Name, result => Result},
    Steps = Steps0 ++ [Step],
    case step_ok(Result) of
        true -> run_specs(Rest, Cwd, Timeout, Steps);
        false -> {failed, Steps, #{phase => Name, result => Result}}
    end.

normalize_extra_commands(List) when is_list(List) ->
    lists:filtermap(
        fun
            ({Name, Exe, Args}) when is_atom(Name), is_list(Args) ->
                {true, {Name, path_to_list(Exe), [path_to_list(A) || A <- Args]}};
            (_) ->
                false
        end,
        List
    );
normalize_extra_commands(_) ->
    [].

capture_failure_sources(Worktree, Failure, PatchFiles) ->
    Paths0 = failure_paths(Failure),
    Paths1 =
        case Paths0 of
            [] -> patchset_paths(PatchFiles);
            _ -> Paths0
        end,
    Paths = lists:sublist(
        lists:usort([
            P
         || P <- Paths1,
            allowed_path(P),
            filename:extension(P) =:= ".erl"
        ]),
        4
    ),
    lists:filtermap(
        fun(RelPath) ->
            Full = filename:join(Worktree, RelPath),
            case file:read_file(Full) of
                {ok, Source0} ->
                    Source = truncate_binary(Source0, ?MAX_SOURCE_BYTES),
                    {true, #{
                        path => to_binary(RelPath),
                        source => Source,
                        module => module_name_from_path(RelPath)
                    }};
                {error, _} ->
                    false
            end
        end,
        Paths
    ).

failure_paths(undefined) ->
    [];
failure_paths(Failure) when is_map(Failure) ->
    Result = maps:get(result, Failure, #{}),
    Output = maps:get(output, Result, <<>>),
    paths_from_output(Output);
failure_paths(_) ->
    [].

paths_from_output(Output) when is_binary(Output) ->
    Pattern = <<"(apps/(?:damage|ecai|erm)/(?:src|test|tests)/[^\\s:]+\\.erl)">>,
    case re:run(Output, Pattern, [global, {capture, [1], binary}]) of
        {match, Matches} -> lists:usort([binary_to_list(P) || [P] <- Matches]);
        nomatch -> []
    end;
paths_from_output(_) ->
    [].

patchset_paths(PatchFiles) ->
    lists:usort(
        lists:append([
            case file:read_file(P) of
                {ok, Bin} -> patch_paths(Bin);
                _ -> []
            end
         || P <- PatchFiles
        ])
    ).

cleanup_stale_dirs(RepoRoot, WorkRoot, Prefix, Opts) ->
    case file:list_dir(WorkRoot) of
        {ok, Names} ->
            [
                cleanup_stale_dir(RepoRoot, WorkRoot, Name, Opts)
             || Name <- Names, lists:prefix(Prefix, Name)
            ];
        {error, enoent} ->
            [];
        {error, Reason} ->
            [#{ok => false, error => {cannot_list_worktree_root, Reason}}]
    end.

cleanup_stale_dir(RepoRoot, WorkRoot, Name, Opts) ->
    Path = filename:join(WorkRoot, Name),
    GitResult = run(
        "git",
        ["-C", RepoRoot, "worktree", "remove", "--force", Path],
        RepoRoot,
        command_timeout(Opts)
    ),
    #{path => to_binary(Path), git => GitResult, still_present => filelib:is_dir(Path)}.

cleanup_worktree(RepoRoot, Worktree, Opts) ->
    Remove = run(
        "git",
        ["-C", RepoRoot, "worktree", "remove", "--force", Worktree],
        RepoRoot,
        command_timeout(Opts)
    ),
    Prune = run(
        "git",
        ["-C", RepoRoot, "worktree", "prune"],
        RepoRoot,
        command_timeout(Opts)
    ),
    #{kept => false, remove => Remove, prune => Prune}.

resolve_base_commit(RepoRoot, Opts) ->
    Base0 = maps:get(base_commit, Opts, "HEAD"),
    Base = path_to_list(Base0),
    VerifyArg = Base ++ "^{commit}",
    Result = run(
        "git",
        ["-C", RepoRoot, "rev-parse", "--verify", "--end-of-options", VerifyArg],
        RepoRoot,
        command_timeout(Opts)
    ),
    case Result of
        #{ok := true, output := Output} -> {ok, trim_binary(Output)};
        _ -> {error, {invalid_base_commit, Base0, Result}}
    end.

run(ExeName, Args, Cwd, Timeout) ->
    case os:find_executable(ExeName) of
        false ->
            #{ok => false, executable => to_binary(ExeName), error => executable_not_found};
        Exe ->
            Port = open_port({spawn_executable, Exe}, [
                binary,
                exit_status,
                stderr_to_stdout,
                {args, Args},
                {cd, Cwd}
            ]),
            collect_port(Port, <<>>, Timeout, ExeName, Args)
    end.

collect_port(Port, Acc0, Timeout, ExeName, Args) ->
    receive
        {Port, {data, Data}} ->
            Acc = append_bounded(Acc0, Data),
            collect_port(Port, Acc, Timeout, ExeName, Args);
        {Port, {exit_status, 0}} ->
            #{
                ok => true,
                executable => to_binary(ExeName),
                args => list_binaries(Args),
                output => Acc0
            };
        {Port, {exit_status, Status}} ->
            #{
                ok => false,
                executable => to_binary(ExeName),
                args => list_binaries(Args),
                exit_status => Status,
                output => Acc0
            }
    after Timeout ->
        try
            port_close(Port)
        catch
            _:_ -> ok
        end,
        #{
            ok => false,
            executable => to_binary(ExeName),
            args => list_binaries(Args),
            error => timeout,
            output => Acc0
        }
    end.

append_bounded(Acc, Data) ->
    Combined = <<Acc/binary, Data/binary>>,
    case byte_size(Combined) =< ?MAX_OUTPUT_BYTES of
        true -> Combined;
        false -> truncate_binary(Combined, ?MAX_OUTPUT_BYTES)
    end.

step_ok(#{ok := true}) -> true;
step_ok(_) -> false.

strip_utf8_bom(<<239, 187, 191, Rest/binary>>) -> Rest;
strip_utf8_bom(Bin) -> Bin.

strip_outer_markdown_fence(Bin) ->
    Lines0 = binary:split(Bin, <<"\n">>, [global]),
    Lines1 =
        case Lines0 of
            [First | Rest] ->
                case fence_line(First) of
                    true -> Rest;
                    false -> Lines0
                end;
            [] ->
                []
        end,
    join_lines(strip_last_fence(Lines1)).

strip_trailing_markdown_fence(Bin) ->
    join_lines(strip_last_fence(binary:split(Bin, <<"\n">>, [global]))).

strip_last_fence(Lines) ->
    Rev0 = lists:dropwhile(fun(Line) -> trim_binary(Line) =:= <<>> end, lists:reverse(Lines)),
    Rev1 =
        case Rev0 of
            [Last | Rest] ->
                case fence_line(Last) of
                    true -> Rest;
                    false -> Rev0
                end;
            [] ->
                []
        end,
    lists:reverse(Rev1).

fence_line(Line0) ->
    Line = trim_binary(Line0),
    Line =:= <<"```">> orelse
        Line =:= <<"```diff">> orelse
        Line =:= <<"```patch">>.

join_lines([]) -> <<>>;
join_lines(Lines) -> iolist_to_binary(lists:join(<<"\n">>, Lines)).

ensure_final_newline(<<>>) ->
    <<>>;
ensure_final_newline(Bin) ->
    case binary:last(Bin) of
        $\n -> Bin;
        _ -> <<Bin/binary, "\n">>
    end.

paths_from_line(<<"diff --git a/", Rest/binary>>) ->
    case binary:split(Rest, <<" b/">>, []) of
        [A, B] -> [binary_to_list(A), binary_to_list(B)];
        _ -> []
    end;
paths_from_line(<<"--- a/", Path/binary>>) ->
    [clean_path(Path)];
paths_from_line(<<"+++ b/", Path/binary>>) ->
    [clean_path(Path)];
paths_from_line(<<"--- /dev/null", _/binary>>) ->
    [];
paths_from_line(<<"+++ /dev/null", _/binary>>) ->
    [];
paths_from_line(_) ->
    [].

clean_path(Path) ->
    binary_to_list(hd(binary:split(Path, <<"\t">>, []))).

validate_paths([]) ->
    {error, no_patch_paths};
validate_paths(Paths) ->
    case [P || P <- Paths, not allowed_path(P)] of
        [] -> ok;
        Bad -> {error, {patch_path_not_allowed, Bad}}
    end.

allowed_path(Path) ->
    filename:pathtype(Path) =:= relative andalso
        not contains_parent(Path) andalso
        not lists:prefix(".git/", Path) andalso
        lists:any(fun(Prefix) -> lists:prefix(Prefix, Path) end, ?ALLOWED_PREFIXES).

contains_parent(Path) ->
    lists:member("..", filename:split(Path)).

has_binary_patch(Patch) ->
    (binary:match(Patch, <<"GIT binary patch">>) =/= nomatch) orelse
        (binary:match(Patch, <<"Binary files ">>) =/= nomatch).

repo_available(Root) ->
    filelib:is_dir(filename:join(Root, ".git")) orelse
        filelib:is_file(filename:join(Root, ".git")).

repo_root(Opts) ->
    case maps:get(base_commit, Opts, undefined) of
        Commit when is_binary(Commit), byte_size(Commit) > 0 ->
            canonical_or_legacy_repo_root(Commit, Opts);
        Commit when is_list(Commit), Commit =/= [] ->
            canonical_or_legacy_repo_root(Commit, Opts);
        _ ->
            try ecai_source_repository:current(Opts) of
                {ok, #{root := Root}} ->
                    filename:absname(path_to_list(Root));
                _ ->
                    legacy_repo_root(Opts)
            catch
                _:_ ->
                    legacy_repo_root(Opts)
            end
    end.

canonical_or_legacy_repo_root(Commit, Opts) ->
    try ecai_source_repository:base_for_commit(Commit, Opts) of
        {ok, #{root := Root}} ->
            filename:absname(path_to_list(Root));
        _ ->
            legacy_repo_root(Opts)
    catch
        _:_ ->
            legacy_repo_root(Opts)
    end.

legacy_repo_root(Opts) ->
    filename:absname(
        path_to_list(
            maps:get(
                repo_root,
                Opts,
                application:get_env(ecai, code_repo_root, ".")
            )
        )
    ).

command_timeout(Opts) ->
    maps:get(
        command_timeout_ms,
        Opts,
        application:get_env(ecai, code_patch_command_timeout_ms, 300000)
    ).

ensure_dir(Dir) -> filelib:ensure_dir(filename:join(Dir, ".keep")).

module_name_from_path(Path) ->
    to_binary(filename:basename(Path, ".erl")).

list_binaries(List) -> [to_binary(V) || V <- List].

dedupe_preserve(List) ->
    lists:reverse(
        element(
            1,
            lists:foldl(
                fun(Item, {Acc, Seen}) ->
                    case maps:is_key(Item, Seen) of
                        true -> {Acc, Seen};
                        false -> {[Item | Acc], Seen#{Item => true}}
                    end
                end,
                {[], #{}},
                List
            )
        )
    ).

truncate_binary(Bin, Max) when is_binary(Bin), byte_size(Bin) =< Max -> Bin;
truncate_binary(Bin, Max) when is_binary(Bin), Max > 0 ->
    <<Prefix:Max/binary, _/binary>> = Bin,
    Prefix.

trim_binary(Bin) when is_binary(Bin) ->
    unicode:characters_to_binary(string:trim(binary_to_list(Bin))).

maybe_binary(undefined) -> undefined;
maybe_binary(Value) -> to_binary(Value).

sha256_hex(Bin) when is_binary(Bin) ->
    iolist_to_binary(
        [
            io_lib:format("~2.16.0b", [Byte])
         || <<Byte>> <= crypto:hash(sha256, Bin)
        ]
    ).

now_iso8601() ->
    to_binary(
        calendar:system_time_to_rfc3339(
            erlang:system_time(second), [{unit, second}, {offset, "Z"}]
        )
    ).

path_to_list(P) when is_list(P) -> P;
path_to_list(P) when is_binary(P) -> binary_to_list(P);
path_to_list(P) when is_atom(P) -> atom_to_list(P).

to_binary(B) when is_binary(B) -> B;
to_binary(L) when is_list(L) -> unicode:characters_to_binary(L);
to_binary(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_binary(I) when is_integer(I) -> integer_to_binary(I);
to_binary(V) -> iolist_to_binary(io_lib:format("~p", [V])).
