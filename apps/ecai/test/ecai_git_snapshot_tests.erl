-module(ecai_git_snapshot_tests).

-include_lib("eunit/include/eunit.hrl").

tracked_source_matches_base_test() ->
    with_repo(fun(Repo, Source, Commit) ->
        Analysis = analysis(Source, <<"one\n">>),
        Context = #{source => <<"one\n">>, analysis => Analysis},
        {ok, Pinned} = ecai_git_snapshot:pin_context(
            Context, #{repo_root => Repo, base_commit => Commit}
        ),
        ?assertEqual(Commit, maps:get(base_commit, Pinned)),
        ?assertEqual(
            <<"apps/ecai/src/sample.erl">>,
            maps:get(source_path, Pinned)
        ),
        ?assertEqual(<<"one\n">>, maps:get(source, Pinned))
    end).

untracked_source_is_rejected_test() ->
    with_repo(fun(Repo, _Tracked, Commit) ->
        Source = filename:join(
            [Repo, "apps", "ecai", "src", "untracked.erl"]
        ),
        ok = file:write_file(Source, <<"untracked\n">>),
        Analysis = analysis(Source, <<"untracked\n">>),
        ?assertMatch(
            {error, #{kind := source_not_in_base_commit}},
            ecai_git_snapshot:check_analysis(
                Analysis, #{repo_root => Repo, base_commit => Commit}
            )
        )
    end).

dirty_source_is_rejected_test() ->
    with_repo(fun(Repo, Source, Commit) ->
        ok = file:write_file(Source, <<"dirty\n">>),
        Analysis = analysis(Source, <<"dirty\n">>),
        ?assertMatch(
            {error, #{kind := source_base_mismatch}},
            ecai_git_snapshot:check_analysis(
                Analysis, #{repo_root => Repo, base_commit => Commit}
            )
        )
    end).

analysis(Source, Bytes) ->
    #{
        source_name => unicode:characters_to_binary(Source),
        source_sha256 => sha256_hex(Bytes)
    }.

with_repo(Fun) ->
    Base = filename:join(
        "/tmp",
        "ecai_git_snapshot_" ++
            integer_to_list(
                erlang:unique_integer([positive, monotonic])
            )
    ),
    Source = filename:join(
        [Base, "apps", "ecai", "src", "sample.erl"]
    ),
    ok = filelib:ensure_dir(Source),
    ok = file:write_file(Source, <<"one\n">>),
    ok = git(Base, ["init", "-q"]),
    ok = git(Base, ["config", "user.email", "ecai-test@example.invalid"]),
    ok = git(Base, ["config", "user.name", "ECAI Test"]),
    ok = git(Base, ["add", "."]),
    ok = git(Base, [
        "-c", "commit.gpgsign=false",
        "-c", "core.hooksPath=/dev/null",
        "commit", "-qm", "base"
    ]),
    Commit = unicode:characters_to_binary(
        git_output(Base, ["rev-parse", "HEAD"])
    ),
    try
        Fun(Base, Source, Commit)
    after
        _ = file:del_dir_r(Base)
    end.

git(Cwd, Args) ->
    case git_command(Cwd, Args) of
        {ok, _Output} ->
            ok;
        {error, Reason} ->
            erlang:error({git_failed, Args, Reason})
    end.

git_output(Cwd, Args) ->
    case git_command(Cwd, Args) of
        {ok, Output} ->
            string:trim(binary_to_list(Output));
        {error, Reason} ->
            erlang:error({git_failed, Args, Reason})
    end.

git_command(Cwd, Args) ->
    case os:find_executable("git") of
        false ->
            {error, executable_not_found};
        Exe ->
            Port = open_port(
                {spawn_executable, Exe},
                [
                    binary,
                    exit_status,
                    stderr_to_stdout,
                    {args, ["-C", Cwd | Args]}
                ]
            ),
            collect_git(Port, <<>>)
    end.

collect_git(Port, Acc) ->
    receive
        {Port, {data, Data}} ->
            collect_git(Port, <<Acc/binary, Data/binary>>);
        {Port, {exit_status, 0}} ->
            {ok, Acc};
        {Port, {exit_status, Status}} ->
            {error, {exit_status, Status, Acc}}
    after 30000 ->
        try port_close(Port)
        catch
            _:_ -> ok
        end,
        {error, timeout}
    end.

sha256_hex(Bin) ->
    iolist_to_binary(
        [io_lib:format("~2.16.0b", [Byte]) ||
         <<Byte>> <= crypto:hash(sha256, Bin)]
    ).
