-module(ecai_patch_verifier).

-export([
    verify/1,
    verify/2,
    verify_patchset/1,
    verify_patchset/2,
    validate_patch/1,
    patch_paths/1,
    cleanup_stale/0,
    cleanup_stale/1
]).

-define(ALLOWED_PREFIXES, ["apps/damage/", "apps/ecai/", "apps/erm/"]).
-define(MAX_OUTPUT_BYTES, 300000).
-define(MAX_SOURCE_BYTES, 65536).

verify(PatchFile) -> verify(PatchFile, #{}).

cleanup_stale() -> cleanup_stale(#{}).

cleanup_stale(Opts) ->
    Keep = maps:get(keep_worktree, Opts,
        application:get_env(ecai, code_patch_keep_worktree, false)),
    case Keep of
        true -> {ok, #{skipped => keep_worktree_enabled}};
        false ->
            RepoRoot = repo_root(Opts),
            case repo_available(RepoRoot) of
                false -> {error, {git_repository_not_found, RepoRoot}};
                true ->
                    case ecai_code_paths:state_root(Opts) of
                        {error, _} = Error -> Error;
                        {ok, StateRoot} ->
                            WorkRoot = ecai_code_paths:worktree_root(StateRoot),
                            Results = cleanup_stale_dirs(RepoRoot, WorkRoot, "repair-", Opts),
                            Prune = run("git", ["-C", RepoRoot, "worktree", "prune"],
                                        RepoRoot, command_timeout(Opts)),
                            {ok, #{worktrees => Results, prune => Prune}}
                    end
            end
    end.

verify(PatchFile0, Opts) when is_map(Opts) ->
    PatchFile = filename:absname(path_to_list(PatchFile0)),
    Preapply = [filename:absname(path_to_list(P)) ||
                   P <- maps:get(preapply_patch_files, Opts, [])],
    verify_patchset(Preapply ++ [PatchFile], Opts#{candidate_patch_file => PatchFile}).

verify_patchset(PatchFiles) -> verify_patchset(PatchFiles, #{}).

verify_patchset([], _Opts) -> {error, no_patch_files};
verify_patchset(PatchFiles0, Opts) when is_list(PatchFiles0), is_map(Opts) ->
    PatchFiles = dedupe_preserve([filename:absname(path_to_list(P)) || P <- PatchFiles0]),
    case validate_patch_files(PatchFiles) of
        ok -> verify_valid_patchset(PatchFiles, Opts);
        {error, _} = Error -> Error
    end.

validate_patch(Patch) when is_binary(Patch) ->
    case byte_size(Patch) of
        0 -> {error, empty_patch};
        _ ->
            case has_binary_patch(Patch) of
                true -> {error, binary_patches_not_allowed};
                false -> validate_paths(patch_paths(Patch))
            end
    end.

patch_paths(Patch) when is_binary(Patch) ->
    Lines = binary:split(Patch, <<"\n">>, [global]),
    lists:usort(lists:append([paths_from_line(Line) || Line <- Lines])).

validate_patch_files([]) -> ok;
validate_patch_files([PatchFile | Rest]) ->
    case file:read_file(PatchFile) of
        {error, Reason} -> {error, {cannot_read_patch, PatchFile, Reason}};
        {ok, Patch} ->
            case validate_patch(Patch) of
                ok -> validate_patch_files(Rest);
                {error, Reason} -> {error, {invalid_patch_file, PatchFile, Reason}}
            end
    end.

verify_valid_patchset(PatchFiles, Opts) ->
    RepoRoot = repo_root(Opts),
    case repo_available(RepoRoot) of
        false -> {error, {git_repository_not_found, RepoRoot}};
        true ->
            case resolve_base_commit(RepoRoot, Opts) of
                {error, _} = Error -> Error;
                {ok, BaseCommit} ->
                    case ecai_code_paths:state_root(Opts) of
                        {error, _} = Error -> Error;
                        {ok, StateRoot} ->
                            WorkRoot0 = maps:get(worktree_root, Opts,
                                ecai_code_paths:worktree_root(StateRoot)),
                            WorkRoot = path_to_list(WorkRoot0),
                            ok = ensure_dir(WorkRoot),
                            Prefix = path_to_list(maps:get(worktree_prefix, Opts, "repair")),
                            Id = integer_to_list(erlang:system_time(microsecond)) ++ "-" ++
                                 integer_to_list(erlang:unique_integer([positive, monotonic])),
                            Worktree = filename:join(WorkRoot, Prefix ++ "-" ++ Id),
                            run_verification(RepoRoot, Worktree, BaseCommit,
                                             PatchFiles, StateRoot, Opts)
                    end
            end
    end.

run_verification(RepoRoot, Worktree, BaseCommit, PatchFiles, _StateRoot, Opts) ->
    Started = now_iso8601(),
    Add = run("git", ["-C", RepoRoot, "worktree", "add", "--detach",
                      Worktree, binary_to_list(BaseCommit)],
              RepoRoot, command_timeout(Opts)),
    case step_ok(Add) of
        false -> {error, {cannot_create_worktree, BaseCommit, Add}};
        true ->
            Steps0 = [#{step => worktree_add, result => Add}],
            {Status, Steps1, Failure} = apply_patchset(Worktree, PatchFiles, 1,
                                                       command_timeout(Opts), Steps0),
            {FinalStatus, Steps, FinalFailure} = case Status of
                failed -> {failed, Steps1, Failure};
                applied -> run_validation_steps(Worktree, Opts, Steps1)
            end,
            FailureSources = case FinalStatus of
                failed -> capture_failure_sources(Worktree, FinalFailure, PatchFiles);
                validated -> []
            end,
            Keep = maps:get(keep_worktree, Opts,
                application:get_env(ecai, code_patch_keep_worktree, false)),
            Cleanup = case Keep of
                true -> #{kept => true, path => to_binary(Worktree)};
                false -> cleanup_worktree(RepoRoot, Worktree, Opts)
            end,
            Result = #{
                status => FinalStatus,
                base_commit => BaseCommit,
                patch_files => [to_binary(P) || P <- PatchFiles],
                candidate_patch_file => maybe_binary(maps:get(candidate_patch_file, Opts, undefined)),
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
    Check = run("git", ["-C", Worktree, "apply", "--check", PatchFile],
                Worktree, Timeout),
    CheckStep = #{step => patch_apply_check, patch_index => Index,
                  patch_file => to_binary(PatchFile), result => Check},
    Steps1 = Steps0 ++ [CheckStep],
    case step_ok(Check) of
        false ->
            %% A repair may already have been committed to the selected base.
            %% Treat an exact reverse-applicable patch as already present rather
            %% than as an integration conflict.
            Reverse = run("git", ["-C", Worktree, "apply", "--reverse", "--check", PatchFile],
                          Worktree, Timeout),
            ReverseStep = #{step => patch_reverse_check, patch_index => Index,
                            patch_file => to_binary(PatchFile), result => Reverse},
            Steps2 = Steps1 ++ [ReverseStep],
            case step_ok(Reverse) of
                true ->
                    PresentStep = #{step => patch_already_present, patch_index => Index,
                                    patch_file => to_binary(PatchFile),
                                    result => #{ok => true}},
                    apply_patchset(Worktree, Rest, Index + 1, Timeout,
                                   Steps2 ++ [PresentStep]);
                false ->
                    {failed, Steps2, #{phase => patch_apply_check, patch_index => Index,
                                      patch_file => to_binary(PatchFile),
                                      result => Check, reverse_check => Reverse}}
            end;
        true ->
            Apply = run("git", ["-C", Worktree, "apply", PatchFile], Worktree, Timeout),
            ApplyStep = #{step => patch_apply, patch_index => Index,
                          patch_file => to_binary(PatchFile), result => Apply},
            Steps2 = Steps1 ++ [ApplyStep],
            case step_ok(Apply) of
                true -> apply_patchset(Worktree, Rest, Index + 1, Timeout, Steps2);
                false ->
                    {failed, Steps2, #{phase => patch_apply, patch_index => Index,
                                      patch_file => to_binary(PatchFile), result => Apply}}
            end
    end.

run_validation_steps(Worktree, Opts, Steps0) ->
    Timeout = command_timeout(Opts),
    Specs0 = [
        {diff_check, "git", ["-C", Worktree, "diff", "--check"]},
        {compile, "rebar3", ["compile"]}
    ],
    Specs1 = case maps:get(run_eunit, Opts,
                           application:get_env(ecai, code_patch_run_eunit, true)) of
        true -> Specs0 ++ [{eunit, "rebar3", ["eunit"]}];
        false -> Specs0
    end,
    Specs2 = case maps:get(run_ct, Opts,
                           application:get_env(ecai, code_patch_run_ct, false)) of
        true -> Specs1 ++ [{ct, "rebar3", ["ct"]}];
        false -> Specs1
    end,
    Extra = maps:get(extra_commands, Opts, []),
    run_specs(Specs2 ++ normalize_extra_commands(Extra), Worktree, Timeout, Steps0).

run_specs([], _Cwd, _Timeout, Steps) -> {validated, Steps, undefined};
run_specs([{Name, Exe, Args} | Rest], Cwd, Timeout, Steps0) ->
    Result = run(Exe, Args, Cwd, Timeout),
    Step = #{step => Name, result => Result},
    Steps = Steps0 ++ [Step],
    case step_ok(Result) of
        true -> run_specs(Rest, Cwd, Timeout, Steps);
        false -> {failed, Steps, #{phase => Name, result => Result}}
    end.

normalize_extra_commands(List) when is_list(List) ->
    lists:filtermap(fun
        ({Name, Exe, Args}) when is_atom(Name), is_list(Args) ->
            {true, {Name, path_to_list(Exe), [path_to_list(A) || A <- Args]}};
        (_) -> false
    end, List);
normalize_extra_commands(_) -> [].

capture_failure_sources(Worktree, Failure, PatchFiles) ->
    Paths0 = failure_paths(Failure),
    Paths1 = case Paths0 of
        [] -> patchset_paths(PatchFiles);
        _ -> Paths0
    end,
    Paths = lists:sublist(lists:usort([P || P <- Paths1, allowed_path(P),
                                           filename:extension(P) =:= ".erl"]), 4),
    lists:filtermap(fun(RelPath) ->
        Full = filename:join(Worktree, RelPath),
        case file:read_file(Full) of
            {ok, Source0} ->
                Source = truncate_binary(Source0, ?MAX_SOURCE_BYTES),
                {true, #{path => to_binary(RelPath), source => Source,
                         module => module_name_from_path(RelPath)}};
            {error, _} -> false
        end
    end, Paths).

failure_paths(undefined) -> [];
failure_paths(Failure) when is_map(Failure) ->
    Result = maps:get(result, Failure, #{}),
    Output = maps:get(output, Result, <<>>),
    paths_from_output(Output);
failure_paths(_) -> [].

paths_from_output(Output) when is_binary(Output) ->
    Pattern = <<"(apps/(?:damage|ecai|erm)/(?:src|test|tests)/[^\\s:]+\\.erl)">>,
    case re:run(Output, Pattern, [global, {capture, [1], binary}]) of
        {match, Matches} -> lists:usort([binary_to_list(P) || [P] <- Matches]);
        nomatch -> []
    end;
paths_from_output(_) -> [].

patchset_paths(PatchFiles) ->
    lists:usort(lists:append([case file:read_file(P) of
        {ok, Bin} -> patch_paths(Bin);
        _ -> []
    end || P <- PatchFiles])).


cleanup_stale_dirs(RepoRoot, WorkRoot, Prefix, Opts) ->
    case file:list_dir(WorkRoot) of
        {ok, Names} ->
            [cleanup_stale_dir(RepoRoot, WorkRoot, Name, Opts)
             || Name <- Names, lists:prefix(Prefix, Name)];
        {error, enoent} -> [];
        {error, Reason} -> [#{ok => false, error => {cannot_list_worktree_root, Reason}}]
    end.

cleanup_stale_dir(RepoRoot, WorkRoot, Name, Opts) ->
    Path = filename:join(WorkRoot, Name),
    GitResult = run("git", ["-C", RepoRoot, "worktree", "remove", "--force", Path],
                    RepoRoot, command_timeout(Opts)),
    #{path => to_binary(Path), git => GitResult, still_present => filelib:is_dir(Path)}.

cleanup_worktree(RepoRoot, Worktree, Opts) ->
    Remove = run("git", ["-C", RepoRoot, "worktree", "remove", "--force", Worktree],
                 RepoRoot, command_timeout(Opts)),
    Prune = run("git", ["-C", RepoRoot, "worktree", "prune"],
                RepoRoot, command_timeout(Opts)),
    #{kept => false, remove => Remove, prune => Prune}.

resolve_base_commit(RepoRoot, Opts) ->
    Base0 = maps:get(base_commit, Opts, "HEAD"),
    Base = path_to_list(Base0),
    VerifyArg = Base ++ "^{commit}",
    Result = run("git", ["-C", RepoRoot, "rev-parse", "--verify", "--end-of-options", VerifyArg],
                 RepoRoot, command_timeout(Opts)),
    case Result of
        #{ok := true, output := Output} -> {ok, trim_binary(Output)};
        _ -> {error, {invalid_base_commit, Base0, Result}}
    end.

run(ExeName, Args, Cwd, Timeout) ->
    case os:find_executable(ExeName) of
        false -> #{ok => false, executable => to_binary(ExeName), error => executable_not_found};
        Exe ->
            Port = open_port({spawn_executable, Exe}, [binary, exit_status, stderr_to_stdout,
                {args, Args}, {cd, Cwd}]),
            collect_port(Port, <<>>, Timeout, ExeName, Args)
    end.

collect_port(Port, Acc0, Timeout, ExeName, Args) ->
    receive
        {Port, {data, Data}} ->
            Acc = append_bounded(Acc0, Data),
            collect_port(Port, Acc, Timeout, ExeName, Args);
        {Port, {exit_status, 0}} ->
            #{ok => true, executable => to_binary(ExeName), args => list_binaries(Args),
              output => Acc0};
        {Port, {exit_status, Status}} ->
            #{ok => false, executable => to_binary(ExeName), args => list_binaries(Args),
              exit_status => Status, output => Acc0}
    after Timeout ->
        catch port_close(Port),
        #{ok => false, executable => to_binary(ExeName), args => list_binaries(Args),
          error => timeout, output => Acc0}
    end.

append_bounded(Acc, Data) ->
    Combined = <<Acc/binary, Data/binary>>,
    case byte_size(Combined) =< ?MAX_OUTPUT_BYTES of
        true -> Combined;
        false -> truncate_binary(Combined, ?MAX_OUTPUT_BYTES)
    end.

step_ok(#{ok := true}) -> true;
step_ok(_) -> false.

paths_from_line(<<"diff --git a/", Rest/binary>>) ->
    case binary:split(Rest, <<" b/">>, []) of
        [A, B] -> [binary_to_list(A), binary_to_list(B)];
        _ -> []
    end;
paths_from_line(<<"--- a/", Path/binary>>) -> [clean_path(Path)];
paths_from_line(<<"+++ b/", Path/binary>>) -> [clean_path(Path)];
paths_from_line(<<"--- /dev/null", _/binary>>) -> [];
paths_from_line(<<"+++ /dev/null", _/binary>>) -> [];
paths_from_line(_) -> [].

clean_path(Path) ->
    binary_to_list(hd(binary:split(Path, <<"\t">>, []))).

validate_paths([]) -> {error, no_patch_paths};
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
    filename:absname(path_to_list(maps:get(repo_root, Opts,
        application:get_env(ecai, code_repo_root, ".")))).

command_timeout(Opts) ->
    maps:get(command_timeout_ms, Opts,
        application:get_env(ecai, code_patch_command_timeout_ms, 300000)).

ensure_dir(Dir) -> filelib:ensure_dir(filename:join(Dir, ".keep")).

module_name_from_path(Path) ->
    to_binary(filename:basename(Path, ".erl")).

list_binaries(List) -> [to_binary(V) || V <- List].

dedupe_preserve(List) ->
    lists:reverse(element(1, lists:foldl(fun(Item, {Acc, Seen}) ->
        case maps:is_key(Item, Seen) of
            true -> {Acc, Seen};
            false -> {[Item | Acc], Seen#{Item => true}}
        end
    end, {[], #{}}, List))).

truncate_binary(Bin, Max) when is_binary(Bin), byte_size(Bin) =< Max -> Bin;
truncate_binary(Bin, Max) when is_binary(Bin), Max > 0 ->
    <<Prefix:Max/binary, _/binary>> = Bin,
    Prefix.

trim_binary(Bin) when is_binary(Bin) ->
    unicode:characters_to_binary(string:trim(binary_to_list(Bin))).

maybe_binary(undefined) -> undefined;
maybe_binary(Value) -> to_binary(Value).

now_iso8601() ->
    to_binary(calendar:system_time_to_rfc3339(
        erlang:system_time(second), [{unit, second}, {offset, "Z"}]
    )).

path_to_list(P) when is_list(P) -> P;
path_to_list(P) when is_binary(P) -> binary_to_list(P);
path_to_list(P) when is_atom(P) -> atom_to_list(P).

to_binary(B) when is_binary(B) -> B;
to_binary(L) when is_list(L) -> unicode:characters_to_binary(L);
to_binary(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_binary(I) when is_integer(I) -> integer_to_binary(I);
to_binary(V) -> iolist_to_binary(io_lib:format("~p", [V])).
