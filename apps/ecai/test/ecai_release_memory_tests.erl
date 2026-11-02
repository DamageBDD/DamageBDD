-module(ecai_release_memory_tests).

-include_lib("eunit/include/eunit.hrl").

semantic_config_and_removed_export_are_reported_test() ->
    with_repo(fun(Repo) ->
        ModulePath = filename:join([Repo, "apps", "ecai", "src", "sample_release_api.erl"]),
        ConfigPath = filename:join([Repo, "config", "sys.config.sample"]),
        ok = write_file(ModulePath, <<
            "-module(sample_release_api).\n"
            "-export([foo/0, bar/1]).\n"
            "foo() -> ok.\n"
            "bar(X) -> X.\n"
        >>),
        ok = write_file(ConfigPath, <<
            "[{ecai, [{mode, old}, {api_token, <<\"secret-a\">>}, "
            "{headers, [{authorization, <<\"Bearer old\">>}]}]}].\n"
        >>),
        ok = commit_all(Repo, "base release state"),
        Base = head(Repo),

        ok = write_file(ModulePath, <<
            "-module(sample_release_api).\n"
            "-export([foo/0, baz/0]).\n"
            "foo() -> ok.\n"
            "baz() -> ok.\n"
        >>),
        ok = write_file(ConfigPath, <<
            "[{ecai, [{mode, new}, {api_token, <<\"secret-b\">>}, "
            "{headers, [{authorization, <<\"Bearer new\">>}]}]}].\n"
        >>),
        ok = commit_all(Repo, "feat: change release interface"),
        Head = head(Repo),

        {ok, Evidence} = ecai_release_memory:analyse_range(
            Base,
            Head,
            #{repo_root => Repo}
        ),
        Config = maps:get(config_changes, Evidence),
        Mode = only([C || C <- Config, maps:get(key, C) =:= <<"ecai.mode">>]),
        ?assertEqual(changed, maps:get(operation, Mode)),
        ?assertEqual(<<"old">>, maps:get(old, Mode)),
        ?assertEqual(<<"new">>, maps:get(new, Mode)),

        Token = only([C || C <- Config, maps:get(key, C) =:= <<"ecai.api_token">>]),
        ?assertEqual(true, maps:get(sensitive, Token)),
        ?assertEqual(<<"<redacted>">>, maps:get(old, Token)),
        ?assertEqual(<<"<redacted>">>, maps:get(new, Token)),
        Headers = only([C || C <- Config, maps:get(key, C) =:= <<"ecai.headers">>]),
        ?assertEqual(true, maps:get(sensitive, Headers)),
        ?assertEqual(<<"<redacted>">>, maps:get(old, Headers)),
        ?assertEqual(<<"<redacted>">>, maps:get(new, Headers)),

        Api = maps:get(api_changes, Evidence),
        ?assert(lists:any(fun(A) ->
            maps:get(operation, A) =:= removed andalso
                maps:get(function, A) =:= <<"bar">> andalso
                maps:get(arity, A) =:= 1
        end, Api)),
        ?assert(lists:any(fun(A) ->
            maps:get(operation, A) =:= added andalso
                maps:get(function, A) =:= <<"baz">> andalso
                maps:get(arity, A) =:= 0
        end, Api)),

        Breaking = maps:get(breaking_changes, Evidence),
        ?assert(lists:any(fun(B) ->
            maps:get(kind, B) =:= exported_api_removed andalso
                maps:get(function, B) =:= <<"bar">>
        end, Breaking)),
        Actions = maps:get(operator_actions, Evidence),
        ?assert(lists:any(fun(A) -> maps:get(id, A) =:= apply_configuration end, Actions)),
        ?assert(lists:any(fun(A) -> maps:get(id, A) =:= migrate_callers end, Actions))
    end).

final_range_does_not_report_intermediate_export_removal_test() ->
    with_repo(fun(Repo) ->
        ModulePath = filename:join([Repo, "apps", "ecai", "src", "stable_api.erl"]),
        Original = <<
            "-module(stable_api).\n"
            "-export([foo/0]).\n"
            "foo() -> ok.\n"
        >>,
        ok = write_file(ModulePath, Original),
        ok = commit_all(Repo, "base"),
        Base = head(Repo),

        ok = write_file(ModulePath, <<
            "-module(stable_api).\n"
            "-export([]).\n"
        >>),
        ok = commit_all(Repo, "refactor: temporarily remove foo"),
        ok = write_file(ModulePath, Original),
        ok = commit_all(Repo, "fix: restore foo"),
        Head = head(Repo),

        {ok, Evidence} = ecai_release_memory:analyse_range(
            Base,
            Head,
            #{repo_root => Repo}
        ),
        ?assertEqual([], maps:get(api_changes, Evidence)),
        ?assertEqual([], maps:get(breaking_changes, Evidence)),
        ?assertEqual(2, length(maps:get(commits, Evidence)))
    end).

