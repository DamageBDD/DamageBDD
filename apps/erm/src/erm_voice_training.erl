%% Serialises lab requests away from the GTK owner process. Only explicit UI
%% actions start a lab/capture; polling never opens the microphone.
-module(erm_voice_training).
-behaviour(gen_server).
-export([start/1,command/2,status/1,present/1]).
-export([init/1,handle_call/3,handle_cast/2,handle_info/2,terminate/2,code_change/3]).
start(Owner)->gen_server:start(?MODULE,Owner,[]).
command(Pid,Action)->gen_server:cast(Pid,{command,Action}).
status(Pid)->gen_server:call(Pid,status).
init(Owner)->
    self()!poll,
    {ok,#{owner=>Owner,monitor=>monitor(process,Owner),lab=>undefined,owned=>false,
        capture=>undefined,enrolment=>undefined,preview_capture=>undefined,delete_pending=>undefined,autoplay_lab=>undefined,
        action=>stop_music,snapshot=>undefined,backend=>#{},error=>undefined,timer=>undefined}}.
handle_call(status,_,S)->{reply,present(S),S};
handle_call(_,_,S)->{reply,{error,badarg},S}.
handle_cast({command,Action},S)->
    %% Recheck the authoritative snapshot; a shell/client may have acted since
    %% the last UI refresh. No parallel or queued duplicate capture requests.
    Fresh=refresh(S),
    Controls=maps:get(controls,present(Fresh)),
    case maps:get(control_key(Action),Controls,false) of
        false->{noreply,notify(Fresh#{error=>{action_unavailable,control_key(Action)}})};
        true->
            _=notify(Fresh#{busy=>control_key(Action),error=>undefined}),
            Next=try execute(Action,Fresh#{error=>undefined})
                 catch C:R->Fresh#{error=>{C,R}} end,
            {noreply,notify(refresh(Next))}
    end;
handle_cast(_,S)->{noreply,S}.
handle_info(poll,S)->
    cancel_timer(maps:get(timer,S)),
    {noreply,notify((refresh(S))#{timer=>erlang:send_after(250,self(),poll)})};
handle_info({'DOWN',M,process,_,_},S=#{monitor:=M})->{stop,normal,S};
handle_info(_,S)->{noreply,S}.

refresh(S)->
    P=whereis(erm_phrase_lab),
    Base=case P=:=maps:get(lab,S) of
        true->S;
        false->S#{lab=>P,owned=>false,capture=>undefined,enrolment=>undefined,error=>undefined}
    end,
    Next=case P of
        undefined->Base#{snapshot=>undefined,backend=>backend_status()};
        _->try Base#{snapshot=>gen_server:call(P,status,3000)}
           catch _:_ ->Base#{snapshot=>unavailable} end
    end,
    case maps:get(delete_pending,Next,undefined)=:=active_voice(Next) of
        true->Next;false->Next#{delete_pending=>undefined}
    end.
backend_status()->try erm_phrase_voice:status() catch _:_ ->#{ready=>false,error=>backend_unavailable} end.
active_voice(S)->
    Snapshot=case maps:get(snapshot,S,undefined) of M when is_map(M)->M;_->maps:get(backend,S,#{}) end,
    maps:get(active_voice,maps:get(profiles,Snapshot,#{}),undefined).
control_key({select_phrase,_})->select_phrase;
control_key({select_voice,_})->select_voice;
control_key({set_wake,_})->set_wake;
control_key({enrol_voice,_,_})->enrol_voice;
control_key({re_enrol_voice,_})->re_enrol_voice;
control_key({record_voice,_})->record_voice;
control_key({restart_voice,_})->restart_voice;
control_key({save_voice,_})->save_voice;
control_key({discard_voice,_})->discard_voice;
control_key(Action)->Action.
execute({select_phrase,A},S)->
    true=lists:member(A,erm_phrase_codec:actions()),S#{action=>A};
execute({select_voice,Id},S)->request({select_voice,Id},S);
execute({set_wake,Text},S)->request({set_wake,Text},S);
execute({enrol_voice,Label,N},S)->
    Name=erm_voice_profiles:label(Label),
    request({enrol_voice,Name,N},open_session(S));
execute({re_enrol_voice,Id},S)->
    %% Explicit recovery from a bad/stale saved identity. Keep that identity
    %% untouched; collect a new reference under an automatically unique name.
    true=Id=/=undefined andalso Id=:=active_voice(S),
    Profiles=profiles(S),Voices=maps:get(voices,Profiles),
    [#{label:=Label}]=[V || V=#{id:=I}<-Voices,I=:=Id],
    Name=next_voice_name(Label,[L || #{label:=L}<-Voices],2),
    request({enrol_voice,Name,5},open_session(S));
execute({record_voice,Id},S)->request(record_voice,adopt_draft(Id,S));
execute({restart_voice,Id},S)->request({restart_voice,Id},adopt_draft(Id,S));
execute({save_voice,Id},S)->request(save_voice,adopt_draft(Id,S));
execute({discard_voice,Id},S)->request({cancel,Id},adopt_draft(Id,S));
execute(delete_voice,S)->
    Id=active_voice(S),true=Id=/=undefined,
    case maps:get(delete_pending,S,undefined) of
        Id->(request({delete_voice,Id},S))#{delete_pending=>undefined};
        _->S#{delete_pending=>Id}
    end;
execute(keep_voice,S)->S#{delete_pending=>undefined};
execute(begin_session,S)->open_session(S);
execute(end_session,S=#{lab:=P})->
    ok=gen_server:stop(P),S#{lab=>undefined,owned=>false,capture=>undefined,enrolment=>undefined};
execute(verify,S)->request({verify,maps:get(action,S)},S);
execute(record,S)->request({record,maps:get(action,S),train},S);
execute(train,S)->request({train,maps:get(action,S)},S);
execute(toggle_autoplay,S)->
    Playback=maps:get(playback,maps:get(snapshot,S,#{}),#{}),
    setting_request({set_autoplay,not maps:get(autoplay,Playback,false)},S);
execute(replay,S)->
    Next=setting_request(replay,S),
    case maps:get(error,Next,undefined) of
        undefined->Next#{preview_capture=>maps:get(id,maps:get(diagnostics,maps:get(snapshot,S,#{}),#{}),undefined)};
        _->Next
    end;
execute(stop_playback,S)->setting_request(stop_playback,S);
execute(clear_trace,S)->setting_request(clear_trace,S);
execute(cancel,S)->
    Id=case maps:get(enrolment,maps:get(snapshot,S,#{}),undefined) of
        #{id:=I} when I=:=map_get(enrolment,S)->I;
        _->maps:get(capture,S)
    end,
    request({cancel,Id},S).
adopt_draft(Id,S)->
    case maps:get(enrolment,maps:get(snapshot,S,#{}),undefined) of
        #{id:=Id}->S#{enrolment=>Id};
        _->error(stale_enrolment)
    end.
profiles(S)->
    Snapshot=case maps:get(snapshot,S,undefined) of M when is_map(M)->M;_->maps:get(backend,S,#{}) end,
    maps:get(profiles,Snapshot,#{voices=>[],active_voice=>undefined,wake=>undefined}).
next_voice_name(Label,Used,N)->
    %% 25 Unicode characters use at most 100 bytes; leave room for the suffix.
    Prefix=unicode:characters_to_binary(lists:sublist(unicode:characters_to_list(Label),25)),
    Name=fmt("~ts (~B)",[Prefix,N]),
    case lists:member(Name,Used) of true->next_voice_name(Label,Used,N+1);false->Name end.
open_session(S=#{lab:=P}) when is_pid(P)->enable_session_autoplay(S);
open_session(S)->
    %% Pause an ambient capture before leasing it; no shell pause is needed.
    Status=backend_status(),
    case maps:get(error,Status,undefined) of backend_unavailable->error(backend_unavailable);_->ok end,
    case maps:get(lab_enabled,Status,undefined) of
        false->error(lab_disabled);
        undefined->error(backend_restart_required);
        true->ok
    end,
    ok=erm_phrase_voice:pause(),
    wait_backend(100),
    case erm_phrase_lab:start() of
        {ok,P}->enable_session_autoplay(S#{lab=>P,owned=>true,capture=>undefined});
        {error,{already_started,P}}->enable_session_autoplay(S#{lab=>P,owned=>false});
        Error->error(Error)
    end.
%% Only an explicit Start/enrol action enables preview for this lab instance.
%% Opening the widget or polling an existing shell session has no side effects.
enable_session_autoplay(S=#{lab:=P})->
    case maps:get(autoplay_lab,S,undefined)=:=P of
        true->S;
        false->(setting_request({set_autoplay,true},S))#{autoplay_lab=>P}
    end.
setting_request(Q,S=#{lab:=P})->
    case gen_server:call(P,Q,15000) of
        ok->S;
        {ok,_}->S;
        Error->S#{error=>Error}
    end.
wait_backend(0)->error(backend_not_ready);
wait_backend(N)->case backend_status() of
    #{ready:=true,processing:=false,suppressed:=false}->ok;
    #{error:=backend_unavailable}->error(backend_unavailable);
    _->receive after 50->wait_backend(N-1) end
end.
request(Q,S=#{lab:=P})->
    case gen_server:call(P,Q,15000) of
        {ok,#{enrolment_id:=Id}}->S#{enrolment=>Id,capture=>undefined};
        {ok,#{id:=Id}}->S#{capture=>Id};
        {ok,_}->S;
        ok->S#{capture=>undefined};
        Error->S#{error=>Error}
    end.
notify(S)->maps:get(owner,S)!{erm_voice_training,self(),present(S)},S.

present(S)->
    A=maps:get(action,S),Snap=maps:get(snapshot,S,undefined),
    Lab=case is_map(Snap) of true->Snap;false->#{} end,
    Phase=maps:get(phase,Lab,offline),Capture=maps:get(capture,Lab,maps:get(backend,S,#{})),
    Playback=maps:get(playback,Lab,#{autoplay=>false,phase=>idle,available=>false}),
    PreviewBusy=lists:member(maps:get(phase,Playback,idle),[rendering,playing]),
    HasLab=is_pid(maps:get(lab,S,undefined)) andalso is_map(Snap),
    Busy=maps:get(busy,S,undefined),Idle=Phase=:=idle andalso Busy=:=undefined andalso not PreviewBusy,
    Ready=Idle andalso maps:get(ready,Capture,false) andalso
        not maps:get(processing,Capture,false) andalso not maps:get(suppressed,Capture,false) andalso
        maps:get(echo_guard_remaining_ms,Capture,0)=:=0,
    Count=maps:get({train,A},maps:get(corpus,Lab,#{}),0),
    Run=maps:get(run,Lab,undefined),Id=maps:get(capture,S,undefined),
    Mine=is_map(Run) andalso Id=/=undefined andalso maps:get(id,Run,undefined)=:=Id,
    Draft=maps:get(enrolment,Lab,undefined),
    DraftMine=is_map(Draft) andalso maps:get(id,Draft)=:=maps:get(enrolment,S,undefined),
    Enrolled=maps:get(enrolled,Lab,false),
    Editing=Idle andalso Draft=:=undefined,
    SettingsReady=Idle andalso maps:get(ready,Capture,false) andalso not maps:get(processing,Capture,false),
    Delete=maps:get(delete_pending,S,undefined),
    Controls=#{begin_session=>Busy=:=undefined andalso (Snap=:=undefined orelse
            (Idle andalso maps:get(autoplay_lab,S,undefined)=/=maps:get(lab,S,undefined))),
        end_session=>is_pid(maps:get(lab,S,undefined)) andalso Busy=:=undefined,
        select_phrase=>(Editing orelse Phase=:=offline) andalso Busy=:=undefined,
        select_voice=>SettingsReady andalso Draft=:=undefined,
        set_wake=>SettingsReady andalso Draft=:=undefined,
        enrol_voice=>(Idle orelse Phase=:=offline) andalso Busy=:=undefined andalso Draft=:=undefined,
        re_enrol_voice=>(Idle orelse Phase=:=offline) andalso Busy=:=undefined andalso
            Draft=:=undefined andalso active_voice(S)=/=undefined,
        record_voice=>Ready andalso is_map(Draft) andalso maps:get(collected,Draft,0)<maps:get(target,Draft,0),
        save_voice=>SettingsReady andalso is_map(Draft) andalso maps:get(collected,Draft,0)=:=maps:get(target,Draft,0),
        discard_voice=>is_map(Draft) andalso Busy=:=undefined,
        restart_voice=>is_map(Draft) andalso Busy=:=undefined,
        delete_voice=>SettingsReady andalso Draft=:=undefined andalso active_voice(S)=/=undefined,
        keep_voice=>Delete=/=undefined andalso Busy=:=undefined,
        verify=>Ready andalso Draft=:=undefined andalso Enrolled,
        record=>Ready andalso Draft=:=undefined andalso Enrolled andalso Count<5,
        train=>Ready andalso Draft=:=undefined andalso Enrolled andalso Count>=3 andalso Count=<5,
        cancel=>(Mine orelse DraftMine) andalso Busy=:=undefined,
        replay=>HasLab andalso Ready andalso maps:get(available,Playback,false),
        stop_playback=>HasLab andalso PreviewBusy andalso Busy=:=undefined,
        toggle_autoplay=>HasLab andalso Busy=:=undefined,
        clear_trace=>HasLab andalso Busy=:=undefined andalso maps:get(trace,Lab,[])=/=[]},
    Last=maps:get(last,Lab,undefined),
    Relevant=case Last of
        #{expected:=Other} when Other=/=A->undefined;
        #{action:=Other} when Other=/=A->undefined;
        _->Last
    end,
    Check=case Relevant of #{check:=C}->C;_->#{} end,
    Limits=maps:get(thresholds,Lab,#{}),
    {Heading,Feedback}=case {Busy,maps:get(error,S,undefined),Phase,Draft,Enrolled} of
        {undefined,undefined,idle,_,_} when PreviewBusy->preview_feedback(Playback);
        {undefined,undefined,idle,_,_} when Delete=/=undefined->
            {<<"Delete this voice profile?">>,<<"Choose Confirm delete to remove the speaker profile, or Keep voice. Phrase recordings remain on disk.">>};
        {undefined,undefined,idle,_,_} when not SettingsReady->feedback(undefined,undefined,idle,Capture,undefined);
        {undefined,undefined,idle,#{},_} when not Ready->feedback(undefined,undefined,idle,Capture,undefined);
        {undefined,undefined,idle,#{collected:=N,target:=N},_}->
            {<<"Voice samples ready">>,<<"Choose Save voice to activate this profile. Existing profiles are preserved.">>};
        {undefined,undefined,idle,#{},_}->voice_feedback(Relevant);
        {undefined,undefined,idle,undefined,false} when not is_map(Relevant)->
            {<<"Enrol your voice first">>,<<"Enter a voice name and choose Start enrolment. Record the prompted sentences, then save the profile.">>};
        _->feedback(Busy,maps:get(error,S,undefined),Phase,Capture,Relevant)
    end,
    Tone=case {Phase,Relevant,maps:get(error,S,undefined)} of
        {idle,#{check:=#{accepted:=false}},_}->error;
        {idle,#{outcome:=human_sample_rejected},_}->error;
        {_,_,Err} when Err=/=undefined->error;
        _->normal
    end,
    Prompt=case Draft of #{collected:=Done,target:=Done}-> <<"Save the new voice reference">>;
        #{prompt:=DPrompt}->DPrompt;
        _->maps:get(A,maps:get(prompts,Lab,#{}),<<"Start a lab session to load the wake phrase"/utf8>>) end,
    Profiles=profiles(S),
    Voices=maps:get(voices,Profiles),
    ActiveLabel=case [L || #{id:=I,label:=L}<-Voices,I=:=maps:get(active_voice,Profiles)] of
        [L0]->L0;_-> <<"this voice">>
    end,
    Actions=erm_phrase_codec:actions(),
    Items=[fmt("~ts   ·   ~B takes / ~B trained",[maps:get(X,maps:get(prompts,Lab,#{}),action_text(X)),
        maps:get({train,X},maps:get(corpus,Lab,#{}),0),maps:get(X,maps:get(templates,Lab,#{}),0)]) || X<-Actions],
    Selected=length(lists:takewhile(fun(X)->X=/=A end,Actions)),
    VoiceIndex=case maps:get(active_voice,Profiles) of undefined-> -1;
        Active->length(lists:takewhile(fun(#{id:=X})->X=/=Active end,Voices)) end,
    CountText=case Draft of
        #{collected:=Got,target:=Target,rejected:=Rejected}->fmt("Voice samples · ~B / ~B accepted · ~B rejected",[Got,Target,Rejected]);
        _->fmt("~B / 3 required takes  ·  up to 5 per phrase",[Count])
    end,
    EnrolState=enrolment_state(Draft,Capture#{playback_phase=>maps:get(phase,Playback,idle)},
        Phase,Busy,maps:get(error,S,undefined),Relevant),
    EnrolPrompt=case Draft of #{collected:=Total,target:=Total}->
            <<"Save voice activates this new reference. Your previous voice profile is preserved.">>;
        #{prompt:=EP}->EP;
        _-> <<"Choose Start enrolment for a new name, or Re-enrol selected voice to build a fresh reference.">> end,
    #{action=>A,phase=>Phase,controls=>Controls,accepted=>Count,check=>Check,tone=>Tone,
      debug=>#{diagnostics=>maps:get(diagnostics,Lab,#{}),trace=>maps:get(trace,Lab,[]),playback=>Playback,
          phase=>Phase,capture=>maps:with([ready,processing],Capture)},
      profiles=>Profiles,enrolment=>Draft,enrolment_state=>EnrolState,
      button_labels=>#{delete_voice=>case Delete of undefined-> <<"Delete voice">>;_-> <<"Confirm delete">> end,
          toggle_autoplay=>case maps:get(autoplay,Playback,false) of true-> <<"Autoplay: on">>;false-> <<"Autoplay: off">> end},
      lists=>#{phrases=>#{items=>Items,selected_index=>Selected},
               voices=>#{items=>[maps:get(label,V)||V<-Voices],selected_index=>VoiceIndex}},
      labels=>#{session=>session_line(Snap,maps:get(owned,S,false),Capture),
        enrol_status=>EnrolState,enrol_prompt=>EnrolPrompt,
        phrase=>case Draft of undefined->action_text(A);_-> <<"Voice enrolment">> end,
        prompt=>Prompt,heading=>Heading,feedback=>Feedback,
        count=>CountText,
        profile_hint=>case {Draft,Phase,Delete} of
            {_,_,D} when D=/=undefined->fmt("Delete '~ts'? Phrase takes remain on disk.",[ActiveLabel]);
            {undefined,_,_}-> <<"Enrolment builds a new speaker reference; verification checks the saved voice.">>;
            {#{label:=DraftLabel,collected:=Got0,target:=Target0},_,_}->
                DraftHint=fmt("~ts · ~B / ~B voice samples accepted",[DraftLabel,Got0,Target0]),
                case maps:get(remaining_ms,Draft,undefined) of
                    Remaining when is_integer(Remaining)->
                        <<DraftHint/binary,(fmt(" · idle timeout in ~B s",[(max(0,Remaining)+999) div 1000]))/binary>>;
                    _->DraftHint
                end end,
        wake_hint=><<"Train the full wake phrase + command. Each wake phrase keeps its own takes.">>,
        limits=>limits(Limits),score=>score(Check),quality=>quality(Check),
        recognition=>case Draft of undefined->recognition(Relevant,Lab,A,Count);
            _-> <<"Enrolment compares these new samples with each other.">> end}}.
enrolment_state(_,_,_,_,Error,_) when Error=/=undefined->error_text(Error);
enrolment_state(_,_,_,Busy,_,_) when Busy=/=undefined-> <<"Working. Waiting for the voice backend...">>;
enrolment_state(undefined,_,_,_,_,#{outcome:=voice_enrolled})->
    <<"Voice saved. You can now verify it or record phrase training takes.">>;
enrolment_state(undefined,_,_,_,_,#{check:=#{reason:=speaker_below_threshold}})->
    <<"No enrolment active. The saved voice did not match. Choose Re-enrol selected voice to record a fresh reference.">>;
enrolment_state(undefined,_,_,_,_,_)->
    <<"No enrolment active. Start enrolment first to enable Record sample.">>;
enrolment_state(_,_,arming_human,_,_,_)-> <<"Opening microphone. Wait for Speak now.">>;
enrolment_state(_,#{processing:=true},_,_,_,_)-> <<"Checking the new voice sample. Please wait.">>;
enrolment_state(#{collected:=N,target:=T},_,listening,_,_,_)->
    fmt("Speak now: read the sentence below, then pause. Sample ~B of ~B.",[N+1,T]);
enrolment_state(#{label:=Name,collected:=N,target:=T},#{playback_phase:=P},_,_,_,_)
    when P=:=rendering;P=:=playing->
    fmt("Enrolment active for ~ts: ~B / ~B accepted. Reconstructed playback keeps the microphone gated.",[Name,N,T]);
enrolment_state(_,#{ready:=false},_,_,_,_)-> <<"Enrolment draft is ready; waiting for the capture backend.">>;
enrolment_state(#{collected:=N,target:=N},_,_,_,_,_)->
    fmt("~B / ~B samples accepted. Choose Save voice.",[N,N]);
enrolment_state(_,#{suppressed:=true},_,_,_,_)-> <<"Waiting for playback to finish before recording a voice sample.">>;
enrolment_state(_,#{echo_guard_remaining_ms:=Ms},_,_,_,_) when Ms>0->
    fmt("Record sample becomes available in ~B s after the microphone echo guard.",[(Ms+999) div 1000]);
enrolment_state(#{label:=Name,collected:=N,target:=T},_,_,_,_,
    #{outcome:=voice_sample_rejected,check:=#{reason:=audio_too_short}})->
    fmt("Enrolment active for ~ts: ~B / ~B accepted. Sample too short. Read the entire sentence at your usual pace.",[Name,N,T]);
enrolment_state(#{label:=Name,collected:=N,target:=T},_,_,_,_,
    #{outcome:=voice_sample_rejected,check:=#{reason:=enrolment_inconsistent}})->
    fmt("Enrolment active for ~ts: ~B / ~B accepted. This take did not match. Retry or choose Restart samples.",[Name,N,T]);
enrolment_state(#{label:=Name,collected:=N,target:=T},_,_,_,_,
    #{outcome:=voice_sample_rejected,check:=#{reason:=Why}})->
    fmt("Enrolment active for ~ts: ~B / ~B accepted. ~ts",[Name,N,T,reason(Why)]);
enrolment_state(#{label:=Name,collected:=N,target:=T},_,_,_,_,_)->
    fmt("Enrolment active for ~ts: ~B / ~B accepted. Choose Record sample.",[Name,N,T]).
voice_feedback(#{outcome:=voice_sample_rejected,check:=#{reason:=Why}})->{<<"Voice sample rejected">>,reason(Why)};
voice_feedback(#{outcome:=voice_sample_accepted})->{<<"Voice sample accepted">>,<<"Choose Record sample, then say the next sentence above at your usual distance and volume.">>};
voice_feedback(_)->{<<"Enrolling a new voice">>,<<"Choose Record sample. Wait for Speak now, then read the sentence above naturally.">>}.
session_line(Snap,Owned,#{echo_guard_remaining_ms:=Ms}) when Ms>0->
    <<(session(Snap,Owned))/binary," · capture in "/utf8,(integer_to_binary((Ms+999) div 1000))/binary," s">>;
session_line(Snap,Owned,#{suppressed:=true})->
    <<(session(Snap,Owned))/binary," · waiting for playback"/utf8>>;
session_line(Snap,Owned,_)->session(Snap,Owned).
session(undefined,_)-> <<"Open a lab session to verify and train your voice."/utf8>>;
session(unavailable,_)-> <<"The lab is not responding. Waiting for status…"/utf8>>;
session(_,true)-> <<"Lab session active · commands paused"/utf8>>;
session(_,false)-> <<"Connected to existing lab · commands paused"/utf8>>.
action_text(stop_music)-> <<"Stop music"/utf8>>;
action_text(pause_music)-> <<"Pause music"/utf8>>;
action_text(play_music)-> <<"Play music"/utf8>>;
action_text(next_track)-> <<"Next track"/utf8>>;
action_text(previous_track)-> <<"Previous track"/utf8>>.
preview_feedback(#{phase:=rendering})->
    {<<"Reconstructing your sample">>,<<"Preparing a lossy playback of the captured sound. The microphone stays gated.">>};
preview_feedback(_)->
    {<<"Playing your sample">>,<<"Listen to the reconstructed capture. Use Stop playback to end it; capture resumes after the echo guard.">>}.
feedback(Busy,_,_,_,_) when Busy=/=undefined->
    {<<"Working…"/utf8>>,case Busy of begin_session-> <<"Opening the voice lab…"/utf8>>;
        train-> <<"Saving verified phrase templates…"/utf8>>;_-> <<"Waiting for the voice backend…"/utf8>> end};
feedback(_,Error,_,_,_) when Error=/=undefined->{<<"Request could not complete"/utf8>>,error_text(Error)};
feedback(_,_,offline,_,_)->{<<"Ready when you are"/utf8>>,<<"Verify checks your speaker profile without saving a take. Record collects human training takes."/utf8>>};
feedback(_,_,arming_human,_,_)->{<<"Wait for listening"/utf8>>,<<"The microphone is opening. Wait for Speak now before starting the phrase."/utf8>>};
feedback(_,_,listening,#{processing:=true},_)->{<<"Checking take…"/utf8>>,<<"Measuring speaker similarity and audio quality."/utf8>>};
feedback(_,_,listening,_,_)->{<<"Speak now"/utf8>>,<<"Say the full phrase above, then pause. The microphone level is shown on the left."/utf8>>};
feedback(_,_,idle,_,#{outcome:=voice_enrolled})->
    {<<"Voice profile saved">>,<<"The new speaker profile is active. Record and train the commands for this voice and wake phrase.">>};
feedback(_,_,idle,_,#{outcome:=voice_deleted,profile_cleanup:={error,Why}})->
    {<<"Voice removed; file cleanup failed">>,fmt("The voice is no longer active or listed. Its speaker file could not be removed: ~p.",[Why])};
feedback(_,_,idle,_,#{outcome:=voice_deleted})->
    {<<"Voice profile deleted">>,<<"The speaker profile was removed. Select another voice or enrol a new one; command capture remains paused.">>};
feedback(_,_,idle,_,#{outcome:=wake_selected})->
    {<<"Wake phrase selected">>,<<"Use the full prompt for each command. Saved takes for other wake phrases remain available when you switch back.">>};
feedback(_,_,idle,_,#{outcome:=voice_selected})->
    {<<"Voice profile selected">>,<<"The phrase list now shows this speaker's recordings and trained templates.">>};
feedback(_,_,idle,_,#{outcome:=human_templates_committed,templates:=N,revision:=R})->
    {<<"Phrase trained"/utf8>>,fmt("Saved ~B verified templates · profile revision ~B",[N,R])};
feedback(_,_,idle,_,#{outcome:=human_sample_saved})->
    {<<"Take saved"/utf8>>,<<"Verified human take added. Record at least 3 distinct takes, then choose Train phrase."/utf8>>};
feedback(_,_,idle,_,#{outcome:=voice_verified,check:=#{accepted:=true}})->
    {<<"Voice verified"/utf8>>,<<"Speaker and audio checks passed. See the separate phrase result below. This diagnostic take was not saved."/utf8>>};
feedback(_,_,idle,_,#{check:=#{accepted:=false,reason:=Why}})->{<<"Take rejected"/utf8>>,reason(Why)};
feedback(_,_,idle,_,#{reason:=Why})->{<<"Take not saved"/utf8>>,reason(Why)};
feedback(_,_,idle,_,{experiment_failed,Why})->{<<"Capture stopped"/utf8>>,error_text(Why)};
feedback(_,_,idle,#{echo_guard_remaining_ms:=Ms},_) when Ms>0->
    {<<"Microphone settling"/utf8>>,fmt("Capture available in ~B s after playback or cancellation.",[(Ms+999) div 1000])};
feedback(_,_,idle,#{suppressed:=true},_)->{<<"Waiting for playback"/utf8>>,<<"Capture resumes when speech output and its echo guard finish."/utf8>>};
feedback(_,_,idle,#{ready:=false},_)->{<<"Backend starting"/utf8>>,<<"Waiting for the phrase and speaker models to become ready."/utf8>>};
feedback(_,_,idle,_,voice_enrolment_expired)->
    {<<"Voice enrolment expired">>,<<"The three-minute enrolment window ended. Choose Start enrolment to start again.">>};
feedback(_,_,idle,_,cancelled)->{<<"Capture cancelled"/utf8>>,<<"No training take was saved."/utf8>>};
feedback(_,_,idle,_,_)->{<<"Ready to capture"/utf8>>,<<"Verify your voice, or record a new training take. Training only uses accepted human takes."/utf8>>};
feedback(_,_,_,_,_)->{<<"Lab working…"/utf8>>,<<"An experiment is running. Training controls will return when it finishes."/utf8>>}.
reason(enrolment_inconsistent)-> <<"This sample does not match the preceding voice samples. Retry with the same microphone and speaking distance. If the first take was poor, choose Restart samples for a fresh reference.">>;
reason(speaker_below_threshold)-> <<"Speaker score is below the enrolled profile threshold. Check the microphone and speaker profile, then retry. This take cannot train the phrase."/utf8>>;
reason(audio_too_short)-> <<"Take too short. Say the full wake phrase and command; meet the minimum duration below."/utf8>>;
reason(audio_too_quiet)-> <<"Take too quiet. Move closer or adjust microphone gain, then record again."/utf8>>;
reason(audio_clipped)-> <<"Audio clipped. Reduce microphone gain or move farther away, then retry."/utf8>>;
reason(duplicate_sample)-> <<"This take is already stored. Record a distinct spoken take."/utf8>>;
reason(Why)->fmt("Check failed: ~p. Review the voice backend before retrying.",[Why]).
error_text({error,Why})->error_text(Why);
error_text({action_unavailable,_})-> <<"This control is unavailable in the current session state. Wait for capture to finish, or discard the pending enrolment.">>;
error_text(stale_enrolment)-> <<"The enrolment changed. Review the displayed draft and try again.">>;
error_text(lab_disabled)-> <<"Enable lab_enabled in the phrase backend configuration, then restart the phrase backend.">>;
error_text(backend_restart_required)-> <<"Restart the phrase backend after compiling this patch. The running backend lacks the enrolment workflow API.">>;
error_text(backend_unavailable)-> <<"Start the phrase voice backend, then try Start enrolment again.">>;
error_text(backend_not_ready)-> <<"The phrase backend or playback is still busy. Wait for ready=true and processing=false, then retry.">>;
error_text({invalid_lab_request,error,Why})->error_text(Why);
error_text({profile_selection,error,Why})->error_text(Why);
error_text(voice_name_already_exists)-> <<"That name already exists. Choose Re-enrol selected voice for a fresh reference, or enter a different name.">>;
error_text(voice_profile_limit)-> <<"All 16 voice slots are in use. Delete an unused saved voice before starting another enrolment.">>;
error_text(invalid_voice_name)-> <<"Enter a voice name using 1 to 128 bytes, without line breaks.">>;
error_text(invalid_wake_phrase)-> <<"Use one to four words for the wake phrase, without line breaks or punctuation other than hyphens/apostrophes.">>;
error_text(Why)->fmt("~P",[Why,8]).
limits(#{speaker_threshold:=T,min_speaker_ms:=Ms,min_rms_dbfs:=R,max_clipped_fraction:=C})->
    fmt("Limits · speaker ≥ ~.3f  ·  ≥ ~B ms\nRMS ≥ ~.1f dBFS  ·  clipping ≤ ~.1f%",[float(T),Ms,float(R),100*C]);
limits(_)-> <<"Verification limits load with the lab session"/utf8>>.
score(#{consistency:=#{candidate_score:=undefined}})-> <<"First sample establishes the speaker reference">>;
score(#{consistency:=#{candidate_score:=C,threshold:=T,profile_min_score:=Min}})
    when is_number(C),is_number(T),is_number(Min)->
    fmt("Voice consistency ~.3f / ~.3f required · profile minimum ~.3f",[float(C),float(T),float(Min)]);
score(#{consistency:=#{candidate_score:=C,threshold:=T}}) when is_number(C),is_number(T)->
    fmt("Voice consistency ~.3f / ~.3f required · fail",[float(C),float(T)]);
score(#{speaker_score:=Score,thresholds:=#{speaker_threshold:=T}})->
    fmt("Speaker  ~.3f / ~.3f required  ·  ~s",[float(Score),float(T),pass(Score>=T)]);
score(#{reason:=_})-> <<"Speaker score unavailable · see the failed check"/utf8>>;
score(_)-> <<"Speaker score appears after each take"/utf8>>.
quality(#{audio_ms:=Ms,quality:=#{rms_dbfs:=R,clipped_fraction:=C},thresholds:=L})->
    fmt("Duration  ~B ms  (~s)\nRMS  ~.1f dBFS  (~s)  ·  clipping  ~.1f%  (~s)",
        [Ms,pass(Ms>=maps:get(min_speaker_ms,L)),float(R),pass(R>=maps:get(min_rms_dbfs,L)),
         C*100,pass(C=<maps:get(max_clipped_fraction,L))]);
quality(_)-> <<"Duration, loudness and clipping appear after each take"/utf8>>.
recognition(Last,Lab,A,Count)->
    Trained=maps:get(A,maps:get(templates,Lab,#{}),0),
    Text=case Last of
        #{recognition:=#{reason:=no_eligible_templates}} when Trained=:=0->phrase_training_hint(Count);
        #{recognition:=_}->recognition(Last);
        _ when Trained=:=0->phrase_training_hint(Count);
        _->recognition(Last)
    end,
    case maps:get(recognition_thresholds,Lab,#{}) of
        #{max_distance:=D,min_margin:=M}->
            <<Text/binary,(fmt("\nPhrase limits · distance ≤ ~.3f · margin ≥ ~.3f",[float(D),float(M)]))/binary>>;
        _->Text
    end.
phrase_training_hint(Count) when Count>=3->
    <<"No trained templates for this phrase, voice and wake phrase. Accepted takes are ready: choose Train phrase.">>;
phrase_training_hint(_)->
    <<"No trained templates for this phrase, voice and wake phrase. Record 3–5 takes, then choose Train phrase."/utf8>>.
recognition(#{recognition:=#{reason:=matched,action:=A,distance:=D,margin:=M},content_match:=Same})->
    fmt("Phrase: ~ts · distance ~.3f · margin ~.3f~ts",[action_text(A),D,M,
        case Same of true-> <<"">>;false-> <<" · different command"/utf8>> end]);
recognition(#{recognition:=#{reason:=Reason,action:=A,distance:=D,margin:=M}})
    when Reason=:=too_far;Reason=:=ambiguous->
    Detail=case Reason of
        too_far-> <<"distance exceeds the phrase limit">>;
        ambiguous-> <<"competing phrases are too close">>
    end,
    fmt("Phrase rejected: ~ts\nClosest: ~ts · distance ~.3f · margin ~.3f",
        [Detail,action_text(A),float(D),float(M)]);
recognition(#{recognition:=#{reason:=no_eligible_templates}})->
    <<"No eligible phrase templates for this voice and wake phrase. Train 3–5 takes; at least 2 templates must have a similar duration to this take."/utf8>>;
recognition(#{recognition:=#{reason:=no_features}})->
    <<"No phrase features were captured. Wait for Speak now, then say the full wake phrase and command.">>;
recognition(#{recognition:=#{reason:=Reason}})->fmt("Phrase not matched: ~p",[Reason]);
recognition(_)-> <<"Verify also checks which trained phrase was recognised.">>.
pass(true)->"pass";pass(false)->"fail".
fmt(F,A)->unicode:characters_to_binary(io_lib:format(F,A)).
cancel_timer(undefined)->ok;
cancel_timer(T)->erlang:cancel_timer(T),ok.
terminate(_,S)->
    cancel_timer(maps:get(timer,S)),
    %% Never stop a session started in the shell. If our trial is still active,
    %% its ID prevents cancelling a later trial started by somebody else.
    try
        P=maps:get(lab,S),
        case is_pid(P) andalso P=:=whereis(erm_phrase_lab) of
            false->ok;
            true->case maps:get(owned,S) of
                true->gen_server:stop(P);
                false->
                    _=catch stop_owned_preview(P,S),
                    lists:foreach(fun(undefined)->ok;
                        (Id)->gen_server:call(P,{cancel,Id},3000)
                    end,[maps:get(enrolment,S,undefined),maps:get(capture,S)])
            end
        end
    catch _:_ ->ok end,ok.
stop_owned_preview(P,S)->
    Status=gen_server:call(P,status,3000),
    Id=maps:get(id,maps:get(diagnostics,Status,#{}),undefined),
    Phase=maps:get(phase,maps:get(playback,Status,#{}),idle),
    Owned=Id=/=undefined andalso lists:member(Id,
        [maps:get(capture,S,undefined),maps:get(preview_capture,S,undefined)]),
    case Owned andalso lists:member(Phase,[rendering,playing]) of
        true->gen_server:call(P,stop_playback,3000);
        false->ok
    end.
code_change(_,_,_)->{error,restart_required}.
