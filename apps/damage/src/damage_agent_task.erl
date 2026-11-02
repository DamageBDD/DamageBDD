%% Each task is responsive while a bounded, linked operation runs separately.
-module(damage_agent_task).
-behaviour(gen_statem).
-license("Apache-2.0").
-export([start_link/1,init/1,callback_mode/0,handle_event/4,terminate/3,code_change/4,format_status/1]).

start_link(J) -> gen_statem:start_link(?MODULE,J,[]).
callback_mode() -> handle_event_function.
init(J0) ->
    process_flag(trap_exit,true),
    Recovery = maps:get(recovery,J0,false),
    J1 = maps:remove(recovery,J0),
    J = case {Recovery,maps:get(status,J1)} of
        {true,paused} -> J1;
        {true,interrupted} -> J1;
        {true,OldPhase} -> checkpoint(J1#{status => interrupted,
            interrupted_phase => OldPhase,recovery_reason => node_or_service_restarted},
            interrupted,#{phase => OldPhase});
        _ -> J1
    end,
    State = case maps:get(status,J) of queued -> ready; X -> X end,
    D = #{job => J, active => none},
    Remaining = max(0,(maps:get(deadline,J)-erlang:system_time(second))*1000),
    Timers = [{{timeout,deadline},Remaining,deadline}],
    B = maps:get(budget,J,#{status => disabled}),
    ResumeAccounting = Recovery andalso lists:member(maps:get(status,B),[settled,complete]),
    case {State,ResumeAccounting} of
        {_,true} -> {ok,State,D,Timers++[{next_event,internal,recover_accounting}]};
        {ready,false} -> {ok,ready,D,Timers++[{next_event,internal,boot}]};
        _ -> {ok,State,D,Timers}
    end.

handle_event(internal,recover_accounting,_,D=#{job := J}) ->
    case maps:get(status,maps:get(budget,J)) of
        settled -> start_receipt(D);
        complete -> terminal_finish(maps:get(execution_status,J),maps:get(reason,J),D)
    end;
handle_event(internal,boot,ready,D) -> budget_boot(D);
handle_event(internal,plan,ready,D=#{job := J}) ->
    case profile(J) of
        {ok,P} ->
            case maps:get(iteration,J) >= damage_agent_policy:limit(P,max_iterations,20) orelse
                 maps:get(llm_calls,J) >= damage_agent_policy:limit(P,max_llm_calls,20) of
                true -> finish(exhausted,iteration_or_call_budget,D);
                false ->
                    Request = damage_agent_actions:request(J,P),
                    J1 = checkpoint(maps:without([pending,reason],J#{status => planning,
                         iteration => maps:get(iteration,J)+1,llm_calls => maps:get(llm_calls,J)+1}),
                         planner_started,#{input_hash => damage_agent_codec:hash(Request)}),
                    Module = maps:get(provider,P), Opts = maps:get(provider_options,P),
                    operation(planning,fun() -> Module:next(Request,Opts) end,P,D#{job => J1})
            end;
        {error,R} -> finish(failed,R,D)
    end;
handle_event(internal,execute,ready,D) -> execute_pending(D);

handle_event(info,{agent_operation,Ref,Result},State,D=#{active := #{ref := Ref}}) ->
    D1 = clear_operation(D),
    case accounting_phase(State) of
        true -> accounting_result(State,Result,D1);
        false -> case profile(maps:get(job,D1)) of
        {ok,P} -> result(State,Result,P,D1);
        {error,R} ->
            case State of
                executing -> interrupt(State,R,D1);
                verifying -> interrupt(State,R,D1);
                _ -> finish(failed,R,D1)
            end
        end
    end;
handle_event(info,{'DOWN',Mon,process,_Pid,_Reason},State,D=#{active := #{monitor := Mon}}) ->
    operation_failed(State,operation_exited,clear_operation(D));
handle_event(state_timeout,operation_timeout,State,D) ->
    operation_failed(State,operation_timeout,clear_operation(D));
handle_event(state_timeout,wake,waiting,D) -> advance(D);
handle_event(state_timeout,approval_expired,awaiting_approval,D=#{job := J}) ->
    J1 = checkpoint(maps:remove(pending,J#{status => paused,reason => approval_expired}),
                    approval_expired,#{}),
    {next_state,paused,D#{job => J1}};
handle_event({timeout,deadline},deadline,State,D) ->
    case State of
        budget_reserving -> keep_state_and_data;
        settling -> keep_state_and_data;
        receipting -> keep_state_and_data;
        reconciling -> keep_state_and_data;
        accounting_pending -> keep_state_and_data;
        executing -> interrupt(State,wall_clock_budget,clear_operation(D));
        verifying -> interrupt(State,wall_clock_budget,clear_operation(D));
        interrupted ->
            case unsafe_resume(maps:get(job,D)) of
                true -> keep_state_and_data;
                false -> finish(exhausted,wall_clock_budget,clear_operation(D))
            end;
        _ -> finish(exhausted,wall_clock_budget,clear_operation(D))
    end;

handle_event({call,From},{command,<<"reconcile">>,_},State,D=#{job := J})
  when State =:= accounting_pending; State =:= interrupted ->
    B = maps:get(budget,J,#{}),
    case lists:member(maps:get(status,B,disabled),
                      [reservation_pending,settlement_pending,receipt_pending]) of
        true ->
            J1 = checkpoint(J#{status => reconciling},accounting_reconciliation_started,#{}),
            gen_statem:reply(From,{ok,damage_agent:public(J1)}),
            chain_operation(reconciling,reconcile,[B,maps:get(receipt,J,#{})],D#{job => J1});
        false -> {keep_state_and_data,[{reply,From,{error,execution_reconciliation_required}}]}
    end;
handle_event({call,From},{command,Cmd,_},State,_)
  when (State =:= budget_reserving orelse State =:= settling orelse
        State =:= receipting orelse State =:= reconciling),
       (Cmd =:= <<"cancel">> orelse Cmd =:= <<"pause">>) ->
    {keep_state_and_data,[{reply,From,{error,accounting_operation_in_flight}}]};
handle_event({call,From},{command,Cmd,_},accounting_pending,_)
  when Cmd =:= <<"cancel">>; Cmd =:= <<"pause">>; Cmd =:= <<"resume">> ->
    {keep_state_and_data,[{reply,From,{error,reconciliation_required}}]};
handle_event({call,From},{command,<<"cancel">>,_Hash},State,D0) ->
    D = clear_operation(D0), J = maps:get(job,D),
    %% A fixed invocation tariff is known even when an external effect is not.
    Status = case State of
        executing -> cancelled_unreconciled;
        verifying -> cancelled_unreconciled;
        interrupted -> case maps:get(interrupted_phase,J,none) of
            executing -> cancelled_unreconciled;
            verifying -> cancelled_unreconciled;
            _ -> cancelled
        end;
        _ -> cancelled
    end,
    finish_and_reply(Status,owner_cancelled,From,D);
handle_event({call,From},{command,<<"pause">>,_},interrupted,_) ->
    {keep_state_and_data,[{reply,From,{error,reconciliation_required}}]};
handle_event({call,From},{command,<<"pause">>,_},State,D=#{job := J}) ->
    %% Repeated pause requests are idempotent and cannot grow the journal forever.
    case State =:= paused orelse maps:get(pause_requested,J,false) of
        true -> {keep_state_and_data,[{reply,From,{ok,damage_agent:public(J)}}]};
        false ->
            case lists:member(State,[planning,executing,verifying,budget_preparing,budget_authorizing]) of
                true ->
                    J1 = checkpoint(J#{pause_requested => true},pause_requested,#{}),
                    {keep_state,D#{job => J1},[{reply,From,{ok,damage_agent:public(J1)}}]};
                false ->
                    J1 = checkpoint(maps:remove(pending,J#{status => paused}),paused,#{}),
                    {next_state,paused,D#{job => J1},[{reply,From,{ok,damage_agent:public(J1)}}]}
            end
    end;
handle_event({call,From},{command,<<"resume">>,_},State,D=#{job := J})
  when State =:= paused; State =:= interrupted ->
    Unsafe = (State =:= interrupted andalso unsafe_resume(J)) orelse
             (damage_agent_budget:enabled(J) andalso
              maps:get(status,maps:get(budget,J)) =/= reserved),
    case {Unsafe,profile(J)} of
        {true,_} -> {keep_state_and_data,[{reply,From,{error,reconciliation_required}}]};
        {false,{ok,_}} ->
            J1 = checkpoint(maps:without([pending,reason,interrupted_phase],
                 J#{status => ready,pause_requested => false}),resumed,#{}),
            {next_state,ready,D#{job => J1},[{reply,From,{ok,damage_agent:public(J1)}},
                                            {next_event,internal,plan}]};
        {_,{error,R}} -> {keep_state_and_data,[{reply,From,{error,R}}]}
    end;
handle_event({call,From},{command,<<"approve">>,Hash},awaiting_approval,D=#{job := J}) ->
    Pending = maps:get(pending,J),
    case {Hash =:= maps:get(hash,Pending) andalso
          erlang:system_time(second) < maps:get(expires_at,Pending),profile(J)} of
        {true,{ok,_}} ->
            J1 = checkpoint(J#{status => ready,pending => Pending#{approved => true}},
                            approved,#{proposal_hash => Hash,actor => maps:get(owner,J)}),
            {next_state,ready,D#{job => J1},[{reply,From,{ok,damage_agent:public(J1)}},
                                            {next_event,internal,execute}]};
        _ -> {keep_state_and_data,[{reply,From,{error,stale_or_invalid_approval}}]}
    end;
handle_event({call,From},{command,<<"reject">>,Hash},awaiting_approval,D=#{job := J}) ->
    case Hash =:= maps:get(hash,maps:get(pending,J)) of
        true ->
            finish_and_reply(failed,owner_rejected,From,D);
        false -> {keep_state_and_data,[{reply,From,{error,stale_or_invalid_approval}}]}
    end;
handle_event({call,From},_,_,_) ->
    {keep_state_and_data,[{reply,From,{error,invalid_state_or_command}}]};
%% Late results, link notifications and old timeout messages cannot advance a task.
handle_event(_,_,_,_) -> keep_state_and_data.

result(planning,{ok,Plan,Meta},P,D=#{job := J}) ->
    case damage_agent_policy:validate_plan(Plan,P) of
        {error,R} -> finish(failed,R,D);
        {ok,Valid} ->
            J0 = checkpoint(J#{provider_meta => safe_meta(Meta)},planner_returned,
                            #{output_hash => damage_agent_codec:hash(Valid),proposal => Valid,
                              metadata => safe_meta(Meta)}),
            case maps:get(pause_requested,J0,false) of
                true -> park(D#{job => J0});
                false -> proposal(Valid,P,D#{job => J0})
            end
    end;
result(executing,{ok,R},P,D=#{job := J}) when is_map(R) ->
    case damage_agent_actions:accept_result(R,P) of
        {ok,Clean} ->
            Pending = maps:get(pending,J), Plan = maps:get(plan,Pending),
            Skill = maps:get(<<"skill">>,Plan),
            EvidenceHash = damage_agent_codec:hash(Clean),
            J0 = damage_agent_actions:collect(J,Skill,Clean),
            Same = case maps:get(last_evidence_hash,J,<<>>) of
                EvidenceHash -> maps:get(no_progress,J,0)+1;
                _ -> 0
            end,
            J1 = checkpoint(J0#{last_evidence_hash => EvidenceHash,no_progress => Same},
                            action_succeeded,#{skill => Skill,evidence_hash => EvidenceHash,result => Clean,
                              idempotency_key => maps:get(idempotency_key,Pending)}),
            case Same >= damage_agent_policy:limit(P,max_no_progress,4) of
                true -> park(D#{job => J1#{reason => no_progress}});
                false -> advance(D#{job => J1})
            end;
        {error,Rsn} -> interrupt(executing,Rsn,D)
    end;
result(verifying,{ok,Evidence},P,D=#{job := J}) when is_map(Evidence) ->
    case damage_agent_actions:accept_result(Evidence,P) of
        {ok,Verified} ->
            J1 = checkpoint(J#{verification => Verified},verification_passed,
                            #{evidence_hash => damage_agent_codec:hash(Verified),result => Verified}),
            finish(completed,acceptance_gate_passed,D#{job => J1});
        {error,R} -> interrupt(verifying,R,D)
    end;
result(executing,{error,_},P,D=#{job := J}) ->
    Plan = maps:get(plan,maps:get(pending,J)),
    A = damage_agent_policy:action(P,maps:get(<<"skill">>,Plan)),
    case proplists:get_value(effect,A,read) of
        read -> retry_observation(read_action_failed,max_read_failures,P,D);
        local_artifact -> finish(failed,artifact_failed,D);
        _ -> interrupt(executing,action_failed,D)
    end;
result(verifying,{error,_},P,D) ->
    retry_observation(acceptance_gate_failed,max_verification_failures,P,D);
result(_State,{error,_},_P,D) -> finish(failed,planner_failed,D);
result(State,_,_P,D) -> operation_failed(State,invalid_adapter_result,D).

proposal(Plan,P,D=#{job := J}) ->
    case maps:get(<<"op">>,Plan) of
        <<"wait">> ->
            Seconds = maps:get(<<"seconds">>,Plan),
            J1 = checkpoint(J#{status => waiting,wake_at => erlang:system_time(second)+Seconds},
                            wait_requested,#{seconds => Seconds}),
            {next_state,waiting,D#{job => J1},[{state_timeout,Seconds*1000,wake}]};
        <<"finish">> ->
            Required = proplists:get_value(required_actions,maps:get(config,P)),
            Done = maps:get(completed_skills,J),
            case lists:all(fun(K) -> lists:member(K,Done) end,Required) of
                false -> finish(failed,missing_required_evidence,D);
                true ->
                    J1 = checkpoint(J#{status => verifying,completion_summary =>
                        maps:get(<<"summary">>,Plan)},verification_started,#{}),
                    operation(verifying,fun() -> damage_agent_actions:verify(J1,P) end,
                              P,D#{job => J1})
            end;
        <<"act">> ->
            A = damage_agent_policy:action(P,maps:get(<<"skill">>,Plan)),
            Requires = proplists:get_value(requires,A,[]),
            case lists:all(fun(K) -> lists:member(K,maps:get(completed_skills,J)) end,Requires) of
                false -> finish(failed,missing_action_precondition,D);
                true ->
                    Hash = damage_agent_codec:hash([maps:get(id,J),maps:get(iteration,J),
                                                   maps:get(policy_hash,J),Plan]),
                    TTL = damage_agent_policy:limit(P,approval_seconds,300),
                    Pending = #{plan => Plan,hash => Hash,idempotency_key => Hash,
                                expires_at => erlang:system_time(second)+TTL,approved => false},
                    J1 = checkpoint(J#{pending => Pending},proposal_validated,
                                    #{proposal_hash => Hash,proposal => Plan,policy_hash => maps:get(policy_hash,J)}),
                    case damage_agent_policy:needs_approval(A) of
                        true ->
                            J2 = checkpoint(J1#{status => awaiting_approval},approval_required,
                                            #{proposal_hash => Hash}),
                            {next_state,awaiting_approval,D#{job => J2},
                             [{state_timeout,TTL*1000,approval_expired}]};
                        false -> execute_pending(D#{job => J1})
                    end
            end
    end.

execute_pending(D=#{job := J}) ->
    case profile(J) of
        {ok,P} ->
            Pending = maps:get(pending,J), Plan = maps:get(plan,Pending),
            Skill = maps:get(<<"skill">>,Plan), A = damage_agent_policy:action(P,Skill),
            Approved = not damage_agent_policy:needs_approval(A) orelse
                (maps:get(approved,Pending,false) andalso
                 erlang:system_time(second) < maps:get(expires_at,Pending)),
            case Approved of
                false -> finish(failed,approval_required,D);
                true ->
                    %% Intent and idempotency key are durable BEFORE the effect starts.
                    J1 = checkpoint(J#{status => executing,action_calls => maps:get(action_calls,J)+1},
                         action_started,#{skill => Skill,idempotency_key =>
                                           maps:get(idempotency_key,Pending)}),
                    Ticket = #{task_id => maps:get(id,J),owner => maps:get(owner,J),
                               policy_hash => maps:get(policy_hash,J),
                               idempotency_key => maps:get(idempotency_key,Pending),
                               deadline => maps:get(deadline,J)},
                    operation(executing,fun() -> damage_agent_actions:execute(
                        A,maps:get(<<"args">>,Plan),Ticket) end,P,D#{job => J1})
            end;
        {error,R} -> finish(failed,R,D)
    end.

profile(J) ->
    case erlang:system_time(second) >= maps:get(deadline,J) of
        true -> {error,wall_clock_budget};
        false ->
            case damage_agent_policy:template(maps:get(owner,J),maps:get(template,J)) of
                {ok,P} -> case maps:get(hash,P) =:= maps:get(policy_hash,J) of
                    true -> {ok,P}; false -> {error,policy_changed} end;
                E -> E
            end
    end.
raw_operation(Phase,Fun,P,D) ->
    Parent = self(), Ref = make_ref(),
    {Pid,Mon} = spawn_opt(fun() ->
        Result = try Fun() catch _:_ -> {error,adapter_exception} end,
        Parent ! {agent_operation,Ref,Result}
    end,[link,monitor,{max_heap_size,#{size => 4000000,kill => true,error_logger => false}}]),
    Timeout = case accounting_phase(Phase) of
        true -> accounting_timeout();
        false -> min(damage_agent_policy:limit(P,operation_timeout_ms,120000),
                  max(1,(maps:get(deadline,maps:get(job,D))-erlang:system_time(second))*1000))
    end,
    {next_state,Phase,D#{active => #{pid => Pid,monitor => Mon,ref => Ref}},
     [{state_timeout,Timeout,operation_timeout}]}.
clear_operation(D=#{active := none}) -> D;
clear_operation(D=#{active := #{pid := Pid,monitor := Mon}}) ->
    unlink(Pid), exit(Pid,kill), erlang:demonitor(Mon,[flush]), D#{active => none}.
operation_failed(budget_preparing,R,D) -> finish(failed,R,D);
operation_failed(budget_authorizing,R,D) -> finish(failed,R,D);
operation_failed(Phase,R,D) when Phase =:= budget_reserving; Phase =:= settling;
                                Phase =:= receipting; Phase =:= reconciling ->
    accounting_hold(Phase,R,D);
operation_failed(planning,R,D) -> finish(failed,R,D);
operation_failed(State,R,D) -> interrupt(State,R,D).
interrupt(Phase,R,D=#{job := J}) ->
    J1 = checkpoint(J#{status => interrupted,interrupted_phase => Phase,reason => R},
                    interrupted,#{phase => Phase,reason => R}),
    {next_state,interrupted,D#{job => J1}}.
advance(D=#{job := J}) ->
    case maps:get(pause_requested,J,false) of
        true -> park(D);
        false ->
            J1 = checkpoint(maps:remove(pending,J#{status => ready}),ready,#{}),
            {next_state,ready,D#{job => J1},[{next_event,internal,plan}]}
    end.
park(D=#{job := J}) ->
    J1 = checkpoint(maps:remove(pending,J#{status => paused,pause_requested => false}),paused,#{}),
    {next_state,paused,D#{job => J1}}.
finish(Status,Reason,D=#{job := J}) ->
    case damage_agent_budget:enabled(J) of
        false -> terminal_finish(Status,Reason,D);
        true -> budget_finish(Status,Reason,D)
    end.
terminal_finish(Status,Reason,D=#{job := J}) ->
    J1 = checkpoint(J#{status => Status,reason => Reason},Status,#{reason => Reason}),
    {stop,normal,D#{job => J1}}.
checkpoint(J,Kind,Data) -> {ok,Saved} = damage_agent_store:save(J,Kind,Data), Saved.
safe_meta(M) when is_map(M) ->
    maps:filter(fun(_K,V) -> is_integer(V) orelse
        (is_binary(V) andalso byte_size(V) =< 200) end,
        maps:with([<<"model">>,<<"prompt_tokens">>,<<"output_tokens">>],M));
safe_meta(_) -> #{}.
terminate(_,_,D) -> _ = clear_operation(D),ok.
code_change(_,State,D,_) -> {ok,State,D}.

retry_observation(Reason,LimitKey,P,D=#{job := J}) ->
    Failures = maps:get(LimitKey,J,0)+1,
    Obs = #{observation => #{status => failed,reason => Reason}},
    J1 = checkpoint(J#{LimitKey => Failures,observations =>
                     lists:sublist([Obs|maps:get(observations,J)],4)},
                    Reason,#{attempt => Failures}),
    case Failures >= damage_agent_policy:limit(P,LimitKey,3) of
        true -> finish(failed,Reason,D#{job => J1});
        false -> advance(D#{job => J1})
    end.
format_status(Status) -> maps:map(fun
    (state,V) -> V;
    (log,_) -> [];
    (_,_) -> redacted
end,Status).


%% ------------------------------------------------------------------
%% Monetary authority is independent of model proposals and task outcomes.
%% The entire task ceiling is reserved once; individual invocations are metered
%% locally against that confirmed reservation, then settled once at termination.
%% ------------------------------------------------------------------
budget_boot(D=#{job := J}) ->
    case damage_agent_budget:enabled(J) of
        false -> advance(D);
        true ->
            J1 = checkpoint(J#{status => budget_preparing},budget_preparing,#{}),
            chain_operation(budget_preparing,prepare,[maps:get(budget,J)],D#{job => J1})
    end.

accounting_phase(S) -> lists:member(S,[budget_preparing,budget_reserving,
    budget_authorizing,settling,receipting,reconciling]).
accounting_timeout() ->
    case damage_agent_policy:env(accounting_timeout_ms,120000) of
        N when is_integer(N),N >= 1000,N =< 300000 -> N;
        _ -> 120000
    end.
chain_operation(State,Function,Args,D=#{job := J}) ->
    raw_operation(State,fun() ->
        M = damage_agent_budget:backend(J), apply(M,Function,Args)
    end,#{config => []},D).

operation(Phase,Fun,P,D=#{job := J}) ->
    case damage_agent_budget:enabled(J) of
        false -> raw_operation(Phase,Fun,P,D);
        true ->
            case damage_agent_budget:cost(Phase,J) of
                {error,R} -> finish(exhausted,R,D);
                {ok,Rate} ->
                    J1 = checkpoint(J#{status => budget_authorizing,
                        accounting_resume_phase => Phase,accounting_rate => Rate},
                        budget_authorizing,#{phase => Phase,rate => Rate}),
                    Continuation = #{phase => Phase,work => Fun},
                    chain_operation(budget_authorizing,authorize,
                        [maps:get(budget,J),maps:get(method,Rate),maps:get(units,Rate)],
                        D#{job => J1,continuation => Continuation})
            end
    end.

accounting_result(budget_preparing,{ok,Binding},D=#{job := J}) ->
    case {profile(J),damage_agent_budget:validate_binding(maps:get(budget,J),Binding)} of
        {{ok,_},{ok,B}} ->
            %% Binding and full reservation intent are durable before the mutation.
            J1 = checkpoint(J#{status => budget_reserving,
                budget => B#{status => reservation_pending}},reservation_intent,
                #{job_id => maps:get(job_id,B),max_cost_units => maps:get(max_cost_units,B),
                  contracts => maps:get(contracts,B)}),
            chain_operation(budget_reserving,reserve,[maps:get(budget,J1)],D#{job => J1});
        {{error,R},_} -> finish(failed,R,D);
        {_,{error,R}} -> finish(failed,R,D)
    end;
accounting_result(budget_preparing,_,D) -> finish(failed,accounting_preflight_failed,D);
accounting_result(budget_reserving,{ok,Proof0},D=#{job := J}) ->
    B = maps:get(budget,J),
    case damage_agent_budget:validate_proof(B,reserve,Proof0) of
        {ok,Proof} ->
            J1 = checkpoint(J#{budget => B#{status => reserved,reservation_proof => Proof}},
                budget_reserved,#{proof => Proof}),
            advance(D#{job => J1});
        {error,R} -> accounting_hold(budget_reserving,R,D)
    end;
accounting_result(budget_reserving,{error,R},D=#{job := J})
  when R =:= reservation_not_submitted; R =:= signer_busy_not_submitted ->
    B = maps:get(budget,J),
    J1 = checkpoint(J#{budget => B#{status => unreserved}},reservation_not_submitted,#{}),
    finish(failed,R,D#{job => J1});
accounting_result(budget_reserving,_,D) -> accounting_hold(budget_reserving,reservation_outcome_unknown,D);
accounting_result(budget_authorizing,ok,D=#{job := J,continuation := C}) ->
    Phase = maps:get(phase,C), Rate = maps:get(accounting_rate,J),
    %% Revalidate local policy and exact approval after the potentially slow read.
    case profile(J) of
        {ok,P} ->
            case {maps:get(pause_requested,J,false),dispatch_allowed(Phase,J,P)} of
                {true,_} -> park(maps:remove(continuation,D));
                {false,true} ->
                    Charged = damage_agent_budget:charge(J,Phase,Rate),
                    J1 = checkpoint(maps:without([accounting_rate,accounting_resume_phase],
                        Charged#{status => Phase}),invocation_charged,
                        #{phase => Phase,units => maps:get(units,Rate),
                          method => maps:get(method,Rate),
                          spent_units => maps:get(spent_units,maps:get(budget,Charged))}),
                    raw_operation(Phase,maps:get(work,C),P,
                                  maps:remove(continuation,D#{job => J1}));
                _ -> finish(failed,stale_or_invalid_approval,D)
            end;
        {error,R} -> finish(failed,R,D)
    end;
accounting_result(budget_authorizing,_,D) -> finish(failed,chain_policy_denied,D);
accounting_result(settling,{ok,Proof0},D=#{job := J}) ->
    B = maps:get(budget,J),
    case damage_agent_budget:validate_proof(B,settle,Proof0) of
        {ok,Proof} ->
            J1 = checkpoint(J#{budget => B#{status => settled,settlement_proof => Proof}},
                budget_settled,#{cost_units => maps:get(spent_units,B),proof => Proof}),
            start_receipt(D#{job => J1});
        {error,R} -> accounting_hold(settling,R,D)
    end;
accounting_result(settling,_,D) -> accounting_hold(settling,settlement_outcome_unknown,D);
accounting_result(receipting,{ok,Proof0},D=#{job := J}) ->
    B = maps:get(budget,J),
    case damage_agent_budget:validate_proof(B,receipt,Proof0) of
        {ok,Proof} -> complete_accounting(Proof,D);
        {error,R} -> accounting_hold(receipting,R,D)
    end;
accounting_result(receipting,_,D) -> accounting_hold(receipting,receipt_outcome_unknown,D);
accounting_result(reconciling,{ok,Observation},D) -> reconcile_observation(Observation,D);
accounting_result(reconciling,_,D) -> accounting_hold(reconciling,reconciliation_unavailable,D).

dispatch_allowed(executing,J,P) ->
    Pending = maps:get(pending,J), Plan = maps:get(plan,Pending),
    A = damage_agent_policy:action(P,maps:get(<<"skill">>,Plan)),
    not damage_agent_policy:needs_approval(A) orelse
        (maps:get(approved,Pending,false) andalso
         erlang:system_time(second) < maps:get(expires_at,Pending));
dispatch_allowed(_,_,_) -> true.

budget_finish(Status,Reason,D=#{job := J}) ->
    B = maps:get(budget,J),
    case maps:get(status,B) of
        reserved ->
            End = erlang:system_time(second),
            Receipt = damage_agent_budget:receipt(J,Status,End),
            J1 = checkpoint(J#{status => settling,execution_status => Status,reason => Reason,
                receipt => Receipt,budget => B#{status => settlement_pending,
                    receipt_id => maps:get(receipt_id,Receipt)}},settlement_intent,
                #{job_id => maps:get(job_id,B),cost_units => maps:get(spent_units,B),
                  receipt_hash => damage_agent_codec:hash(Receipt)}),
            chain_operation(settling,settle,[maps:get(budget,J1),maps:get(spent_units,B)],D#{job => J1});
        settled -> start_receipt(D);
        unprepared -> terminal_finish(Status,Reason,D);
        unreserved -> terminal_finish(Status,Reason,D);
        complete -> terminal_finish(Status,Reason,D);
        _ -> accounting_hold(maps:get(status,J),reconciliation_required,D)
    end.
start_receipt(D=#{job := J}) ->
    B = maps:get(budget,J), R = maps:get(receipt,J),
    J1 = checkpoint(J#{status => receipting,budget => B#{status => receipt_pending}},
                    receipt_intent,#{receipt_hash => damage_agent_codec:hash(R)}),
    chain_operation(receipting,write_receipt,[maps:get(budget,J1),R],D#{job => J1}).
complete_accounting(Proof,D=#{job := J}) ->
    B = maps:get(budget,J),
    J1 = checkpoint(J#{budget => B#{status => complete,receipt_proof => Proof}},
                    receipt_recorded,#{receipt_id => maps:get(receipt_id,B),proof => Proof}),
    terminal_finish(maps:get(execution_status,J1),maps:get(reason,J1),D#{job => J1}).
accounting_hold(Phase,Reason,D=#{job := J}) ->
    J1 = checkpoint(J#{status => accounting_pending,interrupted_phase => Phase,
                      accounting_reason => Reason},accounting_pending,#{phase => Phase,reason => Reason}),
    {next_state,accounting_pending,maps:remove(continuation,D#{job => J1})}.

%% Reconciliation is read-only and must bind both identity and final amounts.
%% Only an installed trusted backend can produce an observation. Client JSON,
%% model output and a bare "ok" are never accepted as reconciliation evidence.
reconcile_observation(O,D=#{job := J}) ->
    %% Keep validation separate from durable writes. A persistence failure must
    %% crash/fail closed, not attempt another write using a stale revision.
    case validate_observation(O,J) of
        {ok,reserved,P} ->
            B = maps:get(budget,J),
            J1 = checkpoint(J#{budget => B#{status => reserved,reservation_proof => P}},
                reservation_reconciled,#{proof => P}),
            %% Never execute a task whose reservation response was lost.
            finish(cancelled,recovered_unused_reservation,D#{job => J1});
        {ok,settled,P} ->
            B = maps:get(budget,J),
            J1 = checkpoint(J#{budget => B#{status => settled,settlement_proof => P}},
                            settlement_reconciled,#{proof => P}),
            start_receipt(D#{job => J1});
        {ok,receipted,P} -> complete_accounting(P,D);
        {error,R} -> accounting_hold(reconciling,R,D)
    end.
validate_observation(O,J) when is_map(O) ->
    B = maps:get(budget,J),
    try
        true = maps:get(job_id,O) =:= maps:get(job_id,B),
        Stage = maps:get(stage,O),
        case {maps:get(status,B),Stage} of
            {reservation_pending,reserved} ->
                true = maps:get(reserved_units,O) =:= maps:get(max_cost_units,B),
                {ok,P} = damage_agent_budget:validate_proof(B,reserve,maps:get(proof,O)),
                {ok,reserved,P};
            {settlement_pending,settled} ->
                true = maps:get(cost_units,O) =:= maps:get(spent_units,B),
                {ok,P} = damage_agent_budget:validate_proof(B,settle,maps:get(proof,O)),
                {ok,settled,P};
            {receipt_pending,receipted} ->
                true = maps:get(receipt_hash,O) =:= damage_agent_codec:hash(maps:get(receipt,J)),
                {ok,P} = damage_agent_budget:validate_proof(B,receipt,maps:get(proof,O)),
                {ok,receipted,P};
            _ -> {error,unexpected_reconciliation_stage}
        end
    catch _:_ -> {error,invalid_reconciliation_evidence}
    end;
validate_observation(_,_) -> {error,invalid_reconciliation_evidence}.

unsafe_resume(J) ->
    lists:member(maps:get(interrupted_phase,J,none),[executing,verifying,budget_reserving,
        settling,receipting,reconciling]) orelse
    (damage_agent_budget:enabled(J) andalso
        maps:get(status,maps:get(budget,J)) =/= reserved).

finish_and_reply(Status,Reason,From,D) ->
    Transition = finish(Status,Reason,D),
    Saved = case Transition of
        {stop,normal,Next} -> maps:get(job,Next);
        {next_state,_,Next} -> maps:get(job,Next);
        {next_state,_,Next,_} -> maps:get(job,Next)
    end,
    gen_statem:reply(From,{ok,damage_agent:public(Saved)}),
    Transition.
