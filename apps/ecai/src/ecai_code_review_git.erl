%% Publish a pinned, approved ECAI patch to a configured review remote/branch.
%% Never checks out or commits in the operator's working tree; never force-pushes.
-module(ecai_code_review_git).
-export([publish/1]).

-define(TIMEOUT, 60000).

publish(Review) ->
    Id = maps:get(id, Review),
    Patch = maps:get(patch, Review),
    Sha = maps:get(patch_sha256, Review),
    Base = maps:get(base_commit, Review),
    ReviewConfig = ecai_code_runtime_config:review_config(),
    case
        {
            maps:get(push_enabled, ReviewConfig, false),
            maps:get(repo_root, ReviewConfig, undefined)
        }
    of
        {true, Repo0} when Repo0 =/= undefined ->
            Repo = filename:absname(to_list(Repo0)),
            case repo_preflight(Repo, Base, Patch, Sha) of
                ok ->
                    case ecai_code_paths:state_root() of
                        {ok, Root} ->
                            do_publish(Repo, Root, Id, Base, Patch, Sha);
                        {error, Reason} ->
                            {error, {state_root_unavailable, Reason}}
                    end;
                Error ->
                    Error
            end;
        _ ->
            {error, publication_not_configured}
    end.

repo_preflight(Repo, Base, Patch, Sha) ->
    case ecai_patch_verifier:validate_patch(Patch) of
        ok ->
            case hash(Patch) =:= Sha andalso valid_commit(Base) of
                false ->
                    {error, patch_integrity_failed};
                true ->
                    case ecai_repair_git:head(Repo) of
                        {ok, Base} ->
                            case git(Repo, ["remote", "get-url", "--push", review_remote()]) of
                                {ok, _} -> ok;
                                _ -> {error, review_remote_unavailable}
                            end;
                        {ok, _Other} ->
                            {error, stale_base_commit};
                        _ ->
                            {error, git_repository_unavailable}
                    end
            end;
        _ ->
            {error, invalid_patch}
    end.

do_publish(Repo, Root, Id, Base, Patch, Sha) ->
    Dir = filename:join([Root, "git", "security", "reviews"]),
    PatchFile = filename:join(Dir, binary_to_list(Id) ++ ".patch"),
    Worktree = filename:join([Dir, "worktrees", binary_to_list(Id)]),
    Prefix = review_branch_prefix(),
    RemoteRef = <<"refs/heads/", Prefix/binary, Id/binary>>,
    case filelib:ensure_dir(PatchFile) of
        ok ->
            case freeze_patch(PatchFile, Patch, Sha) of
                ok ->
                    case existing_remote(Repo, RemoteRef) of
                        absent ->
                            verify_and_push(Repo, Root, Worktree, PatchFile, Base, Sha, RemoteRef);
                        present ->
                            {error, remote_review_branch_exists};
                        {error, Reason} ->
                            {error, {remote_preflight_failed, Reason}}
                    end;
                Error ->
                    Error
            end;
        {error, Reason} ->
            {error, {review_path_unavailable, Reason}}
    end.

