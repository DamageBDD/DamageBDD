%% Supervised voice coordinator. No LLM or MPV work blocks this gen_server.
-module(erm_voice).
-behaviour(gen_server).
-export([
    start_link/1,
    transcript/2,
    command/1,
    status/0,
    reset/0,
    options/1,
    healthcheck/0, healthcheck/1
]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(st, {
    opts,
    boundary,
    tick,
    job = undefined,
    last_result = undefined,
    last_command = undefined,
    completed = 0,
    priority = undefined
}).

healthcheck() -> erm_voice_health:check().
healthcheck(Opts) -> erm_voice_health:check(Opts).

start_link(Opts) -> gen_server:start_link({local, ?MODULE}, ?MODULE, Opts, []).
transcript(Text, Phrases) ->
    case whereis(?MODULE) of
        undefined ->
            {error, not_started};
        Pid ->
            %% Drop input if a misbehaving source floods the mailbox.
            case process_info(Pid, message_queue_len) of
                {message_queue_len, N} when N < 100 ->
                    gen_server:cast(Pid, {transcript, Text, Phrases});
                _ ->
                    {error, overloaded}
            end
    end.
command(Text) -> gen_server:call(?MODULE, {command, Text}, 1000).
status() -> gen_server:call(?MODULE, status, 1000).
reset() -> gen_server:cast(?MODULE, reset).

options(Options) ->
    try
        M =
            case Options of
                O when is_map(O) -> O;
                O when is_list(O) -> proplists:to_map(O)
            end,
        true = is_boolean(maps:get(enabled, M, true)),
        true = is_boolean(maps:get(require_final, M, false)),
        Defaults = #{
            settle_ms => 1100,
            urgent_settle_ms => 300,
            command_window_ms => 8000,
            rearm_silence_ms => 6000,
            command_dedupe_ms => 6000,
            max_command_bytes => 512,
            planning_timeout_ms => 30000,
            action_timeout_ms => 30000,
            ollama_timeout_ms => 12000,
            ecai_timeout_ms => 4000
        },
        Opts = maps:merge(Defaults, M),
        lists:foreach(
            fun(K) ->
                V = maps:get(K, Opts),
                true = is_integer(V) andalso V > 0 andalso V =< 120000
            end,
            maps:keys(Defaults)
        ),
        true = maps:get(settle_ms, Opts) < maps:get(command_window_ms, Opts),
        true = maps:get(max_command_bytes, Opts) =< 4096,
        true = is_boolean(maps:get(auto_pull_model, Opts, true)),
        PullTimeout = maps:get(model_pull_timeout_ms, Opts, 600000),
        true = is_integer(PullTimeout) andalso PullTimeout > 0 andalso PullTimeout =< 3600000,
        Actions = maps:get(actions, Opts, []),
        true = is_list(Actions) andalso length(Actions) =< 32,
        Builtins = erm_voice_intent:actions(#{}),
        lists:foreach(
            fun({Name, Description, {Mod, Fun}}) ->
                true = is_binary(Name) andalso byte_size(Name) > 0 andalso byte_size(Name) =< 64,
                nomatch = re:run(Name, "[^a-z0-9_]"),
                false = lists:member(Name, Builtins),
                true = is_atom(Mod) andalso is_atom(Fun),
                true = is_binary(unicode:characters_to_binary(Description))
            end,
            Actions
        ),
        Names = [N || {N, _, _} <- Actions],
        true = length(Names) =:= length(lists:usort(Names)),
        {ok, Opts}
    catch
        _:_ -> {error, invalid_voice_configuration}
    end.

init(Options) ->
    logger:update_process_metadata(#{domain => [erm, voice]}),
    process_flag(trap_exit, true),
    case options(Options) of
        {ok, Opts} ->
            {ok, #st{
                opts = Opts,
                boundary = erm_voice_boundary:new(),
                tick = erlang:send_after(100, self(), tick)
            }};
        {error, Reason} ->
            {stop, Reason}
    end.
handle_call(status, _From, S) ->
    {reply,
        #{
            phase => maps:get(phase, S#st.boundary),
            busy => S#st.job =/= undefined orelse S#st.priority =/= undefined,
            priority_busy => S#st.priority =/= undefined,
            model => maps:get(model, S#st.opts, "qwen3:1.7b"),
            last_command => S#st.last_command,
            last_result => S#st.last_result,
            health_settings => maps:with(
                [ollama_host, ollama_port, require_final, ecai_base_dir], S#st.opts
            ),
            completed => S#st.completed
        },
        S};
handle_call({command, Text0}, _From, S) ->
    case safe_command(Text0, S#st.opts) of
        {ok, Text} ->
            {Reply, Next} = accept(Text, S),
            {reply, Reply, Next};
        Error ->
            {reply, Error, S}
    end;
handle_call({media_permit, Ref}, _From, S) ->
    Allowed = lists:any(
        fun
            (#{ref := R}) -> R =:= Ref;
            (_) -> false
        end,
        [S#st.job, S#st.priority]
    ),
    {reply, Allowed, S};
handle_call(_, _From, S) ->
    {reply, {error, unsupported_call}, S}.

handle_cast({transcript, Text, Phrases}, S) ->
    try erm_voice_boundary:feed(Text, Phrases, now_ms(), S#st.boundary, S#st.opts) of
        B ->
            case boundary_changed(S#st.boundary, B) of
                true ->
                    utterance_trace(
                        transcript,
                        #{
                            raw => bounded_text(Text),
                            before => boundary_view(S#st.boundary),
                            after_state => boundary_view(B)
                        },
                        S
                    );
                false ->
                    ok
            end,
            %% Final records have a real boundary: consume them before another
            %% cast can replace the candidate. Legacy text still waits for tick.
            Next = S#st{boundary = B},
            case Text of
                #{final := true} -> {noreply, dispatch_boundary(Next)};
                _ -> {noreply, Next}
            end
    catch
        Class:Reason ->
            subsystem_log(warning, "voice transcript rejected: ~p:~tp", [Class, Reason]),
            {noreply, S#st{boundary = erm_voice_boundary:cancel(S#st.boundary)}}
    end;
handle_cast(reset_boundary, S) ->
    {noreply, S#st{boundary = erm_voice_boundary:new()}};
handle_cast(reset, S) ->
    {noreply, (cancel_plan(S))#st{boundary = erm_voice_boundary:new()}};
handle_cast(_, S) ->
    {noreply, S}.

handle_info(tick, S0) ->
    {noreply, dispatch_boundary(S0#st{tick = erlang:send_after(100, self(), tick)})};
handle_info(
    {voice_model_pull, Ref},
    S = #st{
        opts = Opts,
        job = #{ref := Ref, phase := plan, timer := OldTimer} = Job
    }
) ->
    erlang:cancel_timer(OldTimer),
    %% Pulling can take minutes. Keep it in the cancellable planning worker.
    Budget =
        maps:get(model_pull_timeout_ms, Opts, 600000) +
            2 * maps:get(ollama_timeout_ms, Opts, 12000) + 5000,
    TimerToken = make_ref(),
    Timer = erlang:send_after(Budget, self(), {voice_timeout, Ref, TimerToken}),
    {noreply, S#st{job = Job#{timer => Timer, timeout_token => TimerToken}}};
%% Reuse normal worker cleanup for the independently tracked priority lane.
handle_info({voice_result, Ref, _} = Msg, S = #st{priority = #{ref := Ref}}) ->
    priority_info(Msg, S);
handle_info(
    {voice_timeout, Ref, Token} = Msg, S = #st{priority = #{ref := Ref, timeout_token := Token}}
) ->
    priority_info(Msg, S);
handle_info({'DOWN', Mon, process, _, _} = Msg, S = #st{priority = #{monitor := Mon}}) ->
    priority_info(Msg, S);
handle_info({voice_result, Ref, Result}, S = #st{job = #{ref := Ref, phase := plan}}) ->
    Ready = finish_job(S),
    case Result of
        {ok, #{action := answer} = Answer} -> {noreply, record_result({ok, Answer}, Ready)};
        {ok, Intent} when is_map(Intent) -> {noreply, launch(action, Intent, Ready)};
        Error -> {noreply, record_result(Error, Ready)}
    end;
handle_info({voice_result, Ref, Result}, S = #st{job = #{ref := Ref, phase := action}}) ->
    {noreply, record_result(Result, finish_job(S))};
handle_info(
    {voice_timeout, Ref, Token},
    S = #st{job = #{ref := Ref, timeout_token := Token, pid := Pid, phase := Phase}}
) ->
    unlink(Pid),
    exit(Pid, kill),
    %% An action timeout is indeterminate: never retry it automatically.
    {noreply, record_result({error, {Phase, timeout}}, finish_job(S))};
handle_info({'DOWN', Mon, process, _Pid, Reason}, S = #st{job = #{monitor := Mon}}) ->
    {noreply, record_result({error, {worker_down, Reason}}, finish_job(S))};
handle_info(_, S) ->
    {noreply, S}.

%% Completion state and TTS must describe the worker that actually finished.
finish_job(S = #st{job = #{command := Command}}) ->
    (clear_job(S))#st{last_command = Command}.

dispatch_boundary(S0) ->
    {Event, B} = erm_voice_boundary:tick(now_ms(), S0#st.boundary, S0#st.opts),
    case boundary_changed(S0#st.boundary, B) orelse Event =/= none of
        true ->
            utterance_trace(
                capture_tick,
                #{
                    event_result => Event,
                    before => boundary_view(S0#st.boundary),
                    after_state => boundary_view(B)
                },
                S0
            );
        false ->
            ok
    end,
    S1 = S0#st{boundary = B},
    case Event of
        {command, Text} ->
            {Reply, S2} = accept(Text, S1),
            case Reply of
                {error, busy} ->
                    subsystem_log(notice, "voice command rejected (busy): ~tp", [Text]);
                _ ->
                    ok
            end,
            S2;
        none ->
            S1
    end.

priority_info(Msg, S) ->
    {noreply, Next} = handle_info(Msg, S#st{job = S#st.priority, priority = undefined}),
    {noreply, Next#st{job = S#st.job, priority = Next#st.job}}.

accept(_Text, S = #st{priority = P}) when P =/= undefined ->
    {{error, busy}, S};
accept(Text, S = #st{job = #{phase := action}}) ->
    case erm_voice_intent:parse(Text) of
        {ok, #{action := A} = Intent} when A =:= stop; A =:= pause ->
            %% Existing side effects are NOT rolled back. Cancel builtin
            %% workers, retain custom jobs, and submit to the same MPV owner.
            Base = cancel_media_job(S),
            Priority = launch(action, Intent, Base#st{job = undefined, last_command = Text}),
            {ok, Priority#st{priority = Priority#st.job, job = Base#st.job}};
        _ ->
            {{error, busy}, S}
    end;
accept(Text, S = #st{job = undefined}) ->
    {ok, launch(plan, Text, S#st{last_command = Text})};
accept(Text, S = #st{job = #{phase := plan}}) ->
    case erm_voice_intent:parse(Text) of
        {ok, #{action := A}} when A =:= stop; A =:= pause ->
            accept(Text, cancel_plan(S));
        {error, cancelled} ->
            {ok, record_result({error, cancelled}, cancel_plan(S))};
        _ ->
            {{error, busy}, record_result({error, busy}, S)}
    end;
accept(_Text, S) ->
    {{error, busy}, record_result({error, busy}, S)}.

launch(Phase, Input, S = #st{opts = Opts}) ->
    utterance_trace(dispatch, #{stage => Phase, input => Input}, S),
    Parent = self(),
    Ref = make_ref(),
    {Pid, Mon} = spawn_opt(
        fun() ->
            logger:update_process_metadata(#{domain => [erm, voice]}),
            Result =
                try
                    case Phase of
                        plan ->
                            erm_voice_intent:plan(Input, Opts#{
                                model_pull_notify =>
                                    fun() -> Parent ! {voice_model_pull, Ref} end
                            });
                        action ->
                            put(erm_voice_job_ref, Ref),
                            execute(Input, Opts)
                    end
                catch
                    C:R -> {error, {C, R}}
                end,
            Parent ! {voice_result, Ref, Result}
        end,
        [link, monitor]
    ),
    Timeout = maps:get(
        case Phase of
            plan -> planning_timeout_ms;
            action -> action_timeout_ms
        end,
        Opts
    ),
    Token = make_ref(),
    Timer = erlang:send_after(Timeout, self(), {voice_timeout, Ref, Token}),
    S#st{
        job = #{
            ref => Ref,
            pid => Pid,
            monitor => Mon,
            timer => Timer,
            timeout_token => Token,
            phase => Phase,
            input => Input,
            command => S#st.last_command
        }
    }.
execute(#{action := tts} = Intent, _Opts) ->
    erm_voice_tts:execute(Intent);
execute(#{action := custom, name := Name, query := Q}, Opts) ->
    case lists:keyfind(Name, 1, maps:get(actions, Opts, [])) of
        {Name, _, {M, F}} -> apply(M, F, [Q, #{source => voice, action => Name}]);
        false -> {error, unsupported_action}
    end;
execute(Intent, Opts) ->
    erm_voice_media:execute(Intent, Opts).

%% Custom handlers may have their own external effects; leave them tracked.
%% Builtin media workers lose their permit before a priority control is sent.
cancel_media_job(S = #st{job = #{input := #{action := A}}}) when A =:= custom; A =:= tts -> S;
cancel_media_job(S = #st{job = #{pid := Pid}}) ->
    unlink(Pid),
    exit(Pid, kill),
    clear_job(S).

cancel_plan(S = #st{job = #{phase := plan, pid := Pid}}) ->
    unlink(Pid),
    exit(Pid, kill),
    clear_job(S);
cancel_plan(S) ->
    S.
clear_job(S = #st{job = undefined}) ->
    S;
clear_job(S = #st{job = #{pid := Pid, monitor := Mon, timer := Timer}}) ->
    unlink(Pid),
    erlang:demonitor(Mon, [flush]),
    erlang:cancel_timer(Timer),
    S#st{job = undefined}.
record_result(Result, S) ->
    subsystem_log(notice, "voice command result: ~tp", [Result]),
    %% TTS is optional, including in isolated test VMs.
    case whereis(erm_tts) of
        undefined ->
            ok;
        _ ->
            try
                erm_tts:notify(Result, S#st.last_command)
            catch
                Class:Reason ->
                    subsystem_log(warning, "voice TTS notification failed: ~p:~tp", [Class, Reason])
            end
    end,
    S#st{last_result = Result, completed = S#st.completed + 1}.
safe_command(Text0, Opts) ->
    try unicode:characters_to_binary(Text0) of
        Text when is_binary(Text), byte_size(Text) > 0 ->
            case byte_size(Text) =< maps:get(max_command_bytes, Opts) of
                true -> {ok, Text};
                false -> {error, command_too_long}
            end;
        _ ->
            {error, invalid_command}
    catch
        _:_ -> {error, invalid_command}
    end.
now_ms() -> erlang:monotonic_time(millisecond).
terminate(_, S) ->
    erlang:cancel_timer(S#st.tick),
    lists:foreach(
        fun
            (#{pid := Pid}) ->
                unlink(Pid),
                exit(Pid, kill);
            (_) ->
                ok
        end,
        [S#st.job, S#st.priority]
    ),
    ok.
code_change(_, S, _) -> {ok, S}.

%% Diagnostic text is bounded; no logger calls in the pure boundary module.
utterance_trace(Event, Data, #st{opts = Opts}) ->
    case maps:get(debug_utterances, Opts, false) of
        true ->
            subsystem_log(
                debug,
                "voice_trace ~tp",
                [Data#{event => Event}],
                #{domain => [erm, voice]}
            );
        _ ->
            ok
    end.
%% Ignore rolling redraw timestamps and dedupe bookkeeping when deciding to log.
boundary_changed(A, B) -> boundary_signature(A) =/= boundary_signature(B).
boundary_signature(B) -> maps:with([phase, text, consumed, wake_prefix], B).
boundary_view(B) ->
    View = boundary_signature(B),
    case maps:get(deadline, B, undefined) of
        D when is_integer(D) -> View#{remaining_ms => max(0, D - now_ms())};
        _ -> View
    end.
bounded_text(Text) ->
    try unicode:characters_to_list(Text) of
        L when is_list(L) -> lists:sublist(L, 1024);
        _ -> invalid_unicode
    catch
        _:_ -> invalid_text
    end.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
trace_boundary_changes_test() ->
    A = #{phase => idle, text => <<>>, consumed => <<>>, wake_prefix => <<>>},
    ?assertNot(boundary_changed(A, A#{last_seen => 100, changed => 99})),
    ?assert(boundary_changed(A, A#{phase => capturing})),
    ?assert(boundary_changed(A, A#{text => <<"pause">>})),
    ?assert(boundary_changed(A, A#{wake_prefix => <<"hey">>})),
    ?assertNot(maps:is_key(deadline, boundary_view(A#{deadline => now_ms() + 500}))),
    ?assert(maps:is_key(remaining_ms, boundary_view(A#{deadline => now_ms() + 500}))).

final_transcript_dispatches_before_next_cast_test() ->
    {ok, Opts} = options(#{}),
    S0 = #st{opts = Opts, boundary = erm_voice_boundary:new()},
    {noreply, S1} = handle_cast(
        {transcript, #{utterance_id => <<"first">>, text => <<"bob play">>, final => true}, ["bob"]},
        S0
    ),
    try
        ?assertMatch(#{phase := plan, input := <<"play">>}, S1#st.job),
        {noreply, S2} = handle_cast(
            {transcript, #{utterance_id => <<"second">>, text => <<"bob next">>, final => true}, [
                "bob"
            ]},
            S1
        ),
        ?assertEqual(S1#st.job, S2#st.job),
        ?assertEqual(locked, maps:get(phase, S2#st.boundary)),
        {noreply, S3} = handle_cast(
            {transcript, #{utterance_id => <<"first">>, text => <<"bob play">>, final => true}, [
                "bob"
            ]},
            S2
        ),
        ?assertEqual(S2#st.job, S3#st.job)
    after
        cancel_plan(S1)
    end.

priority_result_labels_test_() ->
    [
        ?_test(priority_result_labels(Order, Completion))
     || Order <- [priority_first, original_first],
        Completion <- [result, timeout, down]
    ].

priority_result_labels(Order, Completion) ->
    {ok, Opts} = options(#{}),
    Original = test_job(<<"original custom command">>),
    Priority = test_job(<<"stop">>),
    S = #st{opts = Opts, job = Original, priority = Priority, last_command = <<"stop">>},
    {First, Second} =
        case Order of
            priority_first -> {Priority, Original};
            original_first -> {Original, Priority}
        end,
    try
        {noreply, S1} = handle_info(test_completion(Completion, First), S),
        ?assertEqual(maps:get(command, First), S1#st.last_command),
        {noreply, S2} = handle_info(test_completion(Completion, Second), S1),
        ?assertEqual(maps:get(command, Second), S2#st.last_command),
        ?assertEqual(2, S2#st.completed),
        ?assertEqual(undefined, S2#st.job),
        ?assertEqual(undefined, S2#st.priority)
    after
        exit(maps:get(pid, Original), kill),
        exit(maps:get(pid, Priority), kill)
    end.

test_job(Command) ->
    {Pid, Mon} = spawn_monitor(fun() ->
        receive
            done -> ok
        end
    end),
    #{
        ref => make_ref(),
        pid => Pid,
        monitor => Mon,
        timer => erlang:send_after(60000, self(), unused_test_timer),
        timeout_token => make_ref(),
        phase => action,
        command => Command
    }.
test_completion(result, J) -> {voice_result, maps:get(ref, J), {ok, done}};
test_completion(timeout, J) -> {voice_timeout, maps:get(ref, J), maps:get(timeout_token, J)};
test_completion(down, J) -> {'DOWN', maps:get(monitor, J), process, maps:get(pid, J), failed}.
-endif.

subsystem_log(Level, Format, Args) ->
    logger:log(Level, Format, Args, #{domain => [erm, voice]}).
subsystem_log(Level, Format, Args, Meta) ->
    logger:log(Level, Format, Args, Meta#{domain => [erm, voice]}).
