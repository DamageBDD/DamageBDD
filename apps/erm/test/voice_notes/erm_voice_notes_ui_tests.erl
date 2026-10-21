-module(erm_voice_notes_ui_tests).
-include_lib("eunit/include/eunit.hrl").
button_keyboard_review_and_edits_test_()->{timeout,20,fun()->
    process_flag(trap_exit,true),
    Root=filename:join("/tmp","erm-notes-ui-test-"++integer_to_list(erlang:unique_integer([positive]))),
    Fixture=Root++".pcm",Model=Root++".model",
    PCM= << <<(round(8000*math:sin(2*math:pi()*130*I/16000))):16/little-signed>>||I<-lists:seq(0,28799)>>,
    ok=file:write_file(Fixture,PCM),ok=file:write_file(Model,<<"timeout">>),
    {ok,Sup}=gtknode4_sup:start_link(#{mode=>fake}),
    {ok,_}=erm_voice_notes:start_link(#{directory=>Root,test_pcm=>Fixture,test_playback=>true,
      audio_binary=>filename:absname("apps/erm/priv/bin/erm_voice_notes_audio"),
      whisper_cli=>filename:absname("apps/erm/test/voice_notes/fake_transcriber.py"),whisper_model=>Model}),
    {ok,UI}=erm_voice_notes_ui:show(),
    try
        ui(fun()->gtkgs:inject(erm_voice_notes_record,click,#{}) end),
        await(fun()->maps:get(phase,erm_voice_notes:status())=:=recording end,2000),
        await(fun()->length(erm_voice_notes:notes())=:=1 end,4000),
        await(fun()->maps:get(selected,sys:get_state(UI))=/=undefined end,2000),
        Id=maps:get(selected,sys:get_state(UI)),
        ui(fun()->gtkgs:config(erm_voice_notes_correction,{text,<<"Human text with spaces">>}),
            gtkgs:config(erm_voice_notes_speaker,{text,<<"Steven">>}),
            gtkgs:inject(erm_voice_notes_role_train,click,#{}) end),
        await(fun()->maps:get(jobs,erm_voice_notes:status())=:=[] end,6000),
        timer:sleep(300),
        ?assertEqual(<<"Human text with spaces">>,ui(fun()->gtkgs:read(erm_voice_notes_correction,text) end)),
        ui(fun()->gtkgs:inject(erm_voice_notes_save,click,#{}) end),
        await(fun()->case erm_voice_notes:note(Id) of {ok,#{speaker:= <<"Steven">>,split:=train}}->true;_->false end end,2000),
        ?assertMatch({ok,#{corrected_transcript:= <<"Human text with spaces">>}},erm_voice_notes:note(Id)),
        ui(fun()->gtkgs:inject(erm_voice_notes_play,click,#{}) end),
        await(fun()->maps:get(last,erm_voice_notes:status())=:={playing_original_note,Id} end,2000),
        await(fun()->maps:get(phase,erm_voice_notes:status())=:=idle end,2000),
        %% Space and Escape reach the owner through the gtkgs event contract.
        ui(fun()->gtkgs:inject(erm_voice_notes_window,keypress,#{key=>space}) end),
        await(fun()->Status=erm_voice_notes:status(),maps:get(phase,Status)=:=recording andalso maps:get(recorded_ms,Status)>=100 end,2000),
        ui(fun()->gtkgs:inject(erm_voice_notes_window,keypress,#{key=>escape}) end),
        await(fun()->whereis(erm_voice_notes)=:=undefined andalso not is_process_alive(UI) end,3000),
        {ok,Saved}=erm_voice_notes_store:list(Root),?assertEqual(2,length(Saved))
    after
        catch erm_voice_notes:stop(),catch erm_voice_notes_ui:stop(),
        unlink(Sup),exit(Sup,shutdown),file:delete(Fixture),file:delete(Model),file:del_dir_r(Root)
    end
end}.
ui(F)->
    Parent=self(),Ref=make_ref(),
    sys:replace_state(erm_voice_notes_ui,fun(S)->Parent!{Ref,F()},S end),
    receive {Ref,R}->R after 5000->error(ui_callback_timeout) end.
await(F,Ms)->await(F,erlang:monotonic_time(millisecond)+Ms,undefined).
await(F,Deadline,_)->case F() of true->ok;false->
    case erlang:monotonic_time(millisecond)>=Deadline of true->error(timeout);false->timer:sleep(20),await(F,Deadline,undefined) end end.
