-module(damage_agent_accounting_tests).
-include_lib("eunit/include/eunit.hrl").
-define(BACKEND,damage_agent_accounting_test_backend).

accounting_test_() ->
    {foreach,fun setup/0,fun cleanup/1,[
        fun(_) -> ?_test(reserve_precedes_all_work()) end,
        fun(_) -> ?_test(duplicate_request_does_not_reserve_twice()) end,
        fun(_) -> ?_test(denied_reservation_runs_nothing()) end,
        fun(_) -> ?_test(over_budget_stops_before_action()) end,
        fun(_) -> ?_test(zero_ceiling_is_rejected()) end,
        fun(_) -> ?_test(policy_denial_does_not_charge_invocation()) end,
        fun(_) -> ?_test(failed_plan_is_not_passed_receipt()) end,
        fun(_) -> ?_test(lost_reserve_response_never_executes()) end,
        fun(_) -> ?_test(lost_settlement_response_is_not_recharged()) end,
        fun(_) -> ?_test(lost_receipt_response_is_not_resettled()) end,
        fun(_) -> ?_test(reconciliation_is_identity_bound()) end,
        fun(_) -> ?_test(restart_does_not_resubmit_settlement()) end,
        fun(_) -> ?_test(concurrent_tasks_cannot_overreserve()) end,
        fun(_) -> ?_test(dry_steps_do_not_touch_accounting()) end,
        fun(_) -> ?_test(legacy_execution_requires_approved_template()) end
    ]}.
owner() -> <<"ak_accounting_test_owner">>.
setup() ->
    undefined = whereis(damage_agent_sup),
    application:ensure_all_started(crypto),
    Previous = {application:get_env(damage,agentic),application:get_env(damage,ae_network_id)},
    Dir = filename:join("/tmp","agent-accounting-"++integer_to_list(erlang:unique_integer([positive]))),
    application:set_env(damage,ae_network_id,<<"ae_uat">>),
    application:set_env(damage,agentic,[
        {enabled,true},{owners,[owner()]},{state_dir,Dir},{accounting_required,true},
        {agent_bindings,[{owner(),[<<"bot">>]}]},
        {accounting_backend,?BACKEND},{max_tasks_per_owner,20},
        {provider,{damage_agent_test_provider,[]}},
        {templates,[{<<"review">>,template(20)},{<<"small">>,template(3)},
                    {<<"zero">>,template(0)},{<<"large">>,template(60)}]}]),
    {ok,BP} = ?BACKEND:start_link(),unlink(BP),
    {ok,P} = damage_agent_sup:start_link(),unlink(P),
    {Dir,Previous}.
cleanup({Dir,{Cfg,Net}}) ->
    gen_server:stop(whereis(damage_agent_sup),shutdown,10000),
    ?BACKEND:stop(),file:del_dir_r(Dir),
    restore(agentic,Cfg),restore(ae_network_id,Net).
restore(K,undefined) -> application:unset_env(damage,K);
restore(K,{ok,V}) -> application:set_env(damage,K,V).
template(Cap) -> [
    {max_iterations,8},{max_wall_seconds,60},{operation_timeout_ms,60000},
    {required_actions,[<<"report">>]},{verifier,{artifact,<<"review.md">>}},
    {accounting,[{mode,aeternity},{agent_id,<<"bot">>},{max_cost_units,Cap},
        {task_method,<<"bdd_execute">>},{planner,{2,<<"llm_next">>}},
        {verifier,{1,<<"bdd_verify">>}},{actions,[{<<"report">>,{3,<<"write_report">>}}]}]},
    {actions,[{<<"report">>,[{type,artifact},{effect,local_artifact},{name,<<"review.md">>}]}]}].
start(T,G) ->
    K = integer_to_binary(erlang:unique_integer([positive])),
    {ok,J} = damage_agent:start(owner(),T,G,K),maps:get(id,J).
wait(Id,Want) -> wait(Id,Want,erlang:monotonic_time(millisecond)+4000).
wait(Id,Want,End) ->
    {ok,J} = damage_agent:status(owner(),Id),
    case maps:get(status,J) =:= Want of
        true -> J;
        false ->
            case erlang:monotonic_time(millisecond) < End of
                true -> timer:sleep(5),wait(Id,Want,End);
                false -> error({unexpected_status,Want,J})
            end
    end.
