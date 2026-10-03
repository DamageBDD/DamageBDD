%% Supervised voice coordinator. No LLM or MPV work blocks this gen_server.
-module(erm_voice).
-behaviour(gen_server).
-export([start_link/1, transcript/2, command/1, status/0, reset/0, options/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(st, {opts, boundary, tick, job = undefined, last_result = undefined,
             last_command = undefined, completed = 0}).

start_link(Opts) -> gen_server:start_link({local, ?MODULE}, ?MODULE, Opts, []).
transcript(Text, Phrases) ->
    case whereis(?MODULE) of
        undefined -> {error, not_started};
        Pid ->
            %% Drop input if a misbehaving source floods the mailbox.
            case process_info(Pid, message_queue_len) of
                {message_queue_len, N} when N < 100 -> gen_server:cast(Pid, {transcript, Text, Phrases});
                _ -> {error, overloaded}
            end
    end.
command(Text) -> gen_server:call(?MODULE, {command, Text}, 1000).
status() -> gen_server:call(?MODULE, status, 1000).
reset() -> gen_server:cast(?MODULE, reset).

options(Options) ->
    try
        M = case Options of
            O when is_map(O) -> O;
            O when is_list(O) -> proplists:to_map(O)
        end,
        true = is_boolean(maps:get(enabled, M, true)),
        Defaults = #{settle_ms => 1100, urgent_settle_ms => 300, command_window_ms => 8000,
                     rearm_silence_ms => 6000, command_dedupe_ms => 6000,
                     max_command_bytes => 512, planning_timeout_ms => 30000,
                     action_timeout_ms => 30000, ollama_timeout_ms => 12000,
                     ecai_timeout_ms => 4000},
        Opts = maps:merge(Defaults, M),
        lists:foreach(fun(K) ->
            V = maps:get(K, Opts), true = is_integer(V) andalso V > 0 andalso V =< 120000
        end, maps:keys(Defaults)),
        true = maps:get(settle_ms, Opts) < maps:get(command_window_ms, Opts),
        true = maps:get(max_command_bytes, Opts) =< 4096,
        true = is_boolean(maps:get(auto_pull_model, Opts, true)),
        PullTimeout = maps:get(model_pull_timeout_ms, Opts, 600000),
        true = is_integer(PullTimeout) andalso PullTimeout > 0 andalso PullTimeout =< 3600000,
        Actions = maps:get(actions, Opts, []),
        true = is_list(Actions) andalso length(Actions) =< 32,
        Builtins = erm_voice_intent:actions(#{}),
        lists:foreach(fun({Name, Description, {Mod, Fun}}) ->
            true = is_binary(Name) andalso byte_size(Name) > 0 andalso byte_size(Name) =< 64,
            nomatch = re:run(Name, "[^a-z0-9_]"),
            false = lists:member(Name, Builtins),
            true = is_atom(Mod) andalso is_atom(Fun),
            true = is_binary(unicode:characters_to_binary(Description))
        end, Actions),
        Names = [N || {N, _, _} <- Actions],
        true = length(Names) =:= length(lists:usort(Names)),
        {ok, Opts}
    catch _:_ -> {error, invalid_voice_configuration} end.

init(Options) ->
    logger:update_process_metadata(#{domain => [erm, voice]}),
    process_flag(trap_exit, true),
    case options(Options) of
        {ok, Opts} ->
            {ok, #st{opts = Opts, boundary = erm_voice_boundary:new(),
                     tick = erlang:send_after(100, self(), tick)}};
        {error, Reason} -> {stop, Reason}
    end.
handle_call(status, _From, S) ->
    {reply, #{phase => maps:get(phase, S#st.boundary), busy => S#st.job =/= undefined,
              model => maps:get(model, S#st.opts, "qwen3:1.7b"),
              last_command => S#st.last_command, last_result => S#st.last_result,
              completed => S#st.completed}, S};
handle_call({command, Text0}, _From, S) ->
    case safe_command(Text0, S#st.opts) of
        {ok, Text} ->
            {Reply, Next} = accept(Text, S),
            {reply, Reply, Next};
        Error -> {reply, Error, S}
    end;
handle_call(_, _From, S) -> {reply, {error, unsupported_call}, S}.

handle_cast({transcript, Text, Phrases}, S) ->
    try erm_voice_boundary:feed(Text, Phrases, now_ms(), S#st.boundary, S#st.opts) of
        B ->
            case boundary_changed(S#st.boundary, B) of
                true -> utterance_trace(transcript, #{raw => bounded_text(Text),
                    before => boundary_view(S#st.boundary), after_state => boundary_view(B)}, S);
                false -> ok
            end,
            {noreply, S#st{boundary = B}}
    catch Class:Reason ->
        logger:warning("voice transcript rejected: ~p:~tp", [Class, Reason]),
        {noreply, S#st{boundary = erm_voice_boundary:cancel(S#st.boundary)}} end;
handle_cast(reset_boundary, S) ->
    {noreply, S#st{boundary = erm_voice_boundary:new()}};
handle_cast(reset, S) ->
    {noreply, (cancel_plan(S))#st{boundary = erm_voice_boundary:new()}};
handle_cast(_, S) -> {noreply, S}.

handle_info(tick, S0) ->
    {Event, B} = erm_voice_boundary:tick(now_ms(), S0#st.boundary, S0#st.opts),
    case boundary_changed(S0#st.boundary, B) orelse Event =/= none of
        true -> utterance_trace(capture_tick, #{event_result => Event,
                    before => boundary_view(S0#st.boundary), after_state => boundary_view(B)}, S0);
        false -> ok
    end,
    S1 = S0#st{boundary = B, tick = erlang:send_after(100, self(), tick)},
    case Event of
        {command, Text} -> {_Reply, S2} = accept(Text, S1), {noreply, S2};
        none -> {noreply, S1}
    end;
handle_info({voice_model_pull, Ref}, S = #st{opts = Opts,
        job = #{ref := Ref, phase := plan, timer := OldTimer} = Job}) ->
    erlang:cancel_timer(OldTimer),
    %% Pulling can take minutes. Keep it in the cancellable planning worker.
    Budget = maps:get(model_pull_timeout_ms, Opts, 600000) +
             2 * maps:get(ollama_timeout_ms, Opts, 12000) + 5000,
    TimerToken = make_ref(),
    Timer = erlang:send_after(Budget, self(), {voice_timeout, Ref, TimerToken}),
    {noreply, S#st{job = Job#{timer => Timer, timeout_token => TimerToken}}};
handle_info({voice_result, Ref, Result}, S = #st{job = #{ref := Ref, phase := plan}}) ->
    Ready = clear_job(S),
    case Result of
        {ok, #{action := answer} = Answer} -> {noreply, record_result({ok, Answer}, Ready)};
        {ok, Intent} when is_map(Intent) -> {noreply, launch(action, Intent, Ready)};
        Error -> {noreply, record_result(Error, Ready)}
    end;
handle_info({voice_result, Ref, Result}, S = #st{job = #{ref := Ref, phase := action}}) ->
    {noreply, record_result(Result, clear_job(S))};
handle_info({voice_timeout, Ref, Token}, S = #st{job = #{ref := Ref, timeout_token := Token, pid := Pid, phase := Phase}}) ->
    unlink(Pid), exit(Pid, kill),
    %% An action timeout is indeterminate: never retry it automatically.
    {noreply, record_result({error, {Phase, timeout}}, clear_job(S))};
handle_info({'DOWN', Mon, process, _Pid, Reason}, S = #st{job = #{monitor := Mon}}) ->
    {noreply, record_result({error, {worker_down, Reason}}, clear_job(S))};
handle_info(_, S) -> {noreply, S}.

accept(Text, S = #st{job = undefined}) -> {ok, launch(plan, Text, S#st{last_command = Text})};
accept(Text, S = #st{job = #{phase := plan}}) ->
    case erm_voice_intent:parse(Text) of
        {ok, #{action := A}} when A =:= stop; A =:= pause ->
            accept(Text, cancel_plan(S));
        {error, cancelled} -> {ok, record_result({error, cancelled}, cancel_plan(S))};
        _ -> {{error, busy}, record_result({error, busy}, S)}
    end;
accept(_Text, S) -> {{error, busy}, record_result({error, busy}, S)}.

launch(Phase, Input, S = #st{opts = Opts}) ->
    utterance_trace(dispatch, #{stage => Phase, input => Input}, S),
    Parent = self(), Ref = make_ref(),
    {Pid, Mon} = spawn_opt(fun() ->
        logger:update_process_metadata(#{domain => [erm, voice]}),
        Result = try
            case Phase of
                plan -> erm_voice_intent:plan(Input, Opts#{model_pull_notify =>
                    fun() -> Parent ! {voice_model_pull, Ref} end});
                action -> execute(Input, Opts)
            end
        catch C:R -> {error, {C, R}} end,
        Parent ! {voice_result, Ref, Result}
    end, [link, monitor]),
    Timeout = maps:get(case Phase of plan -> planning_timeout_ms; action -> action_timeout_ms end, Opts),
    Token = make_ref(),
    Timer = erlang:send_after(Timeout, self(), {voice_timeout, Ref, Token}),
    S#st{job = #{ref => Ref, pid => Pid, monitor => Mon, timer => Timer, timeout_token => Token, phase => Phase}}.
execute(#{action := tts} = Intent, _Opts) -> erm_voice_tts:execute(Intent);
execute(#{action := custom, name := Name, query := Q}, Opts) ->
    case lists:keyfind(Name, 1, maps:get(actions, Opts, [])) of
        {Name, _, {M, F}} -> apply(M, F, [Q, #{source => voice, action => Name}]);
        false -> {error, unsupported_action}
    end;
execute(Intent, Opts) -> erm_voice_media:execute(Intent, Opts).

cancel_plan(S = #st{job = #{phase := plan, pid := Pid}}) ->
    unlink(Pid), exit(Pid, kill), clear_job(S);
cancel_plan(S) -> S.
clear_job(S = #st{job = undefined}) -> S;
clear_job(S = #st{job = #{pid := Pid, monitor := Mon, timer := Timer}}) ->
    unlink(Pid), erlang:demonitor(Mon, [flush]), erlang:cancel_timer(Timer),
    S#st{job = undefined}.
record_result(Result, S) ->
    logger:notice("voice command result: ~tp", [Result]),
    %% TTS is optional, including in isolated test VMs.
    case whereis(erm_tts) of
        undefined -> ok;
        _ ->
            try erm_tts:notify(Result, S#st.last_command)
            catch Class:Reason ->
                logger:warning("voice TTS notification failed: ~p:~tp", [Class, Reason])
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
        _ -> {error, invalid_command}
    catch _:_ -> {error, invalid_command} end.
now_ms() -> erlang:monotonic_time(millisecond).
terminate(_, S) ->
    erlang:cancel_timer(S#st.tick),
    case S#st.job of
        #{pid := Pid} -> unlink(Pid), exit(Pid, kill);
        _ -> ok
    end,
    ok.
code_change(_, S, _) -> {ok, S}.

%% Diagnostic text is bounded; no logger calls in the pure boundary module.
utterance_trace(Event, Data, #st{opts = Opts}) ->
    case maps:get(debug_utterances, Opts, false) of
        true -> logger:debug("voice_trace ~tp", [Data#{event => Event}],
                             #{domain => [erm, voice]});
        _ -> ok
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
    catch _:_ -> invalid_text end.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
trace_boundary_changes_test() ->
    A = #{phase => idle, text => <<>>, consumed => <<>>, wake_prefix => <<>>},
    ?assertNot(boundary_changed(A, A#{last_seen => 100, changed => 99})),
    ?assert(boundary_changed(A, A#{phase => capturing})),
    ?assert(boundary_changed(A, A#{text => <<"pause">>})),
    ?assert(boundary_changed(A, A#{wake_prefix => <<"hey">>})),
    ?assertNot(maps:is_key(deadline, boundary_view(A#{deadline => now_ms()+500}))),
    ?assert(maps:is_key(remaining_ms, boundary_view(A#{deadline => now_ms()+500}))).
-endif.
