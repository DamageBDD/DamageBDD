%% Small native gtkgs notebook. Capture and analysis live outside this UI owner.
-module(erm_voice_notes_ui).
-behaviour(gen_server).
-export([show/0,start_link/0,stop/0]).
-export([init/1,handle_call/3,handle_cast/2,handle_info/2,terminate/2,code_change/3]).
show()->case whereis(?MODULE) of
    undefined->gen_server:start({local,?MODULE},?MODULE,[],[]);
    P->gen_server:call(P,show)
end.
start_link()->gen_server:start_link({local,?MODULE},?MODULE,[],[]).
stop()->gen_server:stop(?MODULE).
init([])->
    process_flag(sensitive,true),
    try
        case whereis(gtknode4) of undefined->{ok,_}=erm_sup:start_gtknode4();_->ok end,
        ok=gtknode4:await_ready(15000),_=gtkgs:start(),
        Snapshot=erm_voice_notes:status(),O=maps:get(settings,Snapshot),
        _=gtkgs:set_stylesheet(erm_voice_notes_style,css()),
        Window=gtkgs:create(window,erm_voice_notes_window,gtkgs:server(),[
            {title,"erm · Voice notes"},{width,1020},{height,800},{class,"erm_voice_notes_window"},
            {wm_class,"erm_voice_notes"},{wm_instance,"erm_voice_notes"}]),
        Root=gtkgs:create(frame,Window,[{orient,vertical},{spacing,8},{margin,14},{expand,true}]),
        label(Root,erm_voice_notes_heading,"VOICE NOTES · ECAI"),
        label(Root,erm_voice_notes_hint,"Space starts/stops recording · Escape saves the current take and quits · Space types normally in text fields"),
        Inputs=row(Root),
        label(Inputs,erm_voice_notes_in_label,"Microphone"),
        entry(Inputs,erm_voice_notes_input,maps:get(input_device,O)),
        label(Inputs,erm_voice_notes_out_label,"Playback"),
        entry(Inputs,erm_voice_notes_output,maps:get(output_device,O)),
        STT=row(Root),label(STT,erm_voice_notes_stt_label,"Local transcription"),
        entry(STT,erm_voice_notes_cli,maps:get(whisper_cli,O)),
        entry(STT,erm_voice_notes_model,maps:get(whisper_model,O)),
        button(STT,erm_voice_notes_settings,"Apply settings"),
        Controls=row(Root),button(Controls,erm_voice_notes_record,"● Record · Space"),
        button(Controls,erm_voice_notes_play,"Play selected"),button(Controls,erm_voice_notes_stop,"Stop playback"),
        button(Controls,erm_voice_notes_transcribe,"Transcribe"),button(Controls,erm_voice_notes_analyze,"Re-score"),
        label(Root,erm_voice_notes_live,"Ready"),
        Body=gtkgs:create(frame,Root,[{orient,horizontal},{spacing,16},{expand,true}]),
        Left=gtkgs:create(frame,Body,[{orient,vertical},{spacing,6},{width,330},{expand,true}]),
        label(Left,erm_voice_notes_list_heading,"SAVED RECORDINGS"),
        gtkgs:create(listbox,erm_voice_notes_list,Left,[{items,[]},{expand,true},{min_height,210}]),
        label(Left,erm_voice_notes_storage,maps:get(directory,Snapshot)),
        RightColumn=gtkgs:create(frame,Body,[{orient,vertical},{spacing,8},{expand,true}]),
        Right=gtkgs:create(scrolled,RightColumn,[{orient,vertical},{spacing,8},{expand,true}]),
        label(Right,erm_voice_notes_details,"Select a note or make your first recording."),
        label(Right,erm_voice_notes_score,"Speaker scoring starts after reviewed training notes are available."),
        label(Right,erm_voice_notes_transcript_heading,"TRANSCRIPTION"),
        label(Right,erm_voice_notes_transcript,"No note selected."),
        label(RightColumn,erm_voice_notes_correction_hint,"Corrected text / reference transcript"),
        entry(RightColumn,erm_voice_notes_correction,<<>>),
        Review=row(RightColumn),label(Review,erm_voice_notes_speaker_hint,"Speaker"),
        entry(Review,erm_voice_notes_speaker,<<>>),
        label(RightColumn,erm_voice_notes_split_hint,"Dataset role — use ‘unknown’ for other-speaker validation/test samples"),
        Roles=row(RightColumn),
        [button(Roles,Name,case Role of exclude->"● Exclude";_->Title end)
            ||{Role,Name,Title}<-role_buttons()],
        button(RightColumn,erm_voice_notes_save,"Save reviewed text and speaker label"),
        ModelActions=row(RightColumn),button(ModelActions,erm_voice_notes_rebuild,"Update speaker model"),
        button(ModelActions,erm_voice_notes_test,"Evaluate held-out test"),
        button(ModelActions,erm_voice_notes_export,"Export dataset"),
        label(RightColumn,erm_voice_notes_model_status,"No speaker model yet."),
        label(Root,erm_voice_notes_result,"Original audio is saved locally. Only reviewed labels enter training."),
        ok=gtkgs:config(Window,{map,true}),
        _=gtkgs:config(erm_voice_notes_record,{focus,true}),
        self()!poll,
        {ok,#{window=>Window,notes=>[],selected=>undefined,role=>exclude,detail_key=>undefined,editor_source=><<>>,
            timer=>undefined,last_live=>undefined,last_result=>undefined}}
    catch C:R:Stack->{stop,{voice_notes_ui,C,R,Stack}} end.
