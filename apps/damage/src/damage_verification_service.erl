%% Bounded, supervised jobs and single-use approvals. Preview never calls probes.
%% The existing runner owns durable reports; this process retains only recent
%% public status plus non-secret feature/context input specifications.
-module(damage_verification_service).
-behaviour(gen_server).
-export([start_link/0,child_spec/0,preview/5,approve/2,status/2,history/1,
         authorized/1,public_job/1,preflight/2]).
-export([init/1,handle_call/3,handle_cast/2,handle_info/2,terminate/2,code_change/3]).
-define(RETENTION_MS,3600000).
-define(APPROVAL_MS,300000).
-define(DEADLINE_MS,1500000).
-define(MAX_JOBS,256).
-define(MAX_ACTIVE,4).
start_link()->gen_server:start_link({local,?MODULE},?MODULE,[],[]).
child_spec()->#{id=>?MODULE,start=>{?MODULE,start_link,[]},restart=>permanent,
                shutdown=>5000,type=>worker,modules=>[?MODULE]}.
preview(Id,Hash,Inputs,RequestId,Auth)->
    gen_server:call(?MODULE,{preview,Id,Hash,Inputs,RequestId,Auth},5000).
approve(Id,Auth)->gen_server:call(?MODULE,{approve,Id,Auth},5000).
status(Id,Auth)->gen_server:call(?MODULE,{status,Id,Auth},5000).
history(Auth)->gen_server:call(?MODULE,{history,Auth},5000).
init([])->process_flag(trap_exit,true),{ok,#{jobs=>#{}}}.
authorized(#{authenticated:=true,public_key:=P}=A)->
    is_binary(P) andalso byte_size(P)>0 andalso maps:get(auth_mode,A,legacy)=/=wallet;
authorized(_)->false.
handle_call(Request,From,State0)->
    State=prune(State0),
    case auth_of(Request) of
        A when is_map(A)->
            case authorized(A) of true->dispatch(Request,From,State);false->{reply,{error,forbidden},State} end;
        _->{reply,{error,bad_request},State}
    end.
auth_of({preview,_,_,_,_,A})->A;
auth_of({approve,_,A})->A;
auth_of({status,_,A})->A;
auth_of({history,A})->A;
auth_of(_)->undefined.
dispatch({preview,Id,Hash,Inputs,RequestId,Auth},_,#{jobs:=Jobs}=S)->
    Owner=maps:get(public_key,Auth),
    Valid=is_binary(Id) andalso byte_size(Id)=:=64 andalso is_binary(Hash) andalso byte_size(Hash)=:=64
        andalso is_map(Inputs) andalso map_size(Inputs)=<32 andalso request_id(RequestId),
    Signature=damage_verification_catalog:sha256(term_to_binary({Id,Hash,Inputs},[deterministic])),
    Existing=[J||J<-maps:values(Jobs),maps:get(owner,J)=:=Owner,
        maps:get(request_id,J,undefined)=:=RequestId,maps:get(mode,J)=:=preview],
    case {Valid,Existing} of
        {false,_}->{reply,{error,bad_request},S};
        {true,[#{request_signature:=Signature}=J|_]}->{reply,{ok,public_job(J)},S};
        {true,[_|_]}->{reply,{error,idempotency_conflict},S};
        {true,[]}->
            Spec=#{feature_id=>Id,sha256=>Hash,inputs=>Inputs},
            Extra=#{request_id=>RequestId,request_signature=>Signature},
            launch(preview,Spec,Auth,Extra,S)
    end;
dispatch({approve,Id,Auth},_,#{jobs:=Jobs}=S)->
    Owner=maps:get(public_key,Auth),
    case maps:find(Id,Jobs) of
        {ok,#{owner:=Owner,approved_job:=RunId}} ->
            case maps:find(RunId,Jobs) of
                {ok,J}->{reply,{ok,public_job(J)},S};
                error->{reply,{error,approval_consumed},S}
            end;
        {ok,#{owner:=Owner,mode:=preview,state:=ready,spec:=Spec}=J}->
            case monotonic()-maps:get(finished_mono,J)< ?APPROVAL_MS of
                false->{reply,{error,approval_expired},S};
                true->
                    case launch(execute,Spec,Auth,#{preview_id=>Id},S) of
                        {reply,{ok,#{id:=RunId}}=OK,#{jobs:=Next}=S1}->
                            {reply,OK,S1#{jobs:=Next#{Id=>J#{approved_job=>RunId}}}};
                        Other->Other
                    end
            end;
        {ok,#{owner:=Owner}}->{reply,{error,preview_not_ready},S};
        _->{reply,{error,not_found},S}
    end;
dispatch({status,Id,Auth},_,#{jobs:=Jobs}=S)->
    Owner=maps:get(public_key,Auth),
    case maps:find(Id,Jobs) of
        {ok,#{owner:=Owner}=J}->{reply,{ok,public_job(J)},S};
        _->{reply,{error,not_found},S}
    end;
dispatch({history,Auth},_,#{jobs:=Jobs}=S)->
    Owner=maps:get(public_key,Auth),
    Own=[public_job(J)||J<-maps:values(Jobs),maps:get(owner,J)=:=Owner],
    Sorted=lists:sort(fun(A,B)->maps:get(created_at,A)>maps:get(created_at,B) end,Own),
    {reply,{ok,lists:sublist(Sorted,20)},S};
dispatch(_,_,S)->{reply,{error,bad_request},S}.
launch(Mode,Spec,Auth,Extra,#{jobs:=Jobs}=S)->
    Owner=maps:get(public_key,Auth),
    Active=[J||J<-maps:values(Jobs),maps:get(state,J)=:=running],
    Busy=lists:any(fun(J)->maps:get(owner,J)=:=Owner end,Active),
    case Busy orelse length(Active)>= ?MAX_ACTIVE orelse map_size(Jobs)>= ?MAX_JOBS of
        true->{reply,{error,verification_busy},S};
        false->
            Id=string:lowercase(binary:encode_hex(crypto:strong_rand_bytes(16))),
            Parent=self(),A=damage_verification_runner:principal(Auth),
            {Pid,Ref}=spawn_opt(fun()->
                {Result,Prepared}=work(Mode,Spec,A,Parent,Id),
                Parent!{verification_complete,Id,self(),Result,Prepared}
            end,[link,monitor]),
            Timer=erlang:send_after(?DEADLINE_MS,self(),{verification_timeout,Id,Pid}),
            J=maps:merge(#{id=>Id,owner=>Owner,mode=>Mode,state=>running,
                feature_id=>maps:get(feature_id,Spec),sha256=>maps:get(sha256,Spec),
                created_at=>erlang:system_time(second),created_mono=>monotonic(),
                pid=>Pid,ref=>Ref,timer=>Timer,progress=>#{}},Extra),
            {reply,{ok,public_job(J)},S#{jobs:=Jobs#{Id=>J}}}
    end.
work(Mode,Spec,Auth,Sink,Id)->
    try preflight(Spec,Auth) of
        {ok,Prepared}->
            Result=damage_verification_runner:run(Mode,Prepared,Auth,Sink,Id),
            Next=case Result of #{state:=ready,cost:=Cost}->Prepared#{cost=>Cost};_->#{} end,
            {Result#{context_fingerprint=>maps:get(context_fingerprint,Prepared),
                     code_revision=>maps:get(revision,Prepared),
                     input_values=>maps:get(inputs,Prepared,#{} )},Next};
        {error,Reason}->{#{state=>blocked,error=>Reason},#{}}
    catch _:_->{#{state=>blocked,error=>preflight_unavailable},#{}} end.
preflight(Spec,Auth)->
    case damage_verification_catalog:get(maps:get(feature_id,Spec)) of
        {ok,#{sha256:=Hash}=E}->
            case Hash=:=maps:get(sha256,Spec) of
                false->{error,feature_changed};
                true->preflight_context(Spec,Auth,E)
            end;
        Error->Error
    end.
preflight_context(Spec,Auth,E)->
    case damage_context:public_effective_snapshot(maps:get(public_key,Auth)) of
        {ok,Snapshot}->
            FP=damage_verification_catalog:fingerprint(Snapshot),
            Catalog=damage_bdd_catalog:snapshot(Auth),
            Revision=damage_verification_catalog:sha256(term_to_binary(
                {maps:get(revision,Catalog),damage_verification_runner:revision()},[deterministic])),
            Stable=maps:get(context_fingerprint,Spec,FP)=:=FP andalso maps:get(revision,Spec,Revision)=:=Revision,
            Validation=damage_bdd_validator:validate(maps:get(source,E),Catalog),
            case {Stable,valid_feature(Validation),damage_verification_catalog:validate_inputs(
                    maps:get(inputs,E),maps:get(inputs,Spec,#{}),Snapshot)} of
                {false,_,_}->{error,context_or_code_changed};
                {_,false,_}->{error,step_validation_failed};
                {true,true,{ok,Inputs}}->{ok,Spec#{source=>maps:get(source,E),inputs=>Inputs,
                    revision=>Revision,context_fingerprint=>FP}};
                {_,_,{error,R}}->{error,R}
            end;
        _->{error,context_unavailable}
    end.
valid_feature(#{valid:=true})->true;
valid_feature(_)->false.
handle_info({verification_progress,Id,#{line:=Line,state:=Outcome}},#{jobs:=Jobs}=S)
    when is_integer(Line),Line>0 ->
    case maps:find(Id,Jobs) of
        {ok,#{state:=running,mode:=execute,progress:=Progress}=J} when map_size(Progress)<1024->
            case lists:member(Outcome,[passed,failed,skipped]) of
                true->{noreply,S#{jobs:=Jobs#{Id=>J#{progress:=Progress#{Line=>Outcome}}}}};
                false->{noreply,S}
            end;
        _->{noreply,S}
    end;
handle_info({verification_complete,Id,Pid,Result,Spec},#{jobs:=Jobs}=S)->
    case maps:find(Id,Jobs) of
        {ok,#{pid:=Pid,state:=running}=J}->{noreply,finish(Id,J,Result,Spec,S)};
        _->{noreply,S}
    end;
handle_info({verification_timeout,Id,Pid},#{jobs:=Jobs}=S)->
    case maps:find(Id,Jobs) of
        {ok,#{pid:=Pid,state:=running}=J}->
            exit(Pid,kill),
            {noreply,finish(Id,J,#{state=>indeterminate,error=>deadline_exceeded,retry_feature=>false},#{},S)};
        _->{noreply,S}
    end;
handle_info({'DOWN',Ref,process,_,_},#{jobs:=Jobs}=S)->
    Matches=[{Id,J}||{Id,J}<-maps:to_list(Jobs),maps:get(ref,J,undefined)=:=Ref],
    New=lists:foldl(fun({Id,J},Acc)->finish(Id,J,
        #{state=>indeterminate,error=>worker_stopped,retry_feature=>false},#{},Acc) end,S,Matches),
    {noreply,New};
handle_info(_,S)->{noreply,S}.
finish(Id,J,Result,Spec,#{jobs:=Jobs}=S)->
    erlang:cancel_timer(maps:get(timer,J)),erlang:demonitor(maps:get(ref,J),[flush]),
    unlink(maps:get(pid,J)),
    Base=maps:without([pid,ref,timer],J),
    Next=(maps:merge(Base,Result))#{finished_mono=>monotonic(),completed_at=>erlang:system_time(second),spec=>Spec},
    S#{jobs:=Jobs#{Id=>Next}}.
public_job(J)->
    Base=maps:with([id,mode,state,feature_id,sha256,created_at,completed_at,error,cost,
          run_id,report_hash,feature_hash,context_ipfs_hash,spend,tx_hash,settlement_status,
          retry_feature,preview_id,approved_job,cost_hits,cost_damage,cost_sats,
          context_fingerprint,code_revision,input_values],J),
    Progress=maps:get(progress,J,#{}),
    Base#{progress=>[#{line=>L,state=>V}||{L,V}<-lists:sort(maps:to_list(Progress))],
          approval_expires_at=>case {maps:get(mode,J),maps:get(state,J)} of
              {preview,ready}->maps:get(completed_at,J)+(?APPROVAL_MS div 1000);
              _->null end}.
prune(#{jobs:=Jobs}=S)->
    Now=monotonic(),
    S#{jobs:=maps:filter(fun(_,J)->maps:get(state,J)=:=running orelse
         Now-maps:get(created_mono,J)< ?RETENTION_MS end,Jobs)}.
request_id(B) when is_binary(B),byte_size(B)>=16,byte_size(B)=<80->
    re:run(B,<<"^[a-zA-Z0-9_-]+$">>,[{capture,none}])=:=match;
request_id(_)->false.
monotonic()->erlang:monotonic_time(millisecond).
handle_cast(_,S)->{noreply,S}.
terminate(_,#{jobs:=Jobs})->
    maps:foreach(fun(_,J)->case maps:get(pid,J,undefined) of P when is_pid(P)->exit(P,kill);_->ok end end,Jobs),ok.
code_change(_,S,_)->{ok,S}.
