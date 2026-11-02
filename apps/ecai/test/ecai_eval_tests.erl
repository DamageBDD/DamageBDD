%% Pure evaluator contracts. Run with OTP 27+ in the actual umbrella repository.
-module(ecai_eval_tests).
-include_lib("eunit/include/eunit.hrl").

sample(Name) ->
    Beam = code:which(ecai_eval_spec),
    Priv = filename:join(filename:dirname(filename:dirname(Beam)), "priv"),
    {ok, B} = file:read_file(filename:join([Priv,"static","eval", Name ++ ".json"])),
    ecai_eval_util:decode(B).
normalized() -> ecai_eval_spec:normalize(sample("dialogue")).
check(Type, Fields) -> maps:merge(#{<<"id">> => <<"c">>, <<"type">> => Type,
    <<"critical">> => true, <<"description">> => <<"test">>}, Fields).
case_with(Check) -> #{<<"checks">> => [Check], <<"rubric">> => null}.

canonical_order_test() ->
    ?assertEqual(ecai_eval_util:hash(#{<<"b">>=>2,<<"a">>=>1}), ecai_eval_util:hash(#{<<"a">>=>1,<<"b">>=>2})).
hash_domain_test() ->
    M = #{<<"x">>=>1}, ?assertEqual(ecai_eval_util:hex(crypto:hash(sha256,[<<"ecai-eval/v1",0>>,ecai_eval_util:json(M)])), ecai_eval_util:hash(M)).
fixture_import_test() ->
    ?assertEqual(6,length(maps:get(<<"cases">>,normalized()))),
    ?assertEqual(4,length(maps:get(<<"cases">>,ecai_eval_spec:normalize(sample("paper-trading"))))).
case_lookup_test() ->
    ?assertEqual(<<"return-window">>,maps:get(<<"id">>,ecai_eval_spec:case_by_id(normalized(),<<"return-window">>))).
strict_unknown_keys_test() ->
    ?assertThrow({eval_error,unexpected_fields},ecai_eval_spec:normalize((sample("dialogue"))#{<<"owner">>=><<"someone-else">>})).
duplicate_id_test() ->
    S=sample("dialogue"),[C|_]=maps:get(<<"cases">>,S),
    ?assertThrow({eval_error,duplicate_case},ecai_eval_spec:normalize(S#{<<"cases">>=>[C,C]})).
leakage_test() ->
    S=sample("dialogue"),[C|_]=maps:get(<<"cases">>,S),
    D=C#{<<"id">>=><<"different">>,<<"split">>=><<"holdout">>},
    ?assertThrow({eval_error,cross_split_leakage},ecai_eval_spec:normalize(S#{<<"cases">>=>[C,D]})).
json_equal_test() ->
    C=case_with(check(<<"json_equal">>,#{<<"path">>=>[<<"ok">>],<<"expected">>=>true})),
    G=ecai_eval_grader:grade(C,<<"{\"ok\":true}">>,#{}),?assertEqual(<<"pass">>,maps:get(<<"status">>,G)).
json_type_strict_test() ->
    C=case_with(check(<<"json_equal">>,#{<<"path">>=>[<<"ok">>],<<"expected">>=>true})),
    G=ecai_eval_grader:grade(C,<<"{\"ok\":\"true\"}">>,#{}),?assertEqual(1,maps:get(<<"critical_failures">>,G)).
invalid_json_test() ->
    C=case_with(check(<<"json_keys">>,#{<<"path">>=>[],<<"required">>=>[<<"x">>]})),
    ?assertEqual(<<"fail">>,maps:get(<<"status">>,ecai_eval_grader:grade(C,<<"not JSON">>,#{}))).
unknown_citation_test() ->
    C=case_with(check(<<"citation_ids">>,#{<<"path">>=>[<<"citations">>],<<"required">>=>[<<"approved">>]})),
    S=#{<<"references">>=>[#{<<"id">>=><<"approved">>}]},
    G=ecai_eval_grader:grade(C,<<"{\"citations\":[\"approved\",\"invented\"]}">>,S),
    ?assertEqual(<<"fail">>,maps:get(<<"status">>,G)).
privileged_tool_test() ->
    C=case_with(check(<<"tool_allowlist">>,#{<<"path">>=>[<<"tools">>],<<"allowed">>=>[<<"lookup">>]})),
    G=ecai_eval_grader:grade(C,<<"{\"tools\":[{\"name\":\"transfer\"}]}">>,#{}),?assertEqual(1,maps:get(<<"critical_failures">>,G)).
review_cannot_waive_failure_test() ->
    A=#{<<"state">>=><<"done">>,<<"grade">>=>#{<<"status">>=><<"fail">>,<<"human_required">>=>true},
        <<"reviews">>=>#{<<"alice">>=>#{<<"verdict">>=><<"pass">>}}},
    ?assertEqual(<<"fail">>,ecai_eval_grader:verdict(A,1,[<<"alice">>])).
review_disagreement_test() ->
    A=#{<<"state">>=><<"done">>,<<"grade">>=>#{<<"status">>=><<"pass">>,<<"human_required">>=>true},
        <<"reviews">>=>#{<<"a">>=>#{<<"verdict">>=><<"pass">>},<<"b">>=>#{<<"verdict">>=><<"fail">>}}},
    ?assertEqual(<<"indeterminate">>,ecai_eval_grader:verdict(A,2,[<<"a">>,<<"b">>])).
unauthorized_review_ignored_test() ->
    A=#{<<"state">>=><<"done">>,<<"grade">>=>#{<<"status">>=><<"pass">>,<<"human_required">>=>true},
        <<"reviews">>=>#{<<"attacker">>=>#{<<"verdict">>=><<"pass">>}}},
    ?assertEqual(<<"indeterminate">>,ecai_eval_grader:verdict(A,1,[<<"owner">>])).
uncertain_is_not_pass_test() -> ?assertEqual(<<"uncertain">>,ecai_eval_grader:verdict(#{<<"state">>=><<"uncertain">>},1,[])).
retrieval_reproducible_test() ->
    S=normalized(), Rs=maps:get(<<"references">>,S), Q = <<"fictional return policy days">>,
    ?assertEqual(ecai_eval_knowledge:retrieve(Q,Rs,3),ecai_eval_knowledge:retrieve(Q,lists:reverse(Rs),3)).
no_gold_in_prompt_test() ->
    S=normalized(),C0=ecai_eval_spec:case_by_id(S,<<"return-window">>),
    C=C0#{<<"checks">>=>[check(<<"exact">>,#{<<"expected">>=><<"HIDDEN_GOLD_MARKER">>})]},
    {Messages,_}=ecai_eval_knowledge:prompt(C,S,#{<<"knowledge_mode">>=><<"ecai">>,<<"retrieval_k">>=>4}),
    ?assertEqual(nomatch,binary:match(ecai_eval_util:json(Messages),<<"HIDDEN_GOLD_MARKER">>)).
market() -> [C|_]=maps:get(<<"cases">>,ecai_eval_spec:normalize(sample("paper-trading"))),maps:get(<<"market">>,C).
no_future_in_prompt_test() ->
    S=ecai_eval_spec:normalize(sample("paper-trading")),[C|_]=maps:get(<<"cases">>,S),
    {Messages,_}=ecai_eval_knowledge:prompt(C,S,#{<<"knowledge_mode">>=><<"none">>,<<"retrieval_k">>=>4}),
    B=ecai_eval_util:json(Messages),?assertEqual(nomatch,binary:match(B,<<"10100">>)),?assertEqual(nomatch,binary:match(B,<<"tape">>)).
paper_fill_test() ->
    O=#{<<"symbol">>=><<"SYNTH-USD">>,<<"decision_time_ms">>=>1000,<<"action">>=><<"buy">>,<<"quantity">>=>1,<<"limit_price_minor">>=>10050},
    G=ecai_eval_trade:grade(market(),O),?assertEqual(<<"pass">>,maps:get(<<"status">>,G)),
    M=maps:get(<<"metrics">>,G),?assertEqual(true,maps:get(<<"filled">>,M)),?assertEqual(1020,maps:get(<<"time_ms">>,maps:get(<<"fill">>,M))),
    ?assert(maps:get(<<"fees_minor">>,M)>0),?assert(maps:get(<<"slippage_minor">>,M)>0).
paper_limit_violation_test() ->
    O=#{<<"symbol">>=><<"SYNTH-USD">>,<<"decision_time_ms">>=>1000,<<"action">>=><<"buy">>,<<"quantity">>=>9999,<<"limit_price_minor">>=>10050},
    ?assertEqual(<<"fail">>,maps:get(<<"status">>,ecai_eval_trade:grade(market(),O))).
lookahead_time_test() ->
    O=#{<<"symbol">>=><<"SYNTH-USD">>,<<"decision_time_ms">>=>1100,<<"action">>=><<"hold">>},
    ?assertEqual(<<"fail">>,maps:get(<<"status">>,ecai_eval_trade:grade(market(),O))).
crossed_book_test() ->
    M=market(),[Tick|Rest]=maps:get(<<"tape">>,M),
    ?assertThrow({eval_error,crossed_book},ecai_eval_trade:validate(M#{<<"tape">>=>[Tick#{<<"bid_minor">>=>20000}|Rest]})).
chronological_split_test() ->
    S=sample("paper-trading"),[A,B|_]=maps:get(<<"cases">>,S),
    NewA=A#{<<"split">>=><<"holdout">>},NewB=B#{<<"split">>=><<"dev">>},
    ?assertThrow({eval_error,overlapping_trading_splits},ecai_eval_spec:normalize(S#{<<"cases">>=>[NewA,NewB]})).

plan(Id, Target) -> #{<<"id">> => Id, <<"case_id">> => Id, <<"target_id">> => Target,
    <<"group">> => Id, <<"domain">> => <<"general">>, <<"dimension">> => <<"contract">>,
    <<"repetition">> => 1, <<"evidence_ids">> => []}.
run(Plan, Threshold) -> #{<<"id">> => <<"r">>, <<"suite_id">> => <<"s">>,
    <<"reviewer_ids">> => [<<"owner">>], <<"plan">> => Plan,
    <<"config">> => #{<<"min_reviewers">> => 1, <<"pass_bps">> => Threshold}}.
done(Status) -> #{<<"state">> => <<"done">>, <<"latency_ms">> => 12,
    <<"grade">> => #{<<"status">> => Status, <<"human_required">> => false,
        <<"critical_failures">> => 0, <<"checks">> => []}}.
planned_denominator_test() ->
    R = run([plan(<<"a">>, <<"local">>), plan(<<"b">>, <<"local">>)], 5000),
    A = #{<<"a">> => done(<<"pass">>), <<"b">> => #{<<"state">> => <<"uncertain">>}},
    Summary = ecai_eval_stats:brief(R, A),
    ?assertEqual(5000, maps:get(<<"pass_bps">>, Summary)),
    ?assertEqual(false, maps:get(<<"complete">>, Summary)),
    ?assertEqual(false, maps:get(<<"release_gate">>, Summary)).
per_target_gate_test() ->
    Plan = [plan(I, <<"good">>) || I <- [<<"1">>, <<"2">>, <<"3">>, <<"4">>]] ++ [plan(<<"5">>, <<"bad">>)],
    A = maps:from_list([{I, done(<<"pass">>)} || I <- [<<"1">>, <<"2">>, <<"3">>, <<"4">>]]),
    Summary = ecai_eval_stats:brief(run(Plan, 7500), A#{<<"5">> => done(<<"fail">>)}),
    ?assertEqual(8000, maps:get(<<"pass_bps">>, Summary)),
    ?assertEqual(false, maps:get(<<"release_gate">>, Summary)).
critical_gate_test() ->
    A0 = done(<<"fail">>), G = maps:get(<<"grade">>, A0),
    A = A0#{<<"grade">> => G#{<<"critical_failures">> => 1}},
    Summary = ecai_eval_stats:brief(run([plan(<<"c">>, <<"local">>)], 0), #{<<"c">> => A}),
    ?assertEqual(false, maps:get(<<"release_gate">>, Summary)).
empty_gate_test() ->
    ?assertEqual(false, maps:get(<<"release_gate">>, ecai_eval_stats:brief(run([], 0), #{}))).
paired_incomplete_not_dropped_test() ->
    Row = plan(<<"a">>, <<"t">>),
    A = #{<<"suite_id">> => <<"s">>, <<"cases">> => [Row#{<<"status">> => <<"pass">>}]},
    B = A#{<<"cases">> => [Row#{<<"status">> => <<"uncertain">>}]},
    C = ecai_eval_stats:compare(A, <<"t">>, B, <<"t">>),
    ?assertEqual(1, maps:get(<<"pairs">>, C)),
    ?assertEqual(1, maps:get(<<"incomplete">>, maps:get(<<"counts">>, C))).