handle_call(show,_,S)->{reply,gtkgs:config(maps:get(window,S),{map,true}),S};
handle_call(_,_,S)->{reply,{error,unsupported_request},S}.
handle_cast(_,S)->{noreply,S}.
handle_info(poll,S)->
    try erm_voice_notes:status() of
        Snapshot->S1=render(Snapshot,S),T=erlang:send_after(250,self(),poll),{noreply,S1#{timer:=T}}
    catch exit:_-> {stop,normal,S} end;
handle_info({gtkgs,erm_voice_notes_window,keypress,_,[escape|_]},S)->quit(S);
handle_info({gtkgs,erm_voice_notes_window,keypress,_,[space|_]},S)->toggle(S);
handle_info({gtkgs,erm_voice_notes_window,destroy,_,_},S)->quit(S);
handle_info({gtkgs,erm_voice_notes_record,click,_,_},S)->toggle(S);
handle_info({gtkgs,erm_voice_notes_settings,click,_,_},S)->result(settings(),S);
handle_info({gtkgs,erm_voice_notes_play,click,_,_},S)->selected_action(fun erm_voice_notes:play/1,S);
handle_info({gtkgs,erm_voice_notes_stop,click,_,_},S)->result(erm_voice_notes:stop_playback(),S);
handle_info({gtkgs,erm_voice_notes_transcribe,click,_,_},S)->selected_action(fun erm_voice_notes:transcribe/1,S);
handle_info({gtkgs,erm_voice_notes_analyze,click,_,_},S)->selected_action(fun erm_voice_notes:analyze/1,S);
handle_info({gtkgs,erm_voice_notes_save,click,_,_},S)->
    selected_action(fun(Id)->erm_voice_notes:review(Id,text(erm_voice_notes_speaker),
        maps:get(role,S),text(erm_voice_notes_correction)) end,S);
handle_info({gtkgs,erm_voice_notes_role_exclude,click,_,_},S)->{noreply,set_role(exclude,S)};
handle_info({gtkgs,erm_voice_notes_role_train,click,_,_},S)->{noreply,set_role(train,S)};
handle_info({gtkgs,erm_voice_notes_role_validation,click,_,_},S)->{noreply,set_role(validation,S)};
handle_info({gtkgs,erm_voice_notes_role_test,click,_,_},S)->{noreply,set_role(test,S)};
handle_info({gtkgs,erm_voice_notes_rebuild,click,_,_},S)->result(erm_voice_notes:rebuild_model(),S);
handle_info({gtkgs,erm_voice_notes_test,click,_,_},S)->result(erm_voice_notes:evaluate_test(),S);
handle_info({gtkgs,erm_voice_notes_export,click,_,_},S)->result(erm_voice_notes:export_dataset(),S);
handle_info({gtkgs,erm_voice_notes_list,select,_,[I|_]},S)->
    case I>=0 andalso I<length(maps:get(notes,S)) of
        true->N=lists:nth(I+1,maps:get(notes,S)),
            {noreply,S#{selected:=maps:get(id,N),detail_key:=undefined}};
        false->{noreply,S}
    end;
handle_info(voice_notes_closed,S)->{stop,normal,S};
handle_info(_,S)->{noreply,S}.
terminate(_,S)->
    case maps:get(timer,S,undefined) of undefined->ok;T->erlang:cancel_timer(T) end,
    try gtkgs:destroy(maps:get(window,S)) catch _:_ ->ok end,
    try gtkgs:remove_stylesheet(erm_voice_notes_style) catch _:_ ->ok end,ok.
code_change(_,S,_)->{ok,S}.
quit(S)->_=erm_voice_notes:stop(),{stop,normal,S}.
toggle(S)->
    case maps:get(phase,erm_voice_notes:status()) of
        idle->case settings() of ok->result(erm_voice_notes:toggle(),S);E->result(E,S) end;
        _->result(erm_voice_notes:toggle(),S)
    end.
settings()->erm_voice_notes:configure(#{input_device=>text(erm_voice_notes_input),
    output_device=>text(erm_voice_notes_output),whisper_cli=>text(erm_voice_notes_cli),
    whisper_model=>text(erm_voice_notes_model)}).
selected_action(F,S)->case maps:get(selected,S) of
    undefined->result({error,select_a_note},S);
    Id->result(F(Id),S)
end.
result(R,S)->_=gtkgs:config(erm_voice_notes_result,{label,fmt(R)}),{noreply,S#{last_result:=R}}.
render(Snap,S)->
    Notes=maps:get(notes,Snap),Ids=[maps:get(id,N)||N<-Notes],
    OldIds=[maps:get(id,N)||N<-maps:get(notes,S)],
    Selected=case maps:get(selected,S) of undefined->case Ids of [Id|_]->Id;[]->undefined end;Id->Id end,
    %% Preserve the selected identity and edit buffers while jobs complete.
    Labels=[note_label(N)||N<-Notes],OldLabels=[note_label(N)||N<-maps:get(notes,S)],
    case Ids=/=OldIds orelse Labels=/=OldLabels of
        true->gtkgs:config(erm_voice_notes_list,[{items,Labels},{selected_index,index(Selected,Ids,0)}]);
        false->ok
    end,
    Phase=maps:get(phase,Snap),Ms=maps:get(recorded_ms,Snap),Meter=maps:get(meter,Snap),
    Live=unicode:characters_to_binary(io_lib:format("~p · ~.1f s   ~ts   ~B background job(s)",
        [Phase,Ms/1000,bar(Meter),length(maps:get(jobs,Snap))])),
    case Live=:=maps:get(last_live,S) of true->ok;false->gtkgs:config(erm_voice_notes_live,{label,Live}) end,
    gtkgs:config(erm_voice_notes_record,[{label,case Phase of recording->"■ Stop · Space";stopping->"Saving…";_->"● Record · Space" end},
        {enable,Phase=:=idle orelse Phase=:=recording}]),
    Has=Selected=/=undefined,
    gtkgs:config(erm_voice_notes_play,{enable,Has andalso Phase=:=idle}),
    gtkgs:config(erm_voice_notes_stop,{enable,Phase=:=playing}),
    gtkgs:config(erm_voice_notes_transcribe,{enable,Has}),
    gtkgs:config(erm_voice_notes_analyze,{enable,Has}),
    gtkgs:config(erm_voice_notes_save,{enable,Has}),
    Existing=[N||N<-Notes,maps:get(id,N)=:=Selected],
    Model=maps:get(model,Snap),
    DetailKey={Existing,Model,maps:get(jobs,Snap)},
    S1=S#{notes:=Notes,selected:=Selected,last_live:=Live},
    S2=case DetailKey=:=maps:get(detail_key,S) of
        true->S1;
        false->case Existing of
            [N]->
                {ok,Scored}=erm_voice_notes:note(Selected),
                detail(Scored,Snap),
                %% Never overwrite typing when an asynchronous score/transcript arrives.
                SelectionChanged=Selected=/=maps:get(selected,S),
                Previous=maps:get(editor_source,S,<<>>),Current=text(erm_voice_notes_correction),
                case SelectionChanged of
                    true->gtkgs:config(erm_voice_notes_speaker,{text,maps:get(speaker,N)});
                    false->ok
                end,
                case SelectionChanged orelse Current=:=Previous of
                    true->gtkgs:config(erm_voice_notes_correction,{text,correction(N)});
                    false->ok
                end;
            []->ok
        end,
        Source=case Existing of [Note]->correction(Note);[]-> <<>> end,
        SNext=case {Existing,Selected=/=maps:get(selected,S)} of
            {[SelectedNote],true}->set_role(maps:get(split,SelectedNote),S1);
            _->S1 end,
        SNext#{detail_key:=DetailKey,editor_source:=Source}
    end,
    Last=maps:get(last,Snap),
    case Last=:=maps:get(backend_last,S2,undefined) of
        true->S2;
        false->gtkgs:config(erm_voice_notes_result,{label,last_text(Last)}),S2#{backend_last=>Last}
    end.
detail(N,Snap)->
    Ms=maps:get(duration_ms,N,0),A=maps:get(analysis,N,#{}),
    Text=unicode:characters_to_binary(io_lib:format("~ts\n~.2f s · RMS ~.1f dBFS · clipping ~.3f%\n~ts\nAnalysis: ~p · ~p ms sampled\nCapture: ~p",[
        maps:get(id,N),Ms/1000,maps:get(rms_dbfs,N,-180.0),maps:get(clipped_fraction,N,0.0)*100,
        maps:get(device,N),maps:get(status,A,pending),maps:get(analyzed_ms,A,0),maps:get(ended_by,N,unknown)])),
    gtkgs:config(erm_voice_notes_details,{label,Text}),
    gtkgs:config(erm_voice_notes_score,{label,score_text(maps:get(recognition,N))}),
    Transcript=case maps:get(transcript,N,<<>>) of
        <<>>->case maps:get(transcription,N,#{status=>pending}) of
            #{status:=unavailable}-> <<"Set the local whisper-cli and model paths above, apply settings, then click Transcribe.">>;
            T0->fmt(T0) end;
        T->T end,
    gtkgs:config(erm_voice_notes_transcript,{label,Transcript}),
    ModelText=case maps:get(model,Snap) of
        undefined-> <<"No reviewed speaker model. Label training notes, then add separate validation notes.">>;
        M->unicode:characters_to_binary(io_lib:format("Speaker model: ~B training notes · ~B validation notes · ~B speaker(s) · ~p",[
            maps:get(training_count,M),maps:get(validation_count,M),length(maps:get(speakers,M)),
            maps:get(status,maps:get(calibration,M))]))
    end,
    gtkgs:config(erm_voice_notes_model_status,{label,ModelText}),ok.
score_text(#{reason:=no_independent_reference})->
    <<"This is the only training reference. Record a fresh note to compare it. A note never scores against its own waveform.">>;
score_text(#{reason:=review_notes_to_build_speaker_model})->
    <<"No speaker model yet. Label reviewed notes as Training, then record a fresh note for comparison.">>;
score_text(#{distance:=D,speaker:=L,status:=Status}=R)->
    unicode:characters_to_binary(io_lib:format("Speaker candidate: ~ts · ~p\nECAI acoustic distance: ~.1f (lower is closer; not a probability)\nMargin: ~p · independent references: ~B\nTraining recording: ~p\n~p",[
        L,Status,float(D),maps:get(margin,R,undefined),maps:get(reference_count,R,0),
        maps:get(seen_in_training,R,false),maps:get(limits,R,maps:get(calibration,R,#{}))]));
score_text(R)->fmt(R).
correction(N)->case maps:get(corrected_transcript,N,<<>>) of <<>>->maps:get(transcript,N,<<>>);T->T end.
note_label(N)->
    {{Y,M,D},{H,Min,_}}=calendar:system_time_to_local_time(maps:get(created_ms,N),millisecond),
    Label=case maps:get(speaker,N,<<>>) of <<>>->"unlabelled";L->L end,
    unicode:characters_to_binary(io_lib:format("~4..0B-~2..0B-~2..0B ~2..0B:~2..0B · ~.1fs · ~ts · ~p",[
        Y,M,D,H,Min,maps:get(duration_ms,N,0)/1000,Label,maps:get(split,N,exclude)])).
bar(V)->N=min(24,max(0,round(math:sqrt(V)*48))),lists:duplicate(N,16#2588)++lists:duplicate(24-N,16#2591).
row(P)->gtkgs:create(frame,P,[{orient,horizontal},{spacing,8},{hexpand,true}]).
label(P,Name,Text)->gtkgs:create(label,Name,P,[{label,Text},{wrap,true},{align,start},{hexpand,true}]).
entry(P,Name,Text)->gtkgs:create(entry,Name,P,[{text,Text},{hexpand,true}]).
button(P,Name,Text)->gtkgs:create(button,Name,P,[{label,Text}]).
text(Name)->case gtkgs:read(Name,text) of {ok,V}->V;V when is_binary(V);is_list(V)->V;_-> <<>> end.
fmt(B) when is_binary(B)->B;
fmt(T)->unicode:characters_to_binary(io_lib:format("~0tp",[T])).
last_text({note_saved,_,_})-> <<"Note saved. Analysing the original recording...">>;
last_text({analysis,_,ready})-> <<"Acoustic analysis complete.">>;
last_text({transcription,_,ready})-> <<"Transcription complete. Review the words and speaker label.">>;
last_text({transcription,_,unavailable})-> <<"Note saved. Configure a local transcription model to add text.">>;
last_text({playing_original_note,_})-> <<"Playing the selected original recording.">>;
last_text(V)->fmt(V).
index(_,[],_)-> -1;
index(Id,[Id|_],N)->N;
index(Id,[_|T],N)->index(Id,T,N+1).
role_buttons()->[{exclude,erm_voice_notes_role_exclude,"Exclude"},
    {train,erm_voice_notes_role_train,"Training"},
    {validation,erm_voice_notes_role_validation,"Validation"},
    {test,erm_voice_notes_role_test,"Held-out test"}].
set_role(Role,S)->
    [gtkgs:config(Name,{label,case Role=:=R of true->unicode:characters_to_binary(["● ",Title]);false->Title end})
        ||{R,Name,Title}<-role_buttons()],S#{role:=Role}.
css()-> <<".erm_voice_notes_window { background: #101821; color: #e8eef3; }\n"
".erm_voice_notes_window button { padding: 8px 12px; }\n"
".erm_voice_notes_window entry { min-height: 30px; }\n"
".erm_voice_notes_window label { padding: 2px 0; color: #e8eef3; }\n"
".erm_voice_notes_window button label { color: #182530; }\n"
".erm_voice_notes_window button:disabled label { color: #93999e; }\n"
".erm_voice_notes_window list { background: #182530; border-radius: 8px; }\n">>.
