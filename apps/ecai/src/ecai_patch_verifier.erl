-module(ecai_patch_verifier).

-export([verify/1, verify/2, validate_patch/1]).

-define(ALLOWED_PREFIXES, ["apps/damage/", "apps/ecai/", "apps/erm/"]).
-define(MAX_OUTPUT_BYTES, 200000).

verify(PatchFile) -> verify(PatchFile, #{}).

verify(PatchFile0, Opts) ->
    PatchFile = filename:absname(path_to_list(PatchFile0)),
    case file:read_file(PatchFile) of
        {error, Reason} -> {error, {cannot_read_patch, PatchFile, Reason}};
        {ok, Patch} ->
            case validate_patch(Patch) of
                ok -> verify_valid_patch(PatchFile, Opts);
                {error, _} = Error -> Error
            end
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

verify_valid_patch(PatchFile, Opts) ->
    RepoRoot = repo_root(Opts),
    case repo_available(RepoRoot) of
        false -> {error, {git_repository_not_found, RepoRoot}};
        true ->
            case ecai_code_paths:state_root(Opts) of
                {error, _} = Error -> Error;
                {ok, StateRoot} ->
                    WorkRoot = ecai_code_paths:worktree_root(StateRoot),
                    Id = integer_to_list(erlang:unique_integer([positive, monotonic])),
                    Worktree = filename:join(WorkRoot, "repair-" ++ Id),
                    run_verification(RepoRoot, Worktree, PatchFile, Opts)
            end
    end.

run_verification(RepoRoot, Worktree, PatchFile, Opts) ->
    Started = now_iso8601(),
    Add = run("git", ["-C", RepoRoot, "worktree", "add", "--detach", Worktree, "HEAD"],
              RepoRoot, command_timeout(Opts)),
    case step_ok(Add) of
        false -> {error, {cannot_create_worktree, Add}};
        true ->
            Steps0 = [#{step => worktree_add, result => Add}],
            {Status, Steps} = verify_steps(Worktree, PatchFile, Opts, Steps0),
            Keep = maps:get(keep_worktree, Opts,
                application:get_env(ecai, code_patch_keep_worktree, false)),
            Cleanup = case Keep of
                true -> #{kept => true, path => to_binary(Worktree)};
                false -> cleanup_worktree(RepoRoot, Worktree, Opts)
            end,
            Result = #{
                status => Status,
                patch_file => to_binary(PatchFile),
                worktree => to_binary(Worktree),
                started_at => Started,
                completed_at => now_iso8601(),
                steps => Steps,
                cleanup => Cleanup
            },
            {ok, Result}
    end.

verify_steps(Worktree, PatchFile, Opts, Steps0) ->
    Timeout = command_timeout(Opts),
    Specs0 = [
        {apply_check, "git", ["-C", Worktree, "apply", "--check", PatchFile]},
        {apply, "git", ["-C", Worktree, "apply", PatchFile]},
        {diff_check, "git", ["-C", Worktree, "diff", "--check"]},
        {compile, "rebar3", ["compile"]}
    ],
    Specs = case maps:get(run_eunit, Opts,
                          application:get_env(ecai, code_patch_run_eunit, true)) of
        true -> Specs0 ++ [{eunit, "rebar3", ["eunit"]}];
        false -> Specs0
    end,
    run_specs(Specs, Worktree, Timeout, Steps0).

run_specs([], _Cwd, _Timeout, Steps) -> {validated, Steps};
run_specs([{Name, Exe, Args} | Rest], Cwd, Timeout, Steps0) ->
    Result = run(Exe, Args, Cwd, Timeout),
    Steps = Steps0 ++ [#{step => Name, result => Result}],
    case step_ok(Result) of
        true -> run_specs(Rest, Cwd, Timeout, Steps);
        false -> {failed, Steps}
    end.

cleanup_worktree(RepoRoot, Worktree, Opts) ->
    Result = run("git", ["-C", RepoRoot, "worktree", "remove", "--force", Worktree],
                 RepoRoot, command_timeout(Opts)),
    #{kept => false, result => Result}.

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
        false ->
            Keep = ?MAX_OUTPUT_BYTES,
            <<Prefix:Keep/binary, _/binary>> = Combined,
            Prefix
    end.

step_ok(#{ok := true}) -> true;
step_ok(_) -> false.

patch_paths(Patch) ->
    Lines = binary:split(Patch, <<"\n">>, [global]),
    %% paths_from_line/1 returns a list of filename charlists. Flattening that
    %% result would turn each path into individual integer characters.
    lists:usort(lists:append([paths_from_line(Line) || Line <- Lines])).

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
    filelib:is_dir(filename:join(Root, ".git")) orelse filelib:is_file(filename:join(Root, ".git")).

repo_root(Opts) ->
    filename:absname(path_to_list(maps:get(repo_root, Opts,
        application:get_env(ecai, code_repo_root, ".")))).

command_timeout(Opts) ->
    maps:get(command_timeout_ms, Opts,
        application:get_env(ecai, code_patch_command_timeout_ms, 300000)).

list_binaries(List) -> [to_binary(V) || V <- List].

now_iso8601() ->
    to_binary(calendar:system_time_to_rfc3339(
        erlang:system_time(second), [{unit, second}, {offset, "Z"}]
    )).

path_to_list(P) when is_list(P) -> P;
path_to_list(P) when is_binary(P) -> binary_to_list(P).

to_binary(B) when is_binary(B) -> B;
to_binary(L) when is_list(L) -> unicode:characters_to_binary(L);
to_binary(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_binary(I) when is_integer(I) -> integer_to_binary(I);
to_binary(V) -> iolist_to_binary(io_lib:format("~p", [V])).
