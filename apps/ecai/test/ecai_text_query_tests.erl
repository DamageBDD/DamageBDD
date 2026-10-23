-module(ecai_text_query_tests).
-include_lib("eunit/include/eunit.hrl").

final_token_only_test() ->
    ?assertMatch({ok,#{groups := [{<<"redirect">>,exact},{<<"te">>,prefix}]}},
        ecai_text_query:plan(<<"redirect te">>, bool_prefix)),
    ?assertMatch({ok,#{groups := [{<<"redire">>,prefix}]}},
        ecai_text_query:plan(<<"ReDiRe">>, bool_prefix)).

trailing_delimiters_complete_word_test() ->
    lists:foreach(fun(Q) ->
        ?assertMatch({ok,#{last_token_prefix := false,groups := [{<<"redire">>,exact}]}},
            ecai_text_query:plan(Q,bool_prefix))
    end,[<<"redire ">>,<<"redire\t">>,<<"redire!">>]).

minimum_prefix_and_exact_mode_test() ->
    ?assertMatch({ok,#{last_token_prefix := false}},ecai_text_query:plan(<<"r">>,bool_prefix)),
    ?assertMatch({ok,#{last_token_prefix := true}},ecai_text_query:plan(<<"re">>,bool_prefix)),
    ?assertMatch({ok,#{last_token_prefix := false}},ecai_text_query:plan(<<"redire">>,exact)).

invalid_queries_test() ->
    lists:foreach(fun(Q) -> ?assertEqual({error,invalid_query},ecai_text_query:plan(Q,bool_prefix)) end,
        [<<>>, <<" \t!?">>, <<255>>, binary:copy(<<"a">>,4097), #{}, undefined]),
    ?assertEqual({error,too_many_query_terms},ecai_text_query:plan(binary:copy(<<"a ">>,17),bool_prefix)),
    ?assertEqual({error,invalid_matching},ecai_text_query:plan(<<"redire">>,typo)).

unfinished_word_and_no_shorter_prefix_test() ->
    with_postings(fun(Tab) ->
        ?assertEqual([1,2,3],ids(Tab,<<"redire">>,bool_prefix)),
        ?assertEqual([],ids(Tab,<<"redirex">>,bool_prefix)),
        ?assertEqual([],ids(Tab,<<"dire">>,bool_prefix)),
        ?assertEqual([],ids(Tab,<<"redire">>,exact))
    end).

all_words_required_before_limit_test() ->
    with_postings(fun(Tab) ->
        ?assertEqual([1],ids(Tab,<<"redirect te">>,bool_prefix)),
        ?assertEqual([],ids(Tab,<<"redirect xyz">>,bool_prefix)),
        %% Complete earlier tokens are exact, not prefixes.
        ?assertEqual([],ids(Tab,<<"redire te">>,bool_prefix))
    end).

body_and_long_prefix_test() ->
    with_postings(fun(Tab) ->
        ?assertEqual([3],ids(Tab,<<"redirectbo">>,bool_prefix)),
        ?assertEqual([5],ids(Tab,<<"internationaliz">>,bool_prefix)),
        ?assertEqual([],ids(Tab,<<"internationalize">>,bool_prefix))
    end).

utf8_prefix_test() ->
    Tab = ets:new(utf8_terms,[ordered_set]),
    try
        true = ets:insert(Tab, {{<<"title:éclair"/utf8>>,1},true}),
        ?assertEqual([1],ids(Tab,<<"écl"/utf8>>,bool_prefix))
    after ets:delete(Tab) end.

exact_scores_above_completions_test() ->
    with_postings(fun(Tab) ->
        {Scores,_} = run(Tab,<<"redirect">>,bool_prefix),
        [{1,_}|_] = ecai_text_query:top(Scores,10),
        ?assert(maps:get(1,Scores) > maps:get(2,Scores)),
        ?assert(maps:get(1,Scores) > maps:get(3,Scores))
    end).

bounded_range_test() ->
    with_postings(fun(Tab) ->
        ?assertEqual({[<<"title:redirect">>],true},ecai_text_query:ets_terms(Tab,<<"title:redire">>,1)),
        ?assertEqual({[],false},ecai_text_query:ets_terms(Tab,<<"title:z">>,1)),
        true = ets:insert(Tab,{{<<"title:redirect">>,10},true}),
        ?assertEqual({[1],true},ecai_text_query:ets_docs(Tab,<<"title:redirect">>,1)),
        ?assertEqual({[1,10],false},ecai_text_query:ets_docs(Tab,<<"title:redirect">>,2))
    end).

limits_are_reported_test() ->
    Saved = application:get_env(ecai,knowledge_search_limits),
    try
        application:set_env(ecai,knowledge_search_limits,[{max_expansions_per_field,1}]),
        with_postings(fun(Tab) ->
            {_,Meta} = run(Tab,<<"redire">>,bool_prefix),
            ?assertEqual(true,maps:get(truncated,Meta)),
            ?assert(lists:member(expansion_limit,maps:get(reasons,Meta)))
        end),
        application:set_env(ecai,knowledge_search_limits,[{max_postings,1}]),
        with_postings(fun(Tab) ->
            {_,Meta} = run(Tab,<<"redire">>,bool_prefix),
            ?assertEqual(true,maps:get(truncated,Meta)),
            ?assert(maps:get(postings_read,Meta) =< 1)
        end)
    after restore(knowledge_search_limits,Saved) end.

replacement_removes_prefix_match_test() ->
    with_postings(fun(Tab) ->
        ets:delete(Tab,{<<"title:redirect">>,1}),
        ?assertNot(lists:member(1,ids(Tab,<<"redire">>,bool_prefix)))
    end).

ids(Tab,Q,M) -> {Scores,_} = run(Tab,Q,M), lists:sort(maps:keys(Scores)).
run(Tab,Q,M) ->
    {ok,Plan} = ecai_text_query:plan(Q,M),
    ecai_text_query:run(Plan,fun(T,N)->ecai_text_query:ets_docs(Tab,T,N) end,
                            fun(P,N)->ecai_text_query:ets_terms(Tab,P,N) end).
with_postings(Fun) ->
    Tab = ets:new(text_query_test,[ordered_set]),
    try
        true = ets:insert(Tab,[{{T,Id},true} || {Id,R} <- [
            {1,#{title => <<"Redirect test">>}},
            {2,#{title => <<"Redirection task">>}},
            {3,#{title => <<"Body match">>,text => <<"redirectbody">>}},
            {4,#{title => <<"Red rectangle">>}},
            {5,#{title => <<"Internationalization">>}}], T <- ecai_terms:terms_from_record(R)]),
        Fun(Tab)
    after ets:delete(Tab) end.
restore(K,undefined) -> application:unset_env(ecai,K);
restore(K,{ok,V}) -> application:set_env(ecai,K,V).
