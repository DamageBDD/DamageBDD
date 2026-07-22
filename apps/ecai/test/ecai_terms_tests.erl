-module(ecai_terms_tests).

-include_lib("eunit/include/eunit.hrl").

pipeline_version_is_shared_test() ->
    ?assertEqual(<<"ecai-terms/v1">>, ecai_terms:version()),
    ?assertEqual(ecai_terms:version(), ecai_ingest_event:pipeline_version()).

yelp_terms_remain_compatible_test() ->
    Terms = ecai_terms:terms_from_record(#{
        name => <<"Acme Plumbing Co">>,
        category => <<"Plumber">>,
        city => <<"Sydney NSW">>,
        tags => [<<"24x7">>, <<"Emergency">>],
        phone => <<"+61 2 9123 4567">>
    }),
    assert_members(
        [
            <<"name:acme">>,
            <<"pfx:name:acm">>,
            <<"sfx:name:em">>,
            <<"cat:plumber">>,
            <<"city:sydney">>,
            <<"pfx:city:syd">>,
            <<"tag:24x7">>,
            <<"tag:emergency">>,
            <<"phone:61291234567">>,
            <<"pfx:phone:612">>
        ],
        Terms
    ).

wikipedia_terms_are_shared_test() ->
    Terms = ecai_terms:terms_from_record(#{
        name => <<"Alan Turing">>,
        category => <<"wikipedia">>,
        tags => [<<"wiki">>, <<"wikidata:Q7259">>],
        abstract => <<"English mathematician and computer scientist">>,
        language => <<"en">>,
        wikidata_id => <<"Q7259">>
    }),
    assert_members(
        [
            <<"name:alan">>,
            <<"pfx:name:ala">>,
            <<"cat:wikipedia">>,
            <<"tag:wiki">>,
            <<"tag:wikidata:q7259">>,
            <<"abstract:mathematician">>,
            <<"language:en">>,
            <<"wikidata:q7259">>
        ],
        Terms
    ).

ipfs_terms_are_searchable_test() ->
    RecordTerms = ecai_terms:terms_from_record(#{
        title => <<"Global ECAI IPFS Index">>,
        heading => <<"Durable ingestion">>,
        text => <<"Committed records become searchable after publication">>,
        type => <<"ipfs">>,
        tags => [<<"ECAI">>, <<"production">>]
    }),
    QueryTerms = ecai_terms:terms_from_query(
        #{title => <<"glob">>, prefix => true, tags => [<<"ecai">>]},
        true
    ),
    assert_members(
        [
            <<"title:global">>,
            <<"pfx:title:glob">>,
            <<"heading:durable">>,
            <<"text:searchable">>,
            <<"type:ipfs">>,
            <<"tag:ecai">>
        ],
        RecordTerms
    ),
    ?assert(lists:member(<<"pfx:title:glob">>, QueryTerms)),
    ?assert(lists:member(<<"tag:ecai">>, QueryTerms)),
    ?assertNotEqual([], ordsets:intersection(RecordTerms, QueryTerms)).

binary_query_keys_are_supported_test() ->
    ?assertEqual(
        ecai_terms:terms_from_query(#{name => <<"acm">>, prefix => true}, true),
        ecai_terms:terms_from_query(
            #{<<"name">> => <<"acm">>, <<"prefix">> => true},
            true
        )
    ).

assert_members(Expected, Actual) ->
    lists:foreach(
        fun(Term) -> ?assert(lists:member(Term, Actual)) end,
        Expected
    ).
