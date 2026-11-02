%% Real voice telemetry with an explicit verification/training panel. Opening
%% the widget alone never enables capture or changes speaker verification.
-module(erm_voice_widget).
-behaviour(gen_server).
-export([start/0, start/1, start_link/1, show/0, hide/0, stop/0, status/0,
         view/2, level/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
start() -> start(#{}).
start(O) ->
    case gen_server:start({local,?MODULE},?MODULE,O,[]) of
        {error,{already_started,P}} -> show(), {ok,P}; R -> R
    end.
start_link(O) -> gen_server:start_link({local,?MODULE},?MODULE,O,[]).
show() -> gen_server:call(?MODULE,show).
hide() -> gen_server:call(?MODULE,hide).
stop() -> case whereis(?MODULE) of undefined -> ok; _ -> gen_server:stop(?MODULE) end.
status() -> gen_server:call(?MODULE,status).
init(O) when is_map(O) ->
    try
        Sources=maps:get(sources,O,all),
        true=Sources=:=all orelse (is_list(Sources) andalso lists:all(fun is_atom/1,Sources)),
        Text=maps:get(show_text,O,true), true=is_boolean(Text),
        {ok,Bus}=erm_voice_events:ensure_started(),
        {ok,Seq,Events}=erm_voice_events:subscribe(),
        ok=gtknode4:await_ready(5000),
        #{capabilities:=#{motion:=1}}=gtknode4:status(),
        ok=gtkgs:set_stylesheet(erm_voice_widget,css()),
        Server=gtkgs:server(),
        Window=ref(gtkgs:create(window,erm_voice_window,Server,
                   [{title,"erm · voice"},{width,1600},{min_width,0},{height,850},{min_height,0},{class,"erm_voice_window"},
                    {wm_class,"erm_voice"},{wm_instance,"erm_voice"}])),
        Outer=ref(gtkgs:create(scrolled,Window,
            [{orient,vertical},{hscroll,automatic},{vscroll,never},{expand,true}])),
        Shell=ref(gtkgs:create(frame,Outer,[{orient,horizontal},{spacing,24},{margin,20},{vexpand,true}])),
        LeftScroll=ref(gtkgs:create(scrolled,Shell,[{orient,vertical},{width,420},{expand,true}])),
        Root=ref(gtkgs:create(frame,LeftScroll,[{orient,vertical},{spacing,4}])),
        _=ref(gtkgs:create(label,Root,[{label,"E C A I   /   V O I C E"},{class,"erm_voice_eyebrow"}])),
        %% Put the enrolment entry point first, with its own prompt and errors.
        %% Both columns scroll so tiling cannot crop the controls off-screen.
        TrainingUI=training_ui(Shell,Root),
        Stage=ref(gtkgs:create(motion,Root,[{height,138}])),
        Meter=ref(gtkgs:create(voice_meter,Stage,[{width,138},{height,138}])),
        Title=ref(gtkgs:create(label,Root,[{label,"Waiting for voice"},{class,"erm_voice_title"}])),
        Detail=ref(gtkgs:create(label,Root,[{label,"Start your voice session to connect"},
                    {wrap,true},{class,"erm_voice_detail"},{height,42}])),
        _=ref(gtkgs:create(label,Root,[{label,"MIC  /  teal        VOICE  /  violet"},{class,"erm_voice_legend"}])),
        {ok,Training}=erm_voice_training:start(self()),
        ok=gtkgs:config(Window,{show,true}),
        ok=gtkgs_motion:set(Stage,#{opacity=>0,scale=>0.94,y=>10}),
        {ok,_}=gtkgs_motion:animate(Stage,#{opacity=>1,scale=>1,y=>0},#{duration=>320}),
        Mon=monitor(process,gtkgs:server()),
        States=maps:from_list([{maps:get(key,E),E} || E <- Events]),
        self() ! refresh,
        Initial=#{window=>Window,meter=>Meter,title=>Title,detail=>Detail,seq=>Seq,
              states=>States,options=>O,sources=>Sources,show_text=>Text,
              training=>Training,training_mon=>monitor(process,Training),training_ui=>TrainingUI,
              training_view=>undefined,
              bus=>Bus,bus_mon=>monitor(process,Bus),gtk_mon=>Mon,
              timer=>erlang:send_after(1000,self(),refresh),view=>undefined,hidden=>false},
        %% Complete the initial form update before returning start(). A caller
        %% can then publish a short-lived microphone level without waiting
        %% behind hundreds of initial native widget/style operations.
        Ready=render_training(erm_voice_training:status(Training),Initial),
        ok=gtkgs:sync(5000),
        {ok,Ready}
    catch C:R -> {stop,{voice_widget_start_failed,C,R}} end;
init(_) -> {stop,invalid_options}.
ref({gtkgs_ref,_,_}=R) -> R;
ref(Error) -> error(Error).
handle_call(show,_,S) ->
    ok=gtkgs:config(maps:get(window,S),{show,true}),
    {reply,ok,render(S#{hidden=>false})};
handle_call(hide,_,S) ->
    ok=gtkgs:config(maps:get(window,S),{show,false}), {reply,ok,S#{hidden=>true}};
handle_call(status,_,S) -> {reply,maps:with([view,hidden,sources,training_view],S),S};
handle_call(_,_,S) -> {reply,{error,badarg},S}.
handle_cast(_,S) -> {noreply,S}.
handle_info({erm_voice_event,Seq,E},S) ->
    Next=case Seq=:=maps:get(seq,S)+1 of
        true -> S#{states=>put_event(E,maps:get(states,S)),seq=>Seq};
        false -> resync(S)
    end,
    {noreply,render(Next)};
handle_info(refresh,S) ->
    erlang:cancel_timer(maps:get(timer,S)),
    %% A low-rate reconciliation recovers dropped telemetry and a restarted bus.
    {noreply,render((resync(S))#{timer=>erlang:send_after(1000,self(),refresh)})};
handle_info({erm_voice_training,P,V},S=#{training:=P})->
    {noreply,render_training(V,S)};
handle_info({gtkgs,_,click,{training,Action},[]},S)->
    {noreply,training_action(Action,S)};
handle_info({gtkgs,erm_wake_entry,keypress,_,['Return',_]},S)->
    {noreply,training_action(set_wake,S)};
handle_info({gtkgs,erm_voice_name,keypress,_,['Return',_]},S)->
    {noreply,training_action(enrol_voice,S)};
handle_info({gtkgs,erm_phrase_picker,select,_,[I,_,true]},S) when I>=0,I<5->
    Action=lists:nth(I+1,erm_phrase_codec:actions()),
    {noreply,training_action({select_phrase,Action},S)};
handle_info({gtkgs,erm_speaker_picker,select,_,[I,_,true]},S) when I>=0->
    case maps:get(training_view,S) of
        #{profiles:=#{voices:=Voices},lists:=#{voices:=#{selected_index:=Old}}} when I<length(Voices)->
            UI=maps:get(training_ui,S),
            ok=gtkgs:config(maps:get(voices,maps:get(lists,UI)),{selected_index,Old}),
            #{id:=Id}=lists:nth(I+1,Voices),
            {noreply,training_action({select_voice,Id},S)};
        _->{noreply,S}
    end;
handle_info({'DOWN',M,process,_,_},S=#{training_mon:=M})->{stop,training_controller_stopped,S};
handle_info({'DOWN',M,process,_,_},S=#{gtk_mon:=M}) -> {stop,normal,S};
handle_info({'DOWN',M,process,_,_},S=#{bus_mon:=M}) -> {noreply,S#{states=>#{},bus=>undefined}};
handle_info({gtkgs,erm_voice_window,destroy,_,_},S) -> {stop,normal,S};
handle_info(_,S) -> {noreply,S}.
put_event(#{key:=K,data:=#{phase:=stopped}},States) ->
    maps:remove(K,States);
put_event(E=#{key:=K},States) -> States#{K=>E}.
resync(S) ->
    try
        {ok,P}=erm_voice_events:ensure_started(),
        {ok,Seq,Events}=erm_voice_events:subscribe(),
        Mon=case P=:=maps:get(bus,S) of
            true -> maps:get(bus_mon,S);
            false -> demonitor(maps:get(bus_mon,S),[flush]), monitor(process,P)
        end,
        S#{seq=>Seq,states=>maps:from_list([{maps:get(key,E),E} || E<-Events]),bus=>P,bus_mon=>Mon}
    catch _:_ -> S end.
render(S=#{hidden:=true}) -> S;
render(S) ->
    Sources=maps:get(sources,S),
    Events=[E || E<-maps:values(maps:get(states,S)),
                 Sources=:=all orelse lists:member(maps:get(source,E),Sources)],
    V=view(Events,erlang:monotonic_time(millisecond)),
    Old=maps:get(view,S),
    case Old=/=undefined andalso V=:=maps:remove(display_text,Old) of
        true -> S;
        false ->
            {ok,_}=gtkgs_motion:animate(maps:get(meter,S),
                        maps:with([input,output,mood],V),#{duration=>90,easing=>out_cubic}),
            update_label(title,maps:get(title,V),Old,S),
            Detail=case maps:get(show_text,S) of true->maps:get(text,V);false->maps:get(hint,V) end,
            case Old=:=undefined orelse Detail=/=maps:get(display_text,Old,undefined) of
                true -> gtkgs:config(maps:get(detail,S),{label,Detail}); false -> ok
            end,
            S#{view=>V#{display_text=>Detail}}
    end.
update_label(Key,Value,Old,S) ->
    case Old=:=undefined orelse maps:get(Key,Old)=/=Value of
        true -> gtkgs:config(maps:get(Key,S),{label,Value}); false -> ok
    end.
%% Pure reducer shared by integration tests. Never manufacture an audio level.
view(Events,Now) ->
    Inputs=[E || E=#{channel:=input}<-Events], Outputs=[E || E=#{channel:=output}<-Events],
    Work=[E || E=#{channel:=work}<-Events],
    In=max_level(Inputs,Now), Out=max_level(Outputs,Now),
    Speaking=has_phase(Outputs,[speaking]),
    Processing=has_phase(Work,[processing]) orelse has_phase(Outputs,[synthesizing]),
    Listening=has_phase(Inputs,[listening]),
    Error=has_phase([E || E=#{at:=At}<-Events,Now-At<5000],[error]),
    Muted=has_phase(Inputs,[muted]),
    {Mood,Title,Hint}=case {Speaking,Processing,Listening,Error,Muted} of
        {true,_,_,_,_} -> {3,<<"Speaking">>,<<"Voice output is playing">>};
        {_,true,_,_,_} -> {2,<<"Processing">>,<<"Working on your voice input">>};
        {_,_,_,true,_} -> {4,<<"Voice needs attention">>,<<"Check voice backend status">>};
        {_,_,true,_,_} when In>0.03 -> {1,<<"Listening">>,<<"Microphone activity">>};
        {_,_,true,_,_} -> {0,<<"Ready">>,<<"Voice capture is active">>};
        {_,_,_,_,true} -> {0,<<"Microphone gated">>,<<"Waiting for the capture gate to reopen">>};
        _ -> {0,<<"Waiting for voice">>,<<"Start your voice session to connect">>}
    end,
    Texts=lists:sort([{maps:get(text_at,E,maps:get(at,E)),T} || E=#{data:=#{text:=T}}<-Events,T=/=<<>>]),
    Text=case Texts of []->Hint;_->element(2,lists:last(Texts)) end,
    #{input=>In,output=>Out,mood=>Mood,title=>Title,hint=>Hint,text=>Text}.
has_phase(Events,Phases) -> lists:any(fun(#{data:=D})->lists:member(maps:get(phase,D,idle),Phases) end,Events).
max_level(Events,Now) -> lists:max([0.0|[maps:get(level,D,0.0) || #{at:=At,data:=D}<-Events,
                        Now-At<400, lists:member(maps:get(phase,D,idle),[listening,speaking])]]).
level(Db) when is_number(Db) -> max(0.0,min(1.0,(Db+60)/60));
level(_) -> 0.0.
terminate(_,S) ->
    erlang:cancel_timer(maps:get(timer,S)),
    try gen_server:stop(maps:get(training,S),normal,6000) catch _:_ ->ok end,
    try erm_voice_events:unsubscribe() catch _:_ -> ok end,
    try gtkgs:destroy(maps:get(window,S)) catch _:_ -> ok end,
    ok.
code_change(_,_,_) -> {error,restart_required}.

training_action(Action,S)->
    UI=maps:get(training_ui,S),
    Request=case Action of
        enrol_voice->{enrol_voice,gtkgs:read(maps:get(name,UI),text),5};
        re_enrol_voice->{re_enrol_voice,maps:get(active_voice,maps:get(profiles,maps:get(training_view,S)))};
        set_wake->{set_wake,gtkgs:read(maps:get(wake,UI),text)};
        A when A=:=record_voice;A=:=save_voice;A=:=discard_voice;A=:=restart_voice->
            Draft=maps:get(enrolment,maps:get(training_view,S),#{}),
            {A,case Draft of #{id:=Id}->Id;_->undefined end};
        _->Action
    end,
    erm_voice_training:command(maps:get(training,S),Request),S.
training_ui(Parent,Left)->
    Settings=ref(gtkgs:create(frame,Left,[{orient,vertical},{spacing,8},{class,"erm_voice_settings"}])),
    _=label(Settings,"V O I C E   E N R O L M E N T","erm_voice_eyebrow"),
    Voices=ref(gtkgs:create(listbox,erm_speaker_picker,Settings,
        [{height,82},{selection,single},{class,"erm_voice_picker"}])),
    _=label(Settings,"1. Enter a new name or re-enrol the selected voice","erm_training_muted"),
    NameRow=row(Settings),
    Name=ref(gtkgs:create(entry,erm_voice_name,NameRow,[{text,""},{width,150},{hexpand,true}])),
    Enrol=button(NameRow,enrol_voice,"Start enrolment"),
    ReEnrolRow=row(Settings),
    ReEnrol=button(ReEnrolRow,re_enrol_voice,"Re-enrol selected voice"),
    Restart=button(ReEnrolRow,restart_voice,"Restart samples"),
    EnrolStatus=label(Settings,"No enrolment active","erm_enrol_status"),
    ok=gtkgs:config(EnrolStatus,{height,56}),
    EnrolPrompt=label(Settings,"","erm_enrol_prompt"),
    ok=gtkgs:config(EnrolPrompt,{height,58}),
    _=label(Settings,"2. Repeat each displayed sentence, then save the validated voice","erm_training_muted"),
    VoiceRow=row(Settings),
    VoiceRecord=button(VoiceRow,record_voice,"Record sample"),
    VoiceSave=button(VoiceRow,save_voice,"Save voice"),
    Discard=button(VoiceRow,discard_voice,"Discard enrolment"),
    DeleteRow=row(Settings),
    Delete=button(DeleteRow,delete_voice,"Delete voice"),
    Keep=button(DeleteRow,keep_voice,"Keep voice"),
    ProfileHint=label(Settings,"","erm_training_muted"),
    ok=gtkgs:config(ProfileHint,{height,32}),
    _=label(Settings,"WAKE PHRASE","erm_voice_eyebrow"),
    WakeRow=row(Settings),
    Wake=ref(gtkgs:create(entry,erm_wake_entry,WakeRow,[{text,""},{width,150},{hexpand,true}])),
    ApplyWake=button(WakeRow,set_wake,"Apply"),
    WakeHint=label(Settings,"","erm_training_muted"),
    Scroll=ref(gtkgs:create(scrolled,Parent,[{orient,vertical},{width,620},{expand,true}])),
    Panel=ref(gtkgs:create(frame,Scroll,[{orient,vertical},{spacing,8},{class,"erm_training_panel"}])),
    _=label(Panel,"V O I C E   L A B","erm_voice_eyebrow"),
    _=label(Panel,"Verify & train","erm_training_title"),
    Session=label(Panel,"Connecting…","erm_training_muted"),
    SessionRow=row(Panel),
    Begin=button(SessionRow,begin_session,"Start session"),
    End=button(SessionRow,end_session,"End session"),
    Phrases=ref(gtkgs:create(listbox,erm_phrase_picker,Panel,
        [{height,212},{selection,single},{class,"erm_voice_picker"}])),
    Phrase=label(Panel,"Stop music","erm_training_phrase"),
    Prompt=label(Panel,"","erm_training_prompt"),
    Count=label(Panel,"","erm_training_muted"),
    CaptureRow=row(Panel),
    Verify=button(CaptureRow,verify,"Verify voice"),
    Record=button(CaptureRow,record,"Record take"),
    TrainRow=row(Panel),
    Train=button(TrainRow,train,"Train phrase"),
    Cancel=button(TrainRow,cancel,"Cancel"),
    Heading=label(Panel,"Ready when you are","erm_training_heading"),
    Feedback=label(Panel,"","erm_training_muted"),
    ok=gtkgs:config(Feedback,{height,58}),
    Score=label(Panel,"","erm_training_score"),
    Quality=label(Panel,"","erm_training_muted"),
    Recognition=label(Panel,"","erm_training_muted"),
    Limits=label(Panel,"","erm_training_limits"),
    Debug=debug_ui(Parent),
    DebugControls=maps:get(controls,Debug),
    #{name=>Name,wake=>Wake,lists=>#{phrases=>Phrases,voices=>Voices},
      debug=>Debug,
      labels=>#{session=>Session,phrase=>Phrase,prompt=>Prompt,count=>Count,heading=>Heading,
        enrol_status=>EnrolStatus,enrol_prompt=>EnrolPrompt,
        feedback=>Feedback,score=>Score,quality=>Quality,recognition=>Recognition,limits=>Limits,profile_hint=>ProfileHint,wake_hint=>WakeHint},
      button_labels=>#{delete_voice=>Delete,toggle_autoplay=>maps:get(toggle_autoplay,DebugControls)},
      controls=>maps:merge(DebugControls,#{begin_session=>Begin,end_session=>End,select_phrase=>Phrases,select_voice=>Voices,
        enrol_voice=>Enrol,re_enrol_voice=>ReEnrol,record_voice=>VoiceRecord,save_voice=>VoiceSave,set_wake=>ApplyWake,
        discard_voice=>Discard,restart_voice=>Restart,delete_voice=>Delete,keep_voice=>Keep,
        verify=>Verify,record=>Record,train=>Train,cancel=>Cancel})}.
row(Parent)->ref(gtkgs:create(frame,Parent,[{orient,horizontal},{spacing,8}])).
label(Parent,Text,Class)->ref(gtkgs:create(label,Parent,[{label,Text},{wrap,true},{class,Class}])).
button(Parent,Action,Text)->ref(gtkgs:create(button,Parent,
    [{label,Text},{data,{training,Action}},{enable,false},{hexpand,true}])).
render_training(V,S)->
    UI=maps:get(training_ui,S),
    Old=case maps:get(training_view,S) of undefined->#{};X->X end,
    lists:foreach(fun({Group,Option})->
        Prev=maps:get(Group,Old,#{}),
        maps:foreach(fun(K,Value)->
            case maps:get(K,Prev,undefined)=:=Value of
                true->ok;
                false->ok=gtkgs:config(maps:get(K,maps:get(Group,UI)),{Option,Value})
            end
        end,maps:get(Group,V))
    end,[{labels,label},{controls,enable},{button_labels,label}]),
    OldLists=maps:get(lists,Old,#{}),
    maps:foreach(fun(K,Options)->
        case maps:get(K,OldLists,undefined)=:=Options of
            true->ok;
            false->
                Previous=maps:get(K,OldLists,#{}),
                Patch=case maps:get(items,Previous,undefined)=:=maps:get(items,Options) of
                    true->[{selected_index,maps:get(selected_index,Options)}];
                    false->maps:to_list(Options)
                end,
                ok=gtkgs:config(maps:get(K,maps:get(lists,UI)),Patch)
        end
    end,maps:get(lists,V)),
    Wake=maps:get(wake,maps:get(profiles,V)),
    OldWake=maps:get(wake,maps:get(profiles,Old,#{}),undefined),
    case is_binary(Wake) andalso Wake=/=OldWake of
        true->ok=gtkgs:config(maps:get(wake,UI),{text,Wake});false->ok
    end,
    case maps:get(tone,V)=:=maps:get(tone,Old,undefined) of
        true->ok;
        false->
            Classes=case maps:get(tone,V) of error->["erm_training_heading","erm_training_error"];
                _->["erm_training_heading"] end,
            ok=gtkgs_motion:classes(maps:get(heading,maps:get(labels,UI)),Classes)
    end,
    Debug=maps:get(debug,V,#{}),
    case Debug=:=maps:get(debug,Old,undefined) of
        true->ok;
        false->render_debug(Debug,maps:get(debug,Old,#{}),maps:get(debug,UI))
    end,
    S#{training_view=>V}.

debug_ui(Parent)->
    Column=ref(gtkgs:create(frame,Parent,[{orient,vertical},{width,470},{vexpand,true}])),
    Panel=ref(gtkgs:create(frame,Column,[{orient,vertical},{spacing,8},{expand,true},{class,"erm_debug_panel"}])),
    _=label(Panel,"C A P T U R E   I N S P E C T O R","erm_voice_eyebrow"),
    _=label(Panel,"Matching & playback","erm_training_title"),
    AutoRow=row(Panel),
    Auto=debug_button(AutoRow,erm_debug_autoplay,toggle_autoplay,"Autoplay: off"),
    Clear=debug_button(AutoRow,erm_debug_clear,clear_trace,"Clear trace"),
    PlayRow=row(Panel),
    Replay=debug_button(PlayRow,erm_debug_replay,replay,"Replay last sample"),
    Stop=debug_button(PlayRow,erm_debug_stop,stop_playback,"Stop playback"),
    Current=label(Panel,"No capture in progress.","erm_training_muted"),
    Playback=label(Panel,"No captured sample available for replay.","erm_training_muted"),
    _=label(Panel,"Lossy reconstruction of captured audio, not original recording or transcript.","erm_training_limits"),
    GraphScroll=ref(gtkgs:create(scrolled,Panel,[{orient,vertical},{height,220},{vexpand,true}])),
    Graph=ref(gtkgs:create(frame,GraphScroll,[{orient,vertical},{spacing,8}])),
    Summary=label(Graph,"Record a sample to inspect the measured decision stages.","erm_debug_summary"),
    Context=label(Graph,"Capture settings appear after the first analysed take.","erm_training_limits"),
    _=label(Graph,"DECISION STAGES","erm_voice_eyebrow"),
    Stages=[begin
        Box=row(Graph),
        Badge=label(Box,"WAIT","erm_debug_badge"),
        ok=gtkgs:config(Badge,[{width,48},{valign,start}]),
        Text=label(Box,"","erm_training_muted"),ok=gtkgs:config(Text,{hexpand,true}),
        ok=gtkgs:config(Box,{show,false}),#{box=>Box,badge=>Badge,text=>Text}
    end || _<-lists:seq(1,10)],
    _=label(Graph,"MEASURED SCORES · GOLD = LIMIT","erm_voice_eyebrow"),
    Scores=[debug_score_row(Graph) || _<-lists:seq(1,8)],
    RefTitle=label(Graph,"Pairwise reference scores","erm_training_muted"),
    Refs=[debug_score_row(Graph) || _<-lists:seq(1,10)],
    _=label(Graph,"RMS ENVELOPE · CAPTURED SAMPLE","erm_voice_eyebrow"),
    EnvelopeRow=ref(gtkgs:create(frame,Graph,[{orient,horizontal},{spacing,2},{height,76}])),
    Envelope=[ref(gtkgs:create(frame,EnvelopeRow,
        [{width,10},{height,2},{valign,'end'},{class,"erm_debug_envelope_empty"}])) || _<-lists:seq(1,32)],
    EnvelopeNote=label(Graph,"No measured envelope yet.","erm_training_limits"),
    _=label(Panel,"EVENT TRACE · NEWEST FIRST · SELECT TO COPY","erm_voice_eyebrow"),
    TraceScroll=ref(gtkgs:create(scrolled,Panel,[{orient,vertical},{height,150},{hscroll,automatic},{vscroll,automatic}])),
    Trace=ref(gtkgs:create(editor,erm_voice_debug_trace,TraceScroll,
        [{text,"No events yet."},{editable,false},{wrap,true},{hexpand,true},{height,140},{class,"erm_debug_trace"}])),
    #{summary=>Summary,current=>Current,context=>Context,playback=>Playback,stages=>Stages,scores=>Scores,references=>Refs,
        reference_title=>RefTitle,envelope=>Envelope,envelope_note=>EnvelopeNote,trace=>Trace,graph_scroll=>GraphScroll,
        controls=>#{toggle_autoplay=>Auto,clear_trace=>Clear,replay=>Replay,stop_playback=>Stop}}.
debug_button(Parent,Name,Action,Text)->ref(gtkgs:create(button,Name,Parent,
    [{label,Text},{data,{training,Action}},{enable,false},{hexpand,true}])).
debug_score_row(Parent)->
    Box=ref(gtkgs:create(frame,Parent,[{orient,vertical},{spacing,3}])),
    Text=label(Box,"","erm_debug_score"),
    Band=ref(gtkgs:create(frame,Box,[{orient,horizontal},{spacing,1}])),
    Cells=[ref(gtkgs:create(frame,Band,[{width,10},{height,7},{class,"erm_debug_bin"}])) || _<-lists:seq(1,32)],
    ok=gtkgs:config(Box,{show,false}),#{box=>Box,text=>Text,cells=>Cells}.
render_debug(Debug,Old,UI)->
    Current=capture_text(Debug),
    case Current=:=capture_text(Old) of true->ok;
        false->ok=gtkgs:config(maps:get(current,UI),{label,Current}) end,
    Playback=maps:get(playback,Debug,#{}),
    PlaybackText=playback_text(Playback),
    case PlaybackText=:=playback_text(maps:get(playback,Old,#{})) of true->ok;
        false->ok=gtkgs:config(maps:get(playback,UI),{label,PlaybackText}) end,
    Trace=maps:get(trace,Debug,[]),
    case Trace=:=maps:get(trace,Old,undefined) of
        true->ok;
        false->ok=gtkgs:config(maps:get(trace,UI),{text,trace_text(Trace)})
    end,
    Diagnostics=maps:get(diagnostics,Debug,#{}),
    %% The native controls are created empty/hidden. Avoid an initial blank
    %% repaint that could delay live microphone telemetry after start returns.
    case Diagnostics=:=maps:get(diagnostics,Old,undefined) orelse
         (Diagnostics=:=#{} andalso not maps:is_key(diagnostics,Old)) of
        true->ok;
        false->render_diagnostics(Diagnostics,UI)
    end.
render_diagnostics(D0,UI)->
    D=case is_map(D0) of true->D0;false->#{} end,
    Summary=maps:get(summary,D,maps:get(message,D,
        <<"Record a sample to inspect the measured decision stages.">>)),
    Latest=case maps:get(id,D,undefined) of undefined->Summary;
        Id->debug_fmt("Latest completed take ~p\n~ts",[Id,Summary]) end,
    ok=gtkgs:config(maps:get(summary,UI),{label,Latest}),
    ok=gtkgs:config(maps:get(context,UI),{label,context_text(maps:get(context,D,#{}))}),
    render_stages(maps:get(stages,D,[]),maps:get(stages,UI)),
    render_score_rows(maps:get(scores,D,[]),maps:get(scores,UI)),
    References=maps:get(references,D,[]),
    ok=gtkgs:config(maps:get(reference_title,UI),{show,References=/=[]}),
    RefScores=[#{label=>debug_fmt("Reference ~B",[I]),value=>V,min=> -1.0,max=>1.0,pass=>na}
        || #{index:=I,score:=V}<-References,is_number(V)],
    render_score_rows(RefScores,maps:get(references,UI)),
    render_envelope(maps:get(envelope,D,[]),UI).
playback_text(#{phase:=rendering})-> <<"Reconstructing this captured sample… microphone gated."/utf8>>;
playback_text(#{phase:=playing})-> <<"Playing reconstruction… microphone gated."/utf8>>;
playback_text(#{phase:=failed,error:=Why})->debug_fmt("Playback failed: ~P",[Why,5]);
playback_text(#{phase:=stopped})-> <<"Playback stopped. Last sample remains available for replay.">>;
playback_text(#{available:=true})-> <<"Last captured sample is available for replay. Capture waits for the echo guard.">>;
playback_text(_)-> <<"No captured sample available for replay.">>.
capture_text(#{capture:=#{processing:=true}})-> <<"Current capture: analysing. Charts below show the last completed take.">>;
capture_text(#{phase:=listening})-> <<"Current capture: listening. Charts below show the last completed take.">>;
capture_text(#{phase:=arming_human})-> <<"Current capture: opening microphone. Wait for Speak now.">>;
capture_text(#{phase:=offline})-> <<"No lab session connected.">>;
capture_text(_)-> <<"No capture in progress. Charts describe the latest completed take.">>.
context_text(C) when map_size(C)=:=0-> <<"Capture settings appear after the first analysed take.">>;
context_text(C)->
    debug_fmt("Device: ~ts · model: ~ts\n~p dimensions · gain ~p dB · VAD ~p · silence ~p ms",
        [maps:get(device,C,<<"unavailable">>),maps:get(speaker_model,C,<<"unavailable">>),
         maps:get(speaker_dimension,C,undefined),maps:get(input_gain_db,C,undefined),
         maps:get(vad_threshold,C,undefined),maps:get(silence_ms,C,undefined)]).
render_stages([],Rows)->lists:foreach(fun(#{box:=B})->ok=gtkgs:config(B,{show,false}) end,Rows);
render_stages(_,[])->ok;
render_stages([Stage|Rest],[#{box:=B,badge:=Badge,text:=Text}|Rows])->
    Status=maps:get(status,Stage,pending),
    {Word,Class}=case Status of pass->{<<"PASS">>,"erm_debug_pass"};fail->{<<"FAIL">>,"erm_debug_fail"};
        na->{<<"N/A">>,"erm_debug_na"};_->{<<"WAIT">>,"erm_debug_pending"} end,
    ok=gtkgs:config(B,{show,true}),
    ok=gtkgs:config(Badge,{label,Word}),
    ok=gtkgs_motion:classes(Badge,["erm_debug_badge",Class]),
    ok=gtkgs:config(Text,{label,debug_fmt("~ts · ~ts",[maps:get(label,Stage,<<>>),maps:get(value,Stage,<<>>)])}),
    render_stages(Rest,Rows).
render_score_rows([],Rows)->lists:foreach(fun(#{box:=B})->ok=gtkgs:config(B,{show,false}) end,Rows);
render_score_rows(_,[])->ok;
render_score_rows([Score|Rest],[#{box:=B,text:=Text,cells:=Cells}|Rows])->
    Value=maps:get(value,Score,undefined),Min=maps:get(min,Score,0.0),Max=maps:get(max,Score,1.0),
    case is_number(Value) andalso is_number(Min) andalso is_number(Max) andalso Max>Min of
        false->ok=gtkgs:config(B,{show,false});
        true->
            ok=gtkgs:config(B,{show,true}),Threshold=maps:get(threshold,Score,undefined),
            Limit=case is_number(Threshold) of true->debug_fmt(" · limit ~ts",[debug_number(Threshold)]);false-> <<>> end,
            Verdict=case maps:get(pass,Score,na) of true-> <<" · PASS">>;false-> <<" · FAIL">>;_-> <<>> end,
            ok=gtkgs:config(Text,[{label,debug_fmt("~ts  ~ts~ts~ts",[maps:get(label,Score,<<>>),debug_number(Value),Limit,Verdict])},
                {tooltip,debug_fmt("Axis ~ts to ~ts. Gold marker is the configured limit.",[debug_number(Min),debug_number(Max)])}]),
            Filled=round(32*bounded((Value-Min)/(Max-Min))),
            Marker=case is_number(Threshold) of true->1+round(31*bounded((Threshold-Min)/(Max-Min)));false->0 end,
            Colour=case maps:get(pass,Score,na) of true->"erm_debug_fill_pass";false->"erm_debug_fill_fail";_->"erm_debug_fill_neutral" end,
            lists:foreach(fun({Cell,I})->
                Class=case I of Marker->"erm_debug_limit";_ when I=<Filled->Colour;_->"erm_debug_bin" end,
                ok=gtkgs_motion:classes(Cell,[Class])
            end,lists:zip(Cells,lists:seq(1,32)))
    end,
    render_score_rows(Rest,Rows).
render_envelope(Values,UI)->
    Measured=[float(V) || V<-Values,is_number(V),V>=0,V=<1],
    Peak=lists:max([0.0|Measured]),Bins=envelope_bins(Measured,32),
    lists:foreach(fun({Cell,V})->
        Height=case Peak>0 of true->max(2,round(72*V/Peak));false->2 end,
        ok=gtkgs:config(Cell,[{width,10},{height,Height},{tooltip,debug_fmt("RMS ~.4f",[V])}]),
        Class=case Measured of []->"erm_debug_envelope_empty";_->"erm_debug_envelope" end,
        ok=gtkgs_motion:classes(Cell,[Class])
    end,lists:zip(maps:get(envelope,UI),Bins)),
    Note=case Measured of []-> <<"No measured envelope yet.">>;
        _->debug_fmt("Time → · scaled to this take's peak RMS ~.4f. Energy, not a raw waveform.",[Peak]) end,
    ok=gtkgs:config(maps:get(envelope_note,UI),{label,Note}).
envelope_bins([],N)->lists:duplicate(N,0.0);
envelope_bins(Values,N)->
    Len=length(Values),Tuple=list_to_tuple(Values),
    [begin Lo=(I*Len) div N,Hi=max(Lo+1,((I+1)*Len) div N),
        Part=[element(min(Len,J+1),Tuple)||J<-lists:seq(Lo,Hi-1)],lists:sum(Part)/length(Part)
    end || I<-lists:seq(0,N-1)].
trace_text([])-> <<"No events yet.">>;
trace_text(Trace)->iolist_to_binary(lists:join(<<"\n\n">>,
    [debug_fmt("#~B  ~B ms  ~p\n~ts",[maps:get(seq,E,0),maps:get(ms,E,0),maps:get(event,E,event),maps:get(detail,E,<<>>)]) || E<-lists:reverse(Trace)])).
debug_number(V) when abs(V)>=100->integer_to_binary(round(V));
debug_number(V)->debug_fmt("~.3f",[float(V)]).
bounded(V)->max(0.0,min(1.0,V)).
debug_fmt(F,A)->unicode:characters_to_binary(io_lib:format(F,A)).

css() -> <<
".erm_voice_window { background: #0d1420; color: #edf3fa; }\n"
".erm_voice_eyebrow { color: #86a0b8; font-size: 11px; letter-spacing: 2px; margin-top: 8px; }\n"
".erm_voice_title { font-size: 22px; font-weight: 600; margin: 4px; }\n"
".erm_voice_detail { color: #a9b9cb; font-size: 13px; margin: 4px 12px; }\n"
".erm_training_panel { background: #141f30; border-radius: 18px; padding: 20px; }\n"
".erm_debug_panel { background: #111d2b; border-radius: 18px; padding: 20px; }\n"
".erm_debug_summary { color: #edf3fa; font-size: 13px; font-weight: 600; }\n"
".erm_debug_score { color: #cad8e8; font-size: 12px; }\n"
".erm_debug_badge { font-size: 10px; font-weight: 700; border-radius: 4px; padding: 3px; }\n"
".erm_debug_pass { color: #82ead3; background: #183d3c; }\n"
".erm_debug_fail { color: #ff91a0; background: #4b2638; }\n"
".erm_debug_pending { color: #edcf8f; background: #403826; }\n"
".erm_debug_na { color: #a7b5c6; background: #273447; }\n"
".erm_debug_bin, .erm_debug_envelope_empty { background: #28384d; border-radius: 2px; }\n"
".erm_debug_fill_pass, .erm_debug_envelope { background: #57cdb6; border-radius: 2px; }\n"
".erm_debug_fill_fail { background: #ef7c98; border-radius: 2px; }\n"
".erm_debug_fill_neutral { background: #a893ee; border-radius: 2px; }\n"
".erm_debug_limit { background: #f4cd76; border-radius: 1px; }\n"
".erm_debug_trace, .erm_debug_trace text { background: #0b1420; color: #c5d4e5; font-family: monospace; font-size: 11px; }\n"
".erm_debug_panel button { background: #26364c; color: #edf3fa; border: 1px solid #39516b; border-radius: 9px; padding: 8px; box-shadow: none; }\n"
".erm_debug_panel button:disabled { opacity: 0.35; }\n"
".erm_voice_settings { background: #141f30; border-radius: 18px; padding: 16px; }\n"
".erm_enrol_status { color: #edf3fa; font-size: 13px; margin-top: 4px; }\n"
".erm_enrol_prompt { color: #7ce6d1; font-size: 16px; margin: 4px; }\n"
".erm_voice_window list { background: #0f1928; color: #dce6f2; border-radius: 8px; }\n"
".erm_voice_window row { background: transparent; }\n"
".erm_voice_window row:selected { background: #264759; color: #94f2de; }\n"
".erm_voice_window entry { background: #0d1726; color: #edf3fa; border: 1px solid #39516b; border-radius: 8px; min-width: 0; }\n"
".erm_voice_settings button { background: #26364c; color: #edf3fa; border-radius: 9px; padding: 8px; box-shadow: none; }\n"
".erm_voice_settings button:disabled, .erm_voice_picker:disabled { opacity: 0.35; }\n"
".erm_training_title { font-size: 27px; font-weight: 600; margin-bottom: 4px; }\n"
".erm_training_phrase { font-size: 17px; font-weight: 600; }\n"
".erm_training_prompt { color: #7ce6d1; font-size: 20px; margin: 6px; }\n"
".erm_training_heading { color: #7ce6d1; font-size: 18px; font-weight: 600; margin-top: 8px; }\n"
".erm_training_error { color: #ff7186; }\n"
".erm_training_muted { color: #afbed0; font-size: 12px; }\n"
".erm_training_score { color: #d7c8ff; font-size: 14px; margin-top: 4px; }\n"
".erm_training_limits { color: #889db5; font-size: 11px; margin-top: 8px; }\n"
".erm_training_panel button { background: #26364c; color: #edf3fa; border: 1px solid #39516b; border-radius: 9px; padding: 9px 12px; box-shadow: none; }\n"
".erm_training_panel button:hover { background: #334c65; }\n"
".erm_training_panel button:disabled { opacity: 0.35; }\n"
".erm_voice_legend { color: #7f91a8; font-size: 10px; margin: 4px; }\n">>.
