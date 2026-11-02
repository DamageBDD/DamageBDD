%% Enrolled whole-phrase commands. Optional alternative to erm_native_voice,
%% not another microphone consumer beside it. Only this process may dispatch.
-module(erm_phrase_voice).
-behaviour(gen_server).
-export([start_link/1, status/0, enrol/2, cancel_enrol/0,
    observe_only/1, pause/0, resume/0, forget/1,
    lab_begin/0, lab_capture/1, lab_cancel/1, lab_end/1, lab_train/2, lab_profile/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-record(st, {opts, speaker, binding, samples = [], port = undefined,
    phase = disconnected, config_ack = false, profile_ack = false,
    config_epoch = 0, revision = 1, epoch = 0, armed = false,
    busy = false, inflight = undefined, received = false, last_id = 0,
    paused = false, observe = true, enrol = undefined, last = undefined,
    error = undefined, timer = undefined, retry = undefined, poll = undefined,
    next_arm = 0, lab = undefined, calibration = undefined,
    speaker_meta = undefined}).

start_link(Options) -> gen_server:start_link({local, ?MODULE}, ?MODULE, Options, []).
status() -> gen_server:call(?MODULE, status, 2000).
enrol(Action, Count) -> gen_server:call(?MODULE, {enrol, Action, Count}, 5000).
cancel_enrol() -> gen_server:call(?MODULE, cancel_enrol, 5000).
observe_only(Bool) -> gen_server:call(?MODULE, {observe, Bool}, 5000).
pause() -> gen_server:call(?MODULE, {paused, true}, 5000).
resume() -> gen_server:call(?MODULE, {paused, false}, 5000).
forget(Action) -> gen_server:call(?MODULE, {forget, Action}, 5000).

%% A monitored, exclusive test reservation. Local trusted callers only.
lab_begin() -> gen_server:call(?MODULE, lab_begin, 5000).
lab_capture(Ref) -> gen_server:call(?MODULE, {lab_capture, Ref}, 5000).
lab_cancel(Ref) -> gen_server:call(?MODULE, {lab_cancel, Ref}, 5000).
lab_end(Ref) -> gen_server:call(?MODULE, {lab_end, Ref}, 5000).
lab_profile(Ref, Request) -> gen_server:call(?MODULE, {lab_profile, Ref, Request}, 10000).
lab_train(Ref, Samples) -> gen_server:call(?MODULE, {lab_train, Ref, Samples}, 10000).

init(Options) ->
    process_flag(trap_exit, true),
    logger:update_process_metadata(#{domain => [erm, voice, phrases]}),
    try
        O = options(Options),
        lists:foreach(fun(Name) -> undefined = whereis(Name) end,
            [erm_native_voice, whisper_trigger_srv]),
        Hash = erm_phrase_codec:model_hash(maps:get(speaker_model, O)),
        Store=erm_voice_profiles:open(O,Hash),
        #{profile:=Profile,speaker_meta:=Meta,binding:=Binding,path:=Path,
            samples:=Samples,wake:=Wake}=erm_voice_profiles:resolve(Store),
        Speaker=case Profile of undefined->[];_->maps:get(embedding,Profile) end,
        O1=O#{profile_store=>Store,profile_file=>Path,wake=>Wake},
        log_speaker_profile(loaded,Meta,length(Samples)),
        self() ! connect,
        {ok, #st{opts = O1, speaker = Speaker, speaker_meta = Meta,
            calibration = calibration(Profile), binding = Binding, samples = Samples,
            observe = maps:get(observe_only, O1), paused = Speaker=:=[], next_arm = now_ms(),
            poll = erlang:send_after(100, self(), poll)}}
    catch C:R -> {stop, {phrase_voice_startup, C, R}} end.

handle_call(status, _, S) ->
    Enrol = case S#st.enrol of
        undefined -> undefined;
        #{action := A, count := N, samples := V, deadline := D} ->
            #{action => A, target => N, collected => length(V),
                say => erm_phrase_codec:prompt(A, maps:get(wake, S#st.opts)),
                remaining_ms => max(0, D-now_ms())}
    end,
    {reply, #{backend => phrases, profiles => erm_voice_profiles:public(maps:get(profile_store,S#st.opts)),
        enrolled => S#st.speaker=/=[], lab_enabled => maps:get(lab_enabled,S#st.opts),
        required_protocol => protocol(S), lab_reserved => S#st.lab =/= undefined,
        native_protocol => case S#st.phase of ready -> protocol(S); configuring -> protocol(S); _ -> undefined end,
        ready => S#st.phase =:= ready, phase => S#st.phase,
        listening => S#st.armed andalso not suppressed(), processing => S#st.busy,
        paused => S#st.paused, echo_guard_remaining_ms => max(0, S#st.next_arm-now_ms()),
        suppressed => suppressed(), observe_only => S#st.observe,
        enrolment => Enrol, templates => counts(S#st.samples), revision => S#st.revision,
        speaker_profile_id => speaker_meta(id, S#st.speaker_meta),
        speaker_profile_file => speaker_meta(path, S#st.speaker_meta),
        speaker_profile_fingerprint => speaker_meta(fingerprint, S#st.speaker_meta),
        speaker_profile_disk => speaker_profile_disk_state(S),
        last => S#st.last, error => S#st.error,
        thresholds => maps:with([max_distance, min_margin, speaker_threshold,
            min_speaker_ms, min_rms_dbfs, max_clipped_fraction, configured_speaker_threshold], speaker_options(S)),
        voice_calibration => S#st.calibration}, S};
handle_call({enrol, A, N}, _, S = #st{phase = ready, enrol = undefined, paused = false, lab = undefined})
    when is_integer(N), N >= 3, N =< 5 ->
    case lists:member(A, erm_phrase_codec:actions()) andalso not suppressed() of
        true ->
            E = #{action => A, count => N, samples => [], deadline => now_ms()+180000},
            Next = maybe_arm(close_gate(S#st{enrol = E, last = enrolment_started})),
            {reply, {ok, #{say => erm_phrase_codec:prompt(A, maps:get(wake, S#st.opts)),
                samples => N}}, Next};
        false -> {reply, {error, unknown_action_or_tts_active}, S}
    end;
handle_call({enrol, _, _}, _, S) -> {reply, {error, not_ready_paused_enrolling_or_invalid_count}, S};
handle_call(cancel_enrol, _, S = #st{lab = undefined}) ->
    {reply, ok, maybe_arm(close_gate(S#st{enrol = undefined, last = enrolment_cancelled}))};
handle_call({observe, B}, _, S = #st{lab = undefined}) when is_boolean(B) ->
    %% Every mode transition invalidates captures. Never promote an observation
    %% already in flight into an executable command.
    {reply, ok, maybe_arm(close_gate(S#st{observe = B}))};
handle_call({paused, B}, _, S = #st{lab = undefined}) when is_boolean(B) ->
    {reply, ok, maybe_arm(close_gate(S#st{paused = B}))};
handle_call({forget, A}, _, S = #st{phase = ready, enrol = undefined, lab = undefined}) ->
    case lists:member(A, erm_phrase_codec:actions()) of
        true ->
            Samples = [X || X = #{action := Action} <- S#st.samples, Action =/= A],
            case save_samples(Samples, S) of
                {ok, Next} -> {reply, ok, Next};
                {error, R, Next} -> {reply, {error, R}, Next}
            end;
        false -> {reply, {error, unknown_action}, S}
    end;
handle_call(lab_begin, {Owner, _}, S = #st{phase = ready, busy = false, enrol = undefined, lab = undefined}) ->
    case maps:get(lab_enabled, S#st.opts) andalso not suppressed() of
        true ->
            Ref = make_ref(), Monitor = erlang:monitor(process, Owner),
            L = #{owner => Owner, monitor => Monitor, ref => Ref, waiting => false},
            Next = close_gate(S#st{lab = L, paused = true, observe = true}),
            {reply, {ok, Ref, lab_snapshot(Next)}, Next};
        false -> {reply, {error, lab_disabled_or_tts_active}, S}
    end;
handle_call({lab_capture, Ref}, {Owner, _}, S = #st{phase = ready, busy = false,
    lab = #{owner := Owner, ref := Ref, waiting := false} = L}) ->
    case not suppressed() andalso now_ms() >= S#st.next_arm of
        true ->
            Next = close_gate(S), E = Next#st.epoch+1,
            send(Next, <<"S", (E bsl 1):64>>),
            voice_event(input, #{phase=>listening,level=>0.0,speech=>false}),
            {reply, ok, Next#st{epoch = E, armed = true,
                lab = L#{waiting => true, deadline => now_ms()+15000}}};
        false -> {reply, {error, tts_or_echo_guard}, S}
    end;
handle_call({lab_cancel, Ref}, {Owner, _}, S = #st{lab = #{owner := Owner, ref := Ref} = L}) ->
    {reply, ok, close_gate(S#st{lab = L#{waiting => false}, next_arm = now_ms()+6000})};
handle_call({lab_end, Ref}, {Owner, _}, S = #st{lab = #{owner := Owner, ref := Ref}}) ->
    {reply, ok, release_lab(S)};
handle_call({lab_train, Ref, Samples}, {Owner, _}, S = #st{phase = ready, busy = false,
    lab = #{owner := Owner, ref := Ref, waiting := false}}) ->
    case S#st.speaker=/=[] andalso erm_phrase_codec:validate_samples(Samples) of
        ok -> case save_samples(Samples, S) of
            {ok, Next} -> {reply, {ok, lab_snapshot(Next)}, Next};
            {error, Why, Next} -> {reply, {error, Why}, Next}
        end;
        false -> {reply, {error,not_enrolled}, S};
        Error -> {reply, Error, S}
    end;
handle_call({lab_profile, Ref, Request}, {Owner, _}, S = #st{phase = ready, busy = false,
    lab = #{owner := Owner, ref := Ref, waiting := false}}) ->
    profile_request(Request,S);
handle_call(_, _, S) -> {reply, {error, unsupported_or_busy}, S}.
handle_cast(_, S) -> {noreply, S}.

handle_info(connect, S = #st{port = undefined, opts = O}) ->
    try
        undefined = whereis(erm_native_voice), undefined = whereis(whisper_trigger_srv),
        Flag = case maps:get(lab_enabled, O) of true -> "--phrases-lab"; false -> "--phrases-only" end,
        Args = [Flag] ++ [maps:get(K, O) || K <-
            [vad_model, speaker_model, arecord, device, language]] ++
            [integer_to_list(maps:get(K, O)) || K <- [threads, silence_ms, max_segment_ms]],
        P = open_port({spawn_executable, maps:get(binary, O)},
            [binary, {packet, 4}, use_stdio, exit_status, {args, Args}]),
        {noreply, arm_timer(maps:get(startup_timeout_ms, O),
            S#st{port = P, phase = starting, retry = undefined, last_id = 0,
                busy = false, inflight = undefined, received = false, armed = false})}
    catch C:R -> {noreply, failed({open_port, C, R}, S)} end;
handle_info({P, {data, Data}}, S = #st{port = P}) when is_port(P) ->
    %% Native packets and disk failures cannot cause a partially accepted action.
    try {noreply, packet(Data, S)}
    catch C:R -> {noreply, failed({phrase_protocol, C, R}, S)} end;
handle_info({P, {exit_status, N}}, S = #st{port = P}) when is_port(P) ->
    {noreply, failed({native_exit, N}, S)};
handle_info({'EXIT', P, R}, S = #st{port = P}) when is_port(P) ->
    {noreply, failed({native_exit, R}, S)};
handle_info({timeout, Ref, native}, S = #st{timer = Ref}) ->
    {noreply, failed(native_timeout, S)};
handle_info({'DOWN', Monitor, process, Owner, _},
    S = #st{lab = #{owner := Owner, monitor := Monitor}}) ->
    {noreply, release_lab(S)};
handle_info(poll, S0) ->
    S1 = case S0#st.enrol of
        #{deadline := D} ->
            case now_ms() >= D of
                true -> close_gate(S0#st{enrol = undefined, last = enrolment_timed_out});
                false -> S0
            end;
        _ -> S0
    end,
    S2 = case suppressed() andalso (S1#st.armed orelse S1#st.inflight =/= undefined) of
        true -> close_gate(S1);
        false -> S1
    end,
    {noreply, (maybe_arm(expire_lab(S2)))#st{poll = erlang:send_after(100, self(), poll)}};
handle_info(_, S) -> {noreply, S}.

packet(<<"R", Dim:16, Protocol:8>>, S = #st{phase = starting, speaker = V}) when Dim>0, Dim=<4096, (V=:=[] orelse Dim=:=length(V)) ->
    true = Protocol =:= protocol(S),
    O = S#st.opts,
    Muted = close_gate(S), Epoch = Muted#st.epoch, Gate = (Epoch bsl 1) bor 1,
    send(Muted, <<"C", Gate:64, (float(maps:get(input_gain_db, O))):32/float-big,
        (float(maps:get(vad_threshold, O))):32/float-big,
        (maps:get(silence_ms, O)):32, (maps:get(min_speech_ms, O)):32,
        (maps:get(max_segment_ms, O)):32>>),
    send_profile(Muted),
    arm_timer(10000, Muted#st{opts=O#{embedding_dimension=>Dim},phase = configuring, config_epoch = Epoch,
        config_ack = false, profile_ack = false});
packet(<<"R", Dim:16, Protocol:8>>, _S) ->
    error({unsupported_native_protocol_or_speaker_dimension, Protocol, Dim});
packet(<<"C", Epoch:64>>, S = #st{phase = configuring, config_epoch = Epoch}) ->
    ready(S#st{config_ack = true});
packet(<<"L", Rev:64>>, S = #st{phase = configuring, revision = Rev}) ->
    ready(S#st{profile_ack = true});
%% Meter packets have a different length from the existing profile-load ack.
%% Accept delayed telemetry harmlessly; publish only the current open gate.
packet(<<"L", E:64, Db:32/float, Speech>>, S) when Db >= -200, Db =< 10, Speech =< 1 ->
    case S#st.phase =:= ready andalso E =:= S#st.epoch andalso
         S#st.armed andalso not suppressed() of
        true -> voice_event(input, #{phase=>listening,
            level=>max(0.0,min(1.0,(Db+60)/60)),speech=>Speech=:=1});
        false -> ok
    end,
    S;
packet(<<"B", E:64, Id:64>>, S = #st{phase = Phase, busy = false, last_id = Last})
    when (Phase =:= ready orelse Phase =:= configuring), Id > Last ->
    true = E =/= S#st.epoch orelse S#st.armed,
    case Phase =:= ready andalso E =:= S#st.epoch andalso not suppressed() of
        true ->
            voice_event(input, #{phase=>muted,level=>0.0,speech=>false}),
            voice_event(work, #{phase=>processing}),
            lab_diagnostic(inference_started,S);
        false -> ok
    end,
    Armed = S#st.armed andalso E =/= S#st.epoch,
    %% A cancelled epoch can finish on the worker. Track its F but never accept P.
    Next = S#st{busy = true, inflight = {E, Id}, last_id = Id, received = false, armed = Armed},
    case Phase of
        configuring -> Next; % retain the configuration deadline while draining
        ready -> arm_timer(maps:get(inference_timeout_ms, S#st.opts), Next)
    end;
packet(<<"K", E:64>>, S = #st{epoch = E,
    lab = #{owner := Owner, ref := Ref, waiting := true}}) ->
    Owner ! {erm_phrase_lab, Ref, armed}, S;
packet(<<"K", _E:64>>, S) -> S; % a cancelled capture may still acknowledge
packet(<<"Q", Size:32, Tail/binary>>, S = #st{busy = true, received = false,
    inflight = {E, Id}, lab = L}) when Size =< 30000, L =/= undefined ->
    <<Data:Size/binary, Model/binary>> = Tail,
    ok = erm_phrase_lab_store:validate_model(Model),
    {ok, U = #{epoch := E, id := Id}} = erm_phrase_codec:decode(Data),
    <<"ELS1", AudioSamples:32, _/binary>> = Model,
    true = AudioSamples div 16 =:= maps:get(ms, U),
    Next = S#st{received = true},
    case E =:= S#st.epoch andalso maps:get(revision, U) =:= S#st.revision
        andalso S#st.phase =:= ready andalso maps:get(waiting, L) andalso not suppressed() of
        true ->
            Check = verification_check(U, S),
            log_speaker_verification(U, Check, lab, S),
            maps:get(owner, L) ! {erm_phrase_lab, maps:get(ref, L),
                {sample, U#{synthesis => Model, verification => verification_result(Check),
                            check => Check}}},
            Next#st{lab = L#{waiting => false}, last = #{outcome => lab_only,
                check => Check, speaker_profile_fingerprint => speaker_meta(fingerprint, S#st.speaker_meta)}};
        false -> Next#st{last = {rejected, stale_lab_capture}}
    end;
packet(<<"Q", _/binary>>, S = #st{busy = true, received = false}) ->
    S#st{received = true}; % release/cancel while native analysis was in flight
packet(<<"P", _/binary>> = Data, S = #st{busy = true, received = false, inflight = {E, Id}}) ->
    {ok, U = #{epoch := E, id := Id}} = erm_phrase_codec:decode(Data),
    Next = S#st{received = true},
    case E =:= S#st.epoch andalso maps:get(revision, U) =:= S#st.revision
        andalso S#st.phase =:= ready andalso S#st.lab =:= undefined andalso not S#st.paused andalso not suppressed() of
        true -> accept(U, Next);
        false -> Next#st{last = {rejected, stale_muted_or_reconfigured}}
    end;
packet(<<"F">>, S = #st{busy = true}) ->
    voice_event(work, #{phase=>idle}),
    Next = S#st{busy = false, inflight = undefined, received = false},
    case S#st.phase of ready -> maybe_arm(clear_timer(Next)); _ -> Next end;
packet(<<"D", D/binary>>, S) when byte_size(D) =< 256 ->
    %% D packets have no epoch. Forward only named native diagnostics while
    %% an owned capture is waiting; never expose arbitrary native text in UI.
    case D of
        <<"utterance_too_long">>->lab_diagnostic(utterance_too_long,S);
        <<"utterance_dropped_busy">>->lab_diagnostic(utterance_dropped_busy,S);
        _->ok
    end,
    S#st{last = {native_diagnostic, D}};
packet(<<"E", E/binary>>, _S) when byte_size(E) =< 256 -> error({native, E});
packet(_, _) -> error(unexpected_native_packet).

lab_diagnostic(Code,#st{lab=#{owner:=Owner,ref:=Ref,waiting:=true}})->
    Owner!{erm_phrase_lab,Ref,{diagnostic,Code}},ok;
lab_diagnostic(_,_) -> ok.

ready(S = #st{config_ack = true, profile_ack = true}) ->
    Next = clear_timer(S#st{phase = ready, error = undefined}),
    case Next#st.busy of
        true -> arm_timer(maps:get(inference_timeout_ms, Next#st.opts), Next);
        false -> maybe_arm(Next)
    end;
ready(S) -> S.

accept(U, S) ->
    Check = verification_check(U, S),
    log_speaker_verification(U, Check, command, S),
    case verification_result(Check) of
        {ok, SpeakerScore} ->
            #{result := Result, quality := Quality} = U,
            Measurement = Result#{speaker_score => SpeakerScore, quality => Quality,
                audio_ms => maps:get(ms, U),
                speaker_profile_fingerprint => speaker_meta(fingerprint, S#st.speaker_meta)},
            case S#st.enrol of
                undefined -> recognize(Result, S#st{last = Measurement});
                _ -> enrol_sample(maps:get(sample, U), S#st{last = Measurement})
            end;
        {error, Reason} -> S#st{last = {rejected, Reason}}
    end.

verification_result(#{accepted := true, speaker_score := Score}) -> {ok, Score};
verification_result(#{reason := speaker_below_threshold, speaker_score := Score}) ->
    {error, {speaker_below_threshold, Score}};
verification_result(#{reason := Reason}) -> {error, Reason}.

%% Numeric diagnostics only: never copy embeddings, features or synthesis data
%% into status, logs or UI events. The acceptance gates and order are unchanged.
verification_check(#{embedding := V, ms := Ms, quality := Q,
                     sample := #{frames := Frames}} = U, S) ->
    O = speaker_options(S),
    Check = #{accepted => false, audio_ms => Ms, frames => Frames,
        quality => maps:with([rms_dbfs, peak_dbfs, clipped_fraction, input_gain_db], Q),
        thresholds => maps:with([min_speaker_ms, min_rms_dbfs,
                                max_clipped_fraction, speaker_threshold], O),
        embedding_dimension => length(V), expected_embedding_dimension => maps:get(embedding_dimension,O,length(S#st.speaker))},
    case speaker_profile_disk_state(S) of
        current -> verification_check_current(U, S, O, Check);
        not_enrolled -> verification_check_current(U, S, O, Check);
        changed_restart_required -> Check#{reason => speaker_profile_changed_restart_required};
        {unavailable, _} -> Check#{reason => speaker_profile_unavailable}
    end.

verification_check_current(#{embedding := V, ms := Ms, quality := Q,
                     sample := #{frames := Frames}}, S, O, Check) ->
    Checks = [{not_enrolled,S#st.speaker=/=[]},{audio_too_short, Ms >= maps:get(min_speaker_ms, O)},
        {no_phrase_features, Frames > 0},
        {audio_too_quiet, maps:get(rms_dbfs, Q) >= maps:get(min_rms_dbfs, O)},
        {audio_clipped, maps:get(clipped_fraction, Q) =< maps:get(max_clipped_fraction, O)},
        {missing_embedding, V =/= []},
        {embedding_dimension_mismatch, length(V) =:= length(S#st.speaker)}],
    case [Why || {Why, false} <- Checks] of
        [Reason | _] -> Check#{reason => Reason};
        [] ->
            case erm_native_voice:normalise(V) of
                {ok, Normal} ->
                    Score = erm_native_voice:score(Normal, S#st.speaker),
                    case Score >= maps:get(speaker_threshold, O) of
                        true -> Check#{accepted => true, reason => verified, speaker_score => Score};
                        false -> Check#{reason => speaker_below_threshold, speaker_score => Score}
                    end;
                {error, _} -> Check#{reason => invalid_embedding}
            end
    end.

speaker_meta(_Key, undefined) -> undefined;
speaker_meta(Key, Meta) -> maps:get(Key, Meta).

speaker_profile_disk_state(#st{speaker_meta = undefined}) -> not_enrolled;
speaker_profile_disk_state(#st{speaker_meta = #{path := Path, fingerprint := Expected}}) ->
    case erm_phrase_codec:speaker_file_fingerprint(Path) of
        {ok, Expected} -> current;
        {ok, _} -> changed_restart_required;
        {error, Reason} -> {unavailable, Reason}
    end.

%% The selected speaker reference may be a named voice in /voices/*.speaker,
%% not the legacy owner.profile. Never log or expose the embedding bytes.
log_speaker_profile(Event, undefined, _Templates) ->
    logger:notice("erm_voice_profile event=~p backend=phrases status=not_enrolled", [Event]);
log_speaker_profile(Event, #{id := Id, path := Path, fingerprint := Fingerprint}, Templates) ->
    logger:notice(
        "erm_voice_profile event=~p backend=phrases fingerprint=~ts " ++
        "voice_id=~ts path=~ts templates=~p",
        [Event, Fingerprint, Id, Path, Templates]).

log_speaker_verification(U, Check, Mode, S) ->
    Meta = S#st.speaker_meta,
    logger:notice(
        "erm_voice_profile event=verification backend=phrases mode=~p " ++
        "fingerprint=~ts voice_id=~ts capture_id=~p score=~p threshold=~p " ++
        "outcome=~p reason=~p",
        [Mode, log_value(speaker_meta(fingerprint, Meta)), log_value(speaker_meta(id, Meta)),
            maps:get(id, U, undefined), maps:get(speaker_score, Check, undefined),
            maps:get(speaker_threshold, speaker_options(S)),
            case maps:get(accepted, Check, false) of true -> pass; false -> reject end,
            maps:get(reason, Check, undefined)]).
log_value(undefined) -> <<"none">>;
log_value(Value) -> Value.

recognize(#{reason := matched, action := A, distance := D, margin := Gap}, S) ->
    O = S#st.opts,
    %% Recheck native decisions against the current revision/configuration.
    Eligible = maps:get(A, counts(S#st.samples), 0) >= 3,
    case Eligible andalso D =< maps:get(max_distance, O) andalso Gap >= maps:get(min_margin, O) of
        false -> S#st{last = (S#st.last)#{outcome => rejected}};
        true when S#st.observe -> S#st{last = (S#st.last)#{outcome => observed}};
        true ->
            case now_ms() >= S#st.next_arm andalso not suppressed() of
                false -> S#st{last = (S#st.last)#{outcome => cooldown_or_tts}};
                true ->
                    %% No caller-provided string, MFA, shell command or model output.
                    %% A failed/uncertain delivery is never retried automatically.
                    Outcome = try dispatch(A) of
                        ok -> dispatched;
                        {error, DispatchError} -> {dispatch_failed, DispatchError};
                        Other -> {dispatch_returned, Other}
                    catch DispatchClass:DispatchReason -> {dispatch_failed, DispatchClass, DispatchReason} end,
                    S#st{last = (S#st.last)#{outcome => Outcome},
                        next_arm = now_ms()+maps:get(cooldown_ms, O)}
            end
    end;
recognize(_, S) -> S#st{last = (S#st.last)#{outcome => rejected}}.

enrol_sample(Sample0, S = #st{enrol = #{action := A, samples := Old, count := N} = E}) ->
    Sample = Sample0#{action => A}, Fingerprint = erm_phrase_codec:fingerprint(Sample),
    case lists:any(fun(X) -> erm_phrase_codec:fingerprint(X) =:= Fingerprint end, Old) of
        true -> S#st{last = #{outcome => enrolment_rejected, reason => duplicate_sample}};
        false ->
            Collected = Old ++ [Sample],
            case length(Collected) =:= N of
                false ->
                    logger:notice("phrase enrollment accepted ~p/~p for ~p", [length(Collected), N, A]),
                    S#st{enrol = E#{samples => Collected},
                        last = #{outcome => enrolment_accepted, action => A, collected => length(Collected)}};
                true ->
                    Samples = [X || X = #{action := B} <- S#st.samples, B =/= A] ++ Collected,
                    case save_samples(Samples, S#st{enrol = undefined}) of
                        {ok, Next} -> Next#st{last = #{outcome => enrolment_saved, action => A, collected => N}};
                        {error, R, Next} -> Next#st{last = {enrolment_save_failed, R}}
                    end
            end
    end.

save_samples(Samples, S) ->
    Next = close_gate(S),
    case erm_phrase_codec:save_profile(maps:get(profile_file, S#st.opts), S#st.binding, Samples) of
        ok ->
            Updated = Next#st{samples = Samples, revision = S#st.revision+1,
                phase = configuring, config_ack = true, profile_ack = false},
            try
                send_profile(Updated),
                {ok, arm_timer(10000, Updated)}
            catch LoadClass:LoadReason ->
                %% Disk already committed: retain that revision across reconnect.
                Failure = {profile_load, LoadClass, LoadReason},
                {error, Failure, failed(Failure, Updated)}
            end;
        {error, R} -> {error, R, maybe_arm(Next)}
    end.

dispatch(Action) ->
    Text = erm_phrase_codec:command(Action),
    Expected = case Action of
        stop_music -> stop; pause_music -> pause; play_music -> play;
        next_track -> next; previous_track -> previous
    end,
    %% Refuse to route to the planner if this installation cannot parse the
    %% canonical text as exactly the intended local media action.
    {ok, #{action := Expected}} = erm_voice_intent:parse(Text),
    erm_voice:command(Text).

send_profile(S) ->
    O = S#st.opts,
    send(S, erm_phrase_codec:encode_profile(S#st.revision,
        maps:get(max_distance, O), maps:get(min_margin, O), S#st.samples)).
close_gate(S = #st{port = P}) ->
    E = S#st.epoch+1,
    case is_port(P) of
        true -> try port_command(P, <<"M", ((E bsl 1) bor 1):64>>) catch error:_ -> ok end;
        false -> ok
    end,
    voice_event(input, #{phase=>muted,level=>0.0,speech=>false}),
    voice_event(work, #{phase=>idle}),
    S#st{epoch = E, armed = false}.
maybe_arm(S = #st{phase = ready, busy = false, armed = false, paused = false, lab = undefined}) when S#st.speaker=/=[] ->
    case not suppressed() andalso now_ms() >= S#st.next_arm of
        true ->
            E = S#st.epoch+1,
            try send(S, <<"P", (E bsl 1):64>>),
                voice_event(input, #{phase=>listening,level=>0.0,speech=>false}),
                S#st{epoch = E, armed = true}
            catch C:R -> failed({arm_failed, C, R}, S) end;
        false -> S
    end;
maybe_arm(S) -> S.
send(#st{port = P}, Packet) when is_port(P) -> true = port_command(P, Packet), ok.
failed(Reason, S0) ->
    S = case S0#st.lab of
        #{owner := Owner, ref := Ref} ->
            Owner ! {erm_phrase_lab, Ref, {error, backend_failed}}, release_lab(S0);
        _ -> S0
    end,
    Next = clear_timer(close_gate(S)),
    case S#st.port of P when is_port(P) -> try port_close(P) catch error:_ -> ok end; _ -> ok end,
    cancel_timer(S#st.retry),
    voice_event(input, #{phase=>error,level=>0.0,speech=>false}),
    logger:warning("phrase backend stopped: ~p", [Reason]),
    Next#st{port = undefined, phase = disconnected, busy = false, armed = false,
        inflight = undefined, received = false, enrol = undefined, error = Reason,
        config_ack = false, profile_ack = false, retry = erlang:send_after(5000, self(), connect)}.
clear_timer(S) -> cancel_timer(S#st.timer), S#st{timer = undefined}.
arm_timer(Ms, S) -> Next = clear_timer(S), Next#st{timer = erlang:start_timer(Ms, self(), native)}.
cancel_timer(undefined) -> ok;
cancel_timer(Ref) -> _ = erlang:cancel_timer(Ref), ok.
suppressed() ->
    case persistent_term:get({erm_tts, suppress_until}, 0) of
        0 -> false;
        Until when is_integer(Until) -> Until > now_ms();
        _ -> true
    end.
now_ms() -> erlang:monotonic_time(millisecond).
counts(Samples) -> lists:foldl(fun(#{action := A}, M) ->
    maps:update_with(A, fun(N) -> N+1 end, 1, M) end, #{}, Samples).
terminate(_, S) ->
    cancel_timer(S#st.poll), cancel_timer(S#st.retry), cancel_timer(S#st.timer),
    case S#st.port of P when is_port(P) -> try port_close(P) catch error:_ -> ok end; _ -> ok end, ok.
code_change(_, _, _) -> {error, restart_required}.

voice_event(Channel, Data) ->
    try erm_voice_events:publish(?MODULE, Channel, Data) catch error:undef -> ok end.

protocol(S) -> case maps:get(lab_enabled, S#st.opts) of true -> 6; false -> 5 end.
lab_snapshot(S) ->
    Store=maps:get(profile_store,S#st.opts),
    #{profiles=>erm_voice_profiles:public(Store),
      legacy_binding=>maps:get(legacy_binding,maps:get(state,Store)),
      enrolled=>S#st.speaker=/=[],speaker_dimension=>maps:get(embedding_dimension,S#st.opts,0),
      speaker_profile_id=>speaker_meta(id,S#st.speaker_meta),
      speaker_profile_file=>speaker_meta(path,S#st.speaker_meta),
      speaker_profile_fingerprint=>speaker_meta(fingerprint,S#st.speaker_meta),
      speaker_profile_disk=>speaker_profile_disk_state(S),
      binding => S#st.binding, samples => S#st.samples, revision => S#st.revision,
      profile_file => maps:get(profile_file, S#st.opts),
      wake => maps:get(wake, S#st.opts),
      capture_context => capture_context(S#st.opts),
      thresholds => maps:with([min_speaker_ms, min_rms_dbfs, max_clipped_fraction,
                              speaker_threshold, configured_speaker_threshold, enrolment_threshold, max_segment_ms], speaker_options(S)),
      voice_calibration => S#st.calibration,
      max_distance => maps:get(max_distance, S#st.opts), min_margin => maps:get(min_margin, S#st.opts)}.
capture_context(O)->
    (maps:with([input_gain_db,vad_threshold,silence_ms,min_speech_ms,max_segment_ms],O))#{
        device=>display_text(maps:get(device,O)),
        speaker_model=>display_text(filename:basename(maps:get(speaker_model,O))),
        speaker_dimension=>maps:get(embedding_dimension,O,0)}.
display_text(Text)->unicode:characters_to_binary(lists:sublist(
    [case C>=32 andalso C=/=127 of true->C;false->$? end || C<-unicode:characters_to_list(Text)],128)).
%% Selection is transactional at the manifest boundary. Validate/load before
%% committing; on a native reload failure retain the committed selection while
%% reconnecting, with commands still paused.
profile_request(Request,S)->
    try
        Store=maps:get(profile_store,S#st.opts),
        NextStore=case Request of
            {select,Id}->erm_voice_profiles:select(Store,Id);
            {delete,Id}->erm_voice_profiles:remove(Store,Id);
            {wake,Text}->erm_voice_profiles:wake(Store,Text);
            {enrol_repeated,Label,Payload}->
                {ok,Mean,Calibration}=erm_voice_calibration:profile(Payload,
                    maps:get(speaker_threshold,S#st.opts),maps:get(embedding_dimension,S#st.opts)),
                erm_voice_profiles:enrol(Store,Label,Mean,Calibration);
            {enrol,Label,Vs} when is_list(Vs),length(Vs)>=3,length(Vs)=<10->
                Dim=maps:get(embedding_dimension,S#st.opts),
                true=lists:all(fun(V)->is_list(V) andalso length(V)=:=Dim end,Vs),
                T=maps:get(enrolment_threshold,S#st.opts),
                {Mean,_}=lists:foldl(fun(V,{_,Old})->
                    {ok,N}=erm_native_voice:normalise(V),
                    {accept,M,_}=erm_native_voice:enrolment_check(N,Old,T),{M,Old++[N]}
                end,{undefined,[]},Vs),
                erm_voice_profiles:enrol(Store,Label,Mean)
        end,
        Resolved=erm_voice_profiles:resolve(NextStore),
        case maps:get(profile,Resolved) of
            undefined->ok;
            #{embedding:=Embedding}->true=length(Embedding)=:=maps:get(embedding_dimension,S#st.opts)
        end,
        ok=erm_voice_profiles:commit(NextStore),
        case Request of
            {enrol, _, _} -> log_speaker_profile(saved,maps:get(speaker_meta,Resolved),length(maps:get(samples,Resolved)));
            {enrol_repeated, _, _} -> log_speaker_profile(saved,maps:get(speaker_meta,Resolved),length(maps:get(samples,Resolved)));
            {select, _} -> log_speaker_profile(selected,maps:get(speaker_meta,Resolved),length(maps:get(samples,Resolved)));
            _ -> ok
        end,
        Cleanup=case Request of {delete,Deleted}->erm_voice_profiles:delete_file(Store,Deleted);_->ok end,
        case apply_profile(NextStore,Resolved,S) of
            {reply,{ok,Snapshot},Next}->{reply,{ok,Snapshot#{profile_cleanup=>Cleanup}},Next};
            Reply->Reply
        end
    catch C:R->{reply,{error,{profile_selection,C,R}},S} end.
apply_profile(Store,#{profile:=P,speaker_meta:=Meta,binding:=B,path:=Path,samples:=Samples,wake:=Wake},S)->
    Next=close_gate(S),
    Speaker=case P of undefined->[];_->maps:get(embedding,P) end,
    Updated=Next#st{opts=(S#st.opts)#{profile_store=>Store,profile_file=>Path,wake=>Wake},
        speaker=Speaker,speaker_meta=Meta,calibration=calibration(P),binding=B,
        samples=Samples,revision=S#st.revision+1,
        phase=configuring,config_ack=true,profile_ack=false,paused=true,observe=true},
    try send_profile(Updated),
        log_speaker_profile(loaded,Meta,length(Samples)),
        {reply,{ok,lab_snapshot(Updated)},arm_timer(10000,Updated)}
    catch C:R->{reply,{error,{profile_reload,C,R}},failed({profile_reload,C,R},Updated)} end.

calibration(undefined)->undefined;
calibration(P)->maps:get(voice_calibration,P,undefined).
speaker_options(S)->
    O=S#st.opts,Configured=maps:get(speaker_threshold,O),
    O#{speaker_threshold=>erm_voice_calibration:threshold(S#st.calibration,Configured),
       configured_speaker_threshold=>Configured}.

release_lab(S = #st{lab = L}) when is_map(L) ->
    erlang:demonitor(maps:get(monitor, L), [flush]),
    close_gate(S#st{lab = undefined, paused = true, observe = true, next_arm = now_ms()+6000});
release_lab(S) -> S.
expire_lab(S = #st{lab = #{waiting := true, deadline := D, owner := Owner, ref := Ref} = L}) ->
    case now_ms() >= D orelse suppressed() of
        true ->
            Owner ! {erm_phrase_lab, Ref, {error, capture_timeout_or_tts}},
            close_gate(S#st{lab = L#{waiting => false}});
        false -> S
    end;
expire_lab(S) -> S.

options(Input) ->
    Top = as_map(Input), Native = as_map(maps:get(native, Top, #{})),
    Phrases = as_map(maps:get(phrases, Top, #{})),
    Defaults = #{lab_enabled => false, observe_only => true, max_distance => 0.35, min_margin => 0.08,
        min_rms_dbfs => -45.0, max_clipped_fraction => 0.02, cooldown_ms => 1000},
    true = maps:without([profile_file | maps:keys(Defaults)], Phrases) =:= #{},
    true = maps:get(require_speaker, Native, true) =:= true,
    %% Speaker threshold must be explicitly configured/calibrated, never guessed.
    SpeakerThreshold = maps:get(speaker_threshold, Native),
    Owner = path(maps:get(profile_file, Native)),
    Common = maps:merge(#{binary => default_binary(), arecord => "/usr/bin/arecord",
        device => "default", language => "en", threads => 4, silence_ms => 700,
        max_segment_ms => 8000, min_speaker_ms => 1200, input_gain_db => 0.0,
        enrolment_threshold => SpeakerThreshold, vad_threshold => 0.5, min_speech_ms => 250, startup_timeout_ms => 120000,
        inference_timeout_ms => 30000}, Native),
    O0 = maps:merge(Common, maps:merge(Defaults, Phrases)),
    O1 = O0#{speaker_profile => Owner, speaker_threshold => SpeakerThreshold,
        profile_file => maps:get(profile_file, Phrases,
            filename:join([filename:dirname(Owner), "phrases", "commands.eph"]))},
    O2 = lists:foldl(fun(K, M) -> M#{K => path(maps:get(K, M))} end, O1,
        [binary, arecord, vad_model, speaker_model, profile_file, speaker_profile]),
    Wake0 = case maps:get(trigger_phrases, Top, ["bob"]) of [W] -> W; _ -> error(exactly_one_wake_phrase_required) end,
    Wake = erm_voice_profiles:normalise_wake(Wake0),
    true = is_binary(Wake) andalso byte_size(Wake) > 0 andalso byte_size(Wake) =< 64,
    true = is_boolean(maps:get(observe_only, O2)),
    true = is_boolean(maps:get(lab_enabled, O2)),
    lists:foreach(fun({K, Lo, Hi}) -> V = maps:get(K, O2),
        true = is_integer(V) andalso V >= Lo andalso V =< Hi end,
        [{threads,1,32}, {silence_ms,200,2000}, {max_segment_ms,2000,8000},
         {min_speaker_ms,500,8000}, {min_speech_ms,100,2000}, {cooldown_ms,250,10000},
         {startup_timeout_ms,1000,600000}, {inference_timeout_ms,1000,120000}]),
    lists:foreach(fun({K, Lo, Hi}) -> V = maps:get(K, O2),
        true = is_number(V) andalso V >= Lo andalso V =< Hi end,
        [{speaker_threshold,0.01,0.99}, {enrolment_threshold,0.01,0.99}, {input_gain_db,-24,12}, {vad_threshold,0.05,0.95},
         {max_distance,0.01,5}, {min_margin,0.001,5}, {min_rms_dbfs,-80,-10},
         {max_clipped_fraction,0.0,0.10}]),
    true = maps:get(min_speaker_ms, O2) < maps:get(max_segment_ms, O2),
    true = maps:get(min_speech_ms, O2) < maps:get(max_segment_ms, O2),
    Device = text(maps:get(device, O2)), Language = text(maps:get(language, O2)),
    O2#{wake => Wake, device => Device, language => Language,
        enrolment_threshold=>max(SpeakerThreshold,maps:get(enrolment_threshold,O2))}.
as_map(M) when is_map(M) -> M;
as_map(L) when is_list(L) -> maps:from_list(L).
text(V) ->
    S = unicode:characters_to_list(V),
    true = is_list(S) andalso length(S) > 0 andalso length(S) =< 4096,
    true = not lists:member(0, S), S.
path(V) -> S = text(V), absolute = filename:pathtype(S), S.
default_binary() ->
    case code:priv_dir(erm) of
        Dir when is_list(Dir) -> filename:join(Dir, "erm_native_voice");
        _ -> "/usr/lib/erm/priv/erm_native_voice"
    end.