count(Name,J) ->
    Id = maps:get(job_id,maps:get(budget,J)),
    length([ok || {N,K} <- maps:get(calls,?BACKEND:snapshot()),N =:= Name,K =:= Id]).
reconcile(Id) -> ?assertMatch({ok,_},damage_agent:command(owner(),Id,<<"reconcile">>,<<>>)).

reserve_precedes_all_work() ->
    Id = start(<<"review">>,<<"review">>),J = wait(Id,completed),
    B = maps:get(budget,J),?assertEqual(8,maps:get(spent_units,B)),
    ?assertEqual(complete,maps:get(status,B)),?assertEqual(4,maps:get(dispatch_count,B)),
    {ok,Events} = damage_agent:events(owner(),Id),
    [Reserved] = [maps:get(sequence,E) || E <- Events,maps:get(kind,E) =:= budget_reserved],
    Charges = [maps:get(sequence,E) || E <- Events,maps:get(kind,E) =:= invocation_charged],
    ?assert(lists:all(fun(N) -> N > Reserved end,Charges)),
    ?assertEqual(1,count(reserve,J)),?assertEqual(1,count(settle,J)),?assertEqual(1,count(receipt,J)),
    ?assertEqual(<<"passed">>,maps:get(status,maps:get(receipt,J))).
duplicate_request_does_not_reserve_twice() ->
    {ok,A} = damage_agent:start(owner(),<<"review">>,<<"review">>,<<"same-key">>),
    {ok,B} = damage_agent:start(owner(),<<"review">>,<<"review">>,<<"same-key">>),
    ?assertEqual(maps:get(id,A),maps:get(id,B)),J = wait(maps:get(id,A),completed),
    ?assertEqual(1,count(reserve,J)),?assertEqual(1,count(settle,J)).
denied_reservation_runs_nothing() ->
    ?BACKEND:set(deny_reserve,true),Id = start(<<"review">>,<<"review">>),J = wait(Id,failed),
    ?assertEqual(0,maps:get(llm_calls,J)),?assertEqual(0,maps:get(action_calls,J)),
    ?assertEqual(0,count(settle,J)).
over_budget_stops_before_action() ->
    Id = start(<<"small">>,<<"review">>),J = wait(Id,exhausted),B = maps:get(budget,J),
    ?assertEqual(2,maps:get(spent_units,B)),?assertEqual(1,maps:get(dispatch_count,B)),
    ?assertEqual([],maps:get(completed_skills,J)),
    ?assertEqual(2,maps:get(cost,maps:get(receipt,J))).
zero_ceiling_is_rejected() ->
    ?assertEqual({error,invalid_accounting_configuration},
        damage_agent:start(owner(),<<"zero">>,<<"review">>,<<"zero">>)),
    ?assertEqual([],maps:get(calls,?BACKEND:snapshot())).
policy_denial_does_not_charge_invocation() ->
    ?BACKEND:set(deny_method,<<"llm_next">>),Id = start(<<"review">>,<<"review">>),J = wait(Id,failed),
    ?assertEqual(0,maps:get(spent_units,maps:get(budget,J))),
    ?assertEqual(chain_policy_denied,maps:get(reason,J)),?assertEqual(1,count(settle,J)).
failed_plan_is_not_passed_receipt() ->
    Id = start(<<"review">>,<<"invalid">>),J = wait(Id,failed),
    ?assertEqual(<<"error">>,maps:get(status,maps:get(receipt,J))),
    ?assertEqual(2,maps:get(cost,maps:get(receipt,J))).
lost_reserve_response_never_executes() ->
    ?BACKEND:set(lose_reserve,true),Id = start(<<"review">>,<<"review">>),J = wait(Id,accounting_pending),
    ?assertEqual(0,maps:get(llm_calls,J)),
    ?assertEqual({error,reconciliation_required},damage_agent:command(owner(),Id,<<"resume">>,<<>>)),
    reconcile(Id),Done = wait(Id,cancelled),
    ?assertEqual(1,count(reserve,Done)),?assertEqual(0,maps:get(cost,maps:get(receipt,Done))).
lost_settlement_response_is_not_recharged() ->
    ?BACKEND:set(lose_settle,true),Id = start(<<"review">>,<<"review">>),J = wait(Id,accounting_pending),
    ?assertEqual(completed,maps:get(execution_status,J)),?assertEqual(0,count(receipt,J)),
    reconcile(Id),Done = wait(Id,completed),
    ?assertEqual(1,count(settle,Done)),?assertEqual(1,count(receipt,Done)).
