-module(ecai_code_analyser_tests).

-include_lib("eunit/include/eunit.hrl").

repo_source_files_preserves_paths_test() ->
    Root = temp_root(),
    try
        Src = filename:join([Root, "apps", "ecai", "src"]),
        Test = filename:join([Root, "apps", "ecai", "test"]),
        Nested = filename:join(Src, "nested"),
        ok = filelib:ensure_dir(filename:join(Nested, "dummy")),
        ok = filelib:ensure_dir(filename:join(Test, "dummy")),
        P1 = filename:join(Src, "alpha.erl"),
        P2 = filename:join(Nested, "beta.erl"),
        P3 = filename:join(Test, "alpha_tests.erl"),
        ok = file:write_file(P1, <<"-module(alpha).\n">>),
        ok = file:write_file(P2, <<"-module(beta).\n">>),
        ok = file:write_file(P3, <<"-module(alpha_tests).\n">>),
        {ok, Files} = ecai_code_analyser:repo_source_files(ecai, Root),
        ?assertEqual(lists:sort([P1, P2, P3]), Files),
        ?assert(lists:all(fun is_path/1, Files)),
        ?assertNot(lists:any(fun is_integer/1, Files))
    after
        rm_rf(Root)
    end.

is_path(P) ->
    is_list(P) andalso P =/= [] andalso lists:all(fun is_integer/1, P).

temp_root() ->
    Base =
        case os:getenv("TMPDIR") of
            false -> "/tmp";
            V -> V
        end,
    filename:join(
        Base, "ecai-code-analyser-" ++ integer_to_list(erlang:unique_integer([positive]))
    ).

rm_rf(Path) ->
    case file:list_dir(Path) of
        {ok, Names} ->
            lists:foreach(
                fun(Name) ->
                    Child = filename:join(Path, Name),
                    case filelib:is_dir(Child) of
                        true -> rm_rf(Child);
                        false -> _ = file:delete(Child)
                    end
                end,
                Names
            ),
            _ = file:del_dir(Path),
            ok;
        {error, enoent} ->
            ok
    end.
