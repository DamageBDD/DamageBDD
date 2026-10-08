%% One managed capture stream, native Whisper/VAD and speaker verification.
-module(erm_native_voice).
-behaviour(gen_server).
-include_lib("kernel/include/file.hrl").
-export([start_link/1, status/0, enrol/2, enrol/3, cancel_enrol/0, decode/1, normalise/1, score/2,
    configure/1, reload/0, reload/1, reconnect/0, tune/0, tune/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-record(st, {
    opts,
    port = undefined,
    ready = false,
    dim = 0,
    epoch = 0,
    muted = true,
    timer = undefined,
    poll,
    model_hash = undefined,
    profile = undefined,
    enrol = undefined,
    last_id = 0,
    last = undefined,
    error = undefined,
    processing = false,
    %% Keep existing record tuple positions stable for protocol/test helpers.
    model_retry = undefined,
    backend_retry = undefined,
    extra = #{}
}).
start_link(O) -> gen_server:start_link({local, ?MODULE}, ?MODULE, O, []).
status() -> gen_server:call(?MODULE, status, 1000).
enrol(Label, Count) -> enrol(Label, Count, #{}).
enrol(Label, Count, Options) -> erm_voice_tune:enrol(Label, Count, Options).
cancel_enrol() ->
    case erm_voice_tune:cancel_enrol() of
        ok -> ok;
        {error, not_started} -> gen_server:call(?MODULE, cancel_enrol, 1000);
        not_guided -> gen_server:call(?MODULE, cancel_enrol, 1000)
    end.
configure(Options) -> gen_server:call(?MODULE, {configure, Options}, 5000).
reload() -> reload_from(env).
reload(File) -> reload_from(File).
reload_from(Source) ->
    case erm_voice_acoustics:reload_options(Source) of
        {ok, Options} -> gen_server:call(?MODULE, {reload, Options}, 5000);
        Error -> Error
    end.
reconnect() -> gen_server:call(?MODULE, reconnect, 5000).
tune() -> tune(#{}).
tune(Options) -> erm_voice_tune:start(Options).
map(M) when is_map(M) -> M;
map(L) when is_list(L) -> proplists:to_map(L).
init(O0) ->
    process_flag(trap_exit, true),
    logger:update_process_metadata(#{domain => [erm, voice, native]}),
    try
        User = map(O0),
        O1 = maps:merge(
            #{
                binary => default_binary(),
                arecord => default_arecord(),
                auto_pull => true,
                model_id => native_voice_base_en,
                model_poll_ms => 1000,
                model_retry_ms => 30000,
                backend_retry_ms => 5000,
                device => "default",
                language => "en",
                threads => 4,
                silence_ms => 700,
                max_segment_ms => 8000,
                min_speaker_ms => 1200,
                require_speaker => true,
                speaker_threshold => 0.7,
                startup_timeout_ms => 120000,
                inference_timeout_ms => 30000,
                trigger_phrases => ["bob"],
                debug_utterances => false,
                observe_only => false
            },
            User
        ),
        O2 =
            case maps:is_key(profile_file, User) of
                true -> O1;
                false -> O1#{profile_file => default_profile_file()}
            end,
        {ok, O} = erm_voice_acoustics:validate(#{}, O2),
        true = is_boolean(maps:get(auto_pull, O)),
        true = is_boolean(maps:get(require_speaker, O)),
        true = is_boolean(maps:get(debug_utterances, O)),
        true = is_boolean(maps:get(observe_only, O)),
        true = is_atom(maps:get(model_id, O)),
        lists:foreach(
            fun({K, Lo, Hi}) ->
                V = maps:get(K, O),
                true = is_integer(V) andalso V >= Lo andalso V =< Hi
            end,
            [
                {threads, 1, 32},
                {silence_ms, 200, 2000},
                {max_segment_ms, 2000, 15000},
                {min_speaker_ms, 500, 15000},
                {startup_timeout_ms, 1000, 600000},
                {inference_timeout_ms, 1000, 120000},
                {model_poll_ms, 100, 10000},
                {model_retry_ms, 1000, 3600000},
                {backend_retry_ms, 1000, 3600000}
            ]
        ),
        true = maps:get(min_speaker_ms, O) < maps:get(max_segment_ms, O),
        T = maps:get(speaker_threshold, O),
        true = is_number(T) andalso T > 0 andalso T < 1,
        lists:foreach(
            fun(K) -> absolute = filename:pathtype(maps:get(K, O)) end,
            [binary, arecord, profile_file]
        ),
        validate_explicit_model_paths(O),
        self() ! ensure_models,
        {ok, #st{
            opts = O,
            error = model_startup_state(O),
            poll = erlang:send_after(100, self(), poll)
        }}
    catch
        C:R -> {stop, {invalid_native_voice_configuration, C, R}}
    end.
handle_call(status, _, S) ->
    Enrol =
        case S#st.enrol of
            undefined ->
                undefined;
            #{label := L, count := N, samples := V, deadline := Deadline} = E ->
                #{label => L, target => N, collected => length(V),
                    rejected => maps:get(rejected, E, 0),
                    remaining_ms => max(0, Deadline - now_ms()),
                    last_check => maps:get(last_check, E, undefined)}
        end,
    {reply,
        #{
            ready => S#st.ready,
            processing => S#st.processing,
            muted => S#st.muted,
            enrolled => S#st.profile =/= undefined,
            speaker_settings => maps:with(
                [device, require_speaker, speaker_threshold, enrolment_threshold,
                    min_speaker_ms, observe_only], S#st.opts
            ),
            configuration => maps:with(erm_voice_acoustics:keys(), S#st.opts),
            native_protocol => maps:get(protocol, S#st.extra, 1),
            acoustic_config => maps:get(acoustic_config, S#st.extra, unavailable),
            last_measurement => maps:get(last_measurement, S#st.extra, undefined),
            tuning => guide_kind(S) =:= tuning,
            guidance => guide_kind(S),
            binary => maps:get(binary, S#st.opts),
            arecord => maps:get(arecord, S#st.opts),
            retry_in_ms => retry_in_ms(S#st.backend_retry),
            model_id => maps:get(model_id, S#st.opts, native_voice_base_en),
            model_paths => maps:with([whisper_model, vad_model, speaker_model], S#st.opts),
            enrolment => Enrol,
            last => S#st.last,
            error => S#st.error
        },
        S};
handle_call({configure, _}, _, S = #st{enrol = E}) when E =/= undefined ->
    {reply, {error, enrollment_active}, S};
handle_call({configure, Options}, _, S) -> apply_config(Options, S);
handle_call({reload, Options}, _, S) ->
    Unsupported = [K || {K, V} <- maps:to_list(Options),
        not lists:member(K, erm_voice_acoustics:keys()), maps:get(K, S#st.opts, undefined) =/= V],
    case {Unsupported, S#st.enrol} of
        {[], undefined} -> apply_config(maps:with(erm_voice_acoustics:keys(), Options), S);
        {[], _} -> {reply, {error, enrollment_active}, S};
        _ -> {reply, {error, {restart_required, lists:sort(Unsupported)}}, S}
    end;
handle_call(reconnect, _, S = #st{model_hash = undefined}) ->
    {reply, {error, not_ready}, S};
handle_call(reconnect, _, S = #st{enrol = undefined}) ->
    case maps:is_key(tuner, S#st.extra) of
        true -> {reply, {error, tuning_active}, S};
        false ->
            close_port(S#st.port),
            Next = cancel_backend_retry(clear_timer(S)),
            {reply, ok, connect(Next#st{port = undefined, ready = false, processing = false,
                extra = maps:remove(acoustic_config, Next#st.extra)})}
    end;
handle_call(reconnect, _, S) -> {reply, {error, enrollment_active}, S};
handle_call({enrol_claim, Pid, Label, Count, Timeout}, {Pid, _},
    S = #st{ready = true, enrol = undefined}) when is_integer(Timeout), Timeout >= 1000, Timeout =< 600000 ->
    case guide_available(S) of
        ok ->
            case begin_enrol(Label, Count, Timeout, S) of
                {reply, ok, Next} -> claim_guide(Pid, enrolment, Next);
                Error -> Error
            end;
        Error -> {reply, Error, S}
    end;
handle_call({enrol_claim, _, _, _, _}, _, S) ->
    {reply, {error, not_ready_or_enrolling}, S};
handle_call({tune_claim, Pid}, {Pid, _}, S = #st{ready = true, enrol = undefined, profile = Profile})
    when Profile =/= undefined ->
    case guide_available(S) of
        ok -> claim_guide(Pid, tuning, S);
        Error -> {reply, Error, S}
    end;
handle_call({tune_claim, _}, _, S) -> {reply, {error, not_ready_enrolled_or_idle}, S};
handle_call(tune_ready, {Pid, _}, S = #st{extra = #{tuner := #{pid := Pid}}}) ->
    Muted = suppressed(),
    Next = case S#st.ready andalso Muted =/= S#st.muted of
        true -> bump(S#st{muted = Muted}); false -> S
    end,
    Reply = case Next#st.ready andalso not Muted of true -> ok; false -> {error, not_ready} end,
    {reply, Reply, Next};
handle_call({tune_listen, Enabled}, {Pid, _}, S) when is_boolean(Enabled) ->
    case maps:get(tuner, S#st.extra, undefined) of
        #{pid := Pid} = T ->
            case Enabled andalso (suppressed() orelse not S#st.ready orelse S#st.muted) of
                true -> {reply, {error, not_ready}, S};
                false -> {reply, ok, bump(S#st{extra = (S#st.extra)#{tuner => (maps:remove(detection_id, T))#{listening => Enabled}}})}
            end;
        _ -> {reply, {error, not_tuning_owner}, S}
    end;
handle_call(tune_release, {Pid, _}, S) ->
    case maps:get(tuner, S#st.extra, undefined) of
        #{pid := Pid, monitor := Ref} ->
            demonitor(Ref, [flush]),
            {reply, ok, release_guide(S)};
        _ -> {reply, ok, S}
    end;
handle_call({enrol, _, _}, _, S = #st{extra = #{tuner := _}}) ->
    {reply, {error, tuning_active}, S};
handle_call({enrol, L0, N}, _, S = #st{ready = true, enrol = undefined, muted = false}) when
    is_integer(N), N >= 3, N =< 10
->
    case begin_enrol(L0, N, 120000, S) of
        {reply, ok, Next} -> {reply, ok, bump(Next)};
        Error -> Error
    end;
handle_call({enrol, _, _}, _, S) ->
    {reply, {error, not_ready_muted_or_enrolling}, S};
handle_call({enrol_abort, Pid}, {Pid, _}, S = #st{extra = #{tuner := #{pid := Pid, mode := enrolment} = T}}) ->
    {reply, {ok, maps:get(last_check, T, undefined)},
        bump(S#st{enrol = undefined, extra = (S#st.extra)#{tuner => T#{listening => false}}})};
handle_call(cancel_enrol, _, S = #st{enrol = undefined}) -> {reply, ok, S};
handle_call(cancel_enrol, _, S) ->
    {reply, ok, end_enrol(cancelled, S)};
handle_call(_, _, S) ->
    {reply, {error, unsupported_call}, S}.
handle_cast(_, S) -> {noreply, S}.
handle_info(ensure_models, S = #st{port = undefined, backend_retry = undefined, opts = O}) ->
    case resolve_models(O) of
        {ok, Resolved} ->
            case activate_models(Resolved, S) of
                {ok, Next} ->
                    self() ! connect,
                    {noreply, Next};
                {error, Reason, Next} ->
                    {noreply, schedule_model_retry(Reason, Next)}
            end;
        {pending, Progress} ->
            {noreply, schedule_model_poll({model_pull, Progress}, S)};
        {error, Reason} ->
            _ = maybe_retry_model_pull(O),
            {noreply, schedule_model_retry({model_pull, Reason}, S)}
    end;
handle_info(connect, S = #st{port = undefined, model_hash = Hash}) when is_binary(Hash) ->
    {noreply, connect(cancel_backend_retry(S))};
handle_info({timeout, T, reconnect}, S = #st{backend_retry = T, port = undefined}) when
    is_reference(T)
->
    {noreply, connect(S#st{backend_retry = undefined})};
handle_info({P, {data, <<"R", Dim:16, Version>>}}, S = #st{port = P, ready = false})
    when Dim > 0, Dim =< 4096, Version >= 2, Version =< 4 ->
    {noreply, Next} = handle_info({P, {data, <<"R", Dim:16>>}}, S),
    {noreply, send_acoustics(Next#st{extra = (Next#st.extra)#{protocol => Version}})};
handle_info({P, {data, <<"C", Epoch:64>>}}, S = #st{port = P}) ->
    case maps:get(acoustic_config, S#st.extra, undefined) of
        #{epoch := Epoch} = C ->
            {noreply, S#st{extra = (S#st.extra)#{acoustic_config => C#{state => applied}}}};
        _ -> {noreply, S}
    end;
handle_info({'DOWN', Ref, process, Pid, _}, S = #st{extra = #{tuner := #{pid := Pid, monitor := Ref}}}) ->
    {noreply, release_guide(S)};
handle_info({P, {data, <<"R", Dim:16>>}}, S = #st{port = P, ready = false}) when
    Dim > 0, Dim =< 4096
->
    Profile =
        case S#st.profile of
            #{embedding := V} when length(V) =:= Dim -> S#st.profile;
            _ -> undefined
        end,
    logger:notice("native voice ready: embedding_dimension=~p enrolled=~p", [
        Dim, Profile =/= undefined
    ]),
    {noreply,
        bump(
            clear_timer(S#st{
                ready = true, dim = Dim, profile = Profile, error = undefined, muted = suppressed(),
                extra = (S#st.extra)#{protocol => 1, acoustic_config => unavailable}
            })
        )};
handle_info({P, {data, <<"B", Epoch:64, Id:64>>}}, S = #st{port = P, ready = true, opts = O}) ->
    {noreply, arm(maps:get(inference_timeout_ms, O), detection_end(Epoch, Id, S#st{processing = true}))};
handle_info({P, {data, <<"F">>}}, S = #st{port = P, ready = true}) ->
    {noreply, clear_timer(S#st{processing = false})};
handle_info({P, {data, <<"D", Reason/binary>>}}, S = #st{port = P}) ->
    logger:debug("native voice: ~ts", [Reason]),
    {noreply, S#st{last = {dropped, Reason}}};
handle_info({P, {data, <<"E", Reason/binary>>}}, S = #st{port = P}) ->
    {noreply, failed({native, Reason}, S)};
handle_info({P, {data, Data}}, S = #st{port = P, ready = true}) ->
    case decode(Data) of
        {ok, #{epoch := E, id := Id} = U} when
            E =:= S#st.epoch, Id > S#st.last_id, S#st.muted =:= false
        ->
            case suppressed() of
                true -> {noreply, S#st{last_id = Id, last = {dropped, tts}}};
                false -> {noreply, measured_utterance(U, S#st{last_id = Id})}
            end;
        {ok, _} ->
            {noreply, S};
        _ ->
            {noreply, failed(invalid_protocol, S)}
    end;
handle_info({P, {exit_status, N}}, S = #st{port = P}) ->
    {noreply, failed({exit_status, N}, S)};
handle_info({'EXIT', P, R}, S = #st{port = P}) ->
    {noreply, failed({port_exit, R}, S)};
handle_info({timeout, T, backend}, S = #st{timer = T}) ->
    {noreply, failed(backend_timeout, S)};
handle_info(poll, S0) ->
    S1 = case maps:get(acoustic_config, S0#st.extra, unavailable) of
        #{state := pending, requested_at := At} ->
            case now_ms() - At > 5000 of
                true -> failed(acoustic_config_timeout, S0);
                false -> S0
            end;
        _ -> S0
    end,
    S2 =
        case S1#st.enrol of
            #{deadline := D1} ->
                case now_ms() >= D1 of
                    true ->
                        logger:notice("speaker enrolment expired"),
                        end_enrol(timed_out, S1);
                    false ->
                        S1
                end;
            _ ->
                S1
        end,
    Muted = suppressed(),
    S3 =
        case S2#st.ready andalso Muted =/= S2#st.muted of
            true -> bump(S2#st{muted = Muted});
            false -> S2
        end,
    {noreply, S3#st{poll = erlang:send_after(100, self(), poll)}};
handle_info(_, S) ->
    {noreply, S}.

begin_enrol(L0, N, Timeout, S) when is_integer(N), N >= 3, N =< 10 ->
    try
        L = unicode:characters_to_binary(L0),
        true = is_binary(L) andalso byte_size(L) > 0 andalso byte_size(L) =< 128,
        logger:notice("speaker enrolment started; ~p samples; threshold=~p min_audio_ms=~p device=~ts",
            [N, maps:get(enrolment_threshold, S#st.opts),
                maps:get(min_speaker_ms, S#st.opts), maps:get(device, S#st.opts)]),
        {reply, ok, S#st{enrol = #{label => L, count => N, samples => [],
            deadline => now_ms() + Timeout, rejected => 0, last_check => undefined}}}
    catch _:_ -> {reply, {error, invalid_label}, S} end;
begin_enrol(_, _, _, S) -> {reply, {error, invalid_sample_count}, S}.

guide_available(S) ->
    case {maps:is_key(tuner, S#st.extra), maps:get(acoustic_config, S#st.extra, unavailable)} of
        {true, _} -> {error, tuning_active};
        {_, #{state := pending}} -> {error, acoustic_config_pending};
        _ -> ok
    end.
claim_guide(Pid, Mode, S) ->
    Ref = make_ref(),
    T = #{pid => Pid, monitor => monitor(process, Pid), listening => false, mode => Mode, ref => Ref},
    Next = bump(S#st{extra = (S#st.extra)#{tuner => T}}),
    case Next#st.ready andalso maps:get(protocol, Next#st.extra, 1) >= 3 of
        true -> persistent_term:put({?MODULE, guidance}, #{native => self(), owner => Pid});
        false -> ok
    end,
    {reply, {ok, (maps:with([device | erm_voice_acoustics:keys()], S#st.opts))#{
        native_protocol => maps:get(protocol, S#st.extra, 1), guide_ref => Ref}}, Next}.
clear_guidance() ->
    case persistent_term:get({?MODULE, guidance}, undefined) of
        #{native := Pid} when Pid =:= self() -> persistent_term:erase({?MODULE, guidance});
        _ -> ok
    end.

guide_kind(#st{extra = #{tuner := T}}) -> maps:get(mode, T, tuning);
guide_kind(_) -> undefined.
release_guide(S) ->
    clear_guidance(),
    Enrol = case guide_kind(S) of enrolment -> undefined; _ -> S#st.enrol end,
    bump(S#st{enrol = Enrol, extra = maps:remove(tuner, S#st.extra)}).
end_enrol(Reason, S) ->
    case maps:get(tuner, S#st.extra, undefined) of
        #{pid := Pid, mode := enrolment} = T ->
            Pid ! {voice_enrolment_stopped, self(), maps:get(ref, T, undefined), Reason},
            bump(S#st{enrol = undefined, extra = (S#st.extra)#{tuner => T#{listening => false}}});
        _ -> bump(S#st{enrol = undefined})
    end.


utterance(#{embedding := V, ms := Ms} = U, S = #st{opts = O, dim = Dim}) ->
    case Ms >= maps:get(min_speaker_ms, O) andalso length(V) =:= Dim of
        true ->
            case normalise(V) of
                {ok, N} -> accept_embedding(U, N, S);
                _ -> reject_speaker(invalid_embedding, #{audio_ms => Ms, embedding_dim => length(V)}, S)
            end;
        false ->
            case S#st.enrol =/= undefined orelse maps:get(require_speaker, O) of
                true -> reject_speaker(insufficient_audio, #{audio_ms => Ms,
                    min_audio_ms => maps:get(min_speaker_ms, O),
                    embedding_dim => length(V), expected_dim => Dim}, S);
                false -> dispatch(U, unverified, S)
            end
    end.
accept_embedding(#{ms := Ms}, N, S = #st{enrol = #{samples := Vs, count := Count} = E}) ->
    Threshold = maps:get(enrolment_threshold, S#st.opts),
    case enrolment_check(N, Vs, Threshold) of
        {reject, Check} ->
            %% Compare consecutive rejected candidates for diagnosis only.
            %% These vectors never enter the accepted set or saved profile.
            Retries = maps:get(retry_vectors, E, []),
            Scores = [score(N, V) || V <- Retries],
            RetryCheck = #{compared_samples => length(Retries), scores => Scores,
                min_score => case Scores of [] -> undefined; _ -> lists:min(Scores) end},
            reject_speaker(enrolment_inconsistent,
                Check#{audio_ms => Ms, retry_similarity => RetryCheck},
                S#st{enrol = E#{retry_vectors => lists:sublist([N | Retries], 2)}});
        {accept, Mean, Check} ->
            enrol_sample(N, Vs, Count,
                (maps:remove(retry_vectors, E))#{last_check =>
                    enrol_diagnostics(Check#{accepted => true, audio_ms => Ms}, S)}, Mean, S)
    end;
accept_embedding(U, N, S = #st{opts = O, profile = Profile}) ->
    case maps:get(require_speaker, O) of
        false ->
            dispatch(U, unverified, S);
        true ->
            case Profile of
                #{embedding := Known} ->
                    Score = score(N, Known),
                    case Score >= maps:get(speaker_threshold, O) of
                        true -> dispatch(U, Score, S);
                        false -> reject({speaker_mismatch, Score}, S)
                    end;
                _ ->
                    reject(not_enrolled, S)
            end
    end.
%% Use the same normalized mean that command verification compares against.
%% Score the candidate BEFORE including it, so it cannot improve its own match.
%% Also reject updates that make any accepted sample fail the resulting profile.
enrolment_check(N, Vs, Threshold) ->
    Scores = [score(N, V) || V <- Vs],
    CandidateScore = case Vs of
        [] -> undefined;
        _ ->
            {ok, Reference} = centroid(Vs),
            score(N, Reference)
    end,
    Check = #{method => centroid, threshold => Threshold, scores => Scores,
        compared_samples => length(Vs), candidate_score => CandidateScore,
        min_score => case Scores of [] -> undefined; _ -> lists:min(Scores) end},
    case Vs =:= [] orelse CandidateScore >= Threshold of
        false -> {reject, Check#{failed_check => candidate_score}};
        true ->
            Samples = [N | Vs],
            {ok, Mean} = centroid(Samples),
            ProfileMin = lists:min([score(V, Mean) || V <- Samples]),
            Checked = Check#{profile_min_score => ProfileMin},
            case ProfileMin >= Threshold of
                true -> {accept, Mean, Checked};
                false -> {reject, Checked#{failed_check => profile_consistency}}
            end
    end.

centroid([First | _] = Samples) ->
    Sum = lists:foldl(
        fun(V, A) -> lists:zipwith(fun(X, Y) -> X + Y end, V, A) end,
        lists:duplicate(length(First), 0.0), Samples
    ),
    normalise(Sum).

enrol_sample(N, Vs, Count, E, Mean, S) ->
    Samples = [N | Vs],
    Check = (maps:get(last_check, E))#{collected => length(Samples), target => Count,
        rejected => maps:get(rejected, E, 0)},
    logger:notice("speaker enrolment sample ~p/~p check=~tp", [
        length(Samples), Count, maps:get(last_check, E, undefined)
    ]),
    case length(Samples) =:= Count of
        false ->
            enrol_feedback(Check#{state => collecting},
                S#st{enrol = E#{samples => Samples}, last = {enrolment_sample, length(Samples)}});
        true ->
            Profile = #{
                version => 1,
                label => maps:get(label, E),
                model_hash => S#st.model_hash,
                embedding => Mean
            },
            case save_profile(maps:get(profile_file, S#st.opts), Profile) of
                ok ->
                    logger:notice("speaker enrolment saved"),
                    enrol_feedback(Check#{state => saved},
                        bump(S#st{enrol = undefined, profile = Profile, last = enrolled}));
                Error ->
                    logger:error("speaker profile save failed: ~tp", [Error]),
                    enrol_feedback(Check#{state => save_failed, save_error => Error},
                        S#st{enrol = undefined, last = Error})
            end
    end.
%% Keep the public last-result shape stable. Enrollment diagnostics contain
%% numeric scores and durations, never embeddings or recognised transcripts.
reject_speaker(Reason, Check0, S = #st{enrol = #{samples := Vs, count := Count} = E}) ->
    Rejected = maps:get(rejected, E, 0) + 1,
    Check = enrol_diagnostics(Check0#{accepted => false, reason => Reason}, S),
    Next = case Reason of enrolment_inconsistent -> E; _ -> maps:remove(retry_vectors, E) end,
    logger:notice("speaker enrolment rejected: ~tp check=~tp collected=~p/~p rejected=~p", [
        Reason, Check, length(Vs), Count, Rejected
    ]),
    enrol_feedback(Check#{state => collecting, collected => length(Vs), target => Count, rejected => Rejected},
        S#st{enrol = Next#{rejected => Rejected, last_check => Check}, last = {rejected, Reason}});
reject_speaker(Reason, Check, S) ->
    logger:debug("native utterance rejected: ~tp check=~tp", [Reason, Check]),
    S#st{last = {rejected, Reason}}.

enrol_diagnostics(Check, S) ->
    Measurement = maps:get(last_measurement, S#st.extra, #{}),
    maps:merge(maps:with([id, quality, embedding_dim, min_audio_ms], Measurement), Check).

%% Reuse the enrollment validator and atomic profile writer for guided/manual
%% enrollment. Only numeric diagnostics cross to the shared prompt coordinator.
enrol_feedback(Check, S = #st{extra = #{tuner := #{pid := Pid, mode := enrolment} = T}}) ->
    Result = Check#{kind => enrolment},
    Pid ! {voice_measurement, self(), maps:get(ref, T, undefined), Result},
    S#st{extra = (S#st.extra)#{tuner => T#{last_check => Result}}};
enrol_feedback(_, S) -> S.

reject(R, S) ->
    logger:debug("native utterance rejected: ~tp check=~tp",
        [R, maps:get(last_measurement, S#st.extra, undefined)]),
    S#st{last = {rejected, R}}.
dispatch(#{id := Id}, Score, S = #st{opts = #{observe_only := true}}) ->
    logger:debug("native speaker observation id=~p score=~p", [Id, Score]),
    S#st{last = #{id => Id, verification => Score, dispatch => observe_only}};
dispatch(#{text := Text, id := Id}, Score, S = #st{opts = O}) ->
    case maps:get(debug_utterances, O) of
        true -> logger:debug("native utterance id=~p speaker_score=~p text=~ts", [Id, Score, Text]);
        false -> ok
    end,
    case erm_voice_boundary:wake(Text, maps:get(trigger_phrases, O)) of
        {wake, <<>>} ->
            reject(wake_without_command, S);
        {wake, Command} ->
            %% Completed, verified utterance. No rolling-window state is reused.
            Result =
                try
                    erm_voice:command(Command)
                catch
                    exit:R -> {error, {coordinator, R}}
                end,
            logger:notice("native command id=~p speaker_score=~p result=~tp", [Id, Score, Result]),
            S#st{last = #{id => Id, verification => Score, dispatch => Result}};
        nomatch ->
            S#st{last = {ignored, no_wake}}
    end.
decode(<<"A", Epoch:64, Id:64, Ms:32, Dim:16,
    Rms:32/float-big, Peak:32/float-big, Clipped:32/float-big, Gain:32/float-big, Rest/binary>>)
    when Rms >= -120, Rms =< 1, Peak >= -120, Peak =< 1,
         Clipped >= 0, Clipped =< 1, Gain >= -24, Gain =< 12 ->
    case decode(<<"U", Epoch:64, Id:64, Ms:32, Dim:16, Rest/binary>>) of
        {ok, U} -> {ok, U#{quality => #{rms_dbfs => Rms, peak_dbfs => Peak,
            clipped_fraction => Clipped, input_gain_db => Gain}}};
        Error -> Error
    end;
decode(<<"U", Epoch:64, Id:64, Ms:32, Dim:16, Rest/binary>>) when
    Dim =< 4096, Ms =< 15000, byte_size(Rest) >= Dim * 4
->
    try
        <<Emb:(Dim * 4)/binary, Text/binary>> = Rest,
        true = byte_size(Text) =< 8192,
        true = is_list(unicode:characters_to_list(Text)),
        V = [F || <<F:32/float-big>> <= Emb],
        true = length(V) =:= Dim,
        {ok, #{epoch => Epoch, id => Id, ms => Ms, embedding => V, text => Text}}
    catch
        _:_ -> {error, invalid_packet}
    end;
decode(_) ->
    {error, invalid_packet}.
normalise(V) when is_list(V), length(V) > 0, length(V) =< 4096 ->
    try
        N = math:sqrt(lists:sum([X * X || X <- V])),
        true = N > 1.0e-12,
        {ok, [X / N || X <- V]}
    catch
        _:_ -> {error, invalid_embedding}
    end;
normalise(_) ->
    {error, invalid_embedding}.
score(A, B) when length(A) =:= length(B) -> lists:sum(lists:zipwith(fun(X, Y) -> X * Y end, A, B)).
suppressed() ->
    Now = now_ms(),
    Now < persistent_term:get({erm_tts, suppress_until}, Now).
bump(S = #st{port = P, epoch = E, muted = M, ready = true}) ->
    Epoch = E + 1,
    Tuner = maps:get(tuner, S#st.extra, undefined),
    Closed = case Tuner of #{listening := false} -> true; _ -> false end,
    B = (Epoch bsl 1) bor case M orelse Closed of true -> 1; false -> 0 end,
    Command = case Tuner of
        #{listening := true} = T when not M ->
            case {maps:get(mode, T, tuning), maps:get(protocol, S#st.extra, 1)} of
                {enrolment, Version} when Version >= 4 -> $E;
                {_, Version} when Version >= 3 -> $T;
                _ -> $M
            end;
        _ -> $M
    end,
    try
        true = port_command(P, <<Command, B:64>>),
        S#st{epoch = Epoch}
    catch
        _:_ -> failed(port_closed, S)
    end;
bump(S) ->
    S.
arm(Ms, S) ->
    C = clear_timer(S),
    C#st{timer = erlang:start_timer(Ms, self(), backend)}.
clear_timer(S = #st{timer = undefined}) ->
    S;
clear_timer(S = #st{timer = T}) ->
    erlang:cancel_timer(T),
    S#st{timer = undefined}.
failed(R, S) ->
    clear_guidance(),
    case maps:get(tuner, S#st.extra, undefined) of
        #{pid := Tuner} = T -> Tuner ! {voice_backend_failed, self(), maps:get(ref, T, undefined), R};
        _ -> ok
    end,
    O = S#st.opts,
    RetryMs = maps:get(backend_retry_ms, O, 5000),
    case R =:= S#st.error of
        true -> ok;
        false ->
            logger:error(
                "native voice backend failed: ~tp; binary=~ts arecord=~ts; "
                "retrying in ~p ms (identical failures suppressed)",
                [R, maps:get(binary, O), maps:get(arecord, O), RetryMs]
            )
    end,
    close_port(S#st.port),
    Next = cancel_backend_retry(clear_timer(S)),
    Next#st{
        port = undefined,
        ready = false,
        muted = true,
        enrol = undefined,
        processing = false,
        error = R,
        extra = maps:remove(acoustic_config, Next#st.extra),
        backend_retry = erlang:start_timer(RetryMs, self(), reconnect)
    }.

connect(S = #st{opts = O}) ->
    case check_executables([binary, arecord], O) of
        {error, Reason} ->
            failed(Reason, S);
        ok ->
            try
                Args =
                    [maps:get(K, O) || K <-
                        [whisper_model, vad_model, speaker_model, arecord, device, language]] ++
                    [integer_to_list(maps:get(K, O)) || K <-
                        [threads, silence_ms, max_segment_ms]],
                P = open_port({spawn_executable, maps:get(binary, O)}, [
                    binary, {packet, 4}, use_stdio, exit_status, {args, Args}
                ]),
                arm(maps:get(startup_timeout_ms, O), S#st{port = P, last_id = 0, muted = true})
            catch
                %% If the file exists, enoent can also indicate a missing script
                %% interpreter or ELF loader. Preserve the path and OS error.
                C:R -> failed({open_port, maps:get(binary, O), C, R}, S)
            end
    end.

check_executables([], _) -> ok;
check_executables([Key | Rest], O) ->
    Path = maps:get(Key, O),
    Result =
        case file:read_file_info(Path) of
            {ok, #file_info{type = regular, mode = Mode}} when Mode band 8#111 =/= 0 -> ok;
            {ok, #file_info{type = regular}} -> {error, not_executable};
            {ok, _} -> {error, not_regular};
            {error, R} -> {error, R}
        end,
    case Result of
        ok -> check_executables(Rest, O);
        {error, Reason} -> {error, {executable_unavailable, Key, Path, Reason}}
    end.

cancel_backend_retry(S = #st{backend_retry = undefined}) -> S;
cancel_backend_retry(S = #st{backend_retry = Ref}) ->
    erlang:cancel_timer(Ref),
    S#st{backend_retry = undefined}.

retry_in_ms(undefined) -> undefined;
retry_in_ms(Ref) ->
    case erlang:read_timer(Ref) of
        false -> 0;
        Ms -> Ms
    end.
now_ms() -> erlang:monotonic_time(millisecond).
load_profile(Path, Hash) ->
    try
        true = filelib:file_size(Path) =< 1048576,
        {ok, B} = file:read_file(Path),
        #{version := 1, model_hash := Hash, embedding := V} = P = binary_to_term(B, [safe]),
        {ok, N} = normalise(V),
        P#{embedding => N}
    catch
        _:_ -> undefined
    end.
save_profile(Path, P) ->
    Tmp = Path ++ ".tmp." ++ integer_to_list(erlang:unique_integer([positive])),
    try
        ok = filelib:ensure_dir(Path),
        {ok, F} = file:open(Tmp, [write, binary, exclusive]),
        try
            ok = file:change_mode(Tmp, 8#600),
            ok = file:write(F, term_to_binary(P)),
            ok = file:sync(F)
        after
            file:close(F)
        end,
        ok = file:rename(Tmp, Path),
        ok
    catch
        C:R ->
            file:delete(Tmp),
            {error, {C, R}}
    end.
hash_file(Path) ->
    {ok, F} = file:open(Path, [read, binary, raw]),
    try
        hash_chunks(F, crypto:hash_init(sha256))
    after
        file:close(F)
    end.
hash_chunks(F, C) ->
    case file:read(F, 1048576) of
        {ok, B} -> hash_chunks(F, crypto:hash_update(C, B));
        eof -> crypto:hash_final(C);
        {error, R} -> error(R)
    end.
close_port(undefined) ->
    ok;
close_port(P) ->
    try
        port_close(P)
    catch
        error:badarg -> ok
    end.
terminate(_, S) ->
    clear_guidance(),
    erlang:cancel_timer(S#st.poll),
    cancel_model_retry(S#st.model_retry),
    cancel_backend_retry(S),
    clear_timer(S),
    close_port(S#st.port),
    ok.
%% Upgrade from the pre-tuning record while the server is suspended.
code_change(_, S, _) when tuple_size(S) =:= 18, element(1, S) =:= st ->
    Upgraded = erlang:append_element(S, #{}),
    {ok, Upgraded#st{opts = erm_voice_acoustics:defaults(Upgraded#st.opts)}};
code_change(_, S, _) -> {ok, S}.

apply_config(_, S = #st{extra = #{tuner := _}}) ->
    {reply, {error, tuning_active}, S};
apply_config(Input, S) ->
    case erm_voice_acoustics:validate(Input, S#st.opts) of
        {error, _} = Error -> {reply, Error, S};
        {ok, O} ->
            AudioChanged = maps:with(erm_voice_acoustics:audio_keys(), O) =/=
                maps:with(erm_voice_acoustics:audio_keys(), S#st.opts),
            case {AudioChanged, S#st.ready, maps:get(protocol, S#st.extra, 1)} of
                {true, false, _} -> {reply, {error, not_ready}, S};
                {true, _, 1} -> {reply, {error, native_rebuild_required}, S};
                _ ->
                    Next = bump(S#st{opts = O}),
                    Applied = case AudioChanged andalso Next#st.ready of
                        true -> send_acoustics(Next);
                        false -> Next
                    end,
                    Reply = case S#st.ready andalso not Applied#st.ready of
                        true -> {error, Applied#st.error}; false -> ok end,
                    {reply, Reply, Applied}
            end
    end.

send_acoustics(S = #st{port = P, opts = O, epoch = E, muted = Muted}) ->
    Epoch = E + 1,
    Gate = (Epoch bsl 1) bor case Muted of true -> 1; false -> 0 end,
    try
        true = port_command(P, <<"C", Gate:64,
            (float(maps:get(input_gain_db, O))):32/float-big,
            (float(maps:get(vad_threshold, O))):32/float-big,
            (maps:get(silence_ms, O)):32, (maps:get(min_speech_ms, O)):32,
            (maps:get(max_segment_ms, O)):32>>),
        C = #{epoch => Epoch, state => pending, requested_at => now_ms()},
        S#st{epoch = Epoch, extra = (S#st.extra)#{acoustic_config => C}}
    catch _:_ -> failed(port_closed, S) end.

%% Protocol 3 seals capture before B, but retains the immutable inference job.
%% Do not bump its epoch here: the measurement must survive the end cue.
detection_end(Epoch, Id, S = #st{epoch = Epoch, muted = false,
    extra = #{tuner := #{pid := Pid, listening := true} = T} = X}) ->
    case not suppressed() andalso Id > S#st.last_id andalso
        not maps:is_key(detection_id, T) andalso maps:get(protocol, X, 1) >= 3 of
        true ->
            Pid ! {voice_detection_end, self(), maps:get(ref, T, undefined), Id},
            S#st{extra = X#{tuner => T#{detection_id => Id}}};
        false -> S
    end;
detection_end(_, _, S) -> S.

measured_utterance(U, S) ->
    Check = erm_voice_acoustics:measurement(U, S#st.dim, S#st.profile, S#st.opts),
    Next = S#st{extra = (S#st.extra)#{last_measurement => Check}},
    case maps:get(tuner, S#st.extra, undefined) of
        #{mode := enrolment, listening := true} = T ->
            %% Close before validation/save, including the final sample. A saved
            %% profile must never let a queued enrolment phrase execute a command.
            Closed = Next#st{extra = (Next#st.extra)#{tuner => T#{listening => false}}},
            case S#st.enrol of
                #{deadline := Deadline} ->
                    case now_ms() < Deadline of
                        true -> bump(utterance(U, Closed));
                        false -> end_enrol(timed_out, Closed)
                    end;
                undefined -> bump(Closed)
            end;
        #{pid := Pid, listening := true} = T ->
            Pid ! {voice_measurement, self(), maps:get(ref, T, undefined), Check},
            %% One utterance per prompt, including queued port messages.
            bump(Next#st{extra = (Next#st.extra)#{tuner => T#{listening => false}},
                last = {tuning, maps:get(reason, Check)}});
        #{pid := _} -> Next;
        _ -> utterance(U, Next)
    end.

model_startup_state(O) ->
    case missing_model_paths(O) of
        [] -> undefined;
        Missing -> {model_pull, {waiting_for, Missing}}
    end.

validate_explicit_model_paths(O) ->
    lists:foreach(
        fun(K) ->
            case maps:find(K, O) of
                {ok, P} -> absolute = filename:pathtype(P);
                error -> ok
            end
        end,
        model_path_keys()
    ).

resolve_models(O) ->
    case missing_model_paths(O) of
        [] ->
            {ok, O};
        Missing ->
            case maps:get(auto_pull, O, true) of
                false ->
                    {error, {missing_model_paths, Missing}};
                true ->
                    Id = maps:get(model_id, O, native_voice_base_en),
                    case erm_model_pull:ensure(Id) of
                        {ok, Paths} when is_map(Paths) ->
                            case [K || K <- Missing, not maps:is_key(K, Paths)] of
                                [] -> {ok, maps:merge(Paths, O)};
                                MissingRoles -> {error, {manifest_missing_roles, Id, MissingRoles}}
                            end;
                        Other ->
                            Other
                    end
            end
    end.

activate_models(O, S) ->
    try
        lists:foreach(
            fun(K) ->
                P = maps:get(K, O),
                absolute = filename:pathtype(P),
                true = filelib:is_regular(P)
            end,
            model_path_keys()
        ),
        Hash = hash_file(maps:get(speaker_model, O)),
        Profile = load_profile(maps:get(profile_file, O), Hash),
        {ok, cancel_model_retry_state(S#st{
            opts = O,
            model_hash = Hash,
            profile = Profile,
            error = undefined
        })}
    catch
        C:R -> {error, {invalid_model_files, C, R}, S}
    end.

missing_model_paths(O) ->
    [K || K <- model_path_keys(), not maps:is_key(K, O)].

model_path_keys() -> [whisper_model, vad_model, speaker_model].

maybe_retry_model_pull(O) ->
    case maps:get(auto_pull, O, true) of
        true -> erm_model_pull:retry(maps:get(model_id, O, native_voice_base_en));
        false -> ok
    end.

schedule_model_poll(Reason, S = #st{opts = O}) ->
    schedule_model_timer(maps:get(model_poll_ms, O, 1000), Reason, S).

schedule_model_retry(Reason, S = #st{opts = O}) ->
    logger:warning("native voice model preparation failed: ~tp; retrying", [Reason]),
    schedule_model_timer(maps:get(model_retry_ms, O, 30000), Reason, S).

schedule_model_timer(Ms, Reason, S0) ->
    S = cancel_model_retry_state(S0),
    Ref = erlang:send_after(Ms, self(), ensure_models),
    S#st{model_retry = Ref, error = Reason}.

cancel_model_retry_state(S = #st{model_retry = Ref}) ->
    cancel_model_retry(Ref),
    S#st{model_retry = undefined}.

cancel_model_retry(undefined) -> ok;
cancel_model_retry(Ref) ->
    erlang:cancel_timer(Ref),
    ok.

default_profile_file() ->
    filename:join([damage_config:state_dir(), "voice", "owner.profile"]).

default_arecord() ->
    case os:find_executable("arecord") of
        false -> "/usr/bin/arecord";
        P -> filename:absname(P)
    end.

default_binary() ->
    case code:priv_dir(erm) of
        {error, _} -> "/nonexistent/erm_native_voice";
        D -> filename:join(D, "erm_native_voice")
    end.
