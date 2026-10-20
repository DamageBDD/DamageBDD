-module(ecai_chat_personality_tests).
-include_lib("eunit/include/eunit.hrl").

owned_personality_and_project_instructions_reach_model_test() ->
    with_worker(fun(_Worker) ->
        Options = #{self_store => false, personality_ref => <<"purchase:alice-order">>,
            project_instructions => <<"Prefer Erlang examples.">>,
            %% Caller-authored prompt content is deliberately ignored.
            personality_prompt => <<"UNTRUSTED OVERRIDE">>,
            history_context => [#{role => <<"user">>, content => <<"Earlier context">>}]},
        ?assertEqual({ok, <<"fresh model reply">>},
            ecai_chat:get_reply(<<"session-a">>, <<"alice">>, <<"Question">>, Options)),
        [Request] = calls(),
        System = maps:get(<<"system">>, Request),
        ?assertMatch({0, _}, binary:match(System, <<"BASE SYSTEM RULES">>)),
        ?assertNotEqual(nomatch, binary:match(System, <<"Ask for evidence.">>)),
        ?assertEqual(nomatch, binary:match(System, <<"UNTRUSTED OVERRIDE">>)),
        Prompt = maps:get(<<"prompt">>, Request),
        ?assertNotEqual(nomatch, binary:match(Prompt, <<"Prefer Erlang examples.">>)),
        ?assertNotEqual(nomatch, binary:match(Prompt, <<"Earlier context">>))
    end).

same_worker_recovers_default_and_never_replays_persona_answer_test() ->
    with_worker(fun(Worker) ->
        {ok, _} = ecai_chat:get_reply(<<"session-a">>, <<"alice">>, <<"Question">>,
            #{self_store => false, personality_ref => <<"purchase:alice-order">>}),
        {ok, _} = gen_server:call(Worker,
            {store, <<"session-a">>, <<"alice">>, <<"Question">>, <<"OLD PERSONALITY ANSWER">>}),
        ets:delete_all_objects(ecai_chat_test_calls),
        ?assertEqual({ok, <<"fresh model reply">>},
            ecai_chat:get_reply(<<"session-a">>, <<"alice">>, <<"Question">>, #{self_store => true})),
        [Request] = calls(),
        ?assertEqual(<<"BASE SYSTEM RULES">>, maps:get(<<"system">>, Request)),
        %% Previous content is available as a source, but is never returned as the answer.
        ?assertNotEqual(nomatch, binary:match(maps:get(<<"prompt">>, Request), <<"OLD PERSONALITY ANSWER">>)),
        State = sys:get_state(Worker),
        ?assertEqual(<<"BASE SYSTEM RULES">>, element(tuple_size(State), State))
    end).

unauthorized_malformed_and_unavailable_personalities_never_infer_test() ->
    with_worker(fun(_Worker) ->
        Cases = [
            {<<"bob">>, <<"purchase:alice-order">>, personality_not_owned},
            {<<"alice">>, #{system_prompt => <<"spoof">>}, invalid_personality},
            {<<"alice">>, <<"unknown">>, invalid_personality},
            {<<"alice">>, <<"purchase:unavailable">>, personality_unavailable}
        ],
        lists:foreach(fun({Owner, Ref, Error}) ->
            ?assertEqual({error, Error}, ecai_chat:get_reply(<<"session">>, Owner, <<"Question">>,
                #{self_store => false, personality_ref => Ref}))
        end, Cases),
        ?assertEqual([], calls())
    end).

entitlement_is_resolved_on_every_request_test() ->
    with_worker(fun(_Worker) ->
        Options = #{self_store => false, personality_ref => <<"purchase:alice-order">>},
        {ok, _} = ecai_chat:get_reply(<<"session-a">>, <<"alice">>, <<"Question">>, Options),
        persistent_term:put(ecai_chat_test_revoked, true),
        ets:delete_all_objects(ecai_chat_test_calls),
        ?assertEqual({error, personality_not_owned},
            ecai_chat:get_reply(<<"session-a">>, <<"alice">>, <<"Again">>, Options)),
        ?assertEqual([], calls()),
        {ok, _} = ecai_chat:get_reply(<<"session-a">>, <<"alice">>, <<"Default">>, #{self_store => false}),
        [Request] = calls(),
        ?assertEqual(<<"BASE SYSTEM RULES">>, maps:get(<<"system">>, Request))
    end).

memory_never_crosses_owner_or_session_boundaries_test() ->
    with_worker(fun(Worker) ->
        {ok, _} = gen_server:call(Worker,
            {store, <<"other-session">>, <<"alice">>, <<"Question">>, <<"OTHER SESSION SECRET">>}),
        {ok, _} = gen_server:call(Worker,
            {store, <<"session-a">>, <<"bob">>, <<"Other">>, <<"OTHER OWNER SECRET">>}),
        {ok, _} = ecai_chat:get_reply(<<"session-a">>, <<"alice">>, <<"Question">>,
            #{self_store => true}),
        [Request] = calls(),
        Prompt = maps:get(<<"prompt">>, Request),
        ?assertEqual(nomatch, binary:match(Prompt, <<"OTHER SESSION SECRET">>)),
        ?assertEqual(nomatch, binary:match(Prompt, <<"OTHER OWNER SECRET">>))
    end).

persistent_history_excludes_legacy_cache_even_with_matching_identifiers_test() ->
    with_worker(fun(Worker) ->
        {ok, _} = gen_server:call(Worker,
            {store, <<"session-a">>, <<"alice">>, <<"Question">>, <<"ATTACKER SEEDED LEGACY ANSWER">>}),
        lists:foreach(fun(Ref) ->
            ets:delete_all_objects(ecai_chat_test_calls),
            {ok, _} = ecai_chat:get_reply(<<"session-a">>, <<"alice">>, <<"Question">>,
                #{self_store => false, personality_ref => Ref,
                  history_context => [#{role => <<"user">>, content => <<"AUTHORIZED HISTORY">>}]}),
            [Request] = calls(),
            Prompt = maps:get(<<"prompt">>, Request),
            ?assertEqual(nomatch, binary:match(Prompt, <<"ATTACKER SEEDED LEGACY ANSWER">>)),
            ?assertNotEqual(nomatch, binary:match(Prompt, <<"AUTHORIZED HISTORY">>))
        end, [<<"default">>, <<"purchase:alice-order">>])
    end).

legacy_call_stays_default_test() ->
    with_worker(fun(Worker) ->
        ?assertEqual({ok, <<"fresh model reply">>},
            gen_server:call(Worker, {infer, <<"legacy-session">>, <<"legacy-owner">>,
                                   <<"Question">>, [], <<>>, false})),
        [Request] = calls(),
        ?assertEqual(<<"BASE SYSTEM RULES">>, maps:get(<<"system">>, Request))
    end).

calls() -> [Body || {_Id, Body} <- lists:sort(ets:tab2list(ecai_chat_test_calls))].

with_worker(F) ->
    ets:new(ecai_chat_test_calls, [named_table, public, ordered_set]),
    persistent_term:put(ecai_chat_test_revoked, false),
    {ok, Worker} = ecai_chat:start_link([{system_prompt, <<"BASE SYSTEM RULES">>}]),
    persistent_term:put(ecai_chat_test_worker, Worker),
    try F(Worker)
    after
        gen_server:stop(Worker),
        persistent_term:erase(ecai_chat_test_worker),
        persistent_term:erase(ecai_chat_test_revoked),
        ets:delete(ecai_chat_test_calls)
    end.
