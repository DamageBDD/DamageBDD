-module(ecai_mic_stream).
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

-define(DEFAULT_SAMPLE_RATE, 16000).
-define(DEFAULT_CHANNELS, 2).
-define(DEFAULT_SAMPLE_BYTES, 2).
-define(DEFAULT_FRAME_MS, 20).
-define(DEFAULT_DEVICE, "default").
-define(DEFAULT_VAD_MODE, energy_zcr).
-define(DEFAULT_VAD_ENERGY_THRESHOLD, 500).
-define(DEFAULT_VAD_ZCR_THRESHOLD, 120).
-define(DEFAULT_HANGOVER_FRAMES, 8).

-record(state, {
    port,
    cmd,
    buffer = <<>>,
    frame_bytes,
    frame_ms,
    sample_rate,
    channels,
    sample_bytes,
    subscribers = #{},
    seq = 0,
    vad_state,
    emit_silence_events = false
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

    SampleRate = maps:get(sample_rate, Opts, ?DEFAULT_SAMPLE_RATE),
    Channels = maps:get(channels, Opts, ?DEFAULT_CHANNELS),
    SampleBytes = maps:get(sample_bytes, Opts, ?DEFAULT_SAMPLE_BYTES),
    FrameMs = maps:get(frame_ms, Opts, ?DEFAULT_FRAME_MS),
    Device = maps:get(device, Opts, ?DEFAULT_DEVICE),
    EmitSilence = maps:get(emit_silence_events, Opts, false),

    VadMode = maps:get(vad_mode, Opts, ?DEFAULT_VAD_MODE),
    VadEnergyThr = maps:get(vad_energy_threshold, Opts, ?DEFAULT_VAD_ENERGY_THRESHOLD),
    VadZcrThr = maps:get(vad_zcr_threshold, Opts, ?DEFAULT_VAD_ZCR_THRESHOLD),
    Hangover = maps:get(vad_hangover_frames, Opts, ?DEFAULT_HANGOVER_FRAMES),

    FrameBytes = frame_bytes(SampleRate, Channels, SampleBytes, FrameMs),
    VadState = ecai_vad:init(#{
        mode => VadMode,
        energy_threshold => VadEnergyThr,
        zcr_threshold => VadZcrThr,
        hangover_frames => Hangover
    }),

    Cmd = build_arecord_cmd(Device, SampleRate, Channels),
    Port = open_capture_port(Cmd),

    {ok, #state{
        port = Port,
        cmd = Cmd,
        frame_bytes = FrameBytes,
        frame_ms = FrameMs,
        sample_rate = SampleRate,
        channels = Channels,
        sample_bytes = SampleBytes,
        vad_state = VadState,
        emit_silence_events = EmitSilence
    }}.

