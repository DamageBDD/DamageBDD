%% Durable account-isolated planning workspaces. One DETS object per account;
%% sync before acknowledging writes. Guest demos use separate private ETS only.
%% Heavy work runs in monitored bounded jobs; at most one job is anonymous.
-module(ecai_supply_chain_srv).
-behaviour(gen_server).
-export([start_link/0,start_link/1,child_specs/0,enabled/0,request/3,request/4,guest_session/4,guest_session/5]).
-export([init/1,handle_call/3,handle_cast/2,handle_info/2,terminate/2,code_change/3]).

enabled() -> application:get_env(ecai,supply_chain_enabled,true)=:=true.
child_specs() -> case enabled() of true -> [#{id => ?MODULE,start => {?MODULE,start_link,[]},
    restart => permanent,shutdown => 30000,type => worker,modules => [?MODULE]}];false -> [] end.
start_link() -> gen_server:start_link({local,?MODULE},?MODULE,#{},[]).
start_link(Options) -> gen_server:start_link(?MODULE,Options,[]).
request(Op,Owner,Body) -> request(?MODULE,Op,Owner,Body).
request(Server,Op,Owner,Body) -> gen_server:call(Server,{request,Op,Owner,Body},30000).

guest_session(Token,Peer,Create,Action) -> guest_session(?MODULE,Token,Peer,Create,Action).
guest_session(Server,Token,Peer,Create,Action) ->
    gen_server:call(Server,{guest_session,Token,Peer,Create,Action},5000).

init(Options) ->
    process_flag(trap_exit,true),
    Dir0=maps:get(dir,Options,application:get_env(ecai,supply_chain_state_dir,
        filename:join(ecai_paths:runtime_dir(),"supply-chain"))),
    Dir=ecai_paths:normalize(Dir0),
    ok=ecai_paths:ensure_dir(Dir),ok=file:change_mode(Dir,8#700),
    Path=filename:join(Dir,"workspaces.dets"),
    Table=maps:get(table,Options,?MODULE),
    {ok,Table}=dets:open_file(Table,[{file,Path},{type,set},{auto_save,30000}]),
    ok=file:change_mode(Path,8#600),
    erlang:send_after(60000,self(),prune_guests),
    {ok,#{table => Table,guests => ecai_supply_chain_guest:new(Options),pending => #{},max_owners => maps:get(max_owners,Options,64),
          max_workers => maps:get(max_workers,Options,2),job_timeout_ms => maps:get(job_timeout_ms,Options,20000)}}.

handle_call({guest_session,Token,Peer,Create,Action},_From,St) ->
    try ecai_supply_chain_guest:admit(maps:get(guests,St),Token,Peer,Create,Action) of
        {ok,Owner,NewToken} ->
            {reply,{ok,Owner,NewToken,ecai_supply_chain_guest:ttl_seconds(maps:get(guests,St))},St}
    catch throw:{supply_chain,Why} -> {reply,{error,Why},St} end;
handle_call({request,Op,Owner,Body},From,St) ->
    try
        ecai_supply_chain_util:require((is_binary(Owner) andalso byte_size(Owner)>0 andalso byte_size(Owner)=<256)
            orelse ecai_supply_chain_guest:is_guest(Owner),invalid_owner),
        W=load(Owner,St),
        dispatch(Op,Owner,Body,W,From,St)
    catch
        throw:{supply_chain,Why} -> {reply,{error,Why},St};
        error:{badkey,_} -> {reply,{error,missing_field},St};
        error:{badmatch,{error,_}} -> {stop,storage_failure,{error,storage_unavailable},St}
    end;
handle_call(_,_,St) -> {reply,{error,invalid_request},St}.
handle_cast(_,St) -> {noreply,St}.

dispatch(state,_Owner,Body,W,_From,St) ->
    ecai_supply_chain_util:keys(Body,[]),{reply,{ok,view(W)},St};
dispatch(evidence,_Owner,Body,W,_From,St) ->
    ecai_supply_chain_util:keys(Body,[]),
    Manifest=maps:with([revision,scenario,approved,proposal,history,benchmark],W),
    Bytes=ecai_supply_chain_util:json(Manifest),
    {reply,{ok,#{schema => <<"ecai-supply-chain/evidence-v1">>,manifest_json => Bytes,
        domain => <<"ecai-supply-chain/evidence-v1">>,
        digest => ecai_supply_chain_util:hash(<<"ecai-supply-chain/evidence-v1">>,Manifest),
        authenticated_signature => false,
        note => <<"SHA-256 content integrity only. Simulation evidence, not proof of sensor truth or optimality.">>}},St};
dispatch(reset,Owner,B,W,From,St) ->
    fields(B,[<<"expected_revision">>,<<"seed">>,<<"keep_cases">>],W),
    Seed=ecai_supply_chain_util:integer(maps:get(<<"seed">>,B,42),1,999999),
    Keep=maps:get(<<"keep_cases">>,B,true),ecai_supply_chain_util:require(is_boolean(Keep),invalid_keep_cases),
    ensure_capacity(Owner,St),
    launch(Owner,W,From,fun() ->
        S=ecai_supply_chain_model:scenario(Seed),
        {reset,S,ecai_supply_chain_task:plan(S,null,[],cold),Keep}
    end,St);
dispatch(event,Owner,B,W,_From,St) ->
    fields(B,[<<"expected_revision">>,<<"event">>],W),require_scenario(W),
    S=ecai_supply_chain_model:event(maps:get(scenario,W),maps:get(<<"event">>,B)),
    N=log(event,maps:get(<<"event">>,B),W#{scenario := S,revision := maps:get(revision,W)+1,benchmark := null}),
    persist(Owner,N,St),{reply,{ok,view(N)},St};
dispatch(approve,Owner,B,W,_From,St) ->
    fields(B,[<<"expected_revision">>,<<"plan_id">>],W),require_scenario(W),
    P=maps:get(proposal,W),ecai_supply_chain_util:require(is_map(P),no_proposal),
    ecai_supply_chain_util:require(maps:get(id,P)=:=maps:get(<<"plan_id">>,B),proposal_changed),
    ecai_supply_chain_util:require(maps:get(input_revision,P)=:=maps:get(revision,W),stale_plan),
    Check=ecai_supply_chain_validator:validate(maps:get(scenario,W),P),
    ecai_supply_chain_util:require(maps:get(valid,Check),plan_validation_failed),
    N=log(approved,#{plan_id => maps:get(id,P)},W#{approved := P,proposal := null,
        revision := maps:get(revision,W)+1,benchmark := null}),
    persist(Owner,N,St),{reply,{ok,view(N)},St};
dispatch(Op,Owner,B,W,From,St) when Op=:=plan;Op=:=benchmark ->
    Allowed=case Op of plan -> [<<"expected_revision">>,<<"mode">>];benchmark -> [<<"expected_revision">>] end,
    fields(B,Allowed,W),require_scenario(W),
    S=maps:get(scenario,W),Ref=maps:get(approved,W),Cases=maps:get(cases,W),
    Job=case Op of
        plan -> Mode=mode(maps:get(<<"mode">>,B,<<"ecai">>)),fun() -> {plan,ecai_supply_chain_task:plan(S,Ref,Cases,Mode)} end;
        benchmark -> fun() -> {benchmark,ecai_supply_chain_task:benchmark(S,Ref,Cases)} end
    end,
    launch(Owner,W,From,Job,St);
dispatch(_,_,_,_,_,St) -> {reply,{error,invalid_operation},St}.

mode(<<"cold">>) -> cold;
mode(<<"warm">>) -> warm;
mode(<<"lookup">>) -> lookup;
mode(<<"ecai">>) -> ecai;
mode(_) -> throw({supply_chain,invalid_mode}).
fields(B,Allowed,W) ->
    ecai_supply_chain_util:keys(B,Allowed),
    R=ecai_supply_chain_util:integer(maps:get(<<"expected_revision">>,B),0,1000000000),
    ecai_supply_chain_util:require(R=:=maps:get(revision,W),revision_conflict).
require_scenario(W) -> ecai_supply_chain_util:require(is_map(maps:get(scenario,W)),scenario_required).

launch(Owner,W,From,Fun,St) ->
    Pending=maps:get(pending,St),
    ecai_supply_chain_util:require(not lists:any(fun(J) -> maps:get(owner,J)=:=Owner end,maps:values(Pending)),owner_busy),
    ecai_supply_chain_util:require(map_size(Pending)<maps:get(max_workers,St),worker_capacity),
    GuestJobs=length([J || J <- maps:values(Pending),ecai_supply_chain_guest:is_guest(maps:get(owner,J))]),
    ecai_supply_chain_util:require(not ecai_supply_chain_guest:is_guest(Owner) orelse GuestJobs<1,guest_worker_capacity),
    Parent=self(),Ref=make_ref(),
    {Pid,Monitor}=spawn_opt(fun() ->
        Result=try {ok,Fun()} catch throw:{supply_chain,Why} -> {error,Why};
                                    Class:Reason:Stack ->
                                        logger:error("Supply-chain job failed ~p:~p ~p",[Class,Reason,Stack]),
                                        {error,planning_failed} end,
        Parent!{job_result,Ref,Result}
    end,[link,monitor]),
    Timer=erlang:send_after(maps:get(job_timeout_ms,St),self(),{job_timeout,Ref}),
    J=#{owner => Owner,revision => maps:get(revision,W),from => From,pid => Pid,monitor => Monitor,timer => Timer},
    {noreply,St#{pending := Pending#{Ref => J}}}.

handle_info(prune_guests,St) ->
    ecai_supply_chain_guest:prune(maps:get(guests,St)),
    erlang:send_after(60000,self(),prune_guests),{noreply,St};
handle_info({job_result,Ref,Result},St) ->
    case take_job(Ref,St) of
        none -> {noreply,St};
        {J,Rest} ->
            Owner=maps:get(owner,J),
            try
                W=load(Owner,St),
                ecai_supply_chain_util:require(maps:get(revision,W)=:=maps:get(revision,J),revision_conflict),
                case Result of
                    {error,Why} -> gen_server:reply(maps:get(from,J),{error,Why}),{noreply,Rest};
                    {ok,Value} ->
                        N=complete(Value,W),persist(Owner,N,St),
                        gen_server:reply(maps:get(from,J),{ok,view(N)}),{noreply,Rest}
                end
            catch
                throw:{supply_chain,Why2} -> gen_server:reply(maps:get(from,J),{error,Why2}),{noreply,Rest};
                error:{badmatch,{error,_}} ->
                    gen_server:reply(maps:get(from,J),{error,storage_unavailable}),{stop,storage_failure,Rest}
            end
    end;
handle_info({job_timeout,Ref},St) ->
    case take_job(Ref,St) of
        none -> {noreply,St};
        {J,Rest} -> exit(maps:get(pid,J),kill),gen_server:reply(maps:get(from,J),{error,planning_timeout}),{noreply,Rest}
    end;
handle_info({'DOWN',Monitor,process,_Pid,_Reason},St) ->
    case [Ref || {Ref,J} <- maps:to_list(maps:get(pending,St)),maps:get(monitor,J)=:=Monitor] of
        [Ref] -> {J,Rest}=take_job(Ref,St),gen_server:reply(maps:get(from,J),{error,planning_failed}),{noreply,Rest};
        [] -> {noreply,St}
    end;
handle_info(_,St) -> {noreply,St}.
take_job(Ref,St) ->
    case maps:take(Ref,maps:get(pending,St)) of
        error -> none;
        {J,Pending} -> erlang:cancel_timer(maps:get(timer,J)),erlang:demonitor(maps:get(monitor,J),[flush]),
                       {J,St#{pending := Pending}}
    end.

complete({reset,S,P,Keep},W) ->
    Revision=maps:get(revision,W)+1,
    Cases=case Keep of true -> maps:get(cases,W);false -> [] end,
    log(reset,#{seed => maps:get(seed,S),retained_cases => length(Cases)},W#{revision := Revision,
        scenario := S,approved := tag(P,S,Revision),proposal := null,cases := Cases,benchmark := null});
complete({plan,P},W) ->
    S=maps:get(scenario,W),Sequence=maps:get(sequence,W)+1,
    Tagged=tag(P,S,maps:get(revision,W)),
    {Cases,CaseId}=ecai_supply_chain_cases:put(S,Tagged,maps:get(cases,W),Sequence),
    log(proposed,#{plan_id => maps:get(id,Tagged),source => maps:get(source,Tagged)},
        W#{proposal := Tagged#{stored_case_id => CaseId},cases := Cases,sequence := Sequence});
complete({benchmark,B},W) -> W#{benchmark := B#{input_revision => maps:get(revision,W)}}.
tag(P,S,Revision) ->
    Hash=ecai_supply_chain_model:fingerprint(S),
    Id=ecai_supply_chain_util:hash(<<"ecai-supply-chain/proposal-v1">>,
        #{revision => Revision,state => Hash,routes => ecai_supply_chain_model:skeleton(P)}),
    P#{id => Id,input_revision => Revision,state_hash => Hash}.
log(Kind,Details,W) ->
    W#{history := lists:sublist([#{kind => Kind,revision => maps:get(revision,W),
        at_ms => erlang:system_time(millisecond),details => Details}|maps:get(history,W)],40)}.