freeze_patch(File, Patch, Sha) ->
    case file:read_file(File) of
        {ok, Existing} ->
            case hash(Existing) =:= Sha andalso Existing =:= Patch of
                true -> ok;
                false -> {error, review_patch_file_conflict}
            end;
        {error, enoent} ->
            case file:open(File, [write, raw, binary, exclusive]) of
                {ok, Io} ->
                    Result = file:write(Io, Patch),
                    Sync = file:sync(Io),
                    Close = file:close(Io),
                    _ = file:change_mode(File, 8#600),
                    case {Result, Sync, Close} of
                        {ok, ok, ok} -> ok;
                        _ -> {error, review_patch_write_failed}
                    end;
                {error, eexist} ->
                    {error, concurrent_review_patch_file};
                _ ->
                    {error, review_patch_write_failed}
            end;
        _ ->
            {error, review_patch_read_failed}
    end.

existing_remote(Repo, Branch) ->
    case git(
        Repo,
        ["-c", "core.askPass=/bin/false", "ls-remote", "--heads", review_remote(), Branch]
    ) of
        {ok, <<>>} -> absent;
        {ok, _} -> present;
        _ -> {error, cannot_query_review_remote}
    end.

verify_and_push(Repo, Root, Worktree, PatchFile, Base, Sha, Branch) ->
    %% Force a fresh compile and test in the verifier's isolated Git worktree,
    %% independently of the original worker's old result.
    Review = ecai_code_runtime_config:review_config(),
    Opts = #{
        repo_root => Repo,
        state_root => Root,
        base_commit => Base,
        keep_worktree => false,
        run_eunit => maps:get(run_eunit, Review, true),
        run_ct => maps:get(run_ct, Review, false),
        command_timeout_ms => maps:get(verify_timeout_ms, Review, 600000)
    },
    case ecai_patch_verifier:verify_patchset([PatchFile], Opts) of
        {ok, #{status := validated}} ->
            case filelib:ensure_dir(filename:join(Worktree, ".keep")) of
                ok ->
                    case git(Repo, ["worktree", "add", "--detach", Worktree, Base]) of
                        {ok, _} ->
                            try
                                prepare_commit_push(Repo, Worktree, PatchFile, Base, Sha, Branch)
                            after
                                %% Worktree is disposable; never touch operator checkout.
                                _ = git(Repo, ["worktree", "remove", "--force", Worktree])
                            end;
                        _ ->
                            {error, create_review_worktree_failed}
                    end;
                _ ->
                    {error, review_worktree_unavailable}
            end;
        {ok, _} ->
            {error, verification_failed};
        {error, _} ->
            {error, verifier_unavailable}
    end.

prepare_commit_push(Repo, Worktree, PatchFile, Base, Sha, Branch) ->
    case file:read_file(PatchFile) of
        {ok, Patch} ->
            case hash(Patch) =:= Sha of
                false ->
                    {error, patch_changed_during_verification};
                true ->
                    case git(Worktree, ["apply", "--check", "--recount", PatchFile]) of
                        {ok, _} -> apply_and_commit(Repo, Worktree, PatchFile, Base, Sha, Branch);
                        _ -> {error, patch_no_longer_applies}
                    end
            end;
        _ ->
            {error, patch_file_missing}
    end.

apply_and_commit(Repo, Worktree, PatchFile, Base, Sha, Branch) ->
    case git(Worktree, ["apply", "--index", "--recount", PatchFile]) of
        {ok, _} ->
            case git(Worktree, ["diff", "--cached", "--check"]) of
                {ok, _} ->
                    case git(Worktree, ["diff", "--cached", "--name-only"]) of
                        {ok, Changed} when byte_size(Changed) > 0 ->
                            %% Disable local hooks for a model-authored change;
                            %% commit identity is an explicit service identity.
                            Message =
                                "fix(ecai): reviewed repair " ++
                                    binary_to_list(binary:part(Sha, 0, 12)),
                            Provenance =
                                "ECAI-Review-Branch: " ++ binary_to_list(Branch) ++
                                    "\nPatch-SHA256: " ++ binary_to_list(Sha) ++
                                    "\nBase-Commit: " ++ binary_to_list(Base),
                            CommitArgs = [
                                "-c",
                                "core.hooksPath=/dev/null",
                                "-c",
                                "commit.gpgSign=false",
                                "-c",
                                "user.name=ECAI Review Queue",
                                "-c",
                                "user.email=ecai-review@localhost",
                                "commit",
                                "--no-verify",
                                "-m",
                                Message,
                                "-m",
                                Provenance
                            ],
                            case git(Worktree, CommitArgs) of
                                {ok, _} -> push_commit(Repo, Worktree, Base, Sha, Branch);
                                _ -> {error, review_commit_failed}
                            end;
                        _ ->
                            {error, empty_review_diff}
                    end;
                _ ->
                    {error, staged_patch_checks_failed}
            end;
        _ ->
            {error, patch_apply_failed}
    end.

push_commit(Repo, Worktree, Base, Sha, Branch) ->
    %% HEAD may have advanced during the independent verifier run.
    case ecai_repair_git:head(Repo) of
        {ok, Base} -> push_committed_review(Repo, Worktree, Base, Sha, Branch);
        _ -> {error, stale_base_commit}
    end.

push_committed_review(Repo, Worktree, Base, Sha, Branch) ->
    case ecai_repair_git:head(Worktree) of
        {ok, Commit} ->
            %% Do not recreate an existing branch, even when a previous push
            %% completed but the server lost the response.
            case existing_remote(Repo, Branch) of
                absent ->
                    RefSpec = <<Commit/binary, ":", Branch/binary>>,
                    case
                        git(
                            Repo,
                            [
                                "-c",
                                "core.askPass=/bin/false",
                                "push",
                                "--porcelain",
                                "--no-verify",
                                review_remote(),
                                RefSpec
                            ],
                            120000
                        )
                    of
                        {ok, _} ->
                            {ok, #{
                                remote => to_binary(review_remote()),
                                branch => Branch,
                                commit => Commit,
                                base_commit => Base,
                                patch_sha256 => Sha,
                                tests => <<"verified before commit">>
                            }};
                        _ ->
                            {error, {push_uncertain, check_review_branch}}
                    end;
                _ ->
                    {error, {push_uncertain, remote_branch_changed}}
            end;
        _ ->
            {error, review_commit_unavailable}
    end.

review_remote() ->
    to_list(maps:get(remote, ecai_code_runtime_config:review_config(), <<"origin">>)).

review_branch_prefix() ->
    to_binary(
        maps:get(branch_prefix, ecai_code_runtime_config:review_config(), <<"ecai/reviews/">>)
    ).

git(Repo, Args) -> git(Repo, Args, ?TIMEOUT).
git(Repo, Args, Timeout) -> ecai_repair_git:run(Repo, Args, Timeout).
valid_commit(C) when is_binary(C) ->
    (byte_size(C) =:= 40 orelse byte_size(C) =:= 64) andalso
        lists:all(
            fun(X) ->
                (X >= $0 andalso X =< $9) orelse
                    (X >= $a andalso X =< $f)
            end,
            binary_to_list(C)
        );
valid_commit(_) ->
    false.
hash(Patch) ->
    iolist_to_binary([
        io_lib:format("~2.16.0b", [N])
     || <<N:8>> <= crypto:hash(sha256, Patch)
    ]).
to_list(A) when is_binary(A) -> binary_to_list(A);
to_list(A) when is_list(A) -> A;
to_list(A) when is_atom(A) -> atom_to_list(A).
to_binary(A) when is_binary(A) -> A;
to_binary(A) when is_list(A) -> unicode:characters_to_binary(A);
to_binary(A) when is_atom(A) -> atom_to_binary(A, utf8).
