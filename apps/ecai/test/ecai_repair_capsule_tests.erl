-module(ecai_repair_capsule_tests).

-include_lib("eunit/include/eunit.hrl").

deterministic_capsule_test() ->
    Repo = #{head => <<"abc">>, path => <<"/tmp/repo">>},
    Problem = #{class => compiler_warning, file => <<"src/sample.erl">>},
    Context = #{
        target_files => [<<"src/sample.erl">>],
        source_manifest => #{},
        extracted_invariants => []
    },
    {ok, A} = ecai_repair_capsule:new(Repo, Problem, Context),
    {ok, B} = ecai_repair_capsule:new(Repo, Problem, Context),
    ?assertEqual(ecai_repair_capsule:id(A), ecai_repair_capsule:id(B)),
    ?assertEqual(ok, ecai_repair_capsule:verify_id(A)).

capsule_tamper_detection_test() ->
    {ok, Capsule} = ecai_repair_capsule:new(
        #{head => <<"abc">>},
        #{class => warning},
        #{target_files => [], source_manifest => #{}}
    ),
    Payload = ecai_repair_capsule:payload(Capsule),
    Tampered = Capsule#{payload => Payload#{problem => #{class => different}}},
    ?assertMatch({error, {capsule_id_mismatch, _, _}}, ecai_repair_capsule:verify_id(Tampered)).

prompt_contains_capsule_test() ->
    {ok, Capsule} = ecai_repair_capsule:new(
        #{head => <<"abc">>},
        #{class => warning},
        #{target_files => [<<"src/a.erl">>], source_manifest => #{}}
    ),
    Prompt = ecai_repair_prompt:build(Capsule, <<"repair it">>),
    ?assertNotEqual(nomatch, binary:match(Prompt, ecai_repair_capsule:id(Capsule))),
    ?assertNotEqual(nomatch, binary:match(Prompt, <<"unified diff">>)).

source_invariant_extraction_test_() ->
    {setup,
        fun make_repo/0,
        fun remove_repo/1,
        fun(Repo) ->
            File = filename:join([Repo, "src", "sample.erl"]),
            {ok, Fact} = ecai_code_invariants:file(File, #{relative_path => <<"src/sample.erl">>}),
            [
                ?_assertEqual(sample, maps:get(module, Fact)),
                ?_assertEqual([{answer, 0}], maps:get(exports, Fact)),
                ?_assert(lists:member(#{kind => remote, module => erlang, function => integer_to_binary, arity => 1}, maps:get(calls, Fact)))
            ]
        end}.

bridge_enrichment_test_() ->
    {setup,
        fun make_repo/0,
        fun remove_repo/1,
        fun(Repo) ->
            Request = #{
                task => repair,
                repo => Repo,
                failure => #{file => <<"src/sample.erl">>, class => warning},
                prompt => <<"fix warning">>,
                state_root => filename:join(Repo, "state")
            },
            Enriched = ecai_repair_bridge:maybe_enrich(repair, Request),
            Capsule = maps:get(repair_capsule, Enriched),
            [
                ?_assertEqual(ok, ecai_repair_capsule:validate(Capsule)),
                ?_assertNotEqual(nomatch, binary:match(maps:get(prompt, Enriched), ecai_repair_capsule:id(Capsule)))
            ]
        end}.


store_roundtrip_test_() ->
    {setup,
        fun make_repo/0,
        fun remove_repo/1,
        fun(Repo) ->
            Root = filename:join(Repo, "state"),
            {ok, Capsule} = ecai_repair_capsule:new(
                #{head => <<"abc">>, path => Repo},
                #{class => warning, file => <<"src/sample.erl">>},
                #{target_files => [<<"src/sample.erl">>], source_manifest => #{}}
            ),
            {ok, _Path} = ecai_repair_store:persist_capsule(Root, Capsule),
            {ok, Loaded} = ecai_repair_store:load_capsule(Root, ecai_repair_capsule:id(Capsule)),
            [
                ?_assertEqual(Capsule, Loaded),
                ?_assertEqual(ok, ecai_repair_capsule:validate(Loaded))
            ]
        end}.

candidate_verification_test_() ->
    {setup,
        fun make_repo/0,
        fun remove_repo/1,
        fun(Repo) ->
            Problem = #{class => warning, file => <<"src/sample.erl">>},
            {ok, Context} = ecai_code_invariants:build(Repo, Problem, #{max_files => 4}),
            {ok, Capsule} = ecai_repair_capsule:new(
                maps:get(repo_state, Context),
                Problem,
                Context
            ),
            File = filename:join([Repo, "src", "sample.erl"]),
            ok = file:write_file(File, <<
                "-module(sample).\n",
                "-export([answer/0]).\n",
                "answer() -> erlang:integer_to_binary(43).\n"
            >>),
            [?_assertMatch({ok, #{status := pass}}, ecai_repair_verify:verify_candidate(Repo, Capsule))]
        end}.

api_break_rejected_test_() ->
    {setup,
        fun make_repo/0,
        fun remove_repo/1,
        fun(Repo) ->
            Problem = #{class => warning, file => <<"src/sample.erl">>},
            {ok, Context} = ecai_code_invariants:build(Repo, Problem, #{max_files => 4}),
            {ok, Capsule} = ecai_repair_capsule:new(
                maps:get(repo_state, Context),
                Problem,
                Context
            ),
            File = filename:join([Repo, "src", "sample.erl"]),
            ok = file:write_file(File, <<
                "-module(sample).\n",
                "-export([different/0]).\n",
                "different() -> 43.\n"
            >>),
            [?_assertMatch({error, #{status := fail}}, ecai_repair_verify:verify_candidate(Repo, Capsule))]
        end}.

make_repo() ->
    Base = case os:getenv("TMPDIR") of false -> "/tmp"; D -> D end,
    Repo = filename:join(Base, "ecai_capsule_test_" ++ integer_to_list(erlang:unique_integer([positive, monotonic]))),
    ok = filelib:ensure_dir(filename:join([Repo, "src", "dummy"])),
    Source = <<
        "-module(sample).\n",
        "-export([answer/0]).\n",
        "answer() -> erlang:integer_to_binary(42).\n"
    >>,
    ok = file:write_file(filename:join([Repo, "src", "sample.erl"]), Source),
    Repo.

remove_repo(Repo) ->
    _ = file:del_dir_r(Repo),
    ok.