blank() -> #{revision => 0,scenario => null,approved => null,proposal => null,cases => [],
    sequence => 0,history => [],benchmark => null}.
load({guest,_}=Owner,St) ->
    case ecai_supply_chain_guest:load(maps:get(guests,St),Owner) of undefined -> blank();W -> W end;
load(Owner,St) -> case dets:lookup(maps:get(table,St),Owner) of [{Owner,W}] -> W;[] -> blank() end.
persist({guest,_}=Owner,W,St) -> ecai_supply_chain_guest:save(maps:get(guests,St),Owner,W);
persist(Owner,W,St) ->
    Tab=maps:get(table,St),ok=dets:insert(Tab,{Owner,W}),ok=dets:sync(Tab).
ensure_capacity({guest,_}=Owner,St) -> _=ecai_supply_chain_guest:load(maps:get(guests,St),Owner),ok;
ensure_capacity(Owner,St) ->
    Tab=maps:get(table,St),
    PendingOwners=lists:usort([maps:get(owner,J) || J <- maps:values(maps:get(pending,St)),is_binary(maps:get(owner,J)),not dets:member(Tab,maps:get(owner,J))]),
    ecai_supply_chain_util:require(dets:member(Tab,Owner) orelse
        dets:info(Tab,size)+length(PendingOwners)<maps:get(max_owners,St),workspace_capacity).
view(W) ->
    S=maps:get(scenario,W),
    Base=maps:without([cases,sequence],W),
    Base#{exists => S=/=null,cases => ecai_supply_chain_cases:summaries(maps:get(cases,W)),
          case_count => length(maps:get(cases,W)),
          impact => case S of null -> null;_ -> ecai_supply_chain_model:impact(S,maps:get(approved,W)) end,
          simulation_only => true,execution_model => pre_dispatch,
          planner => <<"native-insertion/v1">>,terms_version => ecai_terms:version()}.
terminate(_,St) ->
    lists:foreach(fun(J) -> exit(maps:get(pid,J),kill),
        gen_server:reply(maps:get(from,J),{error,service_unavailable}) end,maps:values(maps:get(pending,St))),
    dets:close(maps:get(table,St)),ok.
code_change(_,St,_) -> {ok,St}.
