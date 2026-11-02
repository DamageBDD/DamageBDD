-module(damage_ai_ecai_tests).
-include_lib("eunit/include/eunit.hrl").
usage_and_text_test() ->
    ?assertEqual({ok,#{text=><<"Answer">>,model=><<"fixture">>,usage=>#{input_tokens=>7,output_tokens=>2}}},
        damage_ai_ecai:normalize_result(<<"Answer">>,#{provider=>anthropic,model=><<"fixture">>,input_tokens=>7,output_tokens=>2})).
missing_usage_is_not_zero_test() ->
    {ok, #{usage := U}} = damage_ai_ecai:normalize_result(
        <<"Answer">>, #{provider => ollama, model => <<"fixture">>}),
    ?assertEqual(#{}, U).
ollama_usage_test() ->
    ?assertMatch({ok,#{usage:=#{input_tokens:=7,output_tokens:=2}}},
        damage_ai_ecai:normalize_result(<<"Answer">>,#{provider=>ollama,model=><<"fixture">>,prompt_eval_count=>7,eval_count=>2})).
partial_and_invalid_responses_fail_test() ->
    ?assertMatch({error,_},damage_ai_ecai:normalize_result(<<"Partial">>,#{provider=>openai,status=><<"incomplete">>,model=><<"fixture">>})),
    ?assertMatch({error,_},damage_ai_ecai:normalize_result(<<"Partial">>,#{provider=>ollama,done_reason=><<"length">>,model=><<"fixture">>})),
    ?assertMatch({error,_},damage_ai_ecai:normalize_result(<<"Answer">>,#{})),
    ?assertMatch({error,_},damage_ai_ecai:normalize_result(<<>>,#{model=><<"fixture">>})).
embeddings_not_silently_rerouted_test() ->
    ?assertEqual({error,invalid_profile},damage_ai_ecai:invoke([],#{operation=>embedding,input=><<"Text">>})).
