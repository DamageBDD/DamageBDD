-module(erm_voice_notes_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/file.hrl").

partition_and_calibration_test()->
    Rows=dataset(),{ok,M}=erm_voice_notes_model:build(Rows),
    ?assertEqual(2,maps:get(training_count,M)),
    ?assertMatch(#{status:=calibrated},maps:get(calibration,M)),
    ?assertEqual(false,maps:get(test_used_for_build,M)),
    ?assertMatch(#{status:=matched,speaker:= <<"Steven">>,seen_in_training:=false},
        erm_voice_notes_model:score(row(7,<<"Steven">>,test,12),M)),
    ?assertMatch(#{status:=unknown},erm_voice_notes_model:score(row(8,<<"unknown">>,test,240),M)),
    {ok,M2}=erm_voice_notes_model:build(Rows++[row(9,<<"nonsense label">>,test,-255)]),
    ?assertEqual(maps:get(templates,M),maps:get(templates,M2)),
    ?assertEqual(maps:get(calibration,M),maps:get(calibration,M2)),
    ?assertMatch(#{status:=evaluated,count:=2,correct:=2},
        erm_voice_notes_model:evaluate([row(7,<<"Steven">>,test,12),row(8,<<"unknown">>,test,240)],M)).
self_reference_and_leakage_test()->
    Train=row(1,<<"Steven">>,train,10),
    {ok,M}=erm_voice_notes_model:build([Train]),
    ?assertMatch(#{status:=unavailable,reason:=no_independent_reference,seen_in_training:=true},
        erm_voice_notes_model:score(Train,M)),
    ?assertMatch({error,duplicate_recording_in_dataset},erm_voice_notes_model:build([Train,Train#{split:=validation}])),
    {ok,M2}=erm_voice_notes_model:build(dataset()),
    ?assertMatch(#{status:=unavailable,reason:=duplicate_audio_across_development_and_test},
        erm_voice_notes_model:evaluate([Train#{split:=test}],M2)).
uncalibrated_is_not_acceptance_test()->
    {ok,M}=erm_voice_notes_model:build([row(1,<<"Steven">>,train,10)]),
    R=erm_voice_notes_model:score(row(2,<<"Steven">>,test,11),M),
    ?assertEqual(uncalibrated,maps:get(status,R)),?assertNot(maps:is_key(accepted,R)),
    ?assertMatch(#{status:=unavailable},erm_voice_notes_model:evaluate([],M)).
failed_validation_test()->
    {ok,M}=erm_voice_notes_model:build([row(1,<<"Steven">>,train,10),row(2,<<"Other">>,train,100),
        row(3,<<"Steven">>,validation,99),row(4,<<"Other">>,validation,101)]),
    ?assertMatch(#{status:=uncalibrated},maps:get(calibration,M)).
store_restart_and_original_pcm_test()->
    Root=temp(),{ok,Root}=erm_voice_notes_store:open(Root),
    PCM=pcm(1000),{ok,N,F}=erm_voice_notes_store:begin_note(Root,"fixture microphone"),
    ok=file:write(F,PCM),{ok,Saved}=erm_voice_notes_store:finish(Root,N,F,#{ended_by=>test}),
    Id=maps:get(id,N),
    {ok,[Saved]}=erm_voice_notes_store:list(Root),
    {ok,PCM}=erm_voice_notes_store:pcm(Root,Id,0,1000),
    {ok,#file_info{mode=Mode}}=file:read_file_info(erm_voice_notes_store:wav_path(Root,Id)),
    ?assertEqual(0,Mode band 8#077),
    ?assertMatch({error,invalid_note_id},erm_voice_notes_store:get(Root,<<"../../etc/passwd">>)),
    cleanup(Root).

service_record_review_restart_test_()->{timeout,20,fun()->
    Root=temp(),Fixture=Root++".pcm",PCM=pcm(2200),ok=file:write_file(Fixture,PCM),
    Opts=#{directory=>Root,audio_binary=>audio(),test_pcm=>Fixture,test_playback=>true,max_recording_ms=>4000},
    {ok,P}=erm_voice_notes:start_link(Opts),
    ?assertEqual(ok,erm_voice_notes:record()),
    ?assertMatch({error,audio_busy},erm_voice_notes:record()),
    await(fun()->maps:get(phase,erm_voice_notes:status())=:=idle end,5000),
    [N]=erm_voice_notes:notes(),Id=maps:get(id,N),
    ?assertEqual(2200,maps:get(duration_ms,N)),
    {ok,PCM}=erm_voice_notes_store:pcm(Root,Id,0,2200),
    await(fun()->maps:get(jobs,erm_voice_notes:status())=:=[] end,10000),
    ?assertMatch({ok,#{analysis:=#{status:=ready,q:=[_|_]},transcription:=#{status:=unavailable}}},erm_voice_notes:note(Id)),
    ok=erm_voice_notes:review(Id,<<"Steven">>,train,<<"Human corrected reference text">>),
    ?assertMatch(#{model:=#{training_count:=1}},erm_voice_notes:status()),
    ?assertEqual(ok,erm_voice_notes:play(Id)),
    await(fun()->maps:get(phase,erm_voice_notes:status())=:=idle end,3000),
    ok=erm_voice_notes:stop(),await(fun()->not is_process_alive(P) end,1000),
    {ok,_}=erm_voice_notes:start_link(Opts),
    ?assertMatch({ok,#{speaker:= <<"Steven">>,corrected_transcript:= <<"Human corrected reference text">>}},erm_voice_notes:note(Id)),
    ok=erm_voice_notes:review(Id,<<"Steven">>,exclude,<<"Human corrected reference text">>),
    ?assertEqual(undefined,maps:get(model,erm_voice_notes:status())),
    ok=erm_voice_notes:stop(),{ok,_}=erm_voice_notes:start_link(Opts),
    ?assertEqual(undefined,maps:get(model,erm_voice_notes:status())),
    ok=erm_voice_notes:stop(),file:delete(Fixture),cleanup(Root)
end}.
quit_commits_partial_note_test_()->{timeout,10,fun()->
    Root=temp(),Fixture=Root++".pcm",ok=file:write_file(Fixture,pcm(4000)),
    {ok,_}=erm_voice_notes:start_link(#{directory=>Root,audio_binary=>audio(),test_pcm=>Fixture}),
    ok=erm_voice_notes:record(),await(fun()->maps:get(recorded_ms,erm_voice_notes:status())>=100 end,2000),
    ok=erm_voice_notes:stop(),{ok,[N]}=erm_voice_notes_store:list(Root),
    ?assert(maps:get(duration_ms,N)>=100),?assert(maps:get(duration_ms,N)<4000),
    file:delete(Fixture),cleanup(Root)
end}.
missing_microphone_is_recoverable_test_()->{timeout,5,fun()->
    Root=temp(),{ok,_}=erm_voice_notes:start_link(#{directory=>Root,audio_binary=>audio(),input_device=>"/dev/snd/pcmC99D99c"}),
    ok=erm_voice_notes:record(),await(fun()->maps:get(phase,erm_voice_notes:status())=:=idle end,2000),
    ?assertEqual([],erm_voice_notes:notes()),
    ?assertMatch({recording_failed,_,_,_},maps:get(last,erm_voice_notes:status())),
    ok=erm_voice_notes:stop(),cleanup(Root)
end}.

transcription_and_edit_race_test_()->{timeout,15,fun()->
    Root=temp(),Fixture=Root++".pcm",Model=Root++".model",
    ok=file:write_file(Fixture,pcm(1800)),ok=file:write_file(Model,<<"ok">>),
    Opts=#{directory=>Root,audio_binary=>audio(),test_pcm=>Fixture,
        whisper_cli=>filename:absname("apps/erm/test/voice_notes/fake_transcriber.py"),whisper_model=>Model},
    {ok,_}=erm_voice_notes:start_link(Opts),ok=erm_voice_notes:record(),
    await(fun()->length(erm_voice_notes:notes())=:=1 end,4000),[N]=erm_voice_notes:notes(),Id=maps:get(id,N),
    ok=erm_voice_notes:review(Id,<<"Steven">>,train,<<"Manually corrected words">>),
    await(fun()->maps:get(jobs,erm_voice_notes:status())=:=[] end,6000),
    ?assertMatch({ok,#{transcript:= <<"Fixture transcript, not recognised speech.">>,
        corrected_transcript:= <<"Manually corrected words">>,transcription:=#{status:=ready}}},erm_voice_notes:note(Id)),
    {ok,Dataset}=erm_voice_notes:export_dataset(),{ok,[#{source:={wav,Wav}}]}=erm_voice_notes_store:read_term(Dataset,65536),
    ?assertMatch({ok,#{pcm:=_}},ecai_voice_wav:read(Wav)),
    ok=erm_voice_notes:stop(),file:delete(Fixture),file:delete(Model),cleanup(Root)
end}.
transcription_timeout_test_()->{timeout,5,fun()->
    Root=temp(),{ok,Root}=erm_voice_notes_store:open(Root),Model=Root++".model",
    ok=file:write_file(Model,<<"timeout">>),
    R=erm_voice_notes_analysis:transcribe(Root,#{id=> <<"1234567890123456-0123456789abcdef">>},
      #{whisper_cli=>filename:absname("apps/erm/test/voice_notes/fake_transcriber.py"),
        whisper_model=>Model,transcription_timeout_ms=>50}),
    ?assertMatch(#{status:=failed,reason:={error,transcription_timeout}},R),
    file:delete(Model),cleanup(Root)
end}.

dataset()->[row(1,<<"Steven">>,train,10),row(2,<<"Other">>,train,100),
    row(3,<<"Steven">>,validation,11),row(4,<<"Other">>,validation,101),row(5,<<"unknown">>,validation,240)].
row(Id,L,Split,Q)->#{id=>integer_to_binary(Id),speaker=>L,split=>Split,
    pcm_sha256=>crypto:hash(sha256,integer_to_binary(Id)),
    analysis=>#{frontend=>ecai_voice_features:version(),q=>lists:duplicate(30,Q)}}.
pcm(Ms)-> << <<(round(7000*math:sin(2*math:pi()*130*I/16000)+2500*math:sin(2*math:pi()*390*I/16000))):16/little-signed>>
    ||I<-lists:seq(0,Ms*16-1)>>.
temp()->filename:join("/tmp","erm-notes-test-"++integer_to_list(erlang:unique_integer([positive]))).
audio()->filename:absname("apps/erm/priv/bin/erm_voice_notes_audio").
cleanup(Root)->file:del_dir_r(Root).
await(F,Ms)->await(F,erlang:monotonic_time(millisecond)+Ms,undefined).
await(F,Deadline,_)->case F() of true->ok;false->
    case erlang:monotonic_time(millisecond)>=Deadline of true->error(timeout);false->timer:sleep(20),await(F,Deadline,undefined) end end.