non_erlang_config_is_surfaced_for_operator_review_test() ->
    with_repo(fun(Repo) ->
        Config = filename:join([Repo, "config", "runtime.yaml"]),
        ok = write_file(Config, <<"mode: old\n">>),
        ok = commit_all(Repo, "base"),
        Base = head(Repo),
        ok = write_file(Config, <<"mode: new\n">>),
        ok = commit_all(Repo, "ops: change yaml configuration"),
        Head = head(Repo),

        {ok, Evidence} = ecai_release_memory:analyse_range(
            Base,
            Head,
            #{repo_root => Repo}
        ),
        Components = maps:get(component_changes, Evidence),
        ?assert(lists:any(fun(C) ->
            maps:get(path, C) =:= <<"config/runtime.yaml">> andalso
                maps:get(category, C) =:= config
        end, Components)),
        Actions = maps:get(operator_actions, Evidence),
        ?assert(lists:any(fun(A) ->
            maps:get(id, A) =:= review_configuration_file andalso
                maps:get(required, A) =:= true
        end, Actions))
    end).

native_and_dependency_changes_produce_operator_actions_test() ->
    with_repo(fun(Repo) ->
        Lock = filename:join(Repo, "rebar.lock"),
        Native = filename:join([Repo, "apps", "ecai", "c_src", "release_probe.c"]),
        ok = write_file(Lock, <<"[].\n">>),
        ok = write_file(Native, <<"int ecai_probe(void) { return 1; }\n">>),
        ok = commit_all(Repo, "base"),
        Base = head(Repo),
        ok = write_file(Lock, <<"[{pkg, <<\"demo\">>}].\n">>),
        ok = write_file(Native, <<"int ecai_probe(void) { return 2; }\n">>),
        ok = commit_all(Repo, "build: update dependencies and nif"),
        Head = head(Repo),

        {ok, Evidence} = ecai_release_memory:analyse_range(
            Base,
            Head,
            #{repo_root => Repo}
        ),
        Actions = maps:get(operator_actions, Evidence),
        ?assert(lists:any(fun(A) -> maps:get(id, A) =:= rebuild_dependencies end, Actions)),
        ?assert(lists:any(fun(A) -> maps:get(id, A) =:= rebuild_native end, Actions))
    end).

with_repo(Fun) ->
    Base = filename:join(
        "/tmp",
        "ecai_release_memory_" ++ integer_to_list(erlang:unique_integer([positive, monotonic]))
    ),
    ok = filelib:ensure_dir(filename:join(Base, "placeholder")),
    ok = git(Base, ["init", "-q"]),
    ok = git(Base, ["symbolic-ref", "HEAD", "refs/heads/main"]),
    ok = git(Base, ["config", "user.email", "ecai-release-test@example.invalid"]),
    ok = git(Base, ["config", "user.name", "ECAI Release Test"]),
    try
        Fun(Base)
    after
        _ = file:del_dir_r(Base)
    end.

write_file(Path, Data) ->
    ok = filelib:ensure_dir(Path),
    file:write_file(Path, Data).

commit_all(Repo, Message) ->
    ok = git(Repo, ["add", "."]),
    git(Repo, [
        "-c", "commit.gpgsign=false",
        "-c", "core.hooksPath=/dev/null",
        "commit", "-qm", Message
    ]).

head(Repo) ->
    {ok, Output} = git_command(Repo, ["rev-parse", "HEAD"]),
    trim(Output).

git(Cwd, Args) ->
    case git_command(Cwd, Args) of
        {ok, _Output} -> ok;
        {error, Reason} -> erlang:error({git_failed, Args, Reason})
    end.

git_command(Cwd, Args) ->
    case os:find_executable("git") of
        false ->
            {error, executable_not_found};
        Exe ->
            Port = open_port({spawn_executable, Exe}, [
                binary,
                exit_status,
                stderr_to_stdout,
                {args, ["-C", Cwd | Args]}
            ]),
            collect_git(Port, <<>>)
    end.

collect_git(Port, Acc) ->
    receive
        {Port, {data, Data}} -> collect_git(Port, <<Acc/binary, Data/binary>>);
        {Port, {exit_status, 0}} -> {ok, Acc};
        {Port, {exit_status, Status}} -> {error, {exit_status, Status, Acc}}
    after 30000 ->
        try port_close(Port) catch _:_ -> ok end,
        {error, timeout}
    end.

trim(Bin) ->
    unicode:characters_to_binary(string:trim(binary_to_list(Bin))).

only([One]) -> One;
only(Other) -> erlang:error({expected_one, Other}).
