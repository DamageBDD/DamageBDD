-module(ecai_voice_notes_tests).
-include_lib("eunit/include/eunit.hrl").
-export([wav/0]).

wav() ->
    PCM = << <<(round(6000 * math:sin(2 * math:pi() * 220 * I / 16000))):16/little-signed>> || I <- lists:seq(1,16000) >>,
    {ok, Wav} = ecai_voice_wav:encode_mono(PCM), Wav.

limits_and_validation_test() ->
    {ok, C} = ecai_voice_notes:config(),
    ?assertEqual(false, maps:get(enabled, C)),
    ?assertMatch({ok, _, 1000}, ecai_voice_notes:normalize(wav(), wav, C)),
    {ok, Silence} = ecai_voice_wav:encode_mono(binary:copy(<<0>>,32000)),
    ?assertEqual({error,no_speech}, ecai_voice_notes:normalize(Silence, wav, C)),
    ?assertEqual({error,invalid_audio}, ecai_voice_notes:normalize(wav(), webm, C)),
    ?assertEqual({error,invalid_audio}, ecai_voice_notes:normalize(<<"OggSbad">>, ogg, C)),
    ?assertEqual({error,body_too_large}, ecai_voice_notes:normalize(binary:copy(<<0>>,2097153),webm,C)),
    ?assertEqual({error,voice_disabled}, ecai_voice_notes:transcribe(wav(),wav,#{language=><<"en">>,cleanup=>false})),
    ?assertEqual({ok,webm},ecai_voice_notes:media_type(<<"audio/webm;codecs=opus">>)),
    ?assertEqual({error,unsupported_media_type},ecai_voice_notes:media_type(<<"text/html">>)),
    ?assertMatch({ok,#{language:=<<"ml">>}},ecai_voice_notes:request_options(<<"ml">>,<<"1">>)),
    ?assertEqual({error,invalid_request},ecai_voice_notes:request_options(<<"en\r\nX: injected">>,<<"0">>)).

configuration_test() ->
    Old=application:get_env(ecai,voice_notes),
    try
        [begin application:set_env(ecai,voice_notes,C),
            ?assertEqual({error,voice_config_invalid},ecai_voice_notes:config()) end || C <- [
            #{max_duration_ms=>60000},#{max_audio_bytes=>99999999},#{enabled=><<"true">>},
            #{whisper_host=>"remote.example"},#{ollama_host=>"remote.example"},
            #{cleanup_enabled=>true},#{whisper_path=>"/inference\r\nHost: bad"},#{unexpected=>true}]],
        application:set_env(ecai,voice_notes,#{cleanup_enabled=>true,ollama_model=><<"fixture">>}),
        ?assertMatch({ok,_},ecai_voice_notes:config())
    after restore(Old) end.

transcript_validation_test() ->
    ?assertEqual({ok,<<"hello">>},ecai_voice_notes:decode_transcript(<<"{\"text\":\" hello \\n\"}">>)),
    ?assertEqual({error,no_speech},ecai_voice_notes:decode_transcript(<<"{\"text\":\" \"}">>)),
    ?assertEqual({error,transcription_unavailable},ecai_voice_notes:decode_transcript(<<"{\"text\":[]}">>)),
    ?assertEqual({error,transcription_unavailable},ecai_voice_notes:decode_transcript(<<"private failure body">>)),
    ?assertEqual({error,transcription_unavailable},ecai_voice_notes:decode_transcript(jsx:encode(#{text=>binary:copy(<<"x">>,16001)}))).

compressed_codecs_test_() -> {timeout,30,fun() ->
    %% The test runner generates real Opus/WebM, Opus/Ogg and AAC/MP4 fixtures.
    Dir=os:getenv("VOICE_NOTE_FIXTURES"),?assert(is_list(Dir)),
    {ok,C}=ecai_voice_notes:config(),
    [begin {ok,Audio}=file:read_file(filename:join(Dir,"note."++Ext)),
        {ok,Wav,Ms}=ecai_voice_notes:normalize(Audio,Type,C#{temp_dir=>Dir}),
        ?assert(Ms>=900 andalso Ms=<1200),?assertMatch({ok,_},ecai_voice_wav:decode(Wav))
     end || {Ext,Type} <- [{"webm",webm},{"ogg",ogg},{"mp4",mp4}]],
    {ok,Long}=file:read_file(filename:join(Dir,"long.webm")),
    ?assertEqual({error,audio_too_long},ecai_voice_notes:normalize(Long,webm,C#{max_duration_ms=>1000,temp_dir=>Dir})),
    ?assertEqual([],filelib:wildcard(filename:join(Dir,"ecai-note-*")))
end}.

multipart_test() ->
    W=wav(),{Type,Body}=ecai_voice_notes:multipart(W,<<"ta">>),
    ?assertMatch(<<"multipart/form-data; boundary=",_/binary>>,Type),
    ?assertNotEqual(nomatch,binary:match(Body,W)),
    ?assertNotEqual(nomatch,binary:match(Body,<<"name=\"language\"\r\n\r\nta">>)),
    ?assertNotEqual(nomatch,binary:match(Body,<<"filename=\"note.wav\"">>)).

restore(undefined) -> application:unset_env(ecai,voice_notes);
restore({ok,C}) -> application:set_env(ecai,voice_notes,C).
