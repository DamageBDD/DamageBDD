-module(ecai_audio_utterance).
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

-define(DEFAULT_CLOSE_AFTER_MS, 300).
-define(DEFAULT_MAX_FRAMES, 500).
-define(UTT_CLOSE_MSG, utterance_close).

-record(state, {
    subscribers = #{},
    close_after_ms = ?DEFAULT_CLOSE_AFTER_MS,
    max_frames = ?DEFAULT_MAX_FRAMES,
    current = undefined,
    close_timer = undefined
}).

-record(utt, {
    seq_start,
    seq_end,
    first_metadata = #{},
    last_metadata = #{},
    frame_count = 0,
    point_hashes = [],
    point_filename_hashes = [],
    points = []
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
    CloseAfterMs = maps:get(close_after_ms, Opts, ?DEFAULT_CLOSE_AFTER_MS),
    MaxFrames = maps:get(max_frames, Opts, ?DEFAULT_MAX_FRAMES),

    ok = ecai_mic_stream:subscribe(),

    {ok, #state{
        close_after_ms = CloseAfterMs,
        max_frames = MaxFrames
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

handle_info({ecai_audio_point, Event}, State0) when is_map(Event) ->
    {noreply, handle_audio_event(Event, State0)};
handle_info(?UTT_CLOSE_MSG, State0) ->
    State1 = emit_and_reset(State0),
    {noreply, State1#state{close_timer = undefined}};
handle_info({'DOWN', _Ref, process, Pid, _Reason}, State = #state{subscribers = Subs}) ->
    {noreply, State#state{subscribers = maps:remove(Pid, Subs)}};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    maybe_cancel_timer(State#state.close_timer),
    catch ecai_mic_stream:unsubscribe(),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

handle_audio_event(#{type := ecai_audio_point, vad_decision := speech} = Event, State0) ->
    State1 = maybe_cancel_close(State0),
    State2 = append_speech_frame(Event, State1),
    maybe_force_close(State2);
handle_audio_event(#{type := ecai_audio_skipped, vad_decision := silence}, State0) ->
    ensure_close_timer(State0);
handle_audio_event(#{type := ecai_audio_frame_error, vad_decision := speech} = Event, State0) ->
    ?LOG_WARNING("dropping speech frame error from utterance builder: ~p", [Event]),
    State0;
handle_audio_event(_Event, State0) ->
    State0.

append_speech_frame(Event, State = #state{current = undefined}) ->
    Seq = maps:get(seq, Event),
    Metadata = maps:get(metadata, Event, #{}),
    PointHash = maps:get(payload_hash, Event, <<>>),
    PointFilenameHash = maps:get(point_filename_hash, Event, <<>>),
    Point = maps:get(point, Event, #{}),
    U0 = #utt{
        seq_start = Seq,
        seq_end = Seq,
        first_metadata = Metadata,
        last_metadata = Metadata,
        frame_count = 1,
        point_hashes = [PointHash],
        point_filename_hashes = [PointFilenameHash],
        points = [Point]
    },
    State#state{current = U0};
append_speech_frame(Event, State = #state{current = U0}) ->
    Seq = maps:get(seq, Event),
    Metadata = maps:get(metadata, Event, #{}),
    PointHash = maps:get(payload_hash, Event, <<>>),
    PointFilenameHash = maps:get(point_filename_hash, Event, <<>>),
    Point = maps:get(point, Event, #{}),
    U1 = U0#utt{
        seq_end = Seq,
        last_metadata = Metadata,
        frame_count = U0#utt.frame_count + 1,
        point_hashes = [PointHash | U0#utt.point_hashes],
        point_filename_hashes = [PointFilenameHash | U0#utt.point_filename_hashes],
        points = [Point | U0#utt.points]
    },
    State#state{current = U1}.

ensure_close_timer(State = #state{current = undefined}) ->
    State;
ensure_close_timer(State = #state{close_timer = undefined, close_after_ms = Ms}) ->
    TRef = erlang:send_after(Ms, self(), ?UTT_CLOSE_MSG),
    State#state{close_timer = TRef};
ensure_close_timer(State) ->
    State.

maybe_cancel_close(State = #state{close_timer = undefined}) ->
    State;
maybe_cancel_close(State = #state{close_timer = TRef}) ->
    maybe_cancel_timer(TRef),
    State#state{close_timer = undefined}.

maybe_cancel_timer(undefined) ->
    ok;
maybe_cancel_timer(TRef) ->
    _ = erlang:cancel_timer(TRef),
    ok.

maybe_force_close(State = #state{current = undefined}) ->
    State;
maybe_force_close(State = #state{current = U, max_frames = MaxFrames}) ->
    case U#utt.frame_count >= MaxFrames of
        true -> emit_and_reset(State);
        false -> State
    end.

emit_and_reset(State = #state{current = undefined}) ->
    State;
emit_and_reset(State = #state{current = U, subscribers = Subs}) ->
    Event = utterance_event(U),
    broadcast(Event, Subs),
    State#state{current = undefined}.

utterance_event(U) ->
    PointHashes = lists:reverse(U#utt.point_hashes),
    PointFilenameHashes = lists:reverse(U#utt.point_filename_hashes),
    Points = lists:reverse(U#utt.points),

    AggregateHash = aggregate_hash(PointHashes, U),
    {UttXBin, UttYBin, UttCounter} =
        ecai:hash_to_curve(binary_to_list(binary:encode_hex(AggregateHash))),
    UtteranceId = ecai:point_to_filename_hash({UttXBin, UttYBin, UttCounter}),

    FirstMeta = U#utt.first_metadata,
    LastMeta = U#utt.last_metadata,

    #{
        type => ecai_audio_utterance,
        utterance_id => UtteranceId,
        seq_start => U#utt.seq_start,
        seq_end => U#utt.seq_end,
        frame_count => U#utt.frame_count,
        point_hashes => PointHashes,
        point_filename_hashes => PointFilenameHashes,
        aggregate_hash => AggregateHash,
        aggregate_point => #{
            x_bin => UttXBin,
            y_bin => UttYBin,
            x => binary:decode_unsigned(UttXBin, little),
            y => binary:decode_unsigned(UttYBin, little),
            counter => UttCounter
        },
        metadata => #{
            sample_rate => maps:get(sample_rate, FirstMeta, undefined),
            channels => maps:get(channels, FirstMeta, undefined),
            frame_ms => maps:get(frame_ms, FirstMeta, undefined),
            seq_start => U#utt.seq_start,
            seq_end => U#utt.seq_end
        },
        first_metadata => FirstMeta,
        last_metadata => LastMeta,
        points => Points
    }.

aggregate_hash(PointHashes, U) ->
    Domain = <<"ECAI:AUDIO:UTTERANCE:V1">>,
    SeqStart = U#utt.seq_start,
    SeqEnd = U#utt.seq_end,
    FrameCount = U#utt.frame_count,
    Payload = iolist_to_binary([
        Domain,
        <<SeqStart:64/unsigned-big, SeqEnd:64/unsigned-big, FrameCount:32/unsigned-big>>,
        PointHashes
    ]),
    crypto:hash(sha256, Payload).

broadcast(Msg, Subs) ->
    maps:foreach(
        fun(Pid, true) ->
            Pid ! {ecai_audio_utterance, Msg}
        end,
        Subs
    ).
