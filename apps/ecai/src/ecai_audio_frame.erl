-module(ecai_audio_frame).

-export([
    encode/2,
    payload/2
]).

-define(DOMAIN, <<"ECAI:AUDIO:FRAME:V3">>).

encode(FrameBin, Metadata) when is_binary(FrameBin), is_map(Metadata) ->
    try
        Payload = payload(FrameBin, Metadata),
        SafeArg = binary:encode_hex(crypto:hash(sha256, Payload)),
        {XBin, YBin, Counter} = ecai:hash_to_curve(binary_to_list(SafeArg)),
        PointMap = #{
            x_bin => XBin,
            y_bin => YBin,
            x => binary:decode_unsigned(XBin, little),
            y => binary:decode_unsigned(YBin, little),
            counter => Counter
        },
        FilenameHash = ecai:point_to_filename_hash({XBin, YBin, Counter}),
        PayloadHash = crypto:hash(sha256, Payload),
        {ok, #{
            type => ecai_audio_point,
            seq => maps:get(seq, Metadata),
            point => PointMap,
            point_filename_hash => FilenameHash,
            payload_hash => PayloadHash,
            metadata => Metadata
        }}
    catch
        Class:Reason:Stack ->
            {error, {frame_encode_failed, Class, Reason, Stack}}
    end.

payload(FrameBin, Metadata) ->
    Seq = maps:get(seq, Metadata),
    SampleRate = maps:get(sample_rate, Metadata),
    Channels = maps:get(channels, Metadata),
    FrameMs = maps:get(frame_ms, Metadata),
    Vad = maps:get(vad, Metadata, #{}),
    AvgAbs = maps:get(avg_abs, Vad, 0),
    Zcr = maps:get(zcr, Vad, 0),
    RawSpeech = bool_to_u8(maps:get(raw_speech, Vad, false)),
    InSpeech = bool_to_u8(maps:get(in_speech, Vad, false)),
    Hangover = maps:get(hangover_left, Vad, 0),

    <<?DOMAIN/binary, Seq:64/unsigned-big, SampleRate:32/unsigned-big, Channels:16/unsigned-big,
        FrameMs:16/unsigned-big, AvgAbs:32/unsigned-big, Zcr:32/unsigned-big, RawSpeech:8/unsigned,
        InSpeech:8/unsigned, Hangover:16/unsigned-big, (byte_size(FrameBin)):32/unsigned-big,
        FrameBin/binary>>.

bool_to_u8(true) -> 1;
bool_to_u8(false) -> 0.
