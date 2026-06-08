-module(ecai_audio_utterance_verify).
-behaviour(gen_server).

-export([
    start_link/0,
    start_link/1,
    stop/0,
    subscribe/0,
    unsubscribe/0
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-include_lib("kernel/include/logger.hrl").

-define(DEFAULT_MIN_DURATION_MS, 250).
-define(DEFAULT_MAX_DURATION_MS, 6000).
-define(DEFAULT_MIN_FRAMES, 8).
-define(DEFAULT_MIN_AVG_ENERGY, 700).
-define(DEFAULT_MAX_SILENCE_RATIO, 0.35).
-define(DEFAULT_MIN_POINT_DIVERSITY_RATIO, 0.20).

-record(state, {
    subscribers = #{},
    min_duration_ms = ?DEFAULT_MIN_DURATION_MS,
    max_duration_ms = ?DEFAULT_MAX_DURATION_MS,
    min_frames = ?DEFAULT_MIN_FRAMES,
    min_avg_energy = ?DEFAULT_MIN_AVG_ENERGY,
    max_silence_ratio = ?DEFAULT_MAX_SILENCE_RATIO,
    min_point_diversity_ratio = ?DEFAULT_MIN_POINT_DIVERSITY_RATIO,
    accept_candidates = false
}).

start_link() ->
    start_link(#{}).

start_link(Opts) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Opts, []).

stop() ->
    gen_server:call(?MODULE, stop).

subscribe() ->
    gen_server:call(?MODULE, {subscribe, self()}).

unsubscribe() ->
    gen_server:call(?MODULE, {unsubscribe, self()}).

init(Opts) ->
    process_flag(trap_exit, true),
    ok = ecai_audio_utterance:subscribe(),
    {ok, #state{
        min_duration_ms = maps:get(min_duration_ms, Opts, ?DEFAULT_MIN_DURATION_MS),
        max_duration_ms = maps:get(max_duration_ms, Opts, ?DEFAULT_MAX_DURATION_MS),
        min_frames = maps:get(min_frames, Opts, ?DEFAULT_MIN_FRAMES),
        min_avg_energy = maps:get(min_avg_energy, Opts, ?DEFAULT_MIN_AVG_ENERGY),
        max_silence_ratio = maps:get(max_silence_ratio, Opts, ?DEFAULT_MAX_SILENCE_RATIO),
        min_point_diversity_ratio = maps:get(
            min_point_diversity_ratio,
            Opts,
            ?DEFAULT_MIN_POINT_DIVERSITY_RATIO
        ),
        accept_candidates = maps:get(accept_candidates, Opts, false)
    }}.

handle_call(stop, _From, State) ->
    {stop, normal, ok, State};
handle_call({subscribe, Pid}, _From, State = #state{subscribers = Subs}) ->
    _Ref = erlang:monitor(process, Pid),
    {reply, ok, State#state{subscribers = maps:put(Pid, true, Subs)}};
handle_call({unsubscribe, Pid}, _From, State = #state{subscribers = Subs}) ->
    {reply, ok, State#state{subscribers = maps:remove(Pid, Subs)}};
handle_call(_Req, _From, State) ->
    {reply, {error, unsupported}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({ecai_audio_utterance, Utt}, State) when is_map(Utt) ->
    DecisionEvent = verify_utterance(Utt, State),
    broadcast(DecisionEvent, State#state.subscribers),
    {noreply, State};
handle_info({'DOWN', _Ref, process, Pid, _Reason}, State = #state{subscribers = Subs}) ->
    {noreply, State#state{subscribers = maps:remove(Pid, Subs)}};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    catch ecai_audio_utterance:unsubscribe(),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

verify_utterance(Utt, State) ->
    Quality = quality(Utt),
    Checks = checks(Utt, Quality, State),
    Decision = decide(Checks, State#state.accept_candidates),
    Score = score(Quality, Checks),
    #{
        type => ecai_audio_utterance_verification,
        utterance_id => maps:get(utterance_id, Utt, undefined),
        decision => Decision,
        score => Score,
        reasons => failure_reasons(Checks),
        quality => Quality,
        utterance => Utt
    }.

quality(Utt) ->
    FrameCount = maps:get(frame_count, Utt, 0),
    Meta = maps:get(metadata, Utt, #{}),
    FrameMs = maps:get(frame_ms, Meta, 20),
    DurationMs = FrameCount * FrameMs,

    FirstMeta = maps:get(first_metadata, Utt, #{}),
    LastMeta = maps:get(last_metadata, Utt, #{}),

    FirstVad = maps:get(vad, FirstMeta, #{}),
    LastVad = maps:get(vad, LastMeta, #{}),

    %% Current utterance objects do not explicitly track silence frames
    %% or closure reason, so we derive what we can and leave clear placeholders.
    PointHashes = maps:get(point_hashes, Utt, []),
    UniquePointHashes = ordsets:from_list(PointHashes),
    DiversityRatio =
        case FrameCount of
            0 -> 0.0;
            _ -> length(UniquePointHashes) / FrameCount
        end,

    AvgAbsMean = mean_vad_energy(Utt),
    SilenceRatio = estimated_silence_ratio(Utt),
    ClosedBy = maps:get(closed_by, Utt, inferred_natural_silence),

    #{
        duration_ms => DurationMs,
        frame_count => FrameCount,
        avg_abs_mean => AvgAbsMean,
        silence_ratio => SilenceRatio,
        point_diversity_ratio => DiversityRatio,
        closed_by => ClosedBy,
        first_hangover_left => maps:get(hangover_left, FirstVad, undefined),
        last_hangover_left => maps:get(hangover_left, LastVad, undefined)
    }.

mean_vad_energy(Utt) ->
    PointsMeta = collect_vad_energies(Utt),
    case PointsMeta of
        [] -> 0;
        L -> lists:sum(L) div length(L)
    end.

collect_vad_energies(Utt) ->
    case maps:get(points, Utt, undefined) of
        undefined ->
            [];
        Points when is_list(Points) ->
            [];
        _ ->
            []
    end.

%% Placeholder until silence frames are tracked explicitly in utterance builder.
estimated_silence_ratio(_Utt) ->
    0.0.

checks(Utt, Quality, State) ->
    DurationMs = maps:get(duration_ms, Quality),
    FrameCount = maps:get(frame_count, Quality),
    AvgAbsMean = maps:get(avg_abs_mean, Quality),
    SilenceRatio = maps:get(silence_ratio, Quality),
    DiversityRatio = maps:get(point_diversity_ratio, Quality),
    ClosedBy = maps:get(closed_by, Quality),

    #{
        duration_min_ok => DurationMs >= State#state.min_duration_ms,
        duration_max_ok => DurationMs =< State#state.max_duration_ms,
        min_frames_ok => FrameCount >= State#state.min_frames,
        min_avg_energy_ok => AvgAbsMean >= State#state.min_avg_energy,
        silence_ratio_ok => SilenceRatio =< State#state.max_silence_ratio,
        point_diversity_ok => DiversityRatio >= State#state.min_point_diversity_ratio,
        closed_naturally_ok => (ClosedBy =:= natural_silence) orelse
            (ClosedBy =:= inferred_natural_silence),
        has_aggregate_hash_ok => maps:is_key(aggregate_hash, Utt)
    }.

decide(Checks, AcceptCandidates) ->
    AllRequired =
        maps:get(duration_min_ok, Checks) andalso
            maps:get(duration_max_ok, Checks) andalso
            maps:get(min_frames_ok, Checks) andalso
            maps:get(min_avg_energy_ok, Checks) andalso
            maps:get(silence_ratio_ok, Checks) andalso
            maps:get(point_diversity_ok, Checks) andalso
            maps:get(closed_naturally_ok, Checks) andalso
            maps:get(has_aggregate_hash_ok, Checks),

    case AllRequired of
        true ->
            accepted;
        false ->
            case AcceptCandidates andalso candidateish(Checks) of
                true -> candidate;
                false -> rejected
            end
    end.

candidateish(Checks) ->
    maps:get(duration_min_ok, Checks) andalso
        maps:get(duration_max_ok, Checks) andalso
        maps:get(min_frames_ok, Checks) andalso
        maps:get(has_aggregate_hash_ok, Checks).

score(Quality, Checks) ->
    Base = 100,
    Penalties =
        penalty(not maps:get(duration_min_ok, Checks), 20) +
            penalty(not maps:get(duration_max_ok, Checks), 15) +
            penalty(not maps:get(min_frames_ok, Checks), 20) +
            penalty(not maps:get(min_avg_energy_ok, Checks), 20) +
            penalty(not maps:get(silence_ratio_ok, Checks), 10) +
            penalty(not maps:get(point_diversity_ok, Checks), 10) +
            penalty(not maps:get(closed_naturally_ok, Checks), 5),

    Raw = Base - Penalties,
    erlang:max(0, erlang:min(100, Raw)).

penalty(true, N) -> N;
penalty(false, _N) -> 0.

failure_reasons(Checks) ->
    Pairs = [
        {duration_too_short, maps:get(duration_min_ok, Checks)},
        {duration_too_long, maps:get(duration_max_ok, Checks)},
        {too_few_frames, maps:get(min_frames_ok, Checks)},
        {energy_too_low, maps:get(min_avg_energy_ok, Checks)},
        {silence_ratio_too_high, maps:get(silence_ratio_ok, Checks)},
        {point_diversity_too_low, maps:get(point_diversity_ok, Checks)},
        {not_closed_naturally, maps:get(closed_naturally_ok, Checks)},
        {missing_aggregate_hash, maps:get(has_aggregate_hash_ok, Checks)}
    ],
    [Reason || {Reason, false} <- Pairs].

broadcast(Msg, Subs) ->
    maps:foreach(
        fun(Pid, true) ->
            Pid ! {ecai_audio_utterance_verification, Msg}
        end,
        Subs
    ).