lost_receipt_response_is_not_resettled() ->
    ?BACKEND:set(lose_receipt,true),Id = start(<<"review">>,<<"review">>),J = wait(Id,accounting_pending),
    Before = maps:get(receipt,J),reconcile(Id),Done = wait(Id,completed),
    ?assertEqual(Before,maps:get(receipt,Done)),
    ?assertEqual(1,count(settle,Done)),?assertEqual(1,count(receipt,Done)).
reconciliation_is_identity_bound() ->
    ?BACKEND:set(lose_settle,true),?BACKEND:set(bad_reconciliation,true),
    Id = start(<<"review">>,<<"review">>),wait(Id,accounting_pending),reconcile(Id),
    J = wait(Id,accounting_pending),?assertEqual(1,count(settle,J)),?assertEqual(0,count(receipt,J)),
    ?assertEqual({error,not_found},damage_agent:command(<<"ak_other">>,Id,<<"reconcile">>,<<>>)).
restart_does_not_resubmit_settlement() ->
    ?BACKEND:set(lose_settle,true),Id = start(<<"review">>,<<"review">>),wait(Id,accounting_pending),
    gen_server:stop(whereis(damage_agent_sup),shutdown,10000),
    {ok,P} = damage_agent_sup:start_link(),unlink(P),
    J = wait(Id,interrupted),?assertEqual(1,count(settle,J)),
    reconcile(Id),Done = wait(Id,completed),?assertEqual(1,count(settle,Done)).
concurrent_tasks_cannot_overreserve() ->
    A = start(<<"large">>,<<"hang">>),wait(A,planning),
    B = start(<<"large">>,<<"review">>),J = wait(B,failed),
    ?assertEqual(0,maps:get(llm_calls,J)),?assertEqual(40,maps:get(available,?BACKEND:snapshot())),
    ?assertMatch({ok,_},damage_agent:command(owner(),A,<<"cancel">>,<<>>)),wait(A,cancelled).
dry_steps_do_not_touch_accounting() ->
    C = #{public_key => owner()},
    ?assertEqual(C,steps_agentic:step_dry([],C,<<"When">>,1,
        ["I start an agent task named","dry","with objective"],<<"do nothing">>)),
    ?assertEqual([],maps:get(calls,?BACKEND:snapshot())).
legacy_execution_requires_approved_template() ->
    ?assertEqual({error,approved_budgeted_template_required},damage_agent:execute_job(<<"bot">>,
        #{requester => owner(),feature_data => <<"Feature: arbitrary">>})),
    {ok,J} = damage_agent:execute_job(<<"bot">>,#{requester => owner(),template => <<"review">>,
        objective => <<"review">>,job_id => <<"legacy-request">>}),
    wait(maps:get(id,J),completed).

return_normalisation_test() ->
    ?assertMatch({ok,true,_},damage_agent_chain:decode(#{<<"return_type">> => <<"ok">>,<<"return_value">> => true})),
    ?assertMatch({ok,true,_},damage_agent_chain:decode(#{"return_type" => "ok","return_value" => true})),
    ?assertMatch({ok,true,_},damage_agent_chain:decode(#{return_type => ok,return_value => true})),
    ?assertMatch({error,_},damage_agent_chain:decode(#{return_type => ok,<<"return_type">> => <<"revert">>,return_value => true})),
    ?assertMatch({error,_},damage_agent_chain:decode(#{return_type => revert,return_value => <<"no">>})).
inclusion_is_not_dry_run_test() ->
    M = #{return_type => ok,return_value => true,contract_id => <<"ct_t">>,
          caller_id => <<"ak_o">>,caller_nonce => 2,height => 0},
    ?assertMatch({error,_},damage_agent_chain:inclusion(M,<<"ct_t">>,<<"ak_o">>)),
    ?assertMatch({error,_},damage_agent_chain:inclusion(M#{height => 4,return_value => false},<<"ct_t">>,<<"ak_o">>)),
    ?assertMatch({ok,_},damage_agent_chain:inclusion(M#{height => 4},<<"ct_t">>,<<"ak_o">>)),
    ?assertMatch({error,_},damage_agent_chain:inclusion(M#{height => 4},<<"ct_other">>,<<"ak_o">>)).
