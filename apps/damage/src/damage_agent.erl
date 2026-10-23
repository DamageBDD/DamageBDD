%% Public account-scoped facade. Authentication happens before Owner reaches here.
-module(damage_agent).
-author("Steven Joseph <steven@stevenjoseph.in>").
-behaviour(gen_server).
-license("Apache-2.0").
-export([start_link/0, start/4, status/2, list/1, command/4, events/2, learning/2,
         public/1]).
-export([create_agent/1, fund_agent/2, create_job/2, execute_job/2,
         pause_agent/1, revoke_agent/1, write_receipt/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3, handle_continue/2,format_status/1]).

start_link() -> gen_server:start_link({local,?MODULE},?MODULE,[],[]).
start(O,Template,Goal,Key) -> call({start,O,Template,Goal,Key}).
command(O,Id,Cmd,Hash) -> call({command,O,Id,Cmd,Hash}).
call(R) ->
    try gen_server:call(?MODULE,R,20000)
    catch exit:_ -> {error,agent_service_unavailable} end.
status(O,Id) ->
    case damage_agent_store:get(O,Id) of {ok,J} -> {ok,public(J)}; E -> E end.
list(O) -> [summary(J) || J <- damage_agent_store:list(O)].
events(O,Id) -> damage_agent_store:events(O,Id).
learning(O,Id) ->
    case damage_agent_store:bundle(O,Id) of
        {ok,#{task := J,events := Es}} ->
            {ok,#{schema => <<"damage.agent.experience.v1">>,
                   classification => <<"candidate_evidence_not_training_truth">>,
                   training_eligible => false, semantic_correctness => <<"not_established">>,
                   task => public(J), checkpoint => J, events => Es,
                   observations => maps:get(observations,J,[]),
                   source_hashes => maps:get(source_hashes,J,[]),
                   artifacts => maps:get(artifacts,J,#{}),
                   chain_encoding => <<"damage-canonical-json-sha256-v1">>}};
        _ -> {error,not_found}
    end.

init([]) -> {ok,#{}, {continue,recover}}.
%% Recover after init acknowledges startup; never replay a saved operation.
handle_continue(recover,S) ->
    S1 = lists:foldl(fun(J,Acc) ->
        case damage_agent_policy:terminal(maps:get(status,J)) of
            true -> Acc;
            false -> element(2,launch(J#{recovery => true},Acc))
        end
    end,S,damage_agent_store:all()),
    {noreply,S1}.

handle_call({start,O,Template,Goal,Key},_From,S) ->
    case damage_agent_policy:template(O,Template) of
        {ok,P} ->
            case damage_agent_codec:text(Goal,4096) andalso damage_agent_codec:text(Key,128) of
                false -> {reply,{error,invalid_task},S};
                true ->
                    Now = erlang:system_time(second),
                    Id = string:lowercase(binary:encode_hex(crypto:strong_rand_bytes(16))),
                    J = #{id => Id,owner => O,template => Template,goal => Goal,
                          request_id => Key,
                          request_hash => damage_agent_codec:hash([Template,Goal]),
                          policy_hash => maps:get(hash,P),policy_contract => damage_agent_policy:descriptor(P),
                          behaviour_identity => behaviour_identity(P),
                          status => queued,created_at => Now,
                          deadline => Now+damage_agent_policy:limit(P,max_wall_seconds,3600),
                          iteration => 0, llm_calls => 0, action_calls => 0,
                          observations => [],source_hashes => [],completed_skills => [],
                          artifacts => #{},pause_requested => false},
                    case initialise_and_create(O,P,J) of
                        {ok,Saved,new} ->
                            {Reply,S1} = launch(Saved,S),
                            {reply,Reply,S1};
                        {ok,Saved,duplicate} -> {reply,{ok,public(Saved)},S};
                        E -> {reply,E,S}
                    end
            end;
        E -> {reply,E,S}
    end;
handle_call({command,O,Id,Cmd,Hash},_From,S) ->
    case {damage_agent_policy:owner(O),damage_agent_store:get(O,Id),maps:find(Id,S)} of
        {true,{ok,_J},{ok,{Pid,_Mon}}} ->
            Reply = try gen_statem:call(Pid,{command,Cmd,Hash},15000)
                    catch exit:_ -> {error,task_unavailable} end,
            {reply,Reply,S};
        {true,{ok,_J},error} -> {reply,{error,task_terminal},S};
        _ -> {reply,{error,not_found},S}
    end;
handle_call(_,_From,S) -> {reply,{error,bad_request},S}.
handle_cast(_,S) -> {noreply,S}.
handle_info({'DOWN',Mon,process,_Pid,_Reason},S) ->
    Matches = [Id || {Id,{_,M}} <- maps:to_list(S),M =:= Mon],
    lists:foreach(fun(Id) ->
        %% No external action is retried after an unexpected worker exit.
        [J] = [T || T <- damage_agent_store:all(),maps:get(id,T) =:= Id],
        case damage_agent_policy:terminal(maps:get(status,J)) of
            true -> ok;
            false ->
                {ok,_} = damage_agent_store:save(J#{status => interrupted,
                    interrupted_phase => maps:get(interrupted_phase,J,maps:get(status,J)),recovery_reason => worker_exited},
                    interrupted,#{reason => worker_exited})
        end
    end,Matches),
    %% Keep interrupted tasks commandable without restarting their operations.
    S0 = lists:foldl(fun maps:remove/2,S,Matches),
    S1 = lists:foldl(fun(Id,Acc) ->
        [J] = [T || T <- damage_agent_store:all(),maps:get(id,T) =:= Id],
        case maps:get(status,J) of
            interrupted -> element(2,launch(J#{recovery => true},Acc));
            _ -> Acc
        end
    end,S0,Matches),
    {noreply,S1};
handle_info(_,S) -> {noreply,S}.
terminate(_,_) -> ok.
code_change(_,S,_) -> {ok,S}.

launch(J,S) ->
    case damage_agent_jobs_sup:start_task(J) of
        {ok,Pid} -> Mon = erlang:monitor(process,Pid),
                    {{ok,public(J)},S#{maps:get(id,J) => {Pid,Mon}}};
        {error,_} ->
            %% A supervisor/admission failure does not close a financial hold.
            %% Preserve the checkpoint for service restart/operator recovery.
            BudgetState = maps:get(status,maps:get(budget,J,#{}),disabled),
            HasAccounting = not lists:member(BudgetState,[disabled,unprepared,unreserved]),
            Status = case HasAccounting of true -> interrupted; false -> failed end,
            Phase = maps:get(interrupted_phase,J,maps:get(status,J)),
            {ok,Failed} = damage_agent_store:save((maps:remove(recovery,J))#{status => Status,
                interrupted_phase => Phase,recovery_reason => worker_start_failed},
                worker_start_failed,#{reason => worker_start_failed}),
            {{ok,public(Failed)},S}
    end.
summary(J) ->
    S = maps:with([id,template,status,created_at,updated_at,iteration,llm_calls,
                   action_calls,deadline,reason,policy_hash,audit_head,execution_status],J),
    S#{budget => damage_agent_budget:view(J)}.
public(J) ->
    Base = maps:without([owner,request_id,request_hash,observations,artifacts,recovery,
                         budget,accounting_resume_phase,accounting_rate],J),
    Base#{budget => damage_agent_budget:view(J),
          accounting_complete => maps:get(status,maps:get(budget,J,#{}),disabled) =:= complete,
          receipt_state => case maps:get(status,maps:get(budget,J,#{}),disabled) of
              complete -> onchain_included; _ -> offchain_draft_or_absent
          end, artifacts => maps:map(fun(_K,A) -> maps:remove(content,A) end,maps:get(artifacts,J,#{}))}.

format_status(Status) -> maps:map(fun(log,_) -> []; (_,_) -> redacted end,Status).


initialise_and_create(Owner, Profile, Job) ->
    case damage_agent_budget:initial(Owner, Profile, maps:get(id,Job), maps:get(request_id,Job)) of
        {ok, Budget} -> damage_agent_store:create(Job#{budget => Budget});
        E -> E
    end.

%% Legacy management API and supervised tasks now share this facade.
%% Management calls are never made available as model-selected capabilities.
create_agent(Request) -> damage_agent_chain:management(register, Request).
fund_agent(Request, Amount) when is_map(Request) ->
    damage_agent_chain:management(fund, Request#{amount => Amount});
fund_agent(_, _) -> {error, missing_requester}.
pause_agent(Request) -> damage_agent_chain:management(pause, Request).
revoke_agent(Request) -> damage_agent_chain:management(revoke, Request).

%% Migration: create_job now returns an inspectable job descriptor rather than a
%% private record. A job must select a reviewed template; raw generated Gherkin
%% cannot bypass its capabilities, verifier, budget, or identity binding.
create_job(AgentId, R) when is_binary(AgentId), is_map(R) ->
    try
        Owner = maps:get(requester, R), Template = maps:get(template, R),
        {ok, P} = damage_agent_policy:template(Owner, Template),
        Options = proplists:get_value(accounting, maps:get(config,P), []),
        AgentId = proplists:get_value(agent_id, Options),
        true = maps:get(context, R, #{}) =:= #{},
        case maps:find(feature_data, R) of
            {ok, Feature} ->
                true = is_binary(Feature),
                true = lists:any(fun({_K,A}) ->
                    proplists:get_value(type,A) =:= bdd andalso
                    proplists:get_value(feature,A) =:= Feature
                end, proplists:get_value(actions,maps:get(config,P)));
            error -> ok
        end,
        Goal = maps:get(objective, R, <<"Execute the approved task and satisfy its acceptance gate.">>),
        Key = maps:get(job_id, R, string:lowercase(binary:encode_hex(crypto:strong_rand_bytes(16)))),
        true = damage_agent_codec:text(Goal,4096),
        true = damage_agent_codec:text(Key,128),
        {ok, #{agent_id => AgentId, requester => Owner, template => Template,
               objective => Goal, job_id => Key,
               input_hash => damage_agent_codec:hash([AgentId,Owner,Template,Goal,Key]),
               estimated_cost => proplists:get_value(max_cost_units,Options),
               unit => damage_base_units}}
    catch _:_ -> {error, approved_budgeted_template_required}
    end;
create_job(_, _) -> {error, invalid_agent_job}.

%% Returns acceptance, not a synchronous execution/settlement receipt.
execute_job(AgentId, R) ->
    case create_job(AgentId,R) of
        {ok,J} -> start(maps:get(requester,J),maps:get(template,J),
                        maps:get(objective,J),maps:get(job_id,J));
        E -> E
    end.

%% The former public writer allowed arbitrary caller-supplied costs/statuses.
%% Only the persisted settlement pipeline can author an accounting receipt.
write_receipt(_Receipt, _Result) -> {error, receipt_managed_by_task_lifecycle}.


behaviour_identity(P) ->
    Features = [proplists:get_value(feature,A) || {_K,A} <-
        proplists:get_value(actions,maps:get(config,P)), proplists:get_value(type,A) =:= bdd],
    case Features of
        [Feature] -> #{kind => bdd_feature_sha256, hash =>
            string:lowercase(binary:encode_hex(crypto:hash(sha256,Feature)))};
        _ -> #{kind => agent_policy_sha256, hash => maps:get(hash,P)}
    end.
