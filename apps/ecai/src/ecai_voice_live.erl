%%% Interactive local TTS/ALSA enrolled-voice experiment. No application startup hook.
%%% Call start_link/1 from an Erlang shell, then next/1 or loop/2.
-module(ecai_voice_live).
-behaviour(gen_server).
-export([start_link/1, next/1, loop/2, pause/1, status/1, stop/1, options/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(MAX_MS, 35000).

start_link(Opts) -> gen_server:start_link(?MODULE, Opts, []).
next(Pid) -> gen_server:call(Pid, next).
loop(Pid, IntervalMs) -> gen_server:call(Pid, {loop, IntervalMs}).
pause(Pid) -> gen_server:call(Pid, pause).
status(Pid) -> gen_server:call(Pid, status).
stop(Pid) -> gen_server:stop(Pid).

options(O) when is_map(O) ->
    Allowed = [profile, session, device, playback, seconds, settle_ms, prompt, backend],
    case maps:keys(O) -- Allowed of
        [] -> check_options(O);
        Bad -> {error, {unknown_options, Bad}}
    end;
options(_) ->
    {error, options_must_be_map}.

check_options(O) ->
    S = maps:get(seconds, O, 6),
    Settle = maps:get(settle_ms, O, 750),
    B = maps:get(backend, O, curve),
    case
        is_integer(S) andalso S >= 2 andalso S =< 30 andalso
            is_integer(Settle) andalso Settle >= 0 andalso Settle =< 5000 andalso
            lists:member(B, [curve, integer]) andalso
            lists:all(
                fun(K) -> safe_string(maps:get(K, O, "")) end,
                [profile, session, device, playback, prompt]
            ) andalso
            maps:is_key(profile, O) andalso maps:is_key(session, O)
    of
        true -> {ok, O#{seconds => S, settle_ms => Settle, backend => B}};
        false -> {error, invalid_voice_options}
    end.

safe_string(S) when is_list(S) ->
    length(S) =< 4096 andalso
        lists:all(fun(C) -> is_integer(C) andalso C > 31 andalso C < 127 end, S);
safe_string(_) ->
    false.

init(O) ->
    process_flag(trap_exit, true),
    case options(O) of
        {error, E} ->
            {stop, E};
        {ok, Opts} ->
            case ecai_voice:load(maps:get(profile, Opts)) of
                {ok, P} ->
                    Dir = maps:get(session, Opts),
                    case filelib:ensure_dir(filename:join(Dir, "samples/x")) of
                        ok ->
                            {ok, #{
                                opts => Opts,
                                profile => P,
                                dir => Dir,
                                counter => 0,
                                running => false,
                                interval => none,
                                result => undefined,
                                worker => undefined
                            }};
                        Error ->
                            {stop, Error}
                    end;
                Error ->
                    {stop, Error}
            end
    end.

handle_call(status, _, S) ->
    {reply, maps:with([counter, running, interval, result], S), S};
handle_call(next, _, S = #{worker := undefined}) ->
    {reply, ok, launch(S)};
handle_call(next, _, S) ->
    {reply, {error, busy}, S};
handle_call({loop, I}, _, S) when is_integer(I), I >= 0, I =< 3600000 ->
    S1 = S#{running => true, interval => I},
    case maps:get(worker, S1) of
        undefined -> {reply, ok, launch(S1)};
        _ -> {reply, ok, S1}
    end;
handle_call({loop, _}, _, S) ->
    {reply, {error, invalid_interval}, S};
handle_call(pause, _, S) ->
    {reply, ok, S#{running => false, interval => none}};
handle_call(_, _, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast(_, S) -> {noreply, S}.
handle_info(next_tick, S = #{worker := undefined, running := true}) ->
    {noreply, launch(S)};
handle_info(next_tick, S) ->
    {noreply, S};
handle_info({voice_result, Ref, Result}, S = #{worker := {_, Ref, _}}) ->
    N = maps:get(counter, S),
    io:format("~n[ECAI voice sample ~B] ~tp~n", [N, Result]),
    ecai_voice_ui:result(?MODULE, Result),
    S1 = S#{result => Result},
    {noreply, S1};
handle_info({'DOWN', Ref, process, Pid, Reason}, S = #{worker := {Pid, _, Ref}}) ->
    S1 = S#{worker => undefined},
    S2 =
        case Reason of
            normal -> S1;
            _ -> S1#{result => {error, {worker_exit, Reason}}}
        end,
    case maps:get(running, S2) of
        true -> erlang:send_after(maps:get(interval, S2), self(), next_tick);
        false -> ok
    end,
    {noreply, S2};
handle_info(_, S) ->
    {noreply, S}.

terminate(_, S) ->
    case maps:get(worker, S, undefined) of
        {P, _, _} -> exit(P, kill);
        _ -> ok
    end,
    ok.
code_change(_, S, _) -> {ok, S}.

launch(S) ->
    N = maps:get(counter, S) + 1,
    Parent = self(),
    Ref = make_ref(),
    {Pid, Mon} = spawn_monitor(fun() ->
        R =
            try
                execute(S, N)
            catch
                C:E:Stack -> {error, {C, E, lists:sublist(Stack, 3)}}
            end,
        Parent ! {voice_result, Ref, R}
    end),
    S#{counter => N, worker => {Pid, Ref, Mon}}.

execute(#{opts := O, profile := Profile, dir := Dir}, N) ->
    %% Unique sample paths; do not overwrite development recordings or profiles.
    Base = filename:join([Dir, "samples", integer_to_list(N)]),
    PromptWav = Base ++ "-prompt.wav",
    Sample = Base ++ ".wav",
    Prompt = maps:get(prompt, O, "Describe what you did today in your own words."),
    Device = maps:get(device, O, "default"),
    Playback = maps:get(playback, O, "default"),
    Seconds = maps:get(seconds, O),
    try
        ok = command("espeak-ng", ["-w", PromptWav, Prompt], 15000),
        ok = command("aplay", ["-D", Playback, PromptWav], 20000),
        timer:sleep(maps:get(settle_ms, O)),
        io:format("Recording sample ~B for ~B seconds...~n", [N, Seconds]),
        ok = command(
            "arecord",
            [
                "-q",
                "-D",
                Device,
                "-f",
                "S16_LE",
                "-r",
                "16000",
                "-c",
                "1",
                "-d",
                integer_to_list(Seconds),
                Sample
            ],
            Seconds * 1000 + 5000
        ),
        case ecai_voice_wav:read(Sample) of
            {ok, A} ->
                case abs(maps:get(seconds, A) - Seconds) =< 0.05 of
                    true -> ok;
                    false -> erlang:error(incomplete_capture)
                end;
            Error ->
                erlang:error({invalid_capture, Error})
        end,
        Result = ecai_voice_ui:work(?MODULE, fun() ->
            ecai_voice:identify(Profile, {wav, Sample}, maps:get(backend, O)) end),
        ok = file:write_file(Base ++ ".result.term", io_lib:format("~tp.~n", [Result]), [exclusive]),
        Result
    after
        _ = file:delete(PromptWav)
    end.

%% Use spawn_executable and argument vectors, never a shell command string.
command(Name, Args, Timeout) ->
    case os:find_executable(Name) of
        false ->
            erlang:error({missing_executable, Name});
        Exe ->
            Port = open_port({spawn_executable, Exe}, [
                binary,
                exit_status,
                stderr_to_stdout,
                {args, Args}
            ]),
            Token = ecai_voice_ui:begin_audio(?MODULE, Name, Args),
            try
                Result = await_port(Port, erlang:monotonic_time(millisecond) + Timeout, Token),
                ecai_voice_ui:end_audio(Token, ok), Result
            catch C:E:Stack ->
                ecai_voice_ui:end_audio(Token, error), erlang:raise(C,E,Stack)
            after
                try port_close(Port) catch error:badarg -> ok end
            end
    end.
await_port(Port, Deadline, Token) ->
    Remaining = max(0, Deadline - erlang:monotonic_time(millisecond)),
    case Remaining of 0 -> erlang:error(audio_command_timeout); _ -> ok end,
    receive
        {Port, {data, _}} -> await_port(Port, Deadline, Token);
        {Port, {exit_status, 0}} -> ok;
        {Port, {exit_status, Code}} -> erlang:error({audio_command_failed, Code})
    after min(Remaining, 100) ->
        ecai_voice_ui:tick(Token),
        await_port(Port, Deadline, Token)
    end.
