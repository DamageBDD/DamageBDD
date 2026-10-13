-module(ecai_wikimedia_fixture_handler_tests).

-include_lib("eunit/include/eunit.hrl").

closed_range_test() ->
    ?assertEqual(
        {ok, 10, 10},
        ecai_wikimedia_fixture_handler:parse_range(<<"bytes=10-19">>, 100)
    ).

open_ended_range_test() ->
    ?assertEqual(
        {ok, 90, 10},
        ecai_wikimedia_fixture_handler:parse_range(<<"bytes=90-">>, 100)
    ).

suffix_range_test() ->
    ?assertEqual(
        {ok, 90, 10},
        ecai_wikimedia_fixture_handler:parse_range(<<"bytes=-10">>, 100)
    ).

range_end_is_clamped_test() ->
    ?assertEqual(
        {ok, 95, 5},
        ecai_wikimedia_fixture_handler:parse_range(<<"bytes=95-999">>, 100)
    ).

unsatisfiable_range_test() ->
    ?assertMatch(
        {error, _},
        ecai_wikimedia_fixture_handler:parse_range(<<"bytes=100-101">>, 100)
    ).

multiple_ranges_are_rejected_test() ->
    ?assertEqual(
        {error, multiple_ranges_unsupported},
        ecai_wikimedia_fixture_handler:parse_range(
            <<"bytes=0-1,10-11">>,
            100
        )
    ).

content_types_test() ->
    ?assertEqual(
        <<"application/json; charset=utf-8">>,
        ecai_wikimedia_fixture_handler:content_type(
            <<"wikimedia-catalog.json">>
        )
    ),
    ?assertEqual(
        <<"application/x-bzip2">>,
        ecai_wikimedia_fixture_handler:content_type(<<"archive.bz2">>)
    ),
    ?assertEqual(
        <<"text/plain; charset=utf-8">>,
        ecai_wikimedia_fixture_handler:content_type(<<"source.txt">>)
    ).
