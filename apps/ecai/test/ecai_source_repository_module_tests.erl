-module(ecai_source_repository_module_tests).

-include_lib("eunit/include/eunit.hrl").

canonical_module_enumeration_excludes_runtime_only_modules_test() ->
    with_repo(
        fun(Repo, StateRoot) ->
            Opts = #{repo_root => Repo, state_root => StateRoot},
            {ok, Base} = ecai_source_repository:refresh(Opts),
            Commit = maps:get(commit, Base),
            {ok, Modules} =
                ecai_source_repository:application_modules_at_commit(
                    ecai, Commit, Opts),
            ?assert(lists:member(sample, Modules)),
            ?assert(lists:member(nested_sample, Modules)),
            ?assertNot(lists:member(runtime_only_module, Modules))
        end
    ).

nested_module_source_is_resolved_test() ->
    with_repo(
        fun(Repo, StateRoot) ->
            Opts = #{repo_root => Repo, state_root => StateRoot},
            {ok, Base} = ecai_source_repository:refresh(Opts),
            Commit = maps:get(commit, Base),
            {ok, Meta} =
                ecai_source_repository:module_source_at_commit(
                    ecai, nested_sample, Commit, Opts),
            ?assertEqual(
                <<"apps/ecai/src/nested/nested_sample.erl">>,
                maps:get(source_path, Meta)
            ),
            ?assertEqual(
                <<"-module(nested_sample).\nvalue() -> nested.\n">>,
                maps:get(source, Meta)
            )
        end
    ).

with_repo(Fun) ->
    N = integer_to_list(
        erlang:unique_integer([positive, monotonic])),
    Root = filename:join("/tmp", "ecai_source_modules_" ++ N),
    Repo = filename:join(Root, "dev"),
    StateRoot = filename:join(Root, "state"),
    Src = filename:join([Repo, "apps", "ecai", "src"]),
    Nested = filename:join(Src, "nested"),
    ok = filelib:ensure_dir(filename:join(Nested, "dummy")),
    ok = file:write_file(
        filename:join(Src, "sample.erl"),
        <<"-module(sample).\nvalue() -> one.\n">>
    ),
    ok = file:write_file(
        filename:join(Nested, "nested_sample.erl"),
        <<"-module(nested_sample).\nvalue() -> nested.\n">>
    ),
    ok = git(Repo, ["init", "-q"]),
    ok = git(Repo, ["config", "user.email", "ecai@example.invalid"]),
    ok = git(Repo, ["config", "user.name", "ECAI"]),
    ok = git(Repo, ["add", "."]),
    ok = git(Repo, ["commit", "-qm", "base"]),
    try
        Fun(Repo, StateRoot)
    after
        _ = file:del_dir_r(Root)
    end.

git(Repo, Args) ->
    case os:find_executable("git") of
        false ->
            erlang:error(git_not_found);
        Git ->
            Port = open_port(
                {spawn_executable, Git},
                [
                    binary,
                    exit_status,
                    stderr_to_stdout,
                    {args, ["-C", Repo | Args]},
                    {cd, Repo}
                ]
            ),
            collect_git(Port, <<>>)
    end.

collect_git(Port, Acc) ->
    receive
        {Port, {data, Data}} ->
            collect_git(Port, <<Acc/binary, Data/binary>>);
        {Port, {exit_status, 0}} ->
            ok;
        {Port, {exit_status, Status}} ->
            erlang:error({git_failed, Status, Acc})
    after 30000 ->
        try port_close(Port)
        catch _:_ -> ok
        end,
        erlang:error(git_timeout)
    end.
