%% Shared prompts/cues for bounded acoustic trials and speaker enrolment.
%% Commands are gated by erm_native_voice, including while prompts play. Reports contain no audio, text or embeddings.
-module(erm_voice_tune).
-behaviour(gen_server).
-export([start/1, enrol/3, status/0, cancel/0, cancel_enrol/0, history/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-record(st, {session = undefined, history = [], worker = undefined, timer = undefined}).

start(Options) -> start_request({start, tuning, Options}).
enrol(Label, Count, Options) ->
    try
        M = option_map(Options),
        [] = maps:keys(M) -- [tts, cues, timeout_ms],
        true = is_integer(Count) andalso Count >= 3 andalso Count =< 10,
        start_request({start, enrolment, M#{label => Label, samples => Count}})
    catch _:_ -> {error, invalid_enrolment_options} end.
start_request(Request) ->
    case whereis(?MODULE) of
        undefined ->
            case gen_server:start({local, ?MODULE}, ?MODULE, [], []) of
                {ok, _} -> call(Request);
                {error, {already_started, _}} -> call(Request);
                Error -> Error
            end;
        _ -> call(Request)
    end.
status() -> call(status).
cancel() -> call(cancel).
cancel_enrol() -> call(cancel_enrol).
history() -> call(history).
call(Request) ->
    try gen_server:call(?MODULE, Request, 5000)
    catch exit:{noproc, _} -> {error, not_started} end.
init([]) ->
    logger:update_process_metadata(#{domain => [erm, voice, native]}),
    {ok, #st{}}.

handle_call({start, _, _}, _, S = #st{session = E}) when E =/= undefined ->
    Reason = case maps:get(kind, E, tuning) of enrolment -> enrollment_active; _ -> tuning_active end,
    {reply, {error, Reason}, S};
handle_call({start, Kind, Input}, _, S) ->
    case options(Input) of
        {error, _} = Error -> {reply, Error, S};
        {ok, O} ->
            Claim = case Kind of
                tuning -> {tune_claim, self()};
                enrolment -> {enrol_claim, self(), maps:get(label, O), maps:get(samples, O), maps:get(timeout_ms, O)}
            end,
            case native(Claim) of
                {ok, #{native_protocol := Version}} when Version < 3, map_get(cues, O) ->
                    _ = native(tune_release),
                    {reply, {error, native_rebuild_required}, S};
                {ok, Config} ->
                    Pid = whereis(erm_native_voice),
                    Ref = monitor(process, Pid),
                    E = #{kind => Kind, options => O, config => maps:remove(guide_ref, Config),
                        guide_ref => maps:get(guide_ref, Config), native => Pid, monitor => Ref,
                        token => make_ref(), started => now_ms(),
                        deadline => now_ms() + maps:get(timeout_ms, O),
                        phase => prompting, checks => [], collected => 0},
                    Timer = erlang:start_timer(25, self(), poll),
                    {reply, ok, prompt(introduction(Kind), S#st{session = E, timer = Timer})};
                Error -> {reply, Error, S}
            end
    end;
handle_call(status, _, S) ->
    Active = case S#st.session of
        undefined -> undefined;
        E -> #{kind => maps:get(kind, E, tuning), label => maps:get(label, maps:get(options, E)), phase => maps:get(phase, E),
            collected => maps:get(collected, E), attempts => length(maps:get(checks, E)),
            target => maps:get(samples, maps:get(options, E)),
            remaining_ms => max(0, maps:get(deadline, E) - now_ms()),
            prompt => maps:get(prompt, E, undefined),
            expected_phrase => maps:get(expected_phrase, E, undefined),
            last_check => case maps:get(checks, E) of [] -> undefined; [C | _] -> C end}
    end,
    {reply, #{active => Active, last_report => case S#st.history of
        [] -> undefined; [Report | _] -> Report end}, S};
handle_call(history, _, S) -> {reply, lists:reverse(S#st.history), S};
handle_call(cancel_enrol, _, S = #st{session = #{kind := enrolment}}) ->
    {reply, ok, finish(cancelled, S)};
handle_call(cancel_enrol, _, S) -> {reply, not_guided, S};
handle_call(cancel, _, S) -> {reply, ok, finish(cancelled, S)};
handle_call(_, _, S) -> {reply, {error, unsupported_call}, S}.
handle_cast(_, S) -> {noreply, S}.

handle_info({prompt_ready, Token, Result}, S = #st{session = #{token := Token} = E}) ->
    case Result of
        ok -> ok;
        _ -> logger:notice("voice guide TTS unavailable: ~tp; use the logged prompt", [Result])
    end,
    Next = S#st{worker = undefined},
    case maps:get(phase, E) of
        finishing -> {noreply, finish(maps:get(outcome, E), Next)};
        _ -> {noreply, arm_prompt(Next#st{session = E#{phase => arming, prompt_ready_at => now_ms()}})}
    end;
handle_info({voice_detection_end, Pid, GuideRef, Id},
    S = #st{session = #{native := Pid, guide_ref := GuideRef, phase := listening}}) ->
    {noreply, detected(Id, S)};
handle_info({tts_cue, Ref, Result}, S = #st{session = #{cue_ref := Ref} = E}) ->
    Next = S#st{session = maps:remove(cue_ref, E)},
    case {Result, maps:get(cue_kind, E)} of
        {ok, ready} -> {noreply, listen(Next)};
        {ok, 'end'} ->
            {noreply, maybe_measurement(Next#st{session = (Next#st.session)#{end_cue_done => true}})};
        _ -> {noreply, finish({cue_failed, Result}, Next)}
    end;
handle_info({voice_measurement, Pid, GuideRef, Check},
    S = #st{session = #{native := Pid, guide_ref := GuideRef, phase := Phase}})
    when Phase =:= listening; Phase =:= processing ->
    %% Older/manual sources may deliver a measurement without B. Feedback still
    %% follows the end cue; protocol 3 normally notifies us before inference.
    Next = case Phase of listening -> detected(undefined, S); _ -> S end,
    case Next#st.session of
        undefined -> {noreply, Next};
        E ->
            logger:debug("voice guide kind=~p result id=~p detection_to_result_ms=~p",
                [maps:get(kind, E, tuning), maps:get(id, Check, undefined), elapsed(detected_at, E)]),
            {noreply, maybe_measurement(Next#st{session = E#{pending_check => Check}})}
    end;
handle_info({timeout, Ref, poll}, S = #st{session = undefined, timer = Ref}) -> {noreply, S#st{timer = undefined}};
handle_info({timeout, Ref, poll}, S = #st{session = E, timer = Ref}) ->
    Next = case now_ms() >= maps:get(deadline, E) of
        true -> expired(S);
        false ->
            arm_prompt(S)
    end,
    case Next#st.session of
        undefined -> {noreply, Next};
        _ -> {noreply, Next#st{timer = erlang:start_timer(25, self(), poll)}}
    end;
handle_info({voice_enrolment_stopped, Pid, GuideRef, _},
    S = #st{session = #{native := Pid, guide_ref := GuideRef, phase := finishing}}) -> {noreply, S};
handle_info({voice_enrolment_stopped, Pid, GuideRef, timed_out},
    S = #st{session = #{native := Pid, guide_ref := GuideRef, kind := enrolment}}) -> {noreply, expired(S)};
handle_info({voice_enrolment_stopped, Pid, GuideRef, Reason},
    S = #st{session = #{native := Pid, guide_ref := GuideRef, kind := enrolment}}) -> {noreply, finish(Reason, S)};
handle_info({voice_backend_failed, Pid, GuideRef, Reason}, S = #st{session = #{native := Pid, guide_ref := GuideRef}}) ->
    {noreply, finish({backend_failed, Reason}, S)};
handle_info({'DOWN', Ref, process, _, Reason}, S = #st{session = #{monitor := Ref}}) ->
    {noreply, finish({native_down, Reason}, S)};
handle_info(_, S) -> {noreply, S}.

options(Input) ->
    try
        M = option_map(Input),
        [] = maps:keys(M) -- [label, samples, tts, cues, timeout_ms],
        O = maps:merge(#{label => <<"trial">>, samples => 3, tts => true, cues => true, timeout_ms => 180000}, M),
        N = maps:get(samples, O), true = is_integer(N) andalso N >= 1 andalso N =< 10,
        T = maps:get(timeout_ms, O), true = is_integer(T) andalso T >= 1000 andalso T =< 600000,
        true = is_boolean(maps:get(tts, O)),
        true = is_boolean(maps:get(cues, O)),
        Label = unicode:characters_to_binary(maps:get(label, O)),
        true = is_binary(Label) andalso byte_size(Label) > 0 andalso byte_size(Label) =< 128,
        {ok, O#{label => Label}}
    catch _:_ -> {error, invalid_tuning_options} end.

option_map(M) when is_map(M) -> M;
option_map(L) when is_list(L) ->
    true = lists:all(fun({K, _}) -> is_atom(K); (_) -> false end, L),
    proplists:to_map(L).
introduction(tuning) -> "Voice check. ";
introduction(enrolment) -> "Voice enrolment. ".
phrase(#{kind := enrolment, collected := N, options := O}) ->
    Phrases = ["I am speaking naturally at my usual volume.",
        "This is how my voice sounds in this room.",
        "Please remember my voice when I speak clearly."],
    {io_lib:format("Sample ~p of ~p. ", [N + 1, maps:get(samples, O)]),
        lists:nth(N rem length(Phrases) + 1, Phrases)};
phrase(E) ->
    [Wake | _] = maps:get(trigger_phrases, maps:get(config, E)),
    {[], [Wake, ", please stop the music."]}.

prompt(Feedback, S = #st{session = E}) ->
    _ = native({tune_listen, false}),
    {Progress, Phrase} = phrase(E),
    Instruction = case maps:get(cues, maps:get(options, E)) of
        true -> " After the beep: ";
        false -> " When status shows listening, say: "
    end,
    Text = case E of
        #{kind := enrolment, checks := [#{accepted := false} | _]} ->
            [Feedback, "Repeat that sentence."];
        _ -> [Feedback, Progress, Instruction, Phrase]
    end,
    Clean = maps:without([pending_check, detected_id, detected_at, end_cue_done,
        cue_ref, cue_kind, cue_started_at, prompt_ready_at, listening_at], E),
    speak(Text, S#st{session = Clean#{phase => prompting,
        expected_phrase => unicode:characters_to_binary(Phrase)}}).

arm_prompt(S = #st{session = #{phase := arming, options := O}}) ->
    case native(tune_ready) of
        ok -> case maps:get(cues, O) of true -> cue(ready, S); false -> listen(S) end;
        _ -> S
    end;
arm_prompt(S) -> S.

listen(S = #st{session = E}) ->
    case native({tune_listen, true}) of
        ok ->
            Now = now_ms(),
            Start = maps:get(prompt_started_at, E, Now),
            Ready = maps:get(prompt_ready_at, E, Now),
            Cue = maps:get(cue_started_at, E, Now),
            Timing = #{ready_ms => Now - Start, speech_wait_ms => Ready - Start,
                arm_wait_ms => Cue - Ready, cue_ms => Now - Cue},
            logger:notice("voice guide kind=~p listening sample=~p timing=~tp",
                [maps:get(kind, E, tuning), maps:get(collected, E) + 1, Timing]),
            S#st{session = E#{phase => listening, listening_at => Now}};
        Error -> finish({listen_failed, Error}, S)
    end.
cue(Kind, S = #st{session = E}) ->
    Result = try erm_tts:tuning_cue(Kind) catch C:R -> {error, {C, R}} end,
    case Result of
        {ok, Ref} ->
            Phase = case Kind of ready -> ready_cue; 'end' -> processing end,
            S#st{session = E#{phase => Phase, cue_ref => Ref, cue_kind => Kind, cue_started_at => now_ms()}};
        {error, busy} when Kind =:= ready -> S; % bounded by the trial deadline
        Error -> finish({cue_failed, Error}, S)
    end.
detected(Id, S = #st{session = E}) ->
    logger:notice("voice guide kind=~p detection ended id=~p listen_ms=~p; analysing sample",
        [maps:get(kind, E, tuning), Id, elapsed(listening_at, E)]),
    UseCues = maps:get(cues, maps:get(options, E)),
    Next = S#st{session = E#{phase => processing, detected_id => Id,
        detected_at => now_ms(), end_cue_done => not UseCues}},
    case UseCues of true -> cue('end', Next); false -> Next end.
maybe_measurement(S = #st{session = #{end_cue_done := true, pending_check := Check} = E}) ->
    measurement(Check, S#st{session = maps:remove(pending_check, E)});
maybe_measurement(S) -> S.
measurement(#{kind := enrolment} = Check, S = #st{session = #{kind := enrolment} = E}) ->
    Updated = E#{collected => maps:get(collected, Check), checks => [Check | maps:get(checks, E)]},
    Next = S#st{session = Updated},
    case maps:get(state, Check) of
        saved -> enrol_terminal(completed, "Voice profile saved. You're ready.", Next);
        save_failed -> enrol_terminal({save_failed, maps:get(save_error, Check)},
            "I could not save your voice profile. Check the enrolment log and try again.", Next);
        collecting ->
            case length(maps:get(checks, Updated)) >= 3 * maps:get(samples, maps:get(options, E)) of
                true -> enrol_terminal(insufficient_samples,
                    "Enrolment stopped after too many unsuccessful attempts. Your saved profile is unchanged.", Next);
                false -> prompt(enrol_advice(Check), Next)
            end
    end;
measurement(Check, S = #st{session = E}) ->
    Usable = is_number(maps:get(score, Check, undefined)) andalso maps:get(wake_detected, Check),
    Collected = maps:get(collected, E) + case Usable of true -> 1; false -> 0 end,
    Checks = [Check | maps:get(checks, E)],
    Updated = E#{checks => Checks, collected => Collected},
    Target = maps:get(samples, maps:get(options, E)),
    logger:notice("voice tuning sample collected=~p/~p check=~tp", [Collected, Target, Check]),
    Next = S#st{session = Updated},
    case Collected >= Target orelse length(Checks) >= 3 * Target of
        true ->
            Outcome = case Collected >= Target of true -> completed; false -> insufficient_samples end,
            Summary = report(Outcome, Updated),
            End = io_lib:format("Trial finished. ~p of ~p measured utterances matched your profile. ~ts",
                [maps:get(matched, Summary), maps:get(measured, Summary), advice(Check)]),
            speak(End, Next#st{session = Updated#{phase => finishing, outcome => Outcome}});
        false -> prompt(advice(Check), Next)
    end.

enrol_advice(#{accepted := true}) -> "Accepted. ";
enrol_advice(#{reason := insufficient_audio, audio_ms := Ms, min_audio_ms := Min}) when Ms < Min ->
    io_lib:format("Too short. Speak for at least ~p seconds. ", [(Min + 999) div 1000]);
enrol_advice(#{quality := #{clipped_fraction := Fraction}}) when Fraction > 0.01 ->
    "Recording clipped. Check microphone gain. ";
enrol_advice(#{quality := #{rms_dbfs := Rms}}) when Rms < -40 ->
    "Too quiet. Move closer. ";
enrol_advice(#{reason := insufficient_audio}) ->
    "No voice sample. Speak clearly. ";
enrol_advice(#{reason := invalid_embedding}) ->
    "Unusable voice sample. ";
enrol_advice(#{reason := enrolment_inconsistent}) ->
    "No match. ";
enrol_advice(_) -> "Try again. ".

expired(S = #st{session = #{phase := finishing} = E}) ->
    finish(maps:get(outcome, E, timed_out), S);
expired(S = #st{session = #{kind := enrolment} = E}) ->
    %% Saving is authoritative even if its feedback cue has not finished yet.
    case maps:get(profile_saved, report(timed_out, E)) of
        true -> enrol_terminal(completed, "Voice profile saved. You're ready.", S);
        false -> enrol_terminal(timed_out, "Enrolment timed out. Your saved profile is unchanged.", S)
    end;
expired(S) -> finish(timed_out, S).
enrol_terminal(Outcome, Text, S = #st{session = E}) ->
    stop_output(S),
    Synced = sync_enrol(E),
    %% A save may have finished while its event was queued behind the deadline.
    %% The native snapshot is authoritative for both the announcement and report.
    {FinalOutcome, FinalText} = case maps:get(checks, Synced) of
        [#{state := saved} | _] -> {completed, "Voice profile saved. You're ready."};
        [#{state := save_failed, save_error := Error} | _] ->
            {{save_failed, Error}, "I could not save your voice profile. Check the enrolment log and try again."};
        _ -> {Outcome, Text}
    end,
    Clean = maps:without([cue_ref, cue_kind], Synced),
    %% Reserve a bounded final announcement without accepting further samples.
    speak(FinalText, S#st{worker = undefined, session = Clean#{phase => finishing,
        outcome => FinalOutcome, deadline => now_ms() + 15000}}).

speak(Text, S = #st{session = E}) ->
    Prompt = unicode:characters_to_binary(Text),
    logger:notice("voice guide kind=~p prompt: ~ts", [maps:get(kind, E, tuning), Prompt]),
    Token = make_ref(), Owner = self(),
    UseTts = maps:get(tts, maps:get(options, E)),
    Deadline = min(maps:get(deadline, E), now_ms() + 45000),
    Worker = spawn(fun() ->
        Result = case UseTts of true -> speak_wait(Prompt, Deadline); false -> ok end,
        Owner ! {prompt_ready, Token, Result}
    end),
    S#st{worker = Worker, session = E#{token => Token, prompt => Prompt, prompt_started_at => now_ms()}}.

elapsed(Key, E) ->
    case maps:find(Key, E) of {ok, T} -> now_ms() - T; error -> undefined end.

%% Runs outside both gen_servers. Wait for playback AND the existing echo tail.
speak_wait(Text, Deadline) ->
    case now_ms() >= Deadline of
        true -> {error, prompt_timeout};
        false ->
            try erm_tts:say(Text) of
                ok -> wait_silent(Deadline);
                {error, busy} -> receive after 25 -> speak_wait(Text, Deadline) end;
                Error -> Error
            catch C:R -> {error, {C, R}} end
    end.
wait_silent(Deadline) ->
    case now_ms() >= Deadline of
        true -> {error, prompt_timeout};
        false ->
            case erm_tts:status() of
                #{speaking := false, listening_suppressed := false} -> ok;
                #{speaking := _} -> receive after 20 -> wait_silent(Deadline) end;
                Error -> {error, {tts_status, Error}}
            end
    end.

advice(#{quality := #{clipped_fraction := Fraction}}) when Fraction > 0.01 ->
    "The recording is clipping. Lower microphone gain for the next trial. ";
advice(#{quality := #{rms_dbfs := Rms}}) when Rms < -40 ->
    "The recording level is low. Move closer to the microphone for the next trial. ";
advice(#{reason := insufficient_audio}) -> "That sample was too short or lacked a speaker embedding. ";
advice(#{wake_detected := false}) -> "I did not detect the wake phrase. Please repeat the full phrase. ";
advice(#{accepted := false}) -> "The voice match was below the threshold. ";
advice(_) -> "Matched. ".

report(Outcome, #{kind := enrolment} = E) ->
    Checks0 = maps:get(checks, E),
    Checks = case maps:get(pending_check, E, undefined) of
        undefined -> Checks0;
        Pending -> [Pending | Checks0]
    end,
    Last = case Checks of [] -> #{}; [C | _] -> C end,
    #{kind => enrolment, label => maps:get(label, maps:get(options, E)), outcome => Outcome,
        elapsed_ms => now_ms() - maps:get(started, E), config => maps:get(config, E),
        target => maps:get(samples, maps:get(options, E)),
        collected => maps:get(collected, Last, 0), rejected => maps:get(rejected, Last, 0),
        profile_saved => maps:get(state, Last, undefined) =:= saved,
        checks => lists:reverse(Checks)};
report(Outcome, E) ->
    Checks = lists:reverse(maps:get(checks, E)),
    Measured = [C || C <- Checks, is_number(maps:get(score, C, undefined)), maps:get(wake_detected, C)],
    Scores = [maps:get(score, C) || C <- Measured],
    Stats = case Scores of
        [] -> #{min => undefined, max => undefined, mean => undefined};
        _ -> #{min => lists:min(Scores), max => lists:max(Scores), mean => lists:sum(Scores) / length(Scores)}
    end,
    #{kind => tuning, label => maps:get(label, maps:get(options, E)), outcome => Outcome,
        elapsed_ms => now_ms() - maps:get(started, E), config => maps:get(config, E),
        measured => length(Measured), matched => length([C || C <- Measured, maps:get(accepted, C)]),
        score => Stats, checks => Checks}.
finish(_, S = #st{session = undefined}) -> S;
finish(Outcome, S = #st{session = E0}) ->
    stop_output(S),
    E = sync_enrol(E0),
    case S#st.timer of undefined -> ok; Timer -> erlang:cancel_timer(Timer) end,
    _ = native(tune_release),
    demonitor(maps:get(monitor, E), [flush]),
    Report = report(Outcome, E),
    logger:notice("voice guide finished: ~tp", [maps:without([checks], Report)]),
    S#st{session = undefined, worker = undefined, timer = undefined,
        history = lists:sublist([Report | S#st.history], 10)}.
sync_enrol(#{kind := enrolment} = E) ->
    case native({enrol_abort, self()}) of
        {ok, Check} when is_map(Check) ->
            Checks0 = maps:get(checks, E),
            Checks1 = case maps:get(pending_check, E, undefined) of
                undefined -> Checks0; Pending -> [Pending | Checks0]
            end,
            Checks = case Checks1 of [Check | _] -> Checks1; _ -> [Check | Checks1] end,
            (maps:remove(pending_check, E))#{checks => Checks, collected => maps:get(collected, Check)};
        _ -> E
    end;
sync_enrol(E) -> E.

stop_output(S = #st{session = E}) ->
    stop_worker(S#st.worker),
    case maps:get(cue_ref, E, undefined) of
        undefined -> ok;
        CueRef -> try erm_tts:cancel_cue(CueRef) catch _:_ -> ok end
    end.

native(Request) ->
    try gen_server:call(erm_native_voice, Request, 2000)
    catch exit:Reason -> {error, {native, Reason}} end.
stop_worker(undefined) -> ok;
stop_worker(Pid) -> exit(Pid, kill).
now_ms() -> erlang:monotonic_time(millisecond).
terminate(_, S) -> _ = finish(cancelled, S), ok.
code_change(_, S, _) -> {ok, S}.
