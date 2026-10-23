-module(damage_agent_tests).
-include_lib("eunit/include/eunit.hrl").

agent_test_() -> {setup,fun setup/0,fun cleanup/1,fun(_) -> [
    ?_test(owner_isolation()), ?_test(idempotency()), ?_test(complete_and_export()),
    ?_test(reject_unlisted_skill()), ?_test(no_self_certification()),
    ?_test(approval_is_exact_and_one_shot()), ?_test(cancel_is_not_rollback()),
    ?_test(provider_timeout()), ?_test(dry_run_is_side_effect_free()),
    ?_test(policy_change_invalidates_approval()), ?_test(waiting_pause_is_idempotent()),
    ?_test(policy_hash_preserves_types()), ?_test(recovery_does_not_reexecute())
] end}.

owner() -> <<"ak_agent_test_owner">>.
setup() ->
    %% Never replace settings underneath a live task service.
    undefined = whereis(damage_agent_sup),
    application:ensure_all_started(crypto),
    Dir = filename:join("/tmp","damage-agent-tests-"++integer_to_list(erlang:unique_integer([positive]))),
    Previous = application:get_env(damage,agentic),
    application:set_env(damage,agentic,settings(Dir)),
    {ok,Pid} = damage_agent_sup:start_link(),unlink(Pid),
    {Dir,Previous}.
cleanup({Dir,Previous}) ->
    case whereis(damage_agent_sup) of undefined -> ok; P -> gen_server:stop(P,shutdown,10000) end,
    persistent_term:erase({damage_agent_test_adapter,observer}),
    file:del_dir_r(Dir),
    case Previous of undefined -> application:unset_env(damage,agentic); {ok,V} -> application:set_env(damage,agentic,V) end.
settings(Dir) -> [
    {enabled,true},{accounting_required,false},{owners,[owner()]},{state_dir,Dir},{max_tasks_per_owner,20},
    {max_active_tasks,30},{max_saved_tasks,100},
    {provider,{damage_agent_test_provider,[]}},
    {templates,[
        {<<"review">>,review_template(5000)},
        {<<"timeout">>,review_template(30)},
        {<<"approval">>,write_template(0)},
        {<<"slow-write">>,write_template(5000)}
    ]}].
review_template(Timeout) -> [
    {description,<<"fixture">>},{max_iterations,6},{max_wall_seconds,30},
    {operation_timeout_ms,Timeout},{required_actions,[<<"report">>]},
    {verifier,{artifact,<<"review.md">>}},
    {actions,[{<<"report">>,[{type,artifact},{effect,local_artifact},{name,<<"review.md">>}]}]}].
write_template(Delay) -> [
    {max_iterations,6},{max_wall_seconds,30},{operation_timeout_ms,10000},
    {required_actions,[<<"change">>]},{verifier,{adapter,damage_agent_test_adapter,[]}},
    {actions,[{<<"change">>,[{type,adapter},{effect,external_write},
        {module,damage_agent_test_adapter},{options,[{delay_ms,Delay}]}]}]}].
start(Template,Goal) ->
    Key = integer_to_binary(erlang:unique_integer([positive])),
    {ok,J} = damage_agent:start(owner(),Template,Goal,Key),maps:get(id,J).
wait(Id,Status) -> wait(Id,Status,erlang:monotonic_time(millisecond)+3000).
wait(Id,Status,Deadline) ->
    {ok,J} = damage_agent:status(owner(),Id),
    case maps:get(status,J) of
        Status -> J;
        Other ->
            case erlang:monotonic_time(millisecond) >= Deadline of
                true -> error({unexpected_task_status,Status,Other,J});
                false -> timer:sleep(10),wait(Id,Status,Deadline)
            end
    end.

owner_isolation() ->
    Id = start(<<"review">>,<<"review fixture">>),wait(Id,completed),
    ?assertEqual({error,not_found},damage_agent:status(<<"ak_other">>,Id)),
    ?assertEqual({error,not_found},damage_agent:events(<<"ak_other">>,Id)),
    ?assertEqual({error,not_found},damage_agent:learning(<<"ak_other">>,Id)),
    ?assertEqual({error,forbidden},damage_agent:start(<<"ak_other">>,<<"review">>,<<"x">>,<<"key">>)).
idempotency() ->
    {ok,A} = damage_agent:start(owner(),<<"review">>,<<"same">>,<<"stable-request">>),
    {ok,B} = damage_agent:start(owner(),<<"review">>,<<"same">>,<<"stable-request">>),
    ?assertEqual(maps:get(id,A),maps:get(id,B)),
    ?assertEqual({error,idempotency_conflict},damage_agent:start(owner(),<<"review">>,<<"changed">>,<<"stable-request">>)),
    wait(maps:get(id,A),completed).
