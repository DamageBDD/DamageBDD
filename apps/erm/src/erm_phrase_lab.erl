%% Bounded human -> analysis -> synthesis -> recognition experiments. The live
%% microphone is leased from erm_phrase_voice; this is NOT another capture
%% process. Every synthetic/acoustic-loop take is evaluation-only.
-module(erm_phrase_lab).
-behaviour(gen_server).
-export([start/0,start/1,start_link/1,stop/0,status/0,record/2,verify/1,train/1,
    enrol_voice/2,restart_voice/1,record_voice/0,save_voice/0,select_voice/1,delete_voice/1,set_wake/1,
    set_autoplay/1,replay/0,stop_playback/0,clear_trace/0,
    cycle/3,sweep/2,evaluate/1,evaluate/2,calibrate/0,rate/2,report/0,export_report/1,cancel/0,cancel/1]).
-export([init/1,handle_call/3,handle_cast/2,handle_info/2,terminate/2,code_change/3]).
-record(st,{opts,ref,snapshot,backend_monitor,rows=[],phase=idle,job=undefined,
    active=undefined,report=undefined,last=undefined,wav=undefined,player_done=false,mic_done=false,voice_draft=undefined,
    autoplay=false,playback=idle,playback_error=undefined,playback_job=undefined,
    last_synthesis=undefined,last_wav=undefined,diagnostics=#{},history=[],trace=[],trace_seq=0,trace_start=0}).
start()->start(#{}).
start(O)->supervisor:start_child(erm_sup,#{id=>?MODULE,start=>{?MODULE,start_link,[O]},
    restart=>temporary,shutdown=>5000,type=>worker,modules=>[?MODULE]}).
start_link(O)->gen_server:start_link({local,?MODULE},?MODULE,O,[]).
stop()->gen_server:stop(?MODULE).
status()->call(status).
record(Action,Split)->call({record,Action,Split}).
%% A diagnostic capture uses the same gates but never enters the corpus.
verify(Action)->call({verify,Action}).
train(Action)->call({train,Action}).
enrol_voice(Label,Count)->call({enrol_voice,Label,Count}).
restart_voice(Id)->call({restart_voice,Id}).
record_voice()->call(record_voice).
save_voice()->call(save_voice).
select_voice(Id)->call({select_voice,Id}).
delete_voice(Id)->call({delete_voice,Id}).
set_wake(Text)->call({set_wake,Text}).
set_autoplay(B)->call({set_autoplay,B}).
replay()->call(replay).
stop_playback()->call(stop_playback).
clear_trace()->call(clear_trace).
cycle(Action,Index,Controls)->call({cycle,Action,Index,Controls}).
sweep(Action,Index)->call({sweep,Action,Index}).
evaluate(Split)->evaluate(Split,#{}).
evaluate(Split,Thresholds)->call({evaluate,Split,Thresholds}).
calibrate()->call(calibrate).
rate(Run,Rating)->call({rate,Run,Rating}).
report()->call(report).
export_report(Path)->call({export_report,Path}).
cancel()->call(cancel).
%% A UI may cancel only the capture it started, even after another client acts.
cancel(Id)->call({cancel,Id}).
call(Q)->gen_server:call(?MODULE,Q,15000).

init(Input)->
    process_flag(trap_exit,true),
    try
        {ok,Ref,Snapshot}=erm_phrase_voice:lab_begin(),
        O=options(Input,Snapshot),
        {ok,Rows}=erm_phrase_lab_store:load(maps:get(corpus_file,O),maps:get(binding,Snapshot)),
        Mon=erlang:monitor(process,whereis(erm_phrase_voice)),
        {ok,#st{opts=O,ref=Ref,snapshot=Snapshot,rows=Rows,backend_monitor=Mon,trace_start=now_ms()}}
    catch C:R->{stop,{phrase_lab_start,C,R}} end.
handle_call(status,_,S)->
    Counts=lists:foldl(fun(#{expected:=A,split:=Split},M)->
        maps:update_with({Split,A},fun(N)->N+1 end,1,M) end,#{},S#st.rows),
    {reply,#{phase=>S#st.phase,corpus=>Counts,last=>S#st.last,
        profiles=>maps:get(profiles,S#st.snapshot),
        enrolled=>maps:get(enrolled,S#st.snapshot),
        templates=>template_counts(maps:get(samples,S#st.snapshot)),
        recognition_thresholds=>maps:with([max_distance,min_margin],S#st.snapshot),
        playback=>playback_status(S),diagnostics=>S#st.diagnostics,
        history=>lists:reverse(S#st.history),trace=>lists:reverse(S#st.trace),
        enrolment=>draft_status(S#st.voice_draft),
        thresholds=>maps:get(thresholds,S#st.snapshot,#{}),
        prompts=>maps:from_list([{A,erm_phrase_codec:prompt(A,maps:get(wake,S#st.snapshot))}
            || A<-erm_phrase_codec:actions()]),
        run=>S#st.active,capture=>capture_status(S),command_dispatch=>disabled,raw_audio_storage=>false,
        automatic_learning=>false},S};
handle_call(report,_,S)->{reply,S#st.report,S};
handle_call({set_autoplay,B},_,S) when is_boolean(B)->
    {reply,ok,trace(autoplay_changed,#{enabled=>B},S#st{autoplay=B})};
handle_call({set_autoplay,_},_,S)->{reply,{error,invalid_autoplay},S};
handle_call(clear_trace,_,S)->{reply,ok,S#st{trace=[]}};
handle_call(stop_playback,_,S)->{reply,ok,stop_debug_playback(stopped,S)};
handle_call(replay,_,S=#st{phase=idle,playback_job=undefined,last_synthesis=M}) when is_binary(M)->
    {reply,ok,start_debug_playback(touch_draft(S))};
handle_call(replay,_,S=#st{last_synthesis=undefined})->{reply,{error,no_audio_available},S};
handle_call(replay,_,S)->{reply,{error,lab_busy_or_playback_active},S};
handle_call(cancel,_,S)->{reply,ok,cancel_work(S)};
handle_call({cancel,Id},_,S=#st{voice_draft=#{id:=Id}})->{reply,ok,cancel_work(S)};
handle_call({cancel,Id},_,S=#st{active=#{id:=Id}})->{reply,ok,cancel_work(S)};
handle_call({cancel,_},_,S)->{reply,{error,stale_capture},S};
handle_call({restart_voice,Id},_,S0=#st{voice_draft=#{id:=Id,label:=Label,target:=N}})->
    S=clear_debug_audio(stop_debug_playback(restarted,S0)),
    %% Close the owned capture before replacing its reference samples. The
    %% backend advances its epoch, so late native results cannot enter the
    %% replacement draft. Drain messages it sent before acknowledging cancel.
    case erm_phrase_voice:lab_cancel(S#st.ref) of
        ok->
            flush_capture_messages(S#st.ref),
            cancel_voice_timer(S),
            Draft=voice_draft(Label,N),
            {reply,{ok,#{enrolment_id=>maps:get(id,Draft)}},
                trace(enrolment_restarted,#{id=>maps:get(id,Draft)},
                    S#st{voice_draft=Draft,phase=idle,active=undefined,last=voice_enrolment_restarted})};
        Error->{reply,Error,S}
    end;
handle_call({restart_voice,_},_,S)->{reply,{error,stale_enrolment},S};
handle_call({rate,Id,#{intelligible:=B,quality:=Q}=Rating},_,S=#st{report=#{id:=Id}=Report})
    when is_boolean(B),is_integer(Q),Q>=1,Q=<5,map_size(Rating)=:=2 ->
    {reply,ok,S#st{report=Report#{human_rating=>Rating}}};
handle_call({export_report,Path},_,S=#st{report=Report}) when is_map(Report)->
    {reply,erm_phrase_lab_store:write_report(Path,Report),S};
handle_call(Q,_,S=#st{phase=idle})->
    %% User configuration/data failures are recoverable. Do not lose the lease
    %% or a previously committed corpus because one experiment was invalid.
    try idle_call(Q,S)
    catch throw:{lab_error,Why}->{reply,{error,Why},S};
          C:R->{reply,{error,{invalid_lab_request,C,R}},S} end;
handle_call(_,_,S)->{reply,{error,lab_busy_or_invalid_request},S}.
handle_cast(_,S)->{noreply,S}.

idle_call({enrol_voice,Text,N},S=#st{voice_draft=undefined})->
    require(is_integer(N) andalso N>=3 andalso N=<10,invalid_voice_sample_count),
    Label=erm_voice_profiles:label(Text),
    Voices=maps:get(voices,maps:get(profiles,S#st.snapshot)),
    require(not lists:any(fun(#{label:=L})->L=:=Label end,Voices),voice_name_already_exists),
    require(length(Voices)<16,voice_profile_limit),
    Draft=voice_draft(Label,N),
    {reply,{ok,#{enrolment_id=>maps:get(id,Draft)}},S#st{voice_draft=Draft,last=voice_enrolment_started}};
idle_call(record_voice,S=#st{voice_draft=#{collected:=N,target:=Target}=D}) when N<Target->
    begin_capture(#{kind=>voice_enrol,expected=>speaker,say=>maps:get(prompt,D)},S);
idle_call(save_voice,S=#st{voice_draft=#{collected:=N,target:=N,label:=Label,vectors:=Vs}})->
    profile_change({enrol,Label,Vs},S);
idle_call(_,S=#st{voice_draft=D}) when D=/=undefined->
    {reply,{error,finish_or_cancel_voice_enrolment},S};
idle_call({select_voice,Id},S)->profile_change({select,Id},S);
idle_call({delete_voice,Id},S)->profile_change({delete,Id},S);
idle_call({set_wake,Text},S)->profile_change({wake,Text},S);
idle_call(_,S=#st{playback_job=J}) when J=/=undefined->
    {reply,{error,playback_active},S};
idle_call({record,A,Split},S)->
    require(lists:member(A,[unknown|erm_phrase_codec:actions()]),unknown_action),
    require(lists:member(Split,[train,validation,test]),invalid_corpus_split),
    require(Split=/=train orelse A=/=unknown,unknown_is_evaluation_only),
    begin_capture(#{kind=>human_record,expected=>A,split=>Split},S);
idle_call({verify,A},S)->
    require(lists:member(A,erm_phrase_codec:actions()),unknown_action),
    begin_capture(#{kind=>voice_verify,expected=>A},S);
idle_call({train,A},S)->
    require(lists:member(A,erm_phrase_codec:actions()),unknown_action),
    Selected=[(maps:get(sample,R))#{action=>A} || R=#{expected:=B,split:=train,origin:=human,speaker_ok:=true}<-S#st.rows,B=:=A],
    require(length(Selected)>=3 andalso length(Selected)=<5,
        #{reason=>insufficient_training_samples,action=>A,accepted=>length(Selected),
          required_min=>3,required_max=>5,next=>record_human_training_samples}),
    Samples=[X||X=#{action:=B}<-maps:get(samples,S#st.snapshot),B=/=A]++Selected,
    case erm_phrase_voice:lab_train(S#st.ref,Samples) of
        {ok,Snap}->
            Result=#{action=>A,templates=>length(Selected),revision=>maps:get(revision,Snap)},
            lab_event(idle,<<"Phrase trained with verified human takes.">>),
            {reply,{ok,Result},S#st{snapshot=Snap,last=Result#{outcome=>human_templates_committed}}};
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

begin_capture(_,S=#st{playback_job=J}) when J=/=undefined->{reply,{error,playback_active},S};
begin_capture(Active0=#{expected:=A},S0)->
    S=clear_debug_audio(S0#st{playback=idle,playback_error=undefined}),
    case erm_phrase_voice:lab_capture(S#st.ref) of
        ok->
            Say=case maps:find(say,Active0) of
                {ok,Given}->Given;
                error->case A of unknown-> <<"Say an unrelated or negated phrase, not a valid command.">>;
                    _->erm_phrase_codec:prompt(A,maps:get(wake,S#st.snapshot)) end
            end,
            Id=erlang:unique_integer([positive,monotonic]),
            Active=Active0#{id=>Id,say=>Say},
            lab_event(idle,<<"Wait for listening, then say: ",Say/binary>>),
            Limits=maps:get(thresholds,S#st.snapshot,#{}),
            Prompt=(maps:with([min_speaker_ms,max_segment_ms],Limits))#{id=>Id,say=>Say,wait_for=>listening},
            {reply,{ok,Prompt},trace(capture_requested,maps:with([id,kind,expected],Active),
                touch_draft(S#st{phase=arming_human,active=Active,last=undefined,report=undefined,wav=undefined}))};
        Error->{reply,Error,S}
    end.

require(true,_)->ok;
require(false,Why)->throw({lab_error,Why}).

source(A,I,S) ->
    require(lists:member(A,erm_phrase_codec:actions()),unknown_action),
    require(is_integer(I) andalso I>=1 andalso I=<5,
        #{reason=>invalid_sample_index,index=>I,minimum=>1,maximum=>5}),
    Rows=[R||R=#{expected:=B,split:=train,origin:=human,speaker_ok:=true}<-S#st.rows,B=:=A],
    require(length(Rows)>=I,#{reason=>missing_training_sample,action=>A,index=>I,
        available=>length(Rows),next=>record_human_training_samples}),
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
handle_info({voice_playback,Tag,Result},S=#st{playback_job=#{tag:=Tag,monitor:=Mon,kind:=Kind}})->
    erlang:demonitor(Mon,[flush]),
    {noreply,debug_playback_result(Kind,Result,S#st{playback_job=undefined})};
handle_info({'DOWN',Mon,process,_,Why},S=#st{playback_job=#{monitor:=Mon}})->
    {noreply,playback_failed({worker_down,Why},S#st{playback_job=undefined})};
handle_info({lab_job,Tag,Result},S=#st{job=#{tag:=Tag,monitor:=Mon,kind:=Kind}})->
    erlang:demonitor(Mon,[flush]),
    {noreply,job_result(Kind,Result,S#st{job=undefined})};
handle_info({'DOWN',Mon,process,_,Why},S=#st{job=#{monitor:=Mon}})->
    {noreply,finish_error({worker_down,Why},S#st{job=undefined})};
handle_info({'DOWN',Mon,process,_,Why},S=#st{backend_monitor=Mon})->
    {stop,{capture_backend_down,Why},cancel_work(S)};
handle_info({erm_phrase_lab,Ref,armed},S=#st{ref=Ref,phase=arming_human})->
    lab_event(idle,<<"Say: ",(maps:get(say,S#st.active))/binary>>),
    {noreply,trace(capture_armed,maps:with([id,kind],S#st.active),S#st{phase=listening,last=speak_now})};
handle_info({erm_phrase_lab,Ref,{diagnostic,Code}},S=#st{ref=Ref,active=Active}) when is_map(Active)->
    {noreply,trace(capture_progress,(maps:with([id,kind],Active))#{reason=>Code},S)};
handle_info({erm_phrase_lab,Ref,armed},S=#st{ref=Ref,phase=arming_loop,wav=Wav})->
    {noreply,task(play,fun()->erm_phrase_lab_native:play(S#st.opts,Wav) end,
        S#st{phase=playing,player_done=false,mic_done=false})};
handle_info({erm_phrase_lab,Ref,{sample,U}},S=#st{ref=Ref,phase=listening,active=#{kind:=voice_enrol}})->
    {noreply,captured(U,S,voice_sample(U,S))};
handle_info({erm_phrase_lab,Ref,{sample,U}},S=#st{ref=Ref,phase=listening,active=#{kind:=voice_verify}})->
    Check=maps:get(check,U),
    Accepted=maps:get(accepted,Check,false),
    Text=case Accepted of true-> <<"Speaker and audio checks passed. Verification take was not saved.">>;
        false->rejection_text(maps:get(reason,Check),Check) end,
    lab_event(case Accepted of true->idle;false->error end,Text),
    Last=(maps:with([id,expected],S#st.active))#{outcome=>voice_verified,
        verification=>maps:get(verification,U),check=>Check,saved=>false,
        recognition=>maps:get(result,U),content_match=>matched(maps:get(result,U),maps:get(expected,S#st.active))},
    {noreply,captured(U,S,S#st{phase=idle,active=undefined,last=Last})};
handle_info({erm_phrase_lab,Ref,{sample,U}},S=#st{ref=Ref,phase=listening})->
    {noreply,captured(U,S,store_human(U,S))};
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
handle_info({erm_phrase_lab,Ref,{error,Why}},S=#st{ref=Ref,phase=Phase,active=Active})
    when is_map(Active),(Phase=:=arming_human orelse Phase=:=listening)->
    {noreply,capture_failed(Why,S)};
handle_info({erm_phrase_lab,Ref,{error,Why}},S=#st{ref=Ref})->
    {noreply,finish_error(Why,S)};
handle_info({voice_enrol_expired,Id},S=#st{voice_draft=#{id:=Id,deadline:=Deadline}})->
    %% A refreshed inactivity timer may have already queued its old message.
    %% Rendering/playback counts as active work, never as an abandoned draft.
    case now_ms()>=Deadline andalso S#st.playback_job=:=undefined andalso S#st.active=:=undefined of
        true->
            lab_event(error,<<"Voice enrolment expired. Start again when ready.">>),
            {noreply,trace(enrolment_expired,#{id=>Id},(cancel_work(S))#st{last=voice_enrolment_expired})};
        false->{noreply,touch_draft(S)}
    end;
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
    Info=maps:merge(maps:with([id,expected,split],S#st.active),maps:with([verification,check],U)),
    Result=try
        #{expected:=A,split:=Split}=S#st.active,
        Verified=case maps:get(verification,U) of {ok,_}->true;_->false end,
        %% Keep failed speaker/quality checks in held-out evaluation; never
        %% exclude hard positive takes and inflate the reported accuracy.
        require(Split=/=train orelse Verified,
            maps:get(reason,maps:get(check,U,#{}),verification_failed)),
        Sample=maps:get(sample,U),
        case Split of
            train->ok;
            _->Fingerprint=erm_phrase_codec:fingerprint(Sample),
                require(not lists:any(fun(X)->erm_phrase_codec:fingerprint(X)=:=Fingerprint end,
                    maps:get(samples,S#st.snapshot)),sample_already_used_for_training)
        end,
        Model=case Split of train->maps:get(synthesis,U);_-> <<>> end,
        Row=#{origin=>human,expected=>A,split=>Split,sample=>Sample,model=>Model,
            speaker_ok=>Verified,created_at=>erlang:system_time(millisecond),
            id=>erm_phrase_codec:fingerprint(Sample)},
        require(not lists:any(fun(X)->maps:get(id,X)=:=maps:get(id,Row) end,S#st.rows),duplicate_sample),
        Rows=case erm_phrase_lab_store:insert(Row,S#st.rows) of
            {ok,NewRows}->NewRows;
            {error,InsertError}->throw({lab_error,{corpus_insert_failed,InsertError}})
        end,
        case erm_phrase_lab_store:save(maps:get(corpus_file,S#st.opts),maps:get(binding,S#st.snapshot),Rows) of
            ok->{ok,Row,Rows};
            {error,SaveError}->throw({lab_error,{corpus_save_failed,SaveError}})
        end
    catch throw:{lab_error,Why}->{error,Why};
          C:R->{error,{sample_processing_failed,C,R}} end,
    case Result of
        {ok,SavedRow,SavedRows}->
            lab_event(idle,<<"Human take saved. Check the corpus count before training.">>),
            S#st{phase=idle,active=undefined,rows=SavedRows,
                last=Info#{outcome=>human_sample_saved,recorded=>maps:get(id,SavedRow)}};
        {error,Reason}->
            lab_event(error,rejection_text(Reason,maps:get(check,U,#{}))),
            S#st{phase=idle,active=undefined,
                last=Info#{outcome=>human_sample_rejected,reason=>Reason}}
    end.

lab_event(Phase,Text)->
    try erm_voice_events:publish(?MODULE,work,#{phase=>Phase,text=>Text})
    catch error:undef->ok end.
rejection_text(audio_too_short,#{audio_ms:=Ms,thresholds:=#{min_speaker_ms:=Min}})->
    iolist_to_binary(io_lib:format("Recording too short: ~B ms; need ~B ms. Say the full phrase.",[Ms,Min]));
rejection_text(audio_too_quiet,_)-> <<"Recording too quiet. Check microphone level and distance.">>;
rejection_text(audio_clipped,_)-> <<"Recording clipped. Reduce microphone gain or move farther away.">>;
rejection_text(speaker_below_threshold,_)-> <<"Speaker check failed. Check the microphone and enrolled speaker profile.">>;
rejection_text(no_phrase_features,_)-> <<"No usable phrase features. Record a new spoken take.">>;
rejection_text(missing_embedding,_)-> <<"Speaker analysis returned no embedding. Check voice status.">>;
rejection_text(invalid_embedding,_)-> <<"Speaker analysis returned an invalid embedding. Check voice status.">>;
rejection_text(embedding_dimension_mismatch,_)-> <<"Speaker model and profile dimensions differ. Check voice status.">>;
rejection_text(duplicate_sample,_)-> <<"This sample is already in the corpus. Record a new spoken take.">>;
rejection_text(_,_)-> <<"Recording was not saved. Check erm_phrase_lab:status() for the reason.">>.
capture_status(S)->
    C=capture_status(),
    case S#st.playback_job of undefined->C;_->C#{ready=>false,playback_active=>true} end.
capture_status()->
    try maps:with([ready,processing,suppressed,echo_guard_remaining_ms],erm_phrase_voice:status())
    catch _:_ -> #{ready=>false} end.
safe_cancel(S)->try erm_phrase_voice:lab_cancel(S#st.ref) catch _:_ -> ok end.
flush_capture_messages(Ref)->
    receive {erm_phrase_lab,Ref,_}->flush_capture_messages(Ref) after 0->ok end.
cancel_work(S)->
    Next=stop_debug_playback(cancelled,S),
    cancel_voice_timer(Next),
    case Next#st.job of
        #{pid:=Pid,monitor:=Mon}->erlang:demonitor(Mon,[flush]),exit(Pid,kill);
        _->ok
    end,
    safe_cancel(Next),trace(cancelled,#{},Next#st{phase=idle,active=undefined,job=undefined,wav=undefined,last=cancelled,voice_draft=undefined}).
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
    false=lists:member(0,D),
    corpus_options(O#{corpus_base=>maps:get(corpus_file,M,undefined)},Snap).

corpus_options(O,Snap)->
    Binding=maps:get(binding,Snap),
    Path=case maps:get(corpus_base,O,undefined) of
        undefined->filename:join(filename:dirname(maps:get(profile_file,Snap)),"roundtrip.elab");
        Base->case Binding=:=maps:get(legacy_binding,Snap) of
            true->Base;
            false->Base++"."++binary_to_list(binary:encode_hex(Binding))
        end
    end,
    O#{corpus_file=>Path}.
template_counts(Samples)->lists:foldl(fun(#{action:=A},M)->
    maps:update_with(A,fun(N)->N+1 end,1,M) end,#{},Samples).
draft_status(undefined)->undefined;
draft_status(D)->(maps:with([id,label,target,collected,rejected,prompt,last],D))#{
    remaining_ms=>max(0,maps:get(deadline,D)-now_ms())}.
voice_draft(Label,N)->
    Id=erlang:unique_integer([positive,monotonic]),
    #{id=>Id,label=>Label,target=>N,collected=>0,rejected=>0,vectors=>[],fingerprints=>[],
      prompt=>voice_prompt(0),last=>undefined,
      deadline=>now_ms()+180000,timer=>erlang:send_after(180000,self(),{voice_enrol_expired,Id})}.
touch_draft(S=#st{voice_draft=#{id:=Id}=D})->
    cancel_voice_timer(S),
    S#st{voice_draft=D#{deadline=>now_ms()+180000,
        timer=>erlang:send_after(180000,self(),{voice_enrol_expired,Id})}};
touch_draft(S)->S.
voice_prompt(N)->lists:nth((N rem 5)+1,[
    <<"I am speaking naturally at my usual volume.">>,
    <<"Please play some music while I work today.">>,
    <<"The microphone can hear me clearly from here.">>,
    <<"I can pause the music and choose another track.">>,
    <<"This is my voice at a comfortable speaking pace.">>]).
voice_sample(U,S=#st{voice_draft=D})->
    #{vectors:=Vs,fingerprints:=Fs,collected:=N,target:=Target}=D,
    FP=erm_phrase_codec:fingerprint(maps:get(sample,U)),
    Result=case lists:member(FP,Fs) of
        true->{reject,(maps:remove(speaker_score,maps:get(check,U)))#{accepted=>false,reason=>duplicate_sample}};
        false->erm_voice_profiles:enrol_check(U,Vs,maps:get(thresholds,S#st.snapshot),
            maps:get(speaker_dimension,S#st.snapshot))
    end,
    {Next,Check,Outcome}=case Result of
        {accept,V,C}->{D#{vectors=>Vs++[V],fingerprints=>Fs++[FP],collected=>N+1,
            prompt=>voice_prompt(N+1),last=>C},C,voice_sample_accepted};
        {reject,C}->{D#{rejected=>maps:get(rejected,D)+1,last=>C},C,voice_sample_rejected}
    end,
    Text=case {Outcome,maps:get(collected,Next)} of
        {voice_sample_accepted,Target}-> <<"Voice samples ready. Choose Save voice to activate the new profile.">>;
        {voice_sample_accepted,_}-> <<"Voice sample accepted. Record the next prompted sentence.">>;
        _-> <<"Voice sample rejected. Check the quality and consistency feedback, then retry.">>
    end,
    lab_event(case Outcome of voice_sample_accepted->idle;_->error end,Text),
    S#st{phase=idle,active=undefined,voice_draft=Next,last=#{outcome=>Outcome,check=>Check}}.
cancel_voice_timer(#st{voice_draft=#{timer:=T}})->erlang:cancel_timer(T),ok;
cancel_voice_timer(_)->ok.
profile_change(Request,S0)->
    S=clear_debug_audio(stop_debug_playback(profile_changed,S0)),
    case erm_phrase_voice:lab_profile(S#st.ref,Request) of
        {ok,Snap}->
            cancel_voice_timer(S),
            O=corpus_options(S#st.opts,Snap),
            case erm_phrase_lab_store:load(maps:get(corpus_file,O),maps:get(binding,Snap)) of
                {ok,Rows}->
                    Outcome=case Request of {enrol,_,_}->voice_enrolled;{wake,_}->wake_selected;
                        {delete,_}->voice_deleted;_->voice_selected end,
                    Public=maps:get(profiles,Snap),
                    lab_event(idle,<<"Voice settings updated. Training data now matches the selected voice and wake phrase.">>),
                    {reply,{ok,Public},S#st{snapshot=Snap,opts=O,rows=Rows,voice_draft=undefined,
                        report=undefined,last=#{outcome=>Outcome,profiles=>Public,
                            profile_cleanup=>maps:get(profile_cleanup,Snap,ok)}}};
                {error,Why}->
                    %% Never keep the old corpus after the backend changed binding.
                    {stop,{profile_corpus_load_failed,Why},{error,{profile_corpus_load_failed,Why}},
                        S#st{snapshot=Snap,opts=O,rows=[],voice_draft=undefined}}
            end;
        Error->{reply,Error,S}
    end.

%% The debug loop uses only the LPC model of the just-completed human take.
%% It never feeds synthesis back to capture, enrolment or the phrase corpus.
captured(U,Before,After0)->
    Active=Before#st.active,Last=After0#st.last,
    Check0=maps:get(check,Last,maps:get(check,U,#{})),
    Check=case maps:get(outcome,Last) of
        human_sample_rejected->Check0#{accepted=>false,reason=>maps:get(reason,Last)};
        _->Check0
    end,
    Prior=case Before#st.voice_draft of #{vectors:=Vs}->Vs;_->[] end,
    Context=(maps:with([id,kind,expected],Active))#{check=>Check,prior=>Prior,
        snapshot=>Before#st.snapshot,outcome=>maps:get(outcome,Last)},
    Diagnostics=try erm_voice_diagnostics:capture(U,Context)
        catch C:R->#{id=>maps:get(id,Active),error=>diagnostics_failed,reason=>error_summary({C,R})} end,
    Entry=(maps:with([id,kind,expected],Active))#{outcome=>maps:get(outcome,Last),
        reason=>error_summary(maps:get(reason,Check,maps:get(reason,Last,undefined))),
        audio_ms=>maps:get(ms,U,0),accepted=>maps:get(accepted,Check,false)},
    Summary=maps:merge(Entry,history_scores(Check)),
    After=trace(capture_result,Summary,touch_draft(After0#st{diagnostics=Diagnostics,
        history=lists:sublist([Summary|After0#st.history],20)})),
    case maps:get(synthesis,U,undefined) of
        Model when is_binary(Model)->
            case erm_phrase_lab_store:validate_model(Model) of
                ok->
                    Ready=After#st{last_synthesis=Model,last_wav=undefined,playback=idle,playback_error=undefined},
                    case Ready#st.autoplay of true->start_debug_playback(Ready);false->Ready end;
                _->playback_failed(invalid_synthesis_model,clear_debug_audio(After))
            end;
        _->playback_failed(no_audio_available,clear_debug_audio(After))
    end.
history_scores(#{consistency:=C})->
    maps:with([candidate_score,threshold,profile_min_score],C);
history_scores(#{speaker_score:=Score,thresholds:=#{speaker_threshold:=T}})->
    #{speaker_score=>Score,threshold=>T};
history_scores(_)->#{}.
capture_failed(Why,S)->
    safe_cancel(S),
    Id=maps:get(id,S#st.active),
    Detail=(maps:with([id,kind,expected],S#st.active))#{reason=>error_summary(Why),outcome=>capture_failed},
    trace(capture_failed,Detail,touch_draft(clear_debug_audio(S#st{phase=idle,active=undefined,
        playback=failed,playback_error=no_audio_captured,
        last=Detail#{check=>#{accepted=>false,reason=>Why}},
        diagnostics=#{id=>Id,outcome=>capture_failed,reason=>error_summary(Why),
            audio_available=>false,stages=>[],scores=>[],references=>[],envelope=>[],mfcc=>[],
            summary=><<"No completed speech segment was captured; there is no audio to replay.">>}}))).
playback_status(S)->
    Base=#{autoplay=>S#st.autoplay,phase=>S#st.playback,available=>is_binary(S#st.last_synthesis),
        source=>lossy_lpc_resynthesis},
    case S#st.playback_error of undefined->Base;Why->Base#{error=>Why} end.
clear_debug_audio(S)->S#st{last_synthesis=undefined,last_wav=undefined}.
start_debug_playback(S)->
    %% Cancellation closes the lease gate before any output starts. A second
    %% cancellation after completion/stop starts the echo guard AFTER playback.
    case erm_phrase_voice:lab_cancel(S#st.ref) of
        ok->
            flush_capture_messages(S#st.ref),
            Ready=S#st{playback_error=undefined},
            case Ready#st.last_wav of
                Wav when is_binary(Wav)->start_debug_player(Wav,Ready);
                _->
                    Model=Ready#st.last_synthesis,Options=Ready#st.opts,
                    Profile=erm_phrase_lab_native:profile(Ready#st.snapshot),
                    Job=fun()->erm_phrase_lab_native:render(Options,Model,Profile,
                        #{speed=>1.0,pitch=>1.0,noise=>0.15,acoustic=>false}) end,
                    debug_task(render,Job,trace(render_started,#{},Ready#st{playback=rendering}))
            end;
        Error->playback_failed({capture_gate,Error},S)
    end.
start_debug_player(Wav,S)->
    Options=S#st.opts,
    playback_event(speaking),
    debug_task(play,fun()->erm_phrase_lab_native:play(Options,Wav) end,
        trace(playback_started,#{},S#st{playback=playing,last_wav=Wav})).
debug_task(Kind,F,S)->
    Parent=self(),Tag=make_ref(),
    {Pid,Mon}=spawn_opt(fun()->
        Result=try F() catch C:R->{error,{C,R}} end,
        Parent!{voice_playback,Tag,Result}
    end,[link,monitor]),
    S#st{playback_job=#{pid=>Pid,monitor=>Mon,tag=>Tag,kind=>Kind}}.
debug_playback_result(render,{ok,#{wav:=Wav,ms:=Ms}},S)->
    start_debug_player(Wav,trace(render_completed,#{audio_ms=>Ms},S));
debug_playback_result(play,ok,S)->
    safe_cancel(S),
    playback_event(idle),
    trace(playback_completed,#{},touch_draft(S#st{playback=idle,playback_error=undefined}));
debug_playback_result(_,Error,S)->playback_failed(Error,S).
playback_failed(Why,S)->
    safe_cancel(S),
    playback_event(idle),
    Reason=error_summary(Why),
    trace(playback_failed,#{reason=>Reason},touch_draft(S#st{playback=failed,playback_error=Reason})).
stop_debug_playback(Reason,S=#st{playback_job=#{pid:=Pid,monitor:=Mon}})->
    exit(Pid,kill),
    %% Worker death closes its port; the native port kills its player child.
    receive {'DOWN',Mon,process,Pid,_}->ok after 1000->ok end,
    erlang:demonitor(Mon,[flush]),
    safe_cancel(S),
    playback_event(idle),
    trace(playback_stopped,#{reason=>Reason},touch_draft(S#st{playback_job=undefined,
        playback=stopped,playback_error=undefined}));
stop_debug_playback(_,S)->S.
playback_event(Phase)->
    try erm_voice_events:publish(?MODULE,output,#{phase=>Phase,source=>lossy_lpc_resynthesis})
    catch error:undef->ok end.
trace(Event,Detail,S)->
    %% All details are small diagnostics. Never include raw vectors, LPC/WAV,
    %% corpus samples, model paths or arbitrary exception terms in this stream.
    Allowed=maps:map(fun(_,V)->trace_value(V) end,
        maps:with([id,kind,expected,outcome,reason,audio_ms,accepted,enabled,
            speaker_score,candidate_score,threshold,profile_min_score],Detail)),
    Text=unicode:characters_to_binary(lists:sublist(lists:flatten(io_lib:format("~0tp",[Allowed])),320)),
    Seq=S#st.trace_seq+1,
    Entry=#{seq=>Seq,ms=>max(0,now_ms()-S#st.trace_start),event=>Event,detail=>Text},
    S#st{trace_seq=Seq,trace=lists:sublist([Entry|S#st.trace],100)}.
trace_value(V) when is_atom(V);is_number(V)->V;
trace_value(V) when is_binary(V),byte_size(V)=<256->V;
trace_value(V)->error_summary(V).
error_summary(Why) when is_atom(Why)->Why;
error_summary({error,Why})->error_summary(Why);
error_summary({native,Why}) when is_binary(Why),byte_size(Why)=<256->Why;
error_summary({Class,Why}) when is_atom(Class),is_atom(Why)->{Class,Why};
error_summary(_)->playback_operation_failed.
now_ms()->erlang:monotonic_time(millisecond).
