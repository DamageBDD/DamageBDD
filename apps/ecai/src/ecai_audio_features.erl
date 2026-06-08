-module(ecai_audio_features).

-export([
    extract/2,
    canonical_binary/1
]).

-define(FEATURES_VERSION, 1).
-define(NUM_BUCKETS, 8).

-spec extract(binary(), map()) -> map().
extract(FrameBin, Metadata) when is_binary(FrameBin), is_map(Metadata) ->
    Samples = decode_pcm16le(FrameBin),
    extract_from_samples(Samples, Metadata).

-spec canonical_binary(map()) -> binary().
canonical_binary(Features) when is_map(Features) ->
    Version = maps:get(version, Features, ?FEATURES_VERSION),
    SampleCount = maps:get(sample_count, Features, 0),
    DcOffset = maps:get(dc_offset, Features, 0),
    MeanAbs = maps:get(mean_abs, Features, 0),
    Rms = maps:get(rms, Features, 0),
    PeakAbs = maps:get(peak_abs, Features, 0),
    Zcr = maps:get(zcr, Features, 0),
    DiffMeanAbs = maps:get(diff_mean_abs, Features, 0),
    BucketEnergyQ = maps:get(bucket_energy_q, Features, []),
    BucketDeltaQ = maps:get(bucket_delta_q, Features, []),

    BucketEnergyBin = encode_u16_list(BucketEnergyQ, ?NUM_BUCKETS),
    BucketDeltaBin = encode_u16_list(BucketDeltaQ, ?NUM_BUCKETS),

    <<Version:16/unsigned-big, SampleCount:16/unsigned-big, (signed16(DcOffset))/binary,
        MeanAbs:16/unsigned-big, Rms:16/unsigned-big, PeakAbs:16/unsigned-big, Zcr:16/unsigned-big,
        DiffMeanAbs:16/unsigned-big, BucketEnergyBin/binary, BucketDeltaBin/binary>>.

extract_from_samples([], Metadata) ->
    Base = base_features(Metadata, 0),
    Base#{
        dc_offset => 0,
        mean_abs => 0,
        rms => 0,
        peak_abs => 0,
        zcr => 0,
        diff_mean_abs => 0,
        bucket_energy_q => lists:duplicate(?NUM_BUCKETS, 0),
        bucket_delta_q => lists:duplicate(?NUM_BUCKETS, 0)
    };
extract_from_samples(Samples, Metadata) ->
    Count = length(Samples),
    Mean = lists:sum(Samples) div Count,
    MeanAbs = lists:sum([abs(S) || S <- Samples]) div Count,
    PeakAbs = lists:max([abs(S) || S <- Samples]),
    Rms = isqrt(lists:sum([S * S || S <- Samples]) div Count),
    Zcr = zero_crossings(Samples),
    DiffMeanAbs = mean_abs_diff(Samples),

    BucketEnergy = bucket_mean_abs(Samples, ?NUM_BUCKETS),
    BucketDelta = bucket_mean_abs_diff(Samples, ?NUM_BUCKETS),

    BucketEnergyQ = quantize_buckets(BucketEnergy, PeakAbs),
    BucketDeltaQ = quantize_buckets(BucketDelta, PeakAbs),

    Base = base_features(Metadata, Count),
    Base#{
        dc_offset => clamp_s16(Mean),
        mean_abs => clamp_u16(MeanAbs),
        rms => clamp_u16(Rms),
        peak_abs => clamp_u16(PeakAbs),
        zcr => clamp_u16(Zcr),
        diff_mean_abs => clamp_u16(DiffMeanAbs),
        bucket_energy_q => BucketEnergyQ,
        bucket_delta_q => BucketDeltaQ
    }.

base_features(Metadata, SampleCount) ->
    #{
        version => ?FEATURES_VERSION,
        sample_count => SampleCount,
        sample_rate => maps:get(sample_rate, Metadata, undefined),
        frame_ms => maps:get(frame_ms, Metadata, undefined)
    }.

decode_pcm16le(Bin) ->
    decode_pcm16le(Bin, []).

decode_pcm16le(<<S:16/little-signed, Rest/binary>>, Acc) ->
    decode_pcm16le(Rest, [S | Acc]);
decode_pcm16le(<<>>, Acc) ->
    lists:reverse(Acc).

