-module(ecai_codebase_learner_targeted_clean_tests).

-include_lib("eunit/include/eunit.hrl").

dirty_targeted_source_is_skipped_test() ->
    with_repo(
        fun(Repo, Source) ->
            ok = file:write_file(Source, <<"-module(sample).\nchanged.\n">>),
            Analysis = #{
                source_kind => source_file,
                source_name => unicode:characters_to_binary(Source)
            },
            {skip, Skipped} =
                ecai_codebase_learner:
                    module_analysis_learning_eligible(
                        Analysis,
                        #{repo_root => Repo}
                    ),
            ?assertEqual(
                dirty_tracked,
                maps:get(reason, Skipped)
            )
        end
    ).

clean_targeted_source_is_eligible_test() ->
    with_repo(
        fun(Repo, Source) ->
            Analysis = #{
                source_kind => source_file,
                source_name => unicode:characters_to_binary(Source)
            },
            ?assertEqual(
                ok,
                ecai_codebase_learner:
                    module_analysis_learning_eligible(
                        Analysis,
                        #{repo_root => Repo}
                    )
            )
        end
    ).

dirty_override_is_preserved_test() ->
    with_repo(
        fun(Repo, Source) ->
            ok = file:write_file(Source, <<"-module(sample).\nchanged.\n">>),
            Analysis = #{
                source_kind => source_file,
                source_name => unicode:characters_to_binary(Source)
            },
            ?assertEqual(
                ok,
                ecai_codebase_learner:
                    module_analysis_learning_eligible(
                        Analysis,
                        #{
                            repo_root => Repo,
                            include_dirty_files => true
                        }
                    )
            )
        end
    ).

with_repo(Fun) ->
    Repo = filename:join(
        "/tmp",
        "ecai_targeted_clean_" ++
            integer_to_list(
                erlang:unique_integer([positive, monotonic])
            )
    ),
    Source = filename:join(
        [Repo, "apps", "ecai", "src", "sample.erl"]
    ),
    ok = filelib:ensure_dir(Source),
    ok = file:write_file(
        Source,
        <<"-module(sample).\nclean.\n">>
    ),
    ok = git(Repo, ["init", "-q"]),
    ok = git(Repo, ["add", "."]),
    ok = git(
        Repo,
        [
            "-c", "user.name=ECAI",
            "-c", "user.email=ecai@example.invalid",
            "commit", "-qm", "base"
        ]
    ),
    try
        Fun(Repo, Source)
    after
        _ = os:cmd("rm -rf " ++ shell_quote(Repo))
    end.

git(Repo, Args) ->
    Cmd =
        "git -C " ++ shell_quote(Repo) ++ " " ++
            string:join(
                [shell_quote(A) || A <- Args],
                " "
            ),
    case os:cmd(Cmd ++ " 2>&1; printf '\\n%04d' $?") of
        Output ->
            Size = length(Output),
            CodeText = lists:nthtail(Size - 4, Output),
            case list_to_integer(CodeText) of
                0 -> ok;
                Code ->
                    erlang:error({git_failed, Code, Output})
            end
    end.

shell_quote(Value) ->
    "'" ++
        lists:flatten(
            string:replace(
                path_to_list(Value),
                "'",
                "'\\''",
                all
            )
        ) ++
        "'".

path_to_list(Bin) when is_binary(Bin) ->
    binary_to_list(Bin);
path_to_list(List) when is_list(List) ->
    List.
