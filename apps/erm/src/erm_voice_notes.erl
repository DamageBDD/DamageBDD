%% Button-controlled original-audio notebook. No command dispatch, wake gate,
%% existing speaker approval or automatic pseudo-label learning in this app.
-module(erm_voice_notes).
-behaviour(gen_server).
-export([start/0,start/1,start_link/1,show/0,stop/0,status/0,notes/0,note/1,
    toggle/0,record/0,stop_recording/0,play/1,stop_playback/0,configure/1,
    review/4,analyze/1,transcribe/1,rebuild_model/0,evaluate_test/0,export_dataset/0]).
-export([init/1,handle_call/3,handle_cast/2,handle_info/2,terminate/2,code_change/3]).
start()->start(#{}).
start(O)->
    case whereis(?MODULE) of
        undefined->case gen_server:start({local,?MODULE},?MODULE,O,[]) of
            {ok,_}->show();E->E end;
        _->show()
    end.
start_link(O)->gen_server:start_link({local,?MODULE},?MODULE,O,[]).
show()->erm_voice_notes_ui:show().
stop()->case whereis(?MODULE) of undefined->ok;_->call(stop) end.
status()->call(status).
notes()->call(notes).
note(Id)->call({note,Id}).
toggle()->call(toggle).
record()->call(record).
stop_recording()->call(stop_recording).
play(Id)->call({play,Id}).
stop_playback()->call(stop_playback).
configure(O)->call({configure,O}).
review(Id,Speaker,Split,Text)->call({review,Id,Speaker,Split,Text}).
analyze(Id)->call({job,Id,analysis}).
transcribe(Id)->call({job,Id,transcription}).
rebuild_model()->call(rebuild_model).
evaluate_test()->call(evaluate_test).
export_dataset()->call(export_dataset).
call(Q)->gen_server:call(?MODULE,Q,15000).
init(Input)->
    process_flag(trap_exit,true),process_flag(sensitive,true),
    try
        Env=as_map(application:get_env(erm,voice_notes,#{})),
        O=maps:merge(#{directory=>filename:basedir(user_data,"erm/voice-notes"),
            input_device=>"/dev/snd/pcmC0D0c",output_device=>"/dev/snd/pcmC0D0p",
            audio_binary=>default_audio(),max_recording_ms=>300000,
            whisper_cli=>erm_voice_notes_analysis:default_cli(),whisper_model=>configured_model(),
            language=>"auto",transcription_timeout_ms=>120000},maps:merge(Env,as_map(Input))),
        true=is_integer(maps:get(max_recording_ms,O)),
        true=maps:get(max_recording_ms,O)>=1000 andalso maps:get(max_recording_ms,O)=<600000,
        Timeout=maps:get(transcription_timeout_ms,O),true=is_integer(Timeout) andalso Timeout>0 andalso Timeout=<600000,
        %% Safe metadata decoding must know the frontend's fixed atom vocabulary
        %% on a fresh VM too, before any new recording triggers feature loading.
        [{module,M}=code:ensure_loaded(M) ||M<-[ecai_voice_features,ecai_voice_wav,erm_voice_notes_model]],
        {ok,Root}=erm_voice_notes_store:open(maps:get(directory,O)),
        {ok,Notes}=erm_voice_notes_store:list(Root),
        %% Rebuild from the authoritative reviewed notes; an interrupted prior
        %% update cannot resurrect labels that have since been excluded.
        Model=case erm_voice_notes_model:build(Notes) of {ok,M}->M;_->undefined end,
        self()!resume_pending,
        {ok,#{opts=>O,root=>Root,notes=>Notes,phase=>idle,capture=>undefined,playback=>undefined,
            jobs=>#{},model=>Model,last=><<"Ready. Record a note; review its speaker label to train.">>,
            meter=>0.0,recorded_ms=>0,quit=>undefined,stop_timer=>undefined}}
    catch C:R->{stop,{voice_notes_start,C,R}} end.
handle_call(status,_,S)->{reply,present(S),S};
handle_call(notes,_,S)->{reply,maps:get(notes,S),S};
handle_call({note,Id},_,S)->
    Reply=case lookup(Id,S) of
        {ok,N}->M=maps:get(model,S),
            Score=case is_map(M) of true->erm_voice_notes_model:score(N,M);
                false->#{status=>unavailable,reason=>review_notes_to_build_speaker_model} end,
            {ok,N#{recognition=>Score}};
        E->E end,
    {reply,Reply,S};
handle_call(toggle,From,S)->case maps:get(phase,S) of
    idle->handle_call(record,From,S);
    recording->handle_call(stop_recording,From,S);
    _->{reply,{error,audio_busy},S} end;
handle_call(record,_,S=#{phase:=idle})->start_recording(S);
handle_call(record,_,S)->{reply,{error,audio_busy},S};
handle_call(stop_recording,_,S=#{phase:=recording,capture:=#{port:=P}})->
    port_command(P,<<"S">>),T=erlang:send_after(2000,self(),capture_stop_timeout),
    {reply,ok,S#{phase:=stopping,stop_timer:=T}};
handle_call(stop_recording,_,S)->{reply,{error,not_recording},S};
handle_call({play,Id},_,S=#{phase:=idle})->start_playback(Id,S);
handle_call({play,_},_,S)->{reply,{error,audio_busy},S};
handle_call(stop_playback,_,S)->{reply,ok,end_playback(S)};
handle_call({configure,Input},_,S=#{phase:=idle})->
    try
        O=as_map(Input),true=(maps:keys(O)--[input_device,output_device,whisper_cli,whisper_model])=:=[],
        true=lists:all(fun(V)->valid_text(V,4096) end,maps:values(O)),
        Options=maps:merge(maps:get(opts,S),maps:map(fun(_,V)->unicode:characters_to_list(V) end,O)),
        {reply,ok,S#{opts:=Options}}
    catch _:_->{reply,{error,invalid_settings},S} end;
handle_call({configure,_},_,S)->{reply,{error,audio_busy},S};
handle_call({review,Id,L,Split,Text},_,S)->
    case lookup(Id,S) of
        {ok,N}->
            case valid_text(L,128) andalso valid_text(Text,65536) andalso lists:member(Split,[exclude,train,validation,test]) of
                true->
                    Speaker=string:trim(unicode:characters_to_binary(L)),
                    case Split=:=exclude orelse Speaker=/= <<>> of
                        true->
                            New=N#{speaker=>Speaker,split=>Split,corrected_transcript=>unicode:characters_to_binary(Text),
                                reviewed_ms=>erlang:system_time(millisecond)},
                            case persist(New,S) of
                                {ok,S1}->{_,S2}=build_model(S1),{reply,ok,S2};
                                E->{reply,E,S}
                            end;
                        false->{reply,{error,enter_a_speaker_label},S}
                    end;
                false->{reply,{error,invalid_review},S}
            end;
        E->{reply,E,S}
    end;
handle_call({job,Id,Kind},_,S)->
    case launch_job(Id,Kind,S) of {ok,S1}->{reply,ok,S1};E->{reply,E,S} end;
handle_call(rebuild_model,_,S)->{R,S1}=build_model(S),{reply,R,S1};
handle_call(evaluate_test,_,S=#{model:=M}) when is_map(M)->
    R=erm_voice_notes_model:evaluate(maps:get(notes,S),M),
    {reply,R,S#{last:=R}};
handle_call(evaluate_test,_,S)->{reply,{error,no_speaker_model},S};
handle_call(export_dataset,_,S)->
    %% Native ecai_voice dataset format. Corrected text stays in the accompanying
    %% manifest for later transcription/phrase experiments; test labels remain test.
    try
    {ok,Dir}=erm_voice_notes_store:open(filename:join(maps:get(root,S),"dataset")),
    Selected=[N||N<-maps:get(notes,S),maps:get(split,N,exclude)=/=exclude],
    Rows=[begin
        Path0=filename:join(Dir,binary_to_list(maps:get(id,N))++".wav"),
        {ok,PCM}=erm_voice_notes_store:pcm(maps:get(root,S),maps:get(id,N),0,min(30000,maps:get(duration_ms,N))),
        ok=erm_voice_notes_store:write_audio(Path0,PCM),
        #{speaker=>case maps:get(speaker,N) of <<"unknown">>->unknown;L->L end,
        split=>case maps:get(split,N) of train->enroll;validation->calibrate;test->test end,
        source=>{wav,Path0}}
        end ||N<-Selected],
    Path=filename:join(maps:get(root,S),"reviewed-dataset.term"),
    Manifest=filename:join(maps:get(root,S),"reviewed-notes-manifest.term"),
    ok=erm_voice_notes_store:write_term(Manifest,[
        (maps:with([id,pcm_sha256,speaker,split,transcript,corrected_transcript,duration_ms],N))#{
            exported_audio_offset_ms=>0,exported_audio_duration_ms=>min(30000,maps:get(duration_ms,N)),
            transcript_scope=>full_original_note} ||N<-Selected]),
    Result=erm_voice_notes_store:write_term(Path,Rows),
    {reply,case Result of ok->{ok,Path};E->E end,S}
    catch C:R->{reply,{error,{dataset_export,C,R}},S} end;
handle_call(stop,From,S=#{capture:=C}) when is_map(C)->
    case maps:get(phase,S) of
        recording->port_command(maps:get(port,C),<<"S">>);
        _->ok end,
    T=erlang:send_after(2000,self(),capture_stop_timeout),
    {noreply,S#{quit:=From,phase:=stopping,stop_timer:=T}};
handle_call(stop,_,S)->{stop,normal,ok,S};
handle_call(_,_,S)->{reply,{error,unsupported_request},S}.
handle_cast(_,S)->{noreply,S}.
handle_info(resume_pending,S)->{noreply,schedule_pending(S)};
handle_info({P,{data,<<"A",PCM/binary>>}},S=#{capture:=#{port:=P,fd:=F,bytes:=Bytes}=C})
    when byte_size(PCM)>0,byte_size(PCM)=<8192,byte_size(PCM) rem 2=:=0 ->
    Limit=maps:get(max_recording_ms,maps:get(opts,S))*32,
    case Bytes+byte_size(PCM)=<Limit of
        true->case file:write(F,PCM) of
            ok->{noreply,S#{capture:=C#{bytes:=Bytes+byte_size(PCM)},
                meter:=meter(PCM),recorded_ms:=(Bytes+byte_size(PCM)) div 32}};
            E->complete_capture({storage_error,E},S)
        end;
        false->complete_capture(audio_limit_exceeded,S)
    end;
handle_info({P,{data,<<"H",Rate:32,Channels:8>>}},S=#{capture:=#{port:=P}=C})->
    {noreply,S#{capture:=C#{native_format=>#{sample_rate=>Rate,channels=>Channels}},
        last=><<"Recording original audio. Space or Stop finishes the note.">>}};
handle_info({P,{data,<<"D",Reason:8>>}},S=#{capture:=#{port:=P}})->complete_capture({completed,Reason},S);
handle_info({P,{data,<<"E",Error/binary>>}},S=#{capture:=#{port:=P}})->complete_capture({audio_error,Error},S);
handle_info({P,{exit_status,Code}},S=#{capture:=#{port:=P}})->complete_capture({worker_exit,Code},S);
handle_info({'EXIT',P,R},S=#{capture:=#{port:=P}})->complete_capture({worker_exit,R},S);
handle_info({P,{data,<<"E",Error/binary>>}},S=#{playback:=P})->
    {noreply,(end_playback(S))#{last:={playback_error,Error}}};
handle_info({P,{data,<<"D",_/binary>>}},S=#{playback:=P})->{noreply,end_playback(S)};
handle_info({P,{exit_status,Code}},S=#{playback:=P})->
    {noreply,(end_playback(S))#{last:={playback_exit,Code}}};
handle_info({'EXIT',P,R},S=#{playback:=P})->
    {noreply,(end_playback(S))#{last:={playback_exit,R}}};
handle_info(capture_stop_timeout,S=#{capture:=C}) when is_map(C)->complete_capture(stop_timeout,S);
handle_info(capture_stop_timeout,S)->{noreply,S};
handle_info({job_result,Ref,Delta},S)->
    case maps:take(Ref,maps:get(jobs,S)) of
        {#{id:=Id,kind:=Kind,monitor:=Mon},Jobs}->
            erlang:demonitor(Mon,[flush]),S0=S#{jobs:=Jobs},
            case lookup(Id,S0) of
                {ok,N}->
                    New=case Kind of
                        analysis->N#{analysis=>Delta};
                        transcription->case Delta of
                            #{status:=ready,text:=Text}->N#{transcription=>maps:remove(text,Delta),transcript=>Text};
                            _->N#{transcription=>Delta} end
                    end,
                    case persist(New,S0) of
                        {ok,S1}->
                            {_,S2}=build_model(S1),
                            S3=case Kind of
                                analysis->case launch_job(Id,transcription,S2) of {ok,X}->X;_->S2 end;
                                _->S2 end,
                            {noreply,schedule_pending(S3#{last:={Kind,Id,maps:get(status,Delta,failed)}})};
                        E->{noreply,S0#{last:={save_analysis_failed,E}}}
                    end;
                _->{noreply,S0}
            end;
        error->{noreply,S}
    end;
handle_info({'DOWN',Mon,process,_,Reason},S)->
    Lost=[{Ref,J}||{Ref,J=#{monitor:=M}}<-maps:to_list(maps:get(jobs,S)),M=:=Mon],
    case Lost of
        [{Ref,#{id:=Id,kind:=Kind}}]->
            self()!{job_result,Ref,#{status=>failed,reason=>{worker_failed,Reason}}},
            {noreply,S#{last:={job_failed,Id,Kind}}};
        []->{noreply,S}
    end;
handle_info(_,S)->{noreply,S}.
terminate(_,S)->
    close_port(maps:get(playback,S,undefined)),
    case maps:get(capture,S,undefined) of
        #{port:=P,fd:=F,note:=N}->
            close_port(P),_=erm_voice_notes_store:finish(maps:get(root,S),N,F,#{ended_by=>app_shutdown});
        _->ok end,
    [exit(maps:get(pid,J),kill)||J<-maps:values(maps:get(jobs,S,#{}))],
    case whereis(erm_voice_notes_ui) of undefined->ok;UI->UI!voice_notes_closed end,ok.
code_change(_,S,_)->{ok,S}.

start_recording(S)->
    O=maps:get(opts,S),Device=maps:get(input_device,O),
    case erm_voice_notes_store:begin_note(maps:get(root,S),Device) of
        {ok,N,F}->
            try
                Mode=case maps:is_key(test_pcm,O) of true->"capture-file";false->"capture" end,
                Source=maps:get(test_pcm,O,Device),
                P=audio_port(O,[Mode,Source,integer_to_list(maps:get(max_recording_ms,O))]),
                {reply,ok,S#{capture:=#{port=>P,fd=>F,note=>N,bytes=>0},phase:=recording,
                    recorded_ms:=0,meter:=0.0,last=><<"Opening microphone...">>}}
            catch C:R->file:close(F),erm_voice_notes_store:abort(maps:get(root,S),N),
                {reply,{error,{audio_start,C,R}},S#{last:={audio_start_failed,R}}} end;
        E->{reply,E,S}
    end.
complete_capture(Ended,S=#{capture:=#{port:=P,fd:=F,note:=N,bytes:=Bytes}=C})->
    close_port(P),cancel_timer(maps:get(stop_timer,S)),
    Extra=#{ended_by=>Ended,native_format=>maps:get(native_format,C,undefined)},
    Result=erm_voice_notes_store:finish(maps:get(root,S),N,F,Extra),
    Idle=S#{capture:=undefined,phase:=idle,stop_timer:=undefined,meter:=0.0},
    S0=case maps:get(model_dirty,Idle,false) of true->element(2,build_model(Idle));false->Idle end,
    S1=case Result of
        {ok,Note}->
            New=replace_note(Note,S0),
            case launch_job(maps:get(id,Note),analysis,New) of {ok,X}->X;_->New end;
        E->S0#{last:={recording_failed,Ended,E,Bytes}}
    end,
    case maps:get(quit,S) of
        undefined->{noreply,case Result of {ok,_}->S1#{last:={note_saved,maps:get(id,N),Ended}};_->S1 end};
        From->gen_server:reply(From,ok),{stop,normal,S1}
    end.
start_playback(Id,S)->
    case lookup(Id,S) of
        {ok,_}->
            O=maps:get(opts,S),Mode=case maps:get(test_playback,O,false) of true->"check-wav";false->"play" end,
            try P=audio_port(O,[Mode,erm_voice_notes_store:wav_path(maps:get(root,S),Id),maps:get(output_device,O)]),
                {reply,ok,S#{playback:=P,phase:=playing,last:={playing_original_note,Id}}}
            catch C:R->{reply,{error,{playback_start,C,R}},S} end;
        E->{reply,E,S}
    end.
end_playback(S=#{playback:=undefined})->S;
end_playback(S)->
    close_port(maps:get(playback,S)),Idle=S#{playback:=undefined,phase:=idle},
    case maps:get(model_dirty,Idle,false) of true->element(2,build_model(Idle));false->Idle end.
audio_port(O,Args)->
    Bin=filename:absname(maps:get(audio_binary,O)),
    open_port({spawn_executable,Bin},[binary,exit_status,{packet,4},use_stdio,{args,Args}]).
launch_job(Id,Kind,S) when Kind=:=analysis;Kind=:=transcription ->
    Jobs=maps:get(jobs,S),Busy=lists:any(fun(J)->maps:get(id,J)=:=Id end,maps:values(Jobs)),
    case {Busy orelse map_size(Jobs)>=2,lookup(Id,S)} of
        {true,_}->{error,note_processing};
        {false,{ok,N}}->
            Parent=self(),Ref=make_ref(),Root=maps:get(root,S),O=maps:get(opts,S),
            {Pid,Mon}=spawn_monitor(fun()->
                R=case Kind of analysis->erm_voice_notes_analysis:analyze(Root,N);
                    transcription->erm_voice_notes_analysis:transcribe(Root,N,O) end,
                Parent!{job_result,Ref,R}
            end),
            {ok,S#{jobs:=Jobs#{Ref=>#{id=>Id,kind=>Kind,pid=>Pid,monitor=>Mon}}}};
        {_,E}->E
    end;
launch_job(_,_,_)->{error,invalid_job}.
schedule_pending(S)->
    Pending=[{maps:get(id,N),case maps:get(status,maps:get(analysis,N),pending) of
        pending->analysis;_->transcription end} ||N<-maps:get(notes,S),
        maps:get(status,maps:get(analysis,N),pending)=:=pending orelse
        maps:get(status,maps:get(transcription,N),pending)=:=pending],
    lists:foldl(fun({Id,Kind},Acc)->case launch_job(Id,Kind,Acc) of {ok,Next}->Next;_->Acc end end,S,Pending).
build_model(S=#{phase:=Phase}) when Phase=/=idle ->
    {{ok,deferred_until_audio_stops},S#{model:=undefined,model_dirty=>true}};
build_model(S)->
    case erm_voice_notes_model:build(maps:get(notes,S)) of
        {ok,M}->
            case erm_voice_notes_store:write_term(filename:join(maps:get(root,S),"speaker-model.term"),M) of
                ok->{{ok,public_model(M)},S#{model:=M,model_dirty=>false}};
                E->{E,S#{last:={model_save_failed,E}}}
            end;
        E->
            %% Remove a superseded model too: excluded/relabelled examples must
            %% not silently return to recognition after a process restart.
            _=file:delete(filename:join(maps:get(root,S),"speaker-model.term")),
            {E,S#{model:=undefined,model_dirty=>false}}
    end.
persist(N,S)->case erm_voice_notes_store:save(maps:get(root,S),N) of ok->{ok,replace_note(N,S)};E->E end.
replace_note(N,S)->
    Notes=[N|[X||X<-maps:get(notes,S),maps:get(id,X)=/=maps:get(id,N)]],
    S#{notes:=lists:sort(fun(A,B)->maps:get(id,A)>maps:get(id,B) end,Notes)}.
lookup(Id,S)->case [N||N<-maps:get(notes,S),maps:get(id,N)=:=Id] of [N]->{ok,N};_->{error,note_not_found} end.
present(S)->
    M=maps:get(model,S),
    Rows=maps:get(notes,S),
    #{phase=>maps:get(phase,S),recorded_ms=>maps:get(recorded_ms,S),meter=>maps:get(meter,S),
        notes=>Rows,last=>maps:get(last,S),directory=>maps:get(root,S),
        jobs=>[maps:with([id,kind],J)||J<-maps:values(maps:get(jobs,S))],
        settings=>maps:with([input_device,output_device,whisper_cli,whisper_model],maps:get(opts,S)),
        transcription=>erm_voice_notes_analysis:transcription_config(maps:get(opts,S)),
        model=>case is_map(M) of true->public_model(M);false->undefined end}.
public_model(M)->maps:without([templates,development_hashes],M).
meter(B)->N=byte_size(B) div 2,
    math:sqrt(lists:sum([X*X||<<X:16/little-signed>><=B])/max(1,N))/32768.
valid_text(V,Max)->try unicode:characters_to_binary(V) of B when is_binary(B)->byte_size(B)=<Max;_->false catch _:_ ->false end.
as_map(M) when is_map(M)->M;
as_map(L) when is_list(L)->maps:from_list(L).
close_port(undefined)->ok;
close_port(P)->try port_close(P) catch _:_ ->ok end.
cancel_timer(undefined)->ok;
cancel_timer(T)->erlang:cancel_timer(T).
default_audio()->case code:priv_dir(erm) of {error,_}->filename:absname("apps/erm/priv/bin/erm_voice_notes_audio");
    P->filename:join([P,"bin","erm_voice_notes_audio"]) end.
configured_model()->
    try W=as_map(application:get_env(erm,whisper_trigger,[])),N=as_map(maps:get(native,W,#{})),
        maps:get(whisper_model,N,"") catch _:_ ->"" end.
