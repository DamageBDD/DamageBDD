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
        Defaults = #{settle_ms => 1100, command_window_ms => 8000,
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
        B -> {noreply, S#st{boundary = B}}
    catch _:_ -> {noreply, S#st{boundary = erm_voice_boundary:cancel(S#st.boundary)}} end;
handle_cast(reset_boundary, S) ->
    {noreply, S#st{boundary = erm_voice_boundary:new()}};
handle_cast(reset, S) ->
    {noreply, (cancel_plan(S))#st{boundary = erm_voice_boundary:new()}};
handle_cast(_, S) -> {noreply, S}.

handle_info(tick, S0) ->
    {Event, B} = erm_voice_boundary:tick(now_ms(), S0#st.boundary, S0#st.opts),
    S1 = S0#st{boundary = B, tick = erlang:send_after(100, self(), tick)},
    case Event of
        {command, Text} -> {_Reply, S2} = accept(Text, S1), {noreply, S2};
        none -> {noreply, S1}
    end;
handle_info({voice_result, Ref, Result}, S = #st{job = #{ref := Ref, phase := plan}}) ->
    Ready = clear_job(S),
    case Result of
        {ok, #{action := answer} = Answer} -> {noreply, record_result({ok, Answer}, Ready)};
        {ok, Intent} when is_map(Intent) -> {noreply, launch(action, Intent, Ready)};
        Error -> {noreply, record_result(Error, Ready)}
    end;
handle_info({voice_result, Ref, Result}, S = #st{job = #{ref := Ref, phase := action}}) ->
    {noreply, record_result(Result, clear_job(S))};
handle_info({voice_timeout, Ref}, S = #st{job = #{ref := Ref, pid := Pid, phase := Phase}}) ->
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
    Parent = self(), Ref = make_ref(),
    {Pid, Mon} = spawn_opt(fun() ->
        Result = try
            case Phase of
                plan -> erm_voice_intent:plan(Input, Opts);
                action -> execute(Input, Opts)
            end
        catch C:R -> {error, {C, R}} end,
        Parent ! {voice_result, Ref, Result}
    end, [link, monitor]),
    Timeout = maps:get(case Phase of plan -> planning_timeout_ms; action -> action_timeout_ms end, Opts),
    Timer = erlang:send_after(Timeout, self(), {voice_timeout, Ref}),
    S#st{job = #{ref => Ref, pid => Pid, monitor => Mon, timer => Timer, phase => Phase}}.
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
    erm_tts:notify(Result, S#st.last_command),
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
