-module(damage_agent_test_provider).
-export([next/2]).
next(#{goal := <<"hang">>},_) -> timer:sleep(60000),{error,late};
next(#{goal := <<"invalid">>},_) -> {ok,plan(<<"act">>,<<"shell">>,#{}),#{}};
next(#{goal := <<"early finish">>},_) -> {ok,plan(<<"finish">>,<<>>,#{}),#{}};
next(#{goal := <<"wait">>},_) ->
    {ok,(plan(<<"wait">>,<<>>,#{}))#{<<"seconds">> => 1},#{}};
next(#{completed_actions := Done,skills := [#{id := Skill}|_]},_) ->
    case lists:member(Skill,Done) of
        true -> {ok,plan(<<"finish">>,<<>>,#{}),#{}};
        false ->
            Args = case Skill of <<"report">> -> #{<<"content">> => <<"A fixture report">>}; _ -> #{} end,
            {ok,plan(<<"act">>,Skill,Args),#{<<"model">> => <<"deterministic-test-provider">>}}
    end.
plan(Op,Skill,Args) -> #{<<"op">> => Op,<<"skill">> => Skill,<<"args">> => Args,
                         <<"seconds">> => 0,<<"summary">> => <<"fixture proposal">>}.
