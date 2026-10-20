%% Bounded human -> analysis -> synthesis -> recognition experiments. The live
%% microphone is leased from erm_phrase_voice; this is NOT another capture
%% process. Every synthetic/acoustic-loop take is evaluation-only.
-module(erm_phrase_lab).
-behaviour(gen_server).
-export([start/0,start/1,start_link/1,stop/0,status/0,record/2,train/1,
    cycle/3,sweep/2,evaluate/1,evaluate/2,calibrate/0,rate/2,report/0,export_report/1,cancel/0]).
-export([init/1,handle_call/3,handle_cast/2,handle_info/2,terminate/2,code_change/3]).
-record(st,{opts,ref,snapshot,backend_monitor,rows=[],phase=idle,job=undefined,
    active=undefined,report=undefined,last=undefined,wav=undefined,player_done=false,mic_done=false}).
start()->start(#{}).
start(O)->supervisor:start_child(erm_sup,#{id=>?MODULE,start=>{?MODULE,start_link,[O]},
    restart=>temporary,shutdown=>5000,type=>worker,modules=>[?MODULE]}).
start_link(O)->gen_server:start_link({local,?MODULE},?MODULE,O,[]).
stop()->gen_server:stop(?MODULE).
status()->call(status).
record(Action,Split)->call({record,Action,Split}).
train(Action)->call({train,Action}).
cycle(Action,Index,Controls)->call({cycle,Action,Index,Controls}).
sweep(Action,Index)->call({sweep,Action,Index}).
evaluate(Split)->evaluate(Split,#{}).
evaluate(Split,Thresholds)->call({evaluate,Split,Thresholds}).
calibrate()->call(calibrate).
rate(Run,Rating)->call({rate,Run,Rating}).
report()->call(report).
export_report(Path)->call({export_report,Path}).
cancel()->call(cancel).
call(Q)->gen_server:call(?MODULE,Q,15000).

init(Input)->
    process_flag(trap_exit,true),
    try
        {ok,Ref,Snapshot}=erm_phrase_voice:lab_begin(),
        O=options(Input,Snapshot),
        {ok,Rows}=erm_phrase_lab_store:load(maps:get(corpus_file,O),maps:get(binding,Snapshot)),
        Mon=erlang:monitor(process,whereis(erm_phrase_voice)),
        {ok,#st{opts=O,ref=Ref,snapshot=Snapshot,rows=Rows,backend_monitor=Mon}}
    catch C:R->{stop,{phrase_lab_start,C,R}} end.
handle_call(status,_,S)->
    Counts=lists:foldl(fun(#{expected:=A,split:=Split},M)->
        maps:update_with({Split,A},fun(N)->N+1 end,1,M) end,#{},S#st.rows),
    {reply,#{phase=>S#st.phase,corpus=>Counts,last=>S#st.last,
        run=>S#st.active,capture=>capture_status(),command_dispatch=>disabled,raw_audio_storage=>false,
        automatic_learning=>false},S};
handle_call(report,_,S)->{reply,S#st.report,S};
handle_call(cancel,_,S)->{reply,ok,cancel_work(S)};
handle_call({rate,Id,#{intelligible:=B,quality:=Q}=Rating},_,S=#st{report=#{id:=Id}=Report})
    when is_boolean(B),is_integer(Q),Q>=1,Q=<5,map_size(Rating)=:=2 ->
    {reply,ok,S#st{report=Report#{human_rating=>Rating}}};
handle_call({export_report,Path},_,S=#st{report=Report}) when is_map(Report)->
    {reply,erm_phrase_lab_store:write_report(Path,Report),S};
handle_call(Q,_,S=#st{phase=idle})->
    %% User configuration/data failures are recoverable. Do not lose the lease
    %% or a previously committed corpus because one experiment was invalid.
    try idle_call(Q,S) catch C:R->{reply,{error,{invalid_lab_request,C,R}},S} end;
handle_call(_,_,S)->{reply,{error,lab_busy_or_invalid_request},S}.
handle_cast(_,S)->{noreply,S}.

idle_call({record,A,Split},S)->
    true=lists:member(A,[unknown|erm_phrase_codec:actions()]),
    true=lists:member(Split,[train,validation,test]),
    true=Split=/=train orelse A=/=unknown,
    case erm_phrase_voice:lab_capture(S#st.ref) of
        ok->
            Say=case A of unknown-> <<"Say an unrelated or negated phrase, not a valid command.">>;
                _->erm_phrase_codec:prompt(A,maps:get(wake,S#st.snapshot)) end,
            Active=#{kind=>human_record,expected=>A,split=>Split,say=>Say},
            {reply,{ok,#{say=>Say,wait_for=>listening}},S#st{phase=arming_human,active=Active,last=undefined,report=undefined,wav=undefined}};
        Error->{reply,Error,S}
    end;
idle_call({train,A},S)->
    true=lists:member(A,erm_phrase_codec:actions()),
    Selected=[(maps:get(sample,R))#{action=>A} || R=#{expected:=B,split:=train,origin:=human,speaker_ok:=true}<-S#st.rows,B=:=A],
    true=length(Selected)>=3 andalso length(Selected)=<5,
    Samples=[X||X=#{action:=B}<-maps:get(samples,S#st.snapshot),B=/=A]++Selected,
    case erm_phrase_voice:lab_train(S#st.ref,Samples) of
        {ok,Snap}->{reply,{ok,#{action=>A,templates=>length(Selected),revision=>maps:get(revision,Snap)}},
            S#st{snapshot=Snap,last=human_templates_committed}};
        Error->{reply,Error,S}
    end;
idle_call({cycle,A,Index,Input},S)->
    Source=source(A,Index,S),C=erm_phrase_lab_native:controls(Input),
    Id=erlang:unique_integer([positive,monotonic]),
    Active=#{id=>Id,kind=>cycle,expected=>A,source=>maps:get(id,Source),controls=>C,
        profile_hash=>crypto:hash(sha256,erm_phrase_lab_native:profile(S#st.snapshot)),
        started_at=>erlang:system_time(millisecond)},
    Job=fun()->erm_phrase_lab_native:render(S#st.opts,maps:get(model,Source),
        erm_phrase_lab_native:profile(S#st.snapshot),C) end,
    {reply,{ok,Id},task(render,Job,S#st{active=Active,phase=rendering,report=undefined,wav=undefined})};
idle_call({sweep,A,Index},S)->
    Source=source(A,Index,S),Profile=erm_phrase_lab_native:profile(S#st.snapshot),
    Id=erlang:unique_integer([positive,monotonic]),
    Job=fun()->
        Candidates=[#{speed=>1.0,pitch=>P,noise=>N,acoustic=>false}||P<-[0.95,1.0,1.05],N<-[0.05,0.15,0.25]],
        Results=[begin
            {ok,R}=erm_phrase_lab_native:render(S#st.opts,maps:get(model,Source),Profile,C),
            (maps:without([wav],R))#{controls=>C,expected=>A}
        end||C<-Candidates],
        Ranked=lists:sort([{synth_rank(R,A),R}||R<-Results]),
        {ok,#{candidates=>Results,best=>element(2,hd(Ranked)),selection_scope=>training_cycle_only,
            promotion=>not_automatic,human_listening_required=>true}}
    end,
    {reply,{ok,Id},task(sweep,Job,S#st{phase=evaluating,report=undefined,wav=undefined,
        active=#{id=>Id,kind=>sweep,expected=>A,source=>maps:get(id,Source)}})};
idle_call({evaluate,Split,Thresholds},S) when Split=:=validation;Split=:=test ->
    true=is_map(Thresholds),true=maps:without([max_distance,min_margin],Thresholds)=:=#{},
    Snap=maps:merge(S#st.snapshot,Thresholds),_=erm_phrase_lab_native:profile(Snap),
    evaluate_job(Split,Snap,false,S);
idle_call(calibrate,S)->evaluate_job(validation,S#st.snapshot,true,S);
idle_call(_,S)->{reply,{error,unsupported_lab_request},S}.

source(A,I,S) when is_integer(I),I>=1,I=<5 ->
    Rows=[R||R=#{expected:=B,split:=train,origin:=human,speaker_ok:=true}<-S#st.rows,B=:=A],
    lists:nth(I,Rows).
synth_rank(#{result:=R},A)->
    {case matched(R,A) of true->0;false->1 end,maps:get(distance,R),-maps:get(margin,R)}.
matched(#{action:=A,reason:=Reason},A)->Reason=:=0 orelse Reason=:=matched;
matched(_,_) -> false.
evaluate_job(Split,Snap,Calibrate,S)->
    Rows=[R||R=#{split:=X,origin:=human}<-S#st.rows,X=:=Split],
    Profile=erm_phrase_lab_native:profile(Snap),Id=erlang:unique_integer([positive,monotonic]),
    Job=fun()->
        Scored=[begin {ok,M}=erm_phrase_lab_native:evaluate(S#st.opts,Profile,maps:get(sample,R)),
            (maps:with([id,expected,speaker_ok],R))#{result=>M} end||R<-Rows],
        Summary=erm_phrase_lab_metrics:summary(Scored,maps:get(max_distance,Snap),maps:get(min_margin,Snap)),
        Base=#{split=>Split,summary=>Summary,measurements=>Scored,profile_hash=>crypto:hash(sha256,Profile),
            synthetic_samples=>0,automatic_promotion=>false},
        case Calibrate of
            false->{ok,Base};
            true->Actions=lists:usort([A||#{action:=A}<-maps:get(samples,Snap)]),
                {ok,Base#{calibration=>erm_phrase_lab_metrics:recommend(Scored,Actions,Snap)}}
        end
    end,
    {reply,{ok,Id},task(evaluate,Job,S#st{phase=evaluating,report=undefined,wav=undefined,active=#{id=>Id,kind=>evaluation,split=>Split}})}.

task(Kind,F,S)->
    Parent=self(),Tag=make_ref(),
    {Pid,Mon}=spawn_opt(fun()->
        Result=try F() catch C:R->{error,{lab_worker,C,R}} end,
        Parent!{lab_job,Tag,Result}
    end,[link,monitor]),
    S#st{job=#{pid=>Pid,monitor=>Mon,tag=>Tag,kind=>Kind}}.
handle_info({lab_job,Tag,Result},S=#st{job=#{tag:=Tag,monitor:=Mon,kind:=Kind}})->
    erlang:demonitor(Mon,[flush]),
    {noreply,job_result(Kind,Result,S#st{job=undefined})};
handle_info({'DOWN',Mon,process,_,Why},S=#st{job=#{monitor:=Mon}})->
    {noreply,finish_error({worker_down,Why},S#st{job=undefined})};
handle_info({'DOWN',Mon,process,_,Why},S=#st{backend_monitor=Mon})->
    {stop,{capture_backend_down,Why},cancel_work(S)};
handle_info({erm_phrase_lab,Ref,armed},S=#st{ref=Ref,phase=arming_human})->
    {noreply,S#st{phase=listening,last=speak_now}};
handle_info({erm_phrase_lab,Ref,armed},S=#st{ref=Ref,phase=arming_loop,wav=Wav})->
    {noreply,task(play,fun()->erm_phrase_lab_native:play(S#st.opts,Wav) end,
        S#st{phase=playing,player_done=false,mic_done=false})};
handle_info({erm_phrase_lab,Ref,{sample,U}},S=#st{ref=Ref,phase=listening})->
    {noreply,store_human(U,S)};
handle_info({erm_phrase_lab,Ref,{sample,U}},S=#st{ref=Ref,phase=Phase,report=R})
    when Phase=:=playing;Phase=:=waiting_for_audio ->
    A=maps:get(expected,S#st.active),
    Acoustic=#{origin=>synthetic_playback,content_match=>matched(maps:get(result,U),A),
        result=>maps:get(result,U),verification=>maps:get(verification,U),
        quality=>maps:get(quality,U),ms=>maps:get(ms,U),
        attribution=>first_vad_segment_in_trial_not_proof_of_audio_identity},
    safe_cancel(S),
    {noreply,maybe_finish_loop(S#st{mic_done=true,report=R#{acoustic=>Acoustic}})};
handle_info({erm_phrase_lab,Ref,{error,backend_failed}},S=#st{ref=Ref})->
    {stop,capture_backend_failed,cancel_work(S)};
handle_info({erm_phrase_lab,Ref,{error,Why}},S=#st{ref=Ref})->
    {noreply,finish_error(Why,S)};
handle_info(_,S)->{noreply,S}.

job_result(render,{ok,Rendered},S)->
    R=maps:merge(S#st.active,#{digital=>maps:without([wav],Rendered),
        digital_content_match=>matched(maps:get(result,Rendered),maps:get(expected,S#st.active)),
        human_rating=>not_rated,automatic_promotion=>false}),
    C=maps:get(controls,S#st.active),Next=S#st{report=R,wav=maps:get(wav,Rendered)},
    case maps:get(acoustic,C) of
        false->finish(Next);
        true->case erm_phrase_voice:lab_capture(S#st.ref) of
            ok->Next#st{phase=arming_loop};
            Error->finish_error({arm_loop,Error},Next)
        end
    end;
job_result(play,ok,S)->maybe_finish_loop(S#st{player_done=true,phase=waiting_for_audio});
job_result(Kind,{ok,Result},S) when Kind=:=sweep;Kind=:=evaluate ->
    finish(S#st{report=maps:merge(S#st.active,Result)});
job_result(_,Error,S)->finish_error(Error,S).
maybe_finish_loop(S=#st{mic_done=true,player_done=true})->finish(S);
maybe_finish_loop(S)->S.
finish(S)->S#st{phase=idle,active=undefined,last=experiment_complete,job=undefined}.
finish_error(Why,S)->
    Cancelled=cancel_work(S),
    Base=case S#st.report of R when is_map(R)->R;_->case S#st.active of A when is_map(A)->A;_->#{} end end,
    Cancelled#st{report=Base#{error=>Why},last={experiment_failed,Why}}.
store_human(U,S)->
    try
        #{expected:=A,split:=Split}=S#st.active,
        Verified=case maps:get(verification,U) of {ok,_}->true;_->false end,
        %% Keep failed speaker/quality checks in held-out evaluation; never
        %% exclude hard positive takes and inflate the reported accuracy.
        true=Split=/=train orelse Verified,
        Sample=maps:get(sample,U),
        case Split of
            train->ok;
            _->Fingerprint=erm_phrase_codec:fingerprint(Sample),
                false=lists:any(fun(X)->erm_phrase_codec:fingerprint(X)=:=Fingerprint end,
                    maps:get(samples,S#st.snapshot))
        end,
        Model=case Split of train->maps:get(synthesis,U);_-> <<>> end,
        Row=#{origin=>human,expected=>A,split=>Split,sample=>Sample,model=>Model,
            speaker_ok=>Verified,created_at=>erlang:system_time(millisecond),
            id=>erm_phrase_codec:fingerprint(Sample)},
        {ok,Rows}=erm_phrase_lab_store:insert(Row,S#st.rows),
        ok=erm_phrase_lab_store:save(maps:get(corpus_file,S#st.opts),maps:get(binding,S#st.snapshot),Rows),
        S#st{phase=idle,active=undefined,rows=Rows,last=#{recorded=>maps:get(id,Row),expected=>A,split=>Split}}
    catch C:R->S#st{phase=idle,active=undefined,last={human_sample_rejected,C,R}} end.
capture_status()->
    try maps:with([ready,processing,suppressed,echo_guard_remaining_ms],erm_phrase_voice:status())
    catch _:_ -> #{ready=>false} end.
safe_cancel(S)->try erm_phrase_voice:lab_cancel(S#st.ref) catch _:_ -> ok end.
cancel_work(S)->
    case S#st.job of
        #{pid:=Pid,monitor:=Mon}->erlang:demonitor(Mon,[flush]),exit(Pid,kill);
        _->ok
    end,
    safe_cancel(S),S#st{phase=idle,active=undefined,job=undefined,wav=undefined,last=cancelled}.
terminate(_,S)->
    _=cancel_work(S),
    try erm_phrase_voice:lab_end(S#st.ref) catch _:_ -> ok end,ok.
code_change(_,_,_)->{error,restart_required}.
options(M,Snap) when is_map(M)->
    true=maps:without([binary,player,device,corpus_file],M)=:=#{},
    Priv=case code:priv_dir(erm) of Dir when is_list(Dir)->Dir;_->"/usr/lib/erm/priv" end,
    O=maps:merge(#{binary=>filename:join(Priv,"erm_phrase_lab"),player=>"/usr/bin/aplay",device=>"default",
        corpus_file=>filename:join(filename:dirname(maps:get(profile_file,Snap)),"roundtrip.elab")},M),
    lists:foreach(fun(K)->V=maps:get(K,O),true=is_list(V) andalso length(V)>0 andalso length(V)<4096,
        false=lists:member(0,V),absolute=filename:pathtype(V) end,[binary,player,corpus_file]),
    D=maps:get(device,O),true=is_list(D) andalso length(D)>0 andalso length(D)<256,
    false=lists:member(0,D),O.