handle_call(stop, _From, State = #state{port = Port}) ->
    close_port(Port),
    {stop, normal, ok, State};
handle_call({subscribe, Pid}, _From, State = #state{subscribers = Subs}) ->
    _Ref = erlang:monitor(process, Pid),
    NewSubs = maps:put(Pid, true, Subs),
    {reply, ok, State#state{subscribers = NewSubs}};
handle_call({unsubscribe, Pid}, _From, State = #state{subscribers = Subs}) ->
    NewSubs = maps:remove(Pid, Subs),
    {reply, ok, State#state{subscribers = NewSubs}};
handle_call(_Req, _From, State) ->
    {reply, {error, unsupported}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({Port, {data, Data}}, State0 = #state{port = Port}) when is_binary(Data) ->
    Buf0 = State0#state.buffer,
    State1 = State0#state{buffer = <<Buf0/binary, Data/binary>>},
    {Frames, Rest} = take_frames_zero_copy(State1#state.buffer, State1#state.frame_bytes),
    State2 = process_frames(Frames, State1#state{buffer = Rest}),
    {noreply, State2};
handle_info({Port, eof}, State = #state{port = Port}) ->
    close_port(Port),
    {stop, capture_eof, State};
handle_info({'EXIT', Port, Reason}, State = #state{port = Port}) ->
    {stop, {capture_exit, Reason}, State};
handle_info({'DOWN', _Ref, process, Pid, _Reason}, State = #state{subscribers = Subs}) ->
    NewSubs = maps:remove(Pid, Subs),
    {noreply, State#state{subscribers = NewSubs}};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{port = Port}) ->
    close_port(Port),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

frame_bytes(SampleRate, Channels, SampleBytes, FrameMs) ->
    ((SampleRate * Channels * SampleBytes) * FrameMs) div 1000.

build_arecord_cmd(Device, SampleRate, Channels) ->
    lists:flatten(
        io_lib:format(
            "arecord -q -D ~s -t raw -f S16_LE -r ~B -c ~B",
            [Device, SampleRate, Channels]
        )
    ).

open_capture_port(Cmd) ->
    open_port({spawn, Cmd}, [
        binary,
        exit_status,
        use_stdio,
        stderr_to_stdout,
        eof
    ]).

close_port(undefined) ->
    ok;
close_port(Port) when is_port(Port) ->
    catch port_close(Port),
    ok.

take_frames_zero_copy(Bin, FrameBytes) ->
    take_frames_zero_copy(Bin, FrameBytes, []).

take_frames_zero_copy(Bin, FrameBytes, Acc) ->
    BinSize = byte_size(Bin),
    if
        BinSize >= FrameBytes ->
            Frame = binary:part(Bin, 0, FrameBytes),
            RestSize = BinSize - FrameBytes,
            Rest = binary:part(Bin, FrameBytes, RestSize),
            take_frames_zero_copy(Rest, FrameBytes, [Frame | Acc]);
        true ->
            {lists:reverse(Acc), Bin}
    end.

process_frames([], State) ->
    State;
process_frames([Frame | Rest], State0) ->
    Seq0 = State0#state.seq,
    SR = State0#state.sample_rate,
    Ch = State0#state.channels,
    FrameMs = State0#state.frame_ms,
    Subs = State0#state.subscribers,
    Vad0 = State0#state.vad_state,
    EmitSilence = State0#state.emit_silence_events,

    Metadata = #{
        seq => Seq0,
        sample_rate => SR,
        channels => Ch,
        frame_ms => FrameMs
    },

    Frame1 =
        case Ch of
            2 -> stereo_to_mono(Frame);
            _ -> Frame
        end,
    {VadDecision, Vad1, VadFeatures} = ecai_vad:classify(Frame1, Vad0),

    case VadDecision of
        speech ->
            Event =
                case ecai_audio_frame:encode(Frame1, Metadata#{vad => VadFeatures}) of
                    {ok, PointEvent} ->
                        %?LOG_DEBUG("ecai_mic_stream got speech point ~p",[PointEvent]),
                        PointEvent#{vad_decision => speech};
                    {error, Reason} ->
                        ?LOG_DEBUG("ecai_mic_stream got speech point fail ~p", [Reason]),
                        #{
                            type => ecai_audio_frame_error,
                            seq => Seq0,
                            reason => Reason,
                            metadata => Metadata,
                            vad => VadFeatures,
                            vad_decision => speech
                        }
                end,
            broadcast(Event, Subs),
            process_frames(Rest, State0#state{seq = Seq0 + 1, vad_state = Vad1});
        silence ->
            case EmitSilence of
                true ->
                    broadcast(
                        #{
                            type => ecai_audio_skipped,
                            seq => Seq0,
                            metadata => Metadata,
                            vad => VadFeatures,
                            vad_decision => silence
                        },
                        Subs
                    );
                false ->
                    ok
            end,
            process_frames(Rest, State0#state{seq = Seq0 + 1, vad_state = Vad1})
    end.

broadcast(Msg, Subs) ->
    maps:foreach(
        fun(Pid, true) ->
            Pid ! {ecai_audio_point, Msg}
        end,
        Subs
    ).
stereo_to_mono(<<L:16/little-signed, R:16/little-signed, Rest/binary>>) ->
    M = (L + R) div 2,
    <<M:16/little-signed, (stereo_to_mono(Rest))/binary>>;
stereo_to_mono(<<>>) ->
    <<>>.
