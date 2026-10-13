-module(ecai_search_compatibility_tests).

-include_lib("eunit/include/eunit.hrl").

yelp_enriched_result_and_v1_proof_compatibility_test() ->
    Ctx = ecai_search:new(),
    try
        ok = ecai_search:add_record(Ctx, <<"biz:001">>, #{
            name => <<"Acme Plumbing Co">>,
            category => <<"plumber">>,
            city => <<"Sydney NSW">>,
            tags => [<<"24x7">>, <<"emergency">>],
            phone => <<"+61 2 9123 4567">>
        }),
        {Results, ProofHeaders} = ecai_search:search(
            Ctx,
            #{name => <<"acm">>, prefix => true},
            5
        ),
        [Result | _] = Results,
        ?assertEqual(<<"biz:001">>, maps:get(doc_id, Result)),
        ?assert(maps:is_key(score, Result)),
        ?assert(maps:is_key(record, Result)),
        ?assert(maps:is_key(preview, Result)),
        ?assert(is_map(ProofHeaders)),
        ?assertMatch(
            {ok, _Path, _Dirs},
            ecai_search:proof_for(Ctx, <<"pfx:name:acm">>, <<"biz:001">>)
        )
    after
        ok = ecai_search:wipe(Ctx)
    end.

multiple_contexts_and_deterministic_roots_test() ->
    Ctx1 = ecai_search:new(),
    Ctx2 = ecai_search:new(),
    Record = #{name => <<"Acme Plumbing Co">>, category => <<"plumber">>},
    try
        ok = ecai_search:add_record(Ctx1, <<"biz:001">>, Record),
        ok = ecai_search:add_record(Ctx2, <<"biz:001">>, Record),
        ?assertEqual(
            ecai_search:term_root(Ctx1, <<"pfx:name:acm">>),
            ecai_search:term_root(Ctx2, <<"pfx:name:acm">>)
        )
    after
        ok = ecai_search:wipe(Ctx1),
        ok = ecai_search:wipe(Ctx2)
    end.

colon_tag_scoring_compatibility_test() ->
    Ctx = ecai_search:new(),
    try
        ok = ecai_search:add_record(Ctx, <<"wiki:1">>, #{
            name => <<"Quantum mechanics">>,
            category => <<"wikipedia">>,
            tags => [<<"wikidata:q944">>]
        }),
        {Results, _} = ecai_search:search(
            Ctx,
            #{tags => [<<"wikidata:q944">>]},
            5
        ),
        ?assertEqual(<<"wiki:1">>, maps:get(doc_id, hd(Results)))
    after
        ok = ecai_search:wipe(Ctx)
    end.

wikimedia_fields_and_v2_proof_are_additive_test() ->
    Ctx = ecai_search:new(),
    try
        ok = ecai_search:add_record(Ctx, <<"enwiki:42">>, #{
            name => <<"Quantum mechanics">>,
            title => <<"Quantum mechanics">>,
            abstract => <<"Physics theory of matter and energy">>,
            category => <<"wikipedia">>,
            language => <<"en">>,
            wikidata_id => <<"Q944">>,
            pageviews => 1000000,
            active_months => 12,
            visibility_rank => 10
        }),
        {Results, _} = ecai_search:search(Ctx, #{title => <<"quantum">>}, 5),
        ?assertEqual(<<"enwiki:42">>, maps:get(doc_id, hd(Results))),
        Hash = ecai_search:record_commitment(Ctx, <<"enwiki:42">>),
        ?assertEqual(32, byte_size(Hash)),
        ?assertMatch(
            {ok, #{scheme := <<"ecai-posting-proof/v2">>}},
            ecai_search:proof_for_v2(Ctx, <<"title:quantum">>, <<"enwiki:42">>)
        )
    after
        ok = ecai_search:wipe(Ctx)
    end.

deferred_snapshot_rebuilds_roots_test() ->
    Ctx0 = ecai_search:new(),
    Ctx = ecai_search:set_opts(Ctx0, #{root_mode => deferred}),
    Path = filename:join(
        temp_dir(),
        "ecai-search-compat-" ++ integer_to_list(erlang:unique_integer([positive])) ++ ".etf"
    ),
    try
        ok = ecai_search:add_record(Ctx, <<"biz:001">>, #{name => <<"Acme Plumbing">>}),
        ok = ecai_search:save(Ctx, Path),
        {ok, Loaded} = ecai_search:load(Path),
        try
            ?assertEqual(
                ecai_search:term_root(Ctx, <<"name:acme">>),
                ecai_search:term_root(Loaded, <<"name:acme">>)
            )
        after
            ok = ecai_search:wipe(Loaded)
        end
    after
        _ = file:delete(Path),
        ok = ecai_search:wipe(Ctx)
    end.

temp_dir() ->
    case os:getenv("TMPDIR") of
        false -> "/tmp";
        Value -> Value
    end.
