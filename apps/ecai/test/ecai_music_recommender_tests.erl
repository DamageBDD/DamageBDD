-module(ecai_music_recommender_tests).
-include_lib("eunit/include/eunit.hrl").

track(Id,Tags,Bpm) ->
    #{id => Id, title => Id, artist => <<"Fixture artist">>,
      tags => Tags, bpm => Bpm,
      license => #{id => <<"CC-BY-4.0">>,
                   url => <<"https://creativecommons.org/licenses/by/4.0/">>}}.

context_changes_order_test() ->
    Slow = track(<<"slow">>,[<<"ambient">>,<<"calm">>],80),
    Fast = track(<<"fast">>,[<<"psytrance">>,<<"energise">>],145),
    P = ecai_music_recommender:default_policy(),
    {ok,[#{id := <<"slow">>}|_]} = ecai_music_recommender:recommend(
        [Fast,Slow],#{tags => [<<"ambient">>],mood => <<"calm">>},P,#{},2),
    {ok,[#{id := <<"fast">>}|_]} = ecai_music_recommender:recommend(
        [Slow,Fast],#{tags => [<<"psytrance">>],target_bpm => 145},P,#{},2).

stable_input_independent_ties_test() ->
    A = track(<<"a">>,[],100), B = track(<<"b">>,[],100),
    P = ecai_music_recommender:default_policy(),
    {ok,R} = ecai_music_recommender:recommend([B,A],#{},P,#{},2),
    ?assertEqual([<<"a">>,<<"b">>],[maps:get(id,T) || T <- R]),
    ?assertEqual({ok,R},ecai_music_recommender:recommend([A,B],#{},P,#{},2)),
    [#{score := Score,reasons := #{components := Parts}}|_] = R,
    ?assertEqual(Score,lists:sum(maps:values(Parts))).

feedback_and_repetition_test() ->
    A = track(<<"a">>,[],100), B = track(<<"b">>,[],100),
    P = ecai_music_recommender:default_policy(),
    {ok,[#{id := <<"b">>}|_]} = ecai_music_recommender:recommend(
        [A,B],#{recent_ids => [<<"a">>]},P,#{<<"a">> => #{rating=>2,plays=>3}},2),
    {ok,[#{id := <<"a">>}|_]} = ecai_music_recommender:recommend(
        [A,B],#{},P,#{<<"a">> => 2},2).

exclusions_and_casefold_test() ->
    A = track(<<"a">>,[<<"VOCAL">>],100), B = track(<<"b">>,[<<"Ambient">>],100),
    P = (ecai_music_recommender:default_policy())#{excluded_tags => [<<"vocal">>]},
    {ok,[#{id := <<"b">>,tags := [<<"ambient">>]}]} =
       ecai_music_recommender:recommend([A,B],#{},P,#{},10).

invalid_inputs_fail_closed_test() ->
    T = track(<<"a">>,[],100), P = ecai_music_recommender:default_policy(),
    ?assertMatch({error,_},ecai_music_recommender:recommend([T,T],#{},P,#{},2)),
    ?assertMatch({error,_},ecai_music_recommender:recommend([T],#{},P,#{<<"a">> => 100},2)),
    ?assertMatch({error,_},ecai_music_recommender:recommend([T],#{},P,#{},101)),
    ?assertMatch({error,_},ecai_music_recommender:recommend([T#{bpm=>0}],#{},P,#{},1)).

ecai_term_pipeline_test() ->
    Terms = ecai_music_recommender:index_terms(track(<<"Blue Sky">>,[<<"Ambient">>],80)),
    ?assert(lists:member(<<"tag:ambient">>,Terms)),
    ?assert(lists:member(<<"type:music">>,Terms)).
