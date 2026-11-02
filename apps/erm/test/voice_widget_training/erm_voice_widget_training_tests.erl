-module(erm_voice_widget_training_tests).
-include_lib("eunit/include/eunit.hrl").
-export([init/1]).
init([])->{ok,{{one_for_one,1,5},[]}}.
repeated_enrolment_presentation_test()->
    Draft=#{id=>repeats,label=><<"Repeated voice">>,collected=>1,target=>8,rejected=>0,
        stage=>repeats,sentence=>1,repeat_index=>2,repeat_target=>3,
        prompt=><<"I am speaking naturally at my usual volume.">>},
    Last=#{outcome=>voice_sample_accepted,check=>#{accepted=>true,reason=>repeat_collected,
        consistency=>#{method=>repeated_sentences,threshold=>undefined}}},
    View=presentation(Last,#{enrolment=>Draft}),Labels=maps:get(labels,View),
    ?assertMatch({_,_},binary:match(maps:get(score,Labels),<<"consistency is pending">>)),
    ?assertMatch({_,_},binary:match(maps:get(enrol_status,Labels),<<"Sentence 1: repeated training take 2 of 3">>)),
    ?assertEqual(maps:get(prompt,Draft),maps:get(prompt,Labels)),
    ?assertMatch(#{record_voice:=true,save_voice:=false},maps:get(controls,View)).
validation_presentation_test()->
    Draft=#{id=>repeats,label=><<"Repeated voice">>,collected=>6,target=>8,rejected=>1,
        stage=>validation,sentence=>3,repeat_index=>1,repeat_target=>2,prompt=><<"Third sentence">>},
    Last=#{outcome=>voice_sample_rejected,check=>#{accepted=>false,reason=>validation_speaker_mismatch,
        speaker_score=>0.4,consistency=>#{method=>repeated_sentences,threshold=>0.56}}},
    View=presentation(Last,#{enrolment=>Draft}),Labels=maps:get(labels,View),
    ?assertMatch({_,_},binary:match(maps:get(feedback,Labels),<<"cannot lower the threshold">>)),
    ?assertMatch({_,_},binary:match(maps:get(enrol_status,Labels),<<"validation take 1 of 2">>)),
    ?assertMatch(#{record_voice:=true,save_voice:=false},maps:get(controls,View)).
first_enrolment_sample_presentation_test()->
    Draft=#{id=>first_sample,label=><<"Fresh voice">>,collected=>1,target=>5,rejected=>0,
        prompt=><<"Read the next sentence">>},
    Last=#{outcome=>voice_sample_accepted,check=>#{accepted=>true,
        consistency=>#{candidate_score=>undefined,threshold=>0.7,profile_min_score=>1.0}}},
    View=presentation(Last,#{enrolment=>Draft}),
    ?assertEqual(<<"First sample establishes the speaker reference">>,
        maps:get(score,maps:get(labels,View))),
    ?assertMatch(#{record_voice:=true,save_voice:=false},maps:get(controls,View)),
    ?assertMatch({_,_},binary:match(maps:get(enrolment_state,View),<<"Enrolment active">>)).
rejected_enrolment_stays_active_presentation_test()->
    Draft=#{id=>first_sample,label=><<"Fresh voice">>,collected=>1,target=>5,rejected=>1,
        prompt=><<"Read the next sentence">>},
    Last=#{outcome=>voice_sample_rejected,check=>#{accepted=>false,reason=>enrolment_inconsistent,
        consistency=>#{candidate_score=>0.654,threshold=>0.7}}},
    View=presentation(Last,#{enrolment=>Draft}),
    State=maps:get(enrolment_state,View),
    [?assertMatch({_,_},binary:match(State,Expected)) || Expected<-
        [<<"Enrolment active for Fresh voice">>,<<"1 / 5 accepted">>,<<"Restart samples">>]],
    ?assertMatch(#{record_voice:=true,save_voice:=false},maps:get(controls,View)).
rejected_phrase_presentation_test_()->
    [?_test(begin
        Last=#{outcome=>voice_verified,check=>#{accepted=>true},content_match=>false,
            recognition=>#{reason=>Reason,action=>stop_music,distance=>0.42,margin=>0.03}},
        Text=maps:get(recognition,maps:get(labels,presentation(Last,
            #{recognition_thresholds=>#{max_distance=>0.31,min_margin=>0.09}}))),
        [?assertMatch({_,_},binary:match(Text,Expected)) || Expected<-
            [<<"Phrase rejected">>,<<"Closest: Stop music">>,<<"distance 0.420">>,
             <<"margin 0.030">>,<<"distance ≤ 0.310"/utf8>>,<<"margin ≥ 0.090"/utf8>>,Detail]]
    end) || {Reason,Detail}<-[{too_far,<<"distance exceeds">>},{ambiguous,<<"competing phrases">>}]].
missing_phrase_templates_presentation_test()->
    Last=#{outcome=>voice_verified,check=>#{accepted=>true},
        recognition=>#{reason=>no_eligible_templates,action=>undefined,distance=>1000.0,margin=>0.0}},
    Text=maps:get(recognition,maps:get(labels,presentation(Last,#{templates=>#{stop_music=>3}}))),
    [?assertMatch({_,_},binary:match(Text,Expected)) || Expected<-
        [<<"voice and wake phrase">>,<<"Train 3–5 takes"/utf8>>,<<"similar duration">>]].
untrained_phrase_presentation_test_()->
    [?_test(begin
        Text=maps:get(recognition,maps:get(labels,presentation(undefined,
            #{corpus=>#{{train,stop_music}=>Count},templates=>#{pause_music=>3}}))),
        ?assertMatch({_,_},binary:match(Text,<<"No trained templates for this phrase">>)),
        ?assertMatch({_,_},binary:match(Text,Expected))
    end) || {Count,Expected}<-[{0,<<"Record 3–5 takes"/utf8>>},{3,<<"Accepted takes are ready">>}]].
presentation(Last,Extra)->
    Snapshot=maps:merge(#{phase=>idle,enrolled=>true,last=>Last,
        capture=>#{ready=>true,processing=>false,suppressed=>false,echo_guard_remaining_ms=>0}},Extra),
    erm_voice_training:present(#{action=>stop_music,snapshot=>Snapshot}).
training_test_()->
    case os:getenv("WIDGET_DEBUG_ONLY") of
        "1"->{timeout,90,fun debug_only/0};
        _->{timeout,180,fun training/0}
    end.
debug_only()->
    application:set_env(erm,log_to_file,false),
    {ok,Host}=inet:gethostname(),
    {ok,Gtk}=gtknode4_sup:start_link(#{mode=>local_cnode,port=>#{
        cnode_node=>list_to_atom("gtknode4@"++Host),env=>[{"DISPLAY",os:getenv("DISPLAY")},
            {"XAUTHORITY",os:getenv("XAUTHORITY")} ]}}),unlink(Gtk),
    {ok,Sup}=supervisor:start_link({local,erm_sup},?MODULE,[]),unlink(Sup),
    Backend=erm_phrase_lab_tests:setup(0.7),
    try
        ok=erm_phrase_voice:resume(),ok=gtknode4:await_ready(10000),
        {ok,_}=erm_voice_widget:start(),wait_phase(offline),timer:sleep(300),
        Window=string:trim(binary_to_list(command("xdotool",["search","--class","erm_voice"]))),
        click(Window,500,176),wait_phase(idle),
        debug_playback(Window,Backend)
    after
        os:unsetenv("PHRASE_LAB_PLAYER_PID"),os:unsetenv("PHRASE_LAB_PLAYER_FAIL"),
        catch erm_voice_widget:stop(),
        case whereis(erm_phrase_lab) of undefined->ok;LabPid->catch gen_server:stop(LabPid) end,
        erm_phrase_lab_tests:cleanup(Backend),exit(Sup,shutdown),exit(Gtk,shutdown)
    end.
training()->
    application:set_env(erm,log_to_file,false),
    {ok,Host}=inet:gethostname(),
    {ok,Gtk}=gtknode4_sup:start_link(#{mode=>local_cnode,port=>#{
        cnode_node=>list_to_atom("gtknode4@"++Host),env=>[{"DISPLAY",os:getenv("DISPLAY")},
            {"XAUTHORITY",os:getenv("XAUTHORITY")} ]}}),unlink(Gtk),
    {ok,Sup}=supervisor:start_link({local,erm_sup},?MODULE,[]),unlink(Sup),
    Backend=erm_phrase_lab_tests:setup(0.7),
    try
        ok=erm_phrase_voice:resume(),
        ok=gtknode4:await_ready(10000),
        {ok,_}=erm_voice_widget:start(),
        wait(fun()->case erm_voice_widget:status() of
            #{training_view:=#{phase:=offline}}->true;_->false end end),
        ?assertEqual(undefined,whereis(erm_phrase_lab)),
        ?assertMatch(#{lab_reserved:=false,paused:=false},erm_phrase_voice:status()),
        timer:sleep(300),
        Window=string:trim(binary_to_list(command("xdotool",["search","--class","erm_voice"]))),
        screenshot(Window,"initial"),
        %% Coordinates are relative to the undecorated test window on Xvfb.
        %% These are XTEST pointer events, not direct calls into widget handlers.
        %% New voice is usable immediately, without a prior shell pause or
        %% Start session click. Validation errors leave the microphone alone.
        enabled(enrol_voice,true),click(Window,340,225),
        wait_heading(<<"Request could not complete">>),
        ?assertEqual(undefined,whereis(erm_phrase_lab)),
        ?assertMatch({_,_},binary:match(maps:get(enrol_status,maps:get(labels,training_view())),<<"Enter a voice name">>)),
        type(Window,140,225,"Draft to discard"),click(Window,340,225),
        wait(fun()->case erm_voice_widget:status() of
            #{training_view:=#{phase:=idle}}->true;_->false end end),
        ok=gtkgs:sync(1000),timer:sleep(100),
        screenshot(Window,"session"),
        ?assert(is_pid(whereis(erm_phrase_lab))),
        wait(fun()->is_map(maps:get(enrolment,training_view())) end),
        enabled(discard_voice,true),enabled(record_voice,true),
        %% Routine workflow coverage does not need audio after each fixture.
        %% The dedicated debug flow below uses the actual reconstruction worker.
        debug_click(Window,toggle_autoplay),
        wait(fun()->maps:get(autoplay,maps:get(playback,erm_phrase_lab:status()))=:=false end),
        click(Window,350,480),
        wait(fun()->maps:get(enrolment,training_view())=:=undefined end),
        enabled(record_voice,false),enabled(save_voice,false),
        wait(fun()->maps:get(record,maps:get(controls,training_view())) end,400),
        enabled(train,false),enabled(record,true),enabled(verify,true),
        click(Window,580,528),wait_phase(listening),
        enabled(record,false),enabled(cancel,true),
        %% A measured native level packet drives the live meter while listening.
        Voice=sys:get_state(erm_phrase_voice),Port=element(6,Voice),Epoch=element(12,Voice),
        erm_phrase_voice!{Port,{data,<<"L",Epoch:64,-24.0:32/float,1>>}},
        wait(fun()->case erm_voice_widget:status() of #{view:=#{input:=0.6}}->true;_->false end end),
        erm_phrase_lab_tests:complete_capture(#{embedding=>[0.53,0.848],ms=>2118,
            after_begin=>fun()->wait_heading(<<"Checking take…"/utf8>>) end}),
        wait_heading(<<"Take rejected">>),
        #{labels:=#{score:=Score}}=training_view(),
        ?assertMatch({_,_},binary:match(Score,<<"0.530 / 0.700">>)),
        ?assertEqual(#{},maps:get(corpus,erm_phrase_lab:status())),
        enabled(train,false),
        screenshot(Window,"rejected"),
        %% Reproduce the reported dead end: an existing name must show its
        %% error next to Start enrolment, instead of leaving only an old score.
        type(Window,140,225,"test"),click(Window,340,225),
        wait_heading(<<"Request could not complete">>),
        ?assertMatch({_,_},binary:match(maps:get(enrol_status,maps:get(labels,training_view())),<<"already exists">>)),
        ?assertEqual(undefined,maps:get(enrolment,training_view())),
        enabled(record_voice,false),enabled(re_enrol_voice,true),
        screenshot(Window,"duplicate-name"),
        %% A passing verification still leaves the corpus empty.
        click(Window,580,528),wait_phase(listening),
        erm_phrase_lab_tests:complete_capture(#{}),wait_heading(<<"Voice verified">>),
        ?assertEqual(#{},maps:get(corpus,erm_phrase_lab:status())),
        %% Real pointer clicks record three distinct takes and commit them.
        lists:foreach(fun(N)->
            click(Window,890,528),wait_phase(listening),
            erm_phrase_lab_tests:complete_capture(#{offset=>N+30}),
            wait(fun()->maps:get(accepted,training_view())=:=N end),
            enabled(train,N>=3)
        end,[1,2,3]),
        screenshot(Window,"ready-to-train"),
        click(Window,580,580),wait_heading(<<"Phrase trained">>),
        ?assertMatch(#{templates:=#{stop_music:=3},observe_only:=true,paused:=true},erm_phrase_voice:status()),
        screenshot(Window,"trained"),
        click(Window,600,252),
        wait(fun()->maps:get(action,training_view())=:=pause_music end),
        ?assertEqual(0,maps:get(accepted,training_view())),enabled(train,false),
        ?assertEqual(<<"bob pause music">>,maps:get(prompt,maps:get(labels,training_view()))),
        screenshot(Window,"pause-selected"),
        click(Window,600,211),wait(fun()->maps:get(action,training_view())=:=stop_music end),
        %% Wake phrase controls select an isolated corpus and restore it on return.
        type(Window,150,650,"hey erm"),click(Window,350,650),
        wait(fun()->maps:get(wake,maps:get(profiles,training_view()))=:=<<"hey erm">> end),
        ?assertEqual(0,maps:get(accepted,training_view())),enabled(train,false),
        ?assertEqual(<<"hey erm stop music">>,maps:get(prompt,maps:get(labels,training_view()))),
        screenshot(Window,"new-wake"),
        type(Window,150,650,"bob"),click(Window,350,650),
        wait(fun()->maps:get(accepted,training_view())=:=3 end),
        %% Re-enrol gives the selected voice a fresh, uniquely named reference.
        %% These samples fail verification against the old identity, but must
        %% be accepted as a consistent NEW identity without weakening its gate.
        click(Window,220,275),
        wait(fun()->is_map(maps:get(enrolment,training_view())) end),
        ?assertMatch(#{enrolment:=#{label:= <<"test (2)">>,collected:=0}},training_view()),
        ?assertMatch({_,_},binary:match(maps:get(enrol_prompt,maps:get(labels,training_view())),<<"speaking naturally">>)),
        enabled(record,false),enabled(record_voice,true),
        %% The first genuine protocol sample must leave the GTK controller
        %% alive. A lower-similarity second sample remains provisional until
        %% the repeated batch is fitted. Restart still invalidates the draft.
        OldDraftId=maps:get(id,maps:get(enrolment,training_view())),
        click(Window,95,480),wait_phase(listening),
        erm_phrase_lab_tests:complete_capture(#{offset=>85,embedding=>[1.0,0.0]}),
        wait(fun()->maps:get(collected,maps:get(enrolment,training_view()))=:=1 end),
        ?assertMatch({_,_},binary:match(maps:get(score,maps:get(labels,training_view())),<<"Collecting repeated">>)),
        click(Window,95,480),wait_phase(listening),
        erm_phrase_lab_tests:complete_capture(#{offset=>86,embedding=>[0.654,math:sqrt(1-0.654*0.654)]}),
        wait(fun()->maps:get(collected,maps:get(enrolment,training_view()))=:=2 end),
        ?assertMatch({_,_},binary:match(maps:get(score,maps:get(labels,training_view())),<<"consistency is pending">>)),
        enabled(restart_voice,true),screenshot(Window,"voice-inconsistent"),
        click(Window,350,275),
        wait(fun()->maps:get(id,maps:get(enrolment,training_view()))=/=OldDraftId end),
        ?assertMatch(#{enrolment:=#{label:= <<"test (2)">>,collected:=0,rejected:=0}},training_view()),
        ?assertEqual(<<"configured">>,maps:get(active_voice,maps:get(profiles,training_view()))),
        wait(fun()->maps:get(record_voice,maps:get(controls,training_view())) end,400),
        lists:foreach(fun(N)->
            click(Window,95,480),wait_phase(listening),
            ?assertMatch({_,_},binary:match(maps:get(enrol_status,maps:get(labels,training_view())),<<"Speak now">>)),
            erm_phrase_lab_tests:complete_capture(#{offset=>N+90,embedding=>[0.53,0.848]}),
            wait(fun()->maps:get(collected,maps:get(enrolment,training_view()))=:=N end)
        end,lists:seq(1,8)),
        enabled(save_voice,true),enabled(record_voice,false),
        ?assertEqual(<<"configured">>,maps:get(active_voice,maps:get(profiles,training_view()))),
        screenshot(Window,"voice-ready"),
        click(Window,218,480),wait_heading(<<"Voice profile saved">>),
        ?assert(maps:get(active_voice,maps:get(profiles,training_view()))=/=<<"configured">>),
        ?assertEqual(0,maps:get(accepted,training_view())),
        screenshot(Window,"voice-saved"),
        click(Window,580,528),wait_phase(listening),
        erm_phrase_lab_tests:complete_capture(#{embedding=>[0.53,0.848]}),
        wait_heading(<<"Voice verified">>),
        ?assertEqual(#{},maps:get(corpus,erm_phrase_lab:status())),
        %% Deletion has a visible confirmation and a working escape route.
        click(Window,130,530),wait_heading(<<"Delete this voice profile?">>),
        enabled(keep_voice,true),screenshot(Window,"delete-confirm"),
        click(Window,330,530),
        wait(fun()->maps:get(delete_voice,maps:get(button_labels,training_view()))=:= <<"Delete voice">> end),
        ?assertEqual(2,length(maps:get(voices,maps:get(profiles,training_view())))),
        click(Window,130,530),wait_heading(<<"Delete this voice profile?">>),
        click(Window,130,530),wait_heading(<<"Voice profile deleted">>),
        ?assertEqual(undefined,maps:get(active_voice,maps:get(profiles,training_view()))),
        ?assertEqual(1,length(maps:get(voices,maps:get(profiles,training_view())))),
        enabled(delete_voice,false),enabled(verify,false),enabled(enrol_voice,true),
        screenshot(Window,"voice-deleted"),
        %% Pick the original voice from the native list; its templates survive.
        click(Window,180,112),
        wait(fun()->maps:get(active_voice,maps:get(profiles,training_view()))=:=<<"configured">> end),
        ?assertEqual(3,maps:get(accepted,training_view())),
        click(Window,580,528),wait_phase(listening),
        click(Window,890,580),wait_phase(idle),
        ?assertEqual(cancelled,maps:get(last,erm_phrase_lab:status())),
        enabled(record,false),
        click(Window,890,528),
        ?assertEqual(idle,maps:get(phase,erm_phrase_lab:status())),
        click(Window,890,160),wait_phase(offline),
        ?assertEqual(undefined,whereis(erm_phrase_lab)),
        %% Reopening reloads the persisted corpus; closing owns and releases it.
        click(Window,500,176),wait_phase(idle),
        ?assertEqual(3,maps:get(accepted,training_view())),
        debug_playback(Window,Backend)
    after
        os:unsetenv("PHRASE_LAB_PLAYER_PID"),os:unsetenv("PHRASE_LAB_PLAYER_FAIL"),
        catch erm_voice_widget:stop(),
        case whereis(erm_phrase_lab) of undefined->ok;LabPid->catch gen_server:stop(LabPid) end,
        wait(fun()->whereis(erm_phrase_lab)=:=undefined end),
        erm_phrase_lab_tests:cleanup(Backend),exit(Sup,shutdown),exit(Gtk,shutdown)
    end.

%% These checks exercise real native LPC reconstruction and a silent external
%% player boundary. Pausing that player makes playback/cancellation observable
%% without sleeping through audio or using a real speaker device.
debug_playback(Window,{_,Dir})->
    click(Window,890,160),wait_phase(offline),
    {ok,Lab}=erm_phrase_lab:start_link(#{binary=>os:getenv("PHRASE_TEST_LAB"),
        player=>os:getenv("PHRASE_TEST_PLAYER"),corpus_file=>filename:join(Dir,"debug.elab")}),
    unlink(Lab),wait_phase(idle),
    debug_click(Window,toggle_autoplay),
    wait(fun()->maps:get(autoplay,maps:get(playback,erm_phrase_lab:status())) end),
    type(Window,140,225,"Debug voice"),click(Window,340,225),
    wait(fun()->is_map(maps:get(enrolment,training_view())) end),
    wait(fun()->maps:get(record_voice,maps:get(controls,training_view())) end,500),
    PlayerPidFile=filename:join(Dir,"debug-player.pid"),
    true=os:putenv("PHRASE_LAB_PLAYER_PID",PlayerPidFile),
    click(Window,95,480),wait_phase(listening),
    erm_phrase_lab_tests:complete_capture(#{offset=>160,embedding=>[1.0,0.0]}),
    wait_playback(playing),
    ?assertMatch(#{enrolment:=#{collected:=1,rejected:=0}},erm_phrase_lab:status()),
    assert_debug_capture(voice_sample_accepted),
    ?assertMatch(#{listening:=false},erm_phrase_voice:status()),
    enabled(record_voice,false),enabled(stop_playback,true),
    screenshot(Window,"debug-accepted-playback"),
    debug_click(Window,stop_playback),wait_playback(stopped),
    wait(fun()->maps:get(record_voice,maps:get(controls,training_view())) end,500),
    %% The rejected capture must also be reconstructed. Its own diagnostic
    %% frame and trace remain visible rather than the previous accepted take.
    click(Window,95,480),wait_phase(listening),
    erm_phrase_lab_tests:complete_capture(#{offset=>161,rms=> -60.0,
        embedding=>[0.51,math:sqrt(1-0.51*0.51)]}),
    wait_playback(playing),
    ?assertMatch(#{enrolment:=#{collected:=1,rejected:=1}},erm_phrase_lab:status()),
    assert_debug_capture(voice_sample_rejected),
    RejectedDiagnostic=maps:get(diagnostics,erm_phrase_lab:status()),
    ?assertEqual([],maps:get(references,RejectedDiagnostic)),
    RejectedId=maps:get(id,RejectedDiagnostic),
    screenshot(Window,"debug-rejected-playback"),
    _=command("xdotool",["mousemove","--window",Window,"1400","560","click","--repeat","9","--delay","30","5"]),
    screenshot(Window,"debug-rejected-references"),
    debug_click(Window,stop_playback),wait_playback(stopped),
    wait(fun()->maps:get(replay,maps:get(controls,training_view())) end,500),
    %% Replay uses the same received take and does not change the enrolment or
    %% add reconstruction output to the human training corpus.
    debug_click(Window,replay),wait_playback(playing),
    ?assertEqual(RejectedId,maps:get(id,maps:get(diagnostics,erm_phrase_lab:status()))),
    ?assertMatch(#{enrolment:=#{collected:=1,rejected:=1},corpus:=#{}},erm_phrase_lab:status()),
    debug_click(Window,stop_playback),wait_playback(stopped),
    os:unsetenv("PHRASE_LAB_PLAYER_PID"),
    true=os:putenv("PHRASE_LAB_PLAYER_FAIL","1"),
    wait(fun()->maps:get(replay,maps:get(controls,training_view())) end,500),
    debug_click(Window,replay),wait_playback(failed),
    ?assert(is_process_alive(whereis(erm_voice_widget))),
    ?assertMatch(#{enrolment:=#{collected:=1,rejected:=1}},erm_phrase_lab:status()),
    screenshot(Window,"debug-player-failure"),
    os:unsetenv("PHRASE_LAB_PLAYER_FAIL"),
    wait(fun()->maps:get(record_voice,maps:get(controls,training_view())) end,500),
    click(Window,95,480),wait_phase(listening),
    erm_phrase_lab_tests:complete_capture(#{offset=>162,embedding=>[1.0,0.0]}),
    wait(fun()->maps:get(collected,maps:get(enrolment,erm_phrase_lab:status()))=:=2 end),
    wait(fun()->maps:get(record_voice,maps:get(controls,training_view())) end,500),
    ?assertMatch(#{playback:=#{available:=true,autoplay:=true}},erm_phrase_lab:status()),
    assert_debug_capture(voice_sample_accepted),
    screenshot(Window,"debug-playback-complete"),
    debug_click(Window,clear_trace),
    wait(fun()->length(maps:get(trace,erm_phrase_lab:status()))=<1 end),
    debug_click(Window,toggle_autoplay),
    wait(fun()->maps:get(autoplay,maps:get(playback,erm_phrase_lab:status()))=:=false end),
    %% Closing the widget stops only its active replay, preserving an attached
    %% shell-owned lab and its reservation for a later controller.
    true=os:putenv("PHRASE_LAB_PLAYER_PID",PlayerPidFile),
    debug_click(Window,replay),wait_playback(playing),
    wait(fun()->maps:get(stop_playback,maps:get(controls,training_view())) end),
    ok=erm_voice_widget:stop(),
    wait_playback(stopped),?assertEqual(Lab,whereis(erm_phrase_lab)),
    ?assert(is_process_alive(Lab)).
assert_debug_capture(Outcome)->
    Status=erm_phrase_lab:status(),
    #{diagnostics:=Diagnostic,trace:=Trace}=Status,
    ?assertEqual(Outcome,maps:get(outcome,Diagnostic)),
    ?assert(maps:get(stages,Diagnostic)=/=[]),
    ?assert(maps:get(envelope,Diagnostic)=/=[]),
    ?assert(length(Trace)>1),?assert(length(Trace)=<100),
    Seq=[maps:get(seq,E)||E<-Trace],?assertEqual(lists:usort(Seq),Seq),
    wait(fun()->maps:get(diagnostics,maps:get(debug,training_view(),#{}),undefined)=:=Diagnostic end),
    ?assertEqual(false,contains_private(Diagnostic)),
    #{training_ui:=#{debug:=Debug}}=sys:get_state(erm_voice_widget),
    TraceText=gtkgs:read(maps:get(trace,Debug),text),
    ?assert(is_binary(TraceText)),?assert(byte_size(TraceText)>10).
contains_private(M) when is_map(M)->
    lists:any(fun(K)->lists:member(K,[embedding,features,synthesis,wav,vectors,prior]) end,maps:keys(M))
        orelse lists:any(fun contains_private/1,maps:values(M));
contains_private(L) when is_list(L)->lists:any(fun contains_private/1,L);
contains_private(_)->false.
wait_playback(P)->wait(fun()->maps:get(phase,maps:get(playback,erm_phrase_lab:status()))=:=P end,500).
%% Fixed coordinates for the dedicated debug panel are exercised through XTEST.
debug_click(Window,Action)->
    wait(fun()->
        #{training_ui:=#{controls:=Controls}}=sys:get_state(erm_voice_widget),
        maps:get(Action,maps:get(controls,training_view()),false) andalso
            gtkgs:read(maps:get(Action,Controls),enable)
    end,500),
    {X,Y}=case Action of toggle_autoplay->{1238,130};replay->{1238,180};
        stop_playback->{1460,180};clear_trace->{1457,130} end,
    click(Window,X,Y).

training_view()->maps:get(training_view,erm_voice_widget:status()).
wait_phase(Phase)->wait(fun()->maps:get(phase,training_view())=:=Phase end).
wait_heading(Heading)->wait(fun()->maps:get(heading,maps:get(labels,training_view()))=:=Heading end).
enabled(Action,Expected)->
    #{training_ui:=#{controls:=Controls}}=sys:get_state(erm_voice_widget),
    ?assertEqual(Expected,gtkgs:read(maps:get(Action,Controls),enable)).
type(Window,X,Y,Text)->
    click(Window,X,Y),_=command("xdotool",["key","ctrl+a"]),
    _=command("xdotool",["type","--clearmodifiers","--delay","0",Text]),ok.
click(Window,X,Y)->
    _=command("xdotool",["mousemove","--window",Window,integer_to_list(X),integer_to_list(Y),"click","1"]),ok.
screenshot(Window,Name)->
    case os:getenv("WIDGET_SCREENSHOT_DIR") of
        false->ok;
        Dir->ok=gtkgs:sync(1000),timer:sleep(100),_=command("import",["-window",Window,filename:join(Dir,Name++".png")]),ok
    end.
command(Name,Args)->
    P=open_port({spawn_executable,os:find_executable(Name)},[binary,exit_status,stderr_to_stdout,{args,Args}]),
    collect(P,<<>>).
collect(P,Acc)->receive
    {P,{data,B}}->collect(P,<<Acc/binary,B/binary>>);
    {P,{exit_status,0}}->Acc;
    {P,{exit_status,N}}->error({command_failed,N,Acc})
after 5000->port_close(P),error(command_timeout) end.
wait(F)->wait(F,200).
wait(_,0)->error(wait_timeout);
wait(F,N)->case F() of true->ok;false->timer:sleep(20),wait(F,N-1) end.