complete_and_export() ->
    Id = start(<<"review">>,<<"review">>),wait(Id,completed),
    {ok,E} = damage_agent:learning(owner(),Id),
    ?assertEqual(false,maps:get(training_eligible,E)),
    ?assertEqual(ok,damage_agent_store:verify(#{task => maps:get(checkpoint,E),events => maps:get(events,E)})),
    [First|Rest] = maps:get(events,E),
    ?assertException(error,_,damage_agent_store:verify(#{task => maps:get(checkpoint,E),
        events => [First#{kind => tampered}|Rest]})).
reject_unlisted_skill() ->
    Id = start(<<"review">>,<<"invalid">>),J = wait(Id,failed),
    ?assertEqual(invalid_or_forbidden_plan,maps:get(reason,J)),
    ?assertEqual(0,maps:get(action_calls,J)).
no_self_certification() ->
    Id = start(<<"review">>,<<"early finish">>),J = wait(Id,failed),
    ?assertEqual(missing_required_evidence,maps:get(reason,J)).
approval_is_exact_and_one_shot() ->
    persistent_term:put({damage_agent_test_adapter,observer},self()),
    Id = start(<<"approval">>,<<"effect">>),J = wait(Id,awaiting_approval),
    receive {agent_test_effect,_} -> error(effect_before_approval) after 30 -> ok end,
    ?assertEqual({error,stale_or_invalid_approval},damage_agent:command(owner(),Id,<<"approve">>,<<"wrong">>)),
    H = maps:get(hash,maps:get(pending,J)),
    ?assertMatch({ok,_},damage_agent:command(owner(),Id,<<"approve">>,H)),
    wait(Id,completed),
    receive {agent_test_effect,H} -> ok after 500 -> error(no_effect) end,
    ?assertMatch({error,_},damage_agent:command(owner(),Id,<<"approve">>,H)),
    receive {agent_test_effect,_} -> error(duplicate_effect) after 30 -> ok end.
cancel_is_not_rollback() ->
    Id = start(<<"slow-write">>,<<"effect">>),J = wait(Id,awaiting_approval),
    {ok,_} = damage_agent:command(owner(),Id,<<"approve">>,maps:get(hash,maps:get(pending,J))),
    wait(Id,executing),
    {ok,C} = damage_agent:command(owner(),Id,<<"cancel">>,<<>>),
    ?assertEqual(cancelled_unreconciled,maps:get(status,C)).
provider_timeout() ->
    Id = start(<<"timeout">>,<<"hang">>),J = wait(Id,failed),
    ?assertEqual(operation_timeout,maps:get(reason,J)).
dry_run_is_side_effect_free() ->
    Before = length(damage_agent:list(owner())),
    C = #{public_key => owner()},
    ?assertEqual(C,steps_agentic:step_dry([],C,<<"When">>,1,
        ["I start an agent task named","dry","with objective"],<<"not executed">>)),
    ?assertEqual(Before,length(damage_agent:list(owner()))),
    ?assertError(function_clause,steps_agentic:step_dry([],C,<<"When">>,1,["unrelated step"],<<>>)).
policy_change_invalidates_approval() ->
    Id = start(<<"approval">>,<<"effect">>),J = wait(Id,awaiting_approval),
    {ok,Old} = application:get_env(damage,agentic),
    Templates = proplists:get_value(templates,Old),
    Changed = [{description,<<"changed policy">>}|proplists:get_value(<<"approval">>,Templates)],
    NewTemplates = lists:keyreplace(<<"approval">>,1,Templates,{<<"approval">>,Changed}),
    application:set_env(damage,agentic,lists:keyreplace(templates,1,Old,{templates,NewTemplates})),
    ?assertMatch({error,_},damage_agent:command(owner(),Id,<<"approve">>,maps:get(hash,maps:get(pending,J)))),
    application:set_env(damage,agentic,Old),
    damage_agent:command(owner(),Id,<<"cancel">>,<<>>).
recovery_does_not_reexecute() ->
    Id = start(<<"slow-write">>,<<"effect">>),J = wait(Id,awaiting_approval),
    {ok,_} = damage_agent:command(owner(),Id,<<"approve">>,maps:get(hash,maps:get(pending,J))),
    wait(Id,executing),
    gen_server:stop(whereis(damage_agent_sup),shutdown,10000),
    {ok,P} = damage_agent_sup:start_link(),unlink(P),
    Recovered = wait(Id,interrupted),
    ?assertEqual(executing,maps:get(interrupted_phase,Recovered)),
    ?assertEqual({error,reconciliation_required},damage_agent:command(owner(),Id,<<"resume">>,<<>>)),
    damage_agent:command(owner(),Id,<<"cancel">>,<<>>).

waiting_pause_is_idempotent() ->
    Id = start(<<"review">>,<<"wait">>),wait(Id,waiting),
    {ok,E} = damage_agent:learning(owner(),Id),
    ?assertEqual(ok,damage_agent_store:verify(#{task => maps:get(checkpoint,E),events => maps:get(events,E)})),
    {ok,A} = damage_agent:command(owner(),Id,<<"pause">>,<<>>),
    {ok,B} = damage_agent:command(owner(),Id,<<"pause">>,<<>>),
    ?assertEqual(paused,maps:get(status,B)),
    ?assertEqual(maps:get(revision,A),maps:get(revision,B)),
    {ok,_} = damage_agent:command(owner(),Id,<<"resume">>,<<>>),
    wait(Id,waiting),
    {ok,C} = damage_agent:command(owner(),Id,<<"cancel">>,<<>>),
    ?assertEqual(cancelled,maps:get(status,C)).
policy_hash_preserves_types() ->
    {ok,Before} = damage_agent_policy:template(owner(),<<"review">>),
    {ok,Old} = application:get_env(damage,agentic),
    Templates = proplists:get_value(templates,Old),
    Template = proplists:get_value(<<"review">>,Templates),
    Changed = lists:keyreplace(description,1,Template,{description,fixture}),
    NewTemplates = lists:keyreplace(<<"review">>,1,Templates,{<<"review">>,Changed}),
    try
        application:set_env(damage,agentic,lists:keyreplace(templates,1,Old,{templates,NewTemplates})),
        {ok,After} = damage_agent_policy:template(owner(),<<"review">>),
        ?assertNotEqual(maps:get(hash,Before),maps:get(hash,After))
    after application:set_env(damage,agentic,Old) end.
