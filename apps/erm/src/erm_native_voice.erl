%% One managed capture stream, native Whisper/VAD and speaker verification.
-module(erm_native_voice).
-behaviour(gen_server).
-export([start_link/1, status/0, enrol/2, cancel_enrol/0, decode/1, normalise/1, score/2]).
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
    model_retry = undefined
}).
start_link(O) -> gen_server:start_link({local, ?MODULE}, ?MODULE, O, []).
status() -> gen_server:call(?MODULE, status, 1000).
enrol(Label, Count) -> gen_server:call(?MODULE, {enrol, Label, Count}, 1000).
cancel_enrol() -> gen_server:call(?MODULE, cancel_enrol, 1000).
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
        O =
            case maps:is_key(profile_file, User) of
                true -> O1;
                false -> O1#{profile_file => default_profile_file()}
            end,
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
                {model_retry_ms, 1000, 3600000}
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
            #{label := L, count := N, samples := V} ->
                #{label => L, target => N, collected => length(V)}
        end,
    {reply,
        #{
            ready => S#st.ready,
            processing => S#st.processing,
            muted => S#st.muted,
            enrolled => S#st.profile =/= undefined,
            model_id => maps:get(model_id, S#st.opts, native_voice_base_en),
            model_paths => maps:with([whisper_model, vad_model, speaker_model], S#st.opts),
            enrolment => Enrol,
            last => S#st.last,
            error => S#st.error
        },
        S};
handle_call({enrol, L0, N}, _, S = #st{ready = true, enrol = undefined, muted = false}) when
    is_integer(N), N >= 3, N =< 10
->
    try
        L = unicode:characters_to_binary(L0),
        true = is_binary(L) andalso byte_size(L) > 0 andalso byte_size(L) =< 128,
        logger:notice("speaker enrolment started; say ~p separate utterances", [N]),
        Next = bump(S#st{
            enrol = #{label => L, count => N, samples => [], deadline => now_ms() + 120000}
        }),
        {reply, ok, Next}
    catch
        _:_ -> {reply, {error, invalid_label}, S}
    end;
handle_call({enrol, _, _}, _, S) ->
    {reply, {error, not_ready_muted_or_enrolling}, S};
handle_call(cancel_enrol, _, S) ->
    {reply, ok, bump(S#st{enrol = undefined})};
handle_call(_, _, S) ->
    {reply, {error, unsupported_call}, S}.
handle_cast(_, S) -> {noreply, S}.
handle_info(ensure_models, S = #st{opts = O}) ->
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
handle_info(connect, S = #st{port = undefined, opts = O}) ->
    try
        Args =
            [
                maps:get(K, O)
             || K <- [whisper_model, vad_model, speaker_model, arecord, device, language]
            ] ++
                [integer_to_list(maps:get(K, O)) || K <- [threads, silence_ms, max_segment_ms]],
        P = open_port({spawn_executable, maps:get(binary, O)}, [
            binary, {packet, 4}, use_stdio, exit_status, {args, Args}
        ]),
        {noreply, arm(maps:get(startup_timeout_ms, O), S#st{port = P, last_id = 0, muted = true})}
    catch
        C:R -> {noreply, failed({open_port, C, R}, S)}
    end;
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
                ready = true, dim = Dim, profile = Profile, error = undefined, muted = suppressed()
            })
        )};
handle_info({P, {data, <<"B", _:64, _:64>>}}, S = #st{port = P, ready = true, opts = O}) ->
    {noreply, arm(maps:get(inference_timeout_ms, O), S#st{processing = true})};
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
                false -> {noreply, utterance(U, S#st{last_id = Id})}
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
    S1 = S0,
    S2 =
        case S1#st.enrol of
            #{deadline := D1} ->
                case now_ms() >= D1 of
                    true ->
                        logger:notice("speaker enrolment expired"),
                        bump(S1#st{enrol = undefined});
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

utterance(#{embedding := V, ms := Ms} = U, S = #st{opts = O, dim = Dim}) ->
    case Ms >= maps:get(min_speaker_ms, O) andalso length(V) =:= Dim of
        true ->
            case normalise(V) of
                {ok, N} -> accept_embedding(U, N, S);
                _ -> reject(invalid_embedding, S)
            end;
        false ->
            case S#st.enrol =/= undefined orelse maps:get(require_speaker, O) of
                true -> reject(insufficient_audio, S);
                false -> dispatch(U, unverified, S)
            end
    end.
accept_embedding(_U, N, S = #st{enrol = #{samples := Vs, count := Count} = E}) ->
    case lists:all(fun(V) -> score(N, V) >= maps:get(speaker_threshold, S#st.opts) end, Vs) of
        false -> reject(enrolment_inconsistent, S);
        true -> enrol_sample(N, Vs, Count, E, S)
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
enrol_sample(N, Vs, Count, E, S) ->
    Samples = [N | Vs],
    logger:notice("speaker enrolment sample ~p/~p", [length(Samples), Count]),
    case length(Samples) =:= Count of
        false ->
            S#st{enrol = E#{samples => Samples}, last = {enrolment_sample, length(Samples)}};
        true ->
            Sum = lists:foldl(
                fun(V, A) -> lists:zipwith(fun(X, Y) -> X + Y end, V, A) end,
                lists:duplicate(length(N), 0.0),
                Samples
            ),
            {ok, Mean} = normalise(Sum),
            Profile = #{
                version => 1,
                label => maps:get(label, E),
                model_hash => S#st.model_hash,
                embedding => Mean
            },
            case save_profile(maps:get(profile_file, S#st.opts), Profile) of
                ok ->
                    logger:notice("speaker enrolment saved"),
                    bump(S#st{enrol = undefined, profile = Profile, last = enrolled});
                Error ->
                    logger:error("speaker profile save failed: ~tp", [Error]),
                    S#st{enrol = undefined, last = Error}
            end
    end.
reject(R, S) ->
    logger:debug("native utterance rejected: ~tp", [R]),
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
    B =
        (Epoch bsl 1) bor
            case M of
                true -> 1;
                false -> 0
            end,
    try
        true = port_command(P, <<"M", B:64>>),
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
    logger:error("native voice backend failed: ~tp", [R]),
    close_port(S#st.port),
    erlang:send_after(5000, self(), connect),
    clear_timer(S#st{
        port = undefined,
        ready = false,
        muted = true,
        enrol = undefined,
        processing = false,
        error = R
    }).
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
    erlang:cancel_timer(S#st.poll),
    cancel_model_retry(S#st.model_retry),
    close_port(S#st.port),
    ok.
code_change(_, S, _) -> {ok, S}.

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
