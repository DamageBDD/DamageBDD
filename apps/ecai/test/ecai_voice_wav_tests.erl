-module(ecai_voice_wav_tests).
-include_lib("eunit/include/eunit.hrl").

roundtrip_test() ->
    PCM = <<-32768:16/little-signed, 0:16/little-signed, 32767:16/little-signed>>,
    {ok, Bin} = ecai_voice_wav:encode_mono(PCM),
    {ok, A} = ecai_voice_wav:decode(Bin),
    ?assertEqual(PCM, maps:get(pcm, A)),
    ?assertEqual(16000, maps:get(sample_rate, A)),
    ?assertEqual(0, maps:get(selected_channel, A)),
    ?assertEqual(32, byte_size(maps:get(pcm_sha256, A))).

antiphase_stereo_test() ->
    Stereo =
        <<1000:16/little-signed, -1000:16/little-signed, -1000:16/little-signed,
            1000:16/little-signed>>,
    Bin = wave([chunk(<<"fmt ">>, fmt(2, 16000)), chunk(<<"data">>, Stereo)]),
    {ok, Left} = ecai_voice_wav:decode(Bin),
    {ok, Right} = ecai_voice_wav:decode(Bin, 1),
    ?assertEqual(<<1000:16/little-signed, -1000:16/little-signed>>, maps:get(pcm, Left)),
    ?assertEqual(<<-1000:16/little-signed, 1000:16/little-signed>>, maps:get(pcm, Right)).

higher_variance_channel_test() ->
    Stereo =
        <<0:16/little-signed, 1000:16/little-signed, 0:16/little-signed, -1000:16/little-signed>>,
    Bin = wave([chunk(<<"fmt ">>, fmt(2, 16000)), chunk(<<"data">>, Stereo)]),
    {ok, Audio} = ecai_voice_wav:decode(Bin),
    ?assertEqual(1, maps:get(selected_channel, Audio)).

odd_chunk_padding_test() ->
    Bin = wave([
        chunk(<<"JUNK">>, <<1, 2, 3>>),
        chunk(<<"data">>, <<1, 0>>),
        chunk(<<"fmt ">>, fmt(1, 16000))
    ]),
    {ok, A} = ecai_voice_wav:decode(Bin),
    ?assertEqual(<<1, 0>>, maps:get(pcm, A)).

reject_bad_formats_test() ->
    ?assertEqual({error, malformed_riff_wave}, ecai_voice_wav:decode(<<"not a wave">>)),
    ?assertEqual({error, invalid_pcm16_or_duration}, ecai_voice_wav:pcm(<<1>>)),
    ?assertEqual({error, invalid_pcm16_or_duration}, ecai_voice_wav:pcm(<<>>)),
    ?assertEqual(
        {error, {unsupported_sample_rate, 8000, 16000}},
        ecai_voice_wav:decode(wave([chunk(<<"fmt ">>, fmt(1, 8000)), chunk(<<"data">>, <<0, 0>>)]))
    ),
    ?assertEqual(
        {error, duplicate_format},
        ecai_voice_wav:decode(
            wave([
                chunk(<<"fmt ">>, fmt(1, 16000)),
                chunk(<<"fmt ">>, fmt(1, 16000)),
                chunk(<<"data">>, <<0, 0>>)
            ])
        )
    ),
    ?assertEqual(
        {error, duplicate_data},
        ecai_voice_wav:decode(
            wave([
                chunk(<<"fmt ">>, fmt(1, 16000)),
                chunk(<<"data">>, <<0, 0>>),
                chunk(<<"data">>, <<0, 0>>)
            ])
        )
    ),
    ?assertEqual(
        {error, missing_format}, ecai_voice_wav:decode(wave([chunk(<<"data">>, <<0, 0>>)]))
    ),
    ?assertEqual(
        {error, missing_data}, ecai_voice_wav:decode(wave([chunk(<<"fmt ">>, fmt(1, 16000))]))
    ).

reject_corrupt_lengths_test() ->
    {ok, Bin} = ecai_voice_wav:encode_mono(<<1, 0>>),
    ?assertEqual({error, malformed_riff_wave}, ecai_voice_wav:decode(<<Bin/binary, 0>>)),
    ?assertEqual(
        {error, truncated_wav_chunk}, ecai_voice_wav:decode(wave([<<"JUNK", 10:32/little, 0>>]))
    ),
    ?assertEqual({error, truncated_chunk_header}, ecai_voice_wav:decode(wave([<<1>>]))),
    ?assertEqual({error, channel_not_present}, ecai_voice_wav:decode(Bin, 1)),
    ?assertEqual({error, invalid_wav_or_channel}, ecai_voice_wav:decode(Bin, 7)).

canonical_pcm_duplicate_test() ->
    PCM = <<1:16/little, 2:16/little>>,
    {ok, A} = ecai_voice_wav:pcm(PCM),
    {ok, B} = ecai_voice_wav:decode(
        wave([
            chunk(<<"JUNK">>, <<42>>),
            chunk(<<"fmt ">>, fmt(1, 16000)),
            chunk(<<"data">>, PCM)
        ])
    ),
    ?assertEqual(maps:get(pcm_sha256, A), maps:get(pcm_sha256, B)).

wave(Chunks) ->
    Body = iolist_to_binary(Chunks),
    <<"RIFF", (byte_size(Body) + 4):32/little, "WAVE", Body/binary>>.
chunk(Tag, Body) ->
    Pad = byte_size(Body) band 1,
    <<Tag/binary, (byte_size(Body)):32/little, Body/binary, 0:(Pad * 8)>>.
fmt(C, R) ->
    <<1:16/little, C:16/little, R:32/little, (R * C * 2):32/little, (C * 2):16/little,
        16:16/little>>.
