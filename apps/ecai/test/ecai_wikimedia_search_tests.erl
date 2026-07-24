-module(ecai_wikimedia_search_tests).

-include_lib("eunit/include/eunit.hrl").

visibility_search_and_filters_test() ->
    with_search_context(fun(Ctx) ->
        {ok, Search} = ecai_wikimedia_search:search(
            Ctx,
            <<"physics">>,
            #{limit => 10, has_wikidata => true, maximum_rank => 100}
        ),
        [Result] = maps:get(results, Search),
        ?assertEqual(<<"1">>, maps:get(doc_id, Result)),
        ?assertEqual(1, maps:get(count, Search)),
        ?assertEqual(true, maps:get(wikidata_only, maps:get(filters, Search)))
    end).

language_and_minimum_pageviews_filters_test() ->
    with_search_context(fun(Ctx) ->
        {ok, Search} = ecai_wikimedia_search:search(
            Ctx,
            <<"physics">>,
            #{
                limit => 10,
                language => <<"en">>,
                minimum_pageviews => 100000,
                has_wikidata => false
            }
        ),
        [Result] = maps:get(results, Search),
        ?assertEqual(<<"1">>, maps:get(doc_id, Result)),
        Record = maps:get(record, Result),
        ?assertEqual(<<"en">>, maps:get(language, Record)),
        ?assert(maps:get(pageviews, Record) >= 100000)
    end).

invalid_query_is_rejected_test() ->
    Ctx = ecai_search:new(),
    try
        ?assertEqual(
            {error, badarg},
            ecai_wikimedia_search:search(Ctx, <<>>, #{limit => 10})
        )
    after
        ok = ecai_search:wipe(Ctx)
    end.

with_search_context(Fun) ->
    Ctx = ecai_search:new(),
    try
        ok = ecai_search:add_record(Ctx, <<"1">>, #{
            name => <<"Quantum mechanics">>,
            title => <<"Quantum mechanics">>,
            abstract => <<"Physics theory of matter and energy">>,
            category => <<"wikipedia">>,
            tags => [<<"wiki">>, <<"wikidata:Q944">>],
            language => <<"en">>,
            wikidata_id => <<"Q944">>,
            pageviews => 1000000,
            active_months => 12,
            visibility_rank => 10
        }),
        ok = ecai_search:add_record(Ctx, <<"2">>, #{
            name => <<"Classical mechanics">>,
            title => <<"Classical mechanics">>,
            abstract => <<"Physics of macroscopic bodies">>,
            category => <<"wikipedia">>,
            tags => [<<"wiki">>],
            language => <<"en">>,
            wikidata_id => <<>>,
            pageviews => 1000,
            active_months => 12,
            visibility_rank => 1000
        }),
        ok = ecai_search:add_record(Ctx, <<"3">>, #{
            name => <<"Physique quantique">>,
            title => <<"Physique quantique">>,
            abstract => <<"Physics in French">>,
            category => <<"wikipedia">>,
            tags => [<<"wiki">>, <<"wikidata:Q944">>],
            language => <<"fr">>,
            wikidata_id => <<"Q944">>,
            pageviews => 500000,
            active_months => 12,
            visibility_rank => 20
        }),
        Fun(Ctx)
    after
        ok = ecai_search:wipe(Ctx)
    end.