zero_crossings([]) ->
    0;
zero_crossings([_]) ->
    0;
zero_crossings([A, B | Rest]) ->
    zero_crossings([B | Rest], sign(A), zcr_step(sign(A), sign(B), 0)).

zero_crossings([], _PrevSign, Count) ->
    Count;
zero_crossings([S | Rest], PrevSign, Count) ->
    Sign = sign(S),
    Count1 = zcr_step(PrevSign, Sign, Count),
    zero_crossings(Rest, Sign, Count1).

zcr_step(0, _Sign, Count) ->
    Count;
zcr_step(Sign, Sign, Count) ->
    Count;
zcr_step(_Prev, 0, Count) ->
    Count;
zcr_step(_Prev, _Sign, Count) ->
    Count + 1.

sign(N) when N > 0 -> 1;
sign(N) when N < 0 -> -1;
sign(_) -> 0.

mean_abs_diff([]) ->
    0;
mean_abs_diff([_]) ->
    0;
mean_abs_diff([A, B | Rest]) ->
    mean_abs_diff([B | Rest], B, 1, abs(B - A)).

mean_abs_diff([], _Prev, Count, Sum) ->
    Sum div Count;
mean_abs_diff([S | Rest], Prev, Count, Sum) ->
    mean_abs_diff(Rest, S, Count + 1, Sum + abs(S - Prev)).

bucket_mean_abs(Samples, Buckets) ->
    Parts = split_buckets(Samples, Buckets),
    [bucket_abs_mean(P) || P <- Parts].

bucket_abs_mean([]) ->
    0;
bucket_abs_mean(L) ->
    lists:sum([abs(X) || X <- L]) div length(L).

bucket_mean_abs_diff(Samples, Buckets) ->
    Parts = split_buckets(Samples, Buckets),
    [bucket_diff_mean(P) || P <- Parts].

bucket_diff_mean([]) ->
    0;
bucket_diff_mean([_]) ->
    0;
bucket_diff_mean([A, B | Rest]) ->
    bucket_diff_mean(Rest, B, 1, abs(B - A)).

bucket_diff_mean([], _Prev, Count, Sum) ->
    Sum div Count;
bucket_diff_mean([S | Rest], Prev, Count, Sum) ->
    bucket_diff_mean(Rest, S, Count + 1, Sum + abs(S - Prev)).

split_buckets(Samples, Buckets) ->
    N = length(Samples),
    case N of
        0 ->
            lists:duplicate(Buckets, []);
        _ ->
            [slice_bucket(Samples, N, Buckets, I) || I <- lists:seq(0, Buckets - 1)]
    end.

slice_bucket(Samples, N, Buckets, I) ->
    Start = (I * N) div Buckets,
    End = ((I + 1) * N) div Buckets,
    Len = End - Start,
    sublist(Samples, Start, Len).

sublist(List, Start, Len) ->
    lists:sublist(lists:nthtail(Start, List), Len).

quantize_buckets(Buckets, PeakAbs) ->
    Denom =
        case PeakAbs of
            0 -> 1;
            _ -> PeakAbs
        end,
    [clamp_u16((B * 65535) div Denom) || B <- Buckets].

encode_u16_list(List, ExpectedLen) ->
    Fixed =
        case length(List) of
            ExpectedLen ->
                List;
            N when N < ExpectedLen ->
                List ++ lists:duplicate(ExpectedLen - N, 0);
            _ ->
                lists:sublist(List, ExpectedLen)
        end,
    iolist_to_binary([<<V:16/unsigned-big>> || V <- Fixed]).

signed16(N) ->
    <<(clamp_s16(N)):16/signed-big>>.

clamp_s16(N) when N < -32768 ->
    -32768;
clamp_s16(N) when N > 32767 ->
    32767;
clamp_s16(N) ->
    N.

clamp_u16(N) when N < 0 ->
    0;
clamp_u16(N) when N > 65535 ->
    65535;
clamp_u16(N) ->
    N.

isqrt(N) when N =< 0 ->
    0;
isqrt(N) ->
    isqrt(N, N).

isqrt(N, X) ->
    Y = (X + (N div X)) div 2,
    case Y >= X of
        true -> X;
        false -> isqrt(N, Y)
    end.
