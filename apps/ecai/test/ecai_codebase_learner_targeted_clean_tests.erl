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
    Repo = temp_root(),
    try
        Source = filename:join([Repo, "apps", "ecai", "src", "sample.erl"]),
        ok = filelib:ensure_dir(Source),
        ok = file:write_file(Source, <<"-module(sample).\nclean.\n">>),
        ok = git(Repo, ["init", "-q"]),
        ok = git(Repo, ["add", "."]),
        %% Override inherited signing only for this disposable fixture commit.
        ok = git(Repo, [
            "-c", "user.name=ECAI",
            "-c", "user.email=ecai@example.invalid",
            "commit", "--no-gpg-sign", "-qm", "base"
        ]),
        Fun(Repo, Source)
    after
        ok = file:del_dir_r(Repo)
    end.

%% A failed prior VM may leave directories behind. Never adopt one of them.
temp_root() ->
    {ok, _} = application:ensure_all_started(crypto),
    Parent = case os:getenv("TMPDIR") of
        false -> "/tmp";
        "" -> "/tmp";
        Value -> Value
    end,
    temp_root(filename:absname(Parent), 16).

temp_root(_Parent, 0) ->
    erlang:error(test_directory_collision_limit);
temp_root(Parent, Attempts) ->
    Suffix = binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(16))),
    Root = filename:join(Parent, "ecai_targeted_clean_" ++ Suffix),
    case file:make_dir(Root) of
        ok -> Root;
        {error, eexist} -> temp_root(Parent, Attempts - 1);
        {error, Reason} -> erlang:error({test_directory_failed, Root, Reason})
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
