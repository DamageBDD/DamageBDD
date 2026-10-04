%% Read-only diagnostics. Never dispatches a command, starts listening or generates speech.
-module(erm_voice_health).
-export([check/0, check/1, log_probe/0]).

check() -> check(#{}).
check(Options) when is_map(Options) ->
    Timeout = maps:get(timeout_ms, Options, 1000),
    Probe = maps:get(probe_ollama, Options, false),
    case
        is_integer(Timeout) andalso Timeout > 0 andalso Timeout =< 3000 andalso
            is_boolean(Probe)
    of
        false -> #{status => error, reason => invalid_health_options};
        true -> check_services(Timeout, Probe)
    end.

check_services(Timeout, Probe) ->
    Voice = service(erm_voice, Timeout),
    Config = voice_config(),
    Backend =
        case Config of
            {ok, WC, _} -> maps:get(backend, WC, whisper_cpp);
            _ -> whisper_cpp
        end,
    Speech = service(
        case Backend of
            native -> erm_native_voice;
            _ -> whisper_trigger_srv
        end,
        Timeout
    ),
    Enabled =
        case Config of
            {ok, W, _} ->
                application:get_env(erm, enabled, true) =/= false andalso
                    maps:get(enabled, W, true) =/= false;
            _ ->
                true
        end,
    VoiceEnabled =
        Enabled andalso
            case Config of
                {ok, _, V} -> maps:get(enabled, V, true) =/= false;
                _ -> true
            end,
    Settings =
        case Voice of
            {ok, Live} ->
                maps:get(health_settings, Live, #{});
            _ ->
                case Config of
                    {ok, _, VC} -> VC;
                    _ -> #{}
                end
        end,
    Checks = #{
        configuration =>
            case Config of
                {ok, _, _} -> result(ok);
                _ -> result(error, invalid_configuration)
            end,
        speech => speech_check(Backend, Enabled, Speech),
        voice => voice_check(VoiceEnabled, Voice),
        media => media_check(VoiceEnabled, Timeout),
        voice_log => log_check(erm_voice_file, [erm, voice]),
        whisper_log => log_check(erm_whisper_file, [erm, whisper]),
        general_log_exclusions => exclusions(),
        ollama => ollama_check(VoiceEnabled andalso Probe, Settings, Timeout)
    },
    #{
        status => overall(Checks, Enabled),
        checks => Checks,
        scope => readiness,
        checked_at_ms => erlang:system_time(millisecond),
        note =>
            <<"Readiness only: microphone audio, recognition accuracy and model generation are not exercised.">>
    }.

voice_config() ->
    try
        W = as_map(application:get_env(erm, whisper_trigger, [])),
        V = as_map(maps:get(voice, W, [])),
        true = is_boolean(maps:get(enabled, W, true)),
        true = is_boolean(maps:get(enabled, V, true)),
        {ok, W, V}
    catch
        _:_ -> {error, invalid_configuration}
    end.
as_map(M) when is_map(M) -> M;
as_map(L) when is_list(L) -> proplists:to_map(L).

service(Name, Timeout) ->
    Request =
        case Name of
            whisper_trigger_srv -> health;
            _ -> status
        end,
    try gen_server:call(Name, Request, Timeout) of
        S when is_map(S) -> {ok, S};
        _ -> {error, invalid_status}
    catch
        exit:{noproc, _} -> {error, not_started};
        exit:{timeout, _} -> {error, timeout};
        _:_ -> {error, unavailable}
    end.

whisper_check(false, _) ->
    result(disabled);
whisper_check(true, {error, Reason}) ->
    result(error, Reason);
whisper_check(true, {ok, S}) ->
    Summary = maps:with(
        [
            ready,
            listening,
            os_pid,
            transcript_count,
            trigger_count,
            last_transcript_at_ms,
            last_output_at_ms,
            uptime_ms
        ],
        S
    ),
    Files = #{
        executable => readable(maps:get(bin, S, undefined)),
        model => readable(maps:get(model, S, undefined))
    },
    Good =
        maps:get(ready, S, false) andalso maps:get(listening, S, false) andalso
            maps:get(executable, Files) andalso maps:get(model, Files),
    %% Port presence does not prove working audio input. No transcript content is returned.
    Summary#{
        status =>
            case Good of
                true -> ok;
                false -> error
            end,
        files_readable => Files,
        has_last_error => maps:get(last_error, S, undefined) =/= undefined
    }.

speech_check(native, false, _) ->
    (result(disabled))#{backend => native};
speech_check(native, true, {error, Reason}) ->
    (result(error, Reason))#{backend => native};
speech_check(native, true, {ok, S}) ->
    Summary = maps:with([ready, processing, muted, enrolled], S),
    Summary#{
        backend => native,
        status =>
            case maps:get(ready, S, false) of
                true -> ok;
                false -> error
            end
    };
speech_check(_, Enabled, Speech) ->
    (whisper_check(Enabled, Speech))#{backend => whisper_cpp}.

voice_check(false, _) ->
    result(disabled);
voice_check(true, {error, Reason}) ->
    result(error, Reason);
voice_check(true, {ok, S}) ->
    Summary = maps:with([phase, busy, priority_busy, model, completed], S),
    Last =
        case maps:get(last_result, S, undefined) of
            undefined -> none;
            {error, _} -> error;
            _ -> ok
        end,
    Summary#{
        status => ok,
        last_result_status => Last,
        require_final => maps:get(require_final, maps:get(health_settings, S, #{}), false)
    }.

readable(undefined) ->
    false;
readable(Path) ->
    try file:open(Path, [read, binary, raw]) of
        {ok, F} ->
            file:close(F),
            filelib:is_regular(Path);
        _ ->
            false
    catch
        _:_ -> false
    end.

media_check(false, _) ->
    result(disabled);
media_check(true, Timeout) ->
    bounded(
        fun() ->
            case erm_mpv_proc:command(status, [], Timeout) of
                {ok, S} when is_map(S) -> (maps:with([idle_active, pause], S))#{status => ok};
                _ -> result(error, unavailable)
            end
        end,
        Timeout
    ).

%% Calls are isolated so a slow external adapter cannot block the healthcheck indefinitely.
bounded(Fun, Timeout) ->
    {Pid, Ref} = spawn_monitor(fun() -> exit({health_result, Fun()}) end),
    receive
        {'DOWN', Ref, process, Pid, {health_result, Result}} -> Result;
        {'DOWN', Ref, process, Pid, _} -> result(error, unavailable)
    after Timeout ->
        exit(Pid, kill),
        erlang:demonitor(Ref, [flush]),
        result(error, timeout)
    end.

log_check(Id, Domain) ->
    case logger:get_handler_config(Id) of
        {ok, #{
            module := logger_std_h,
            filter_default := stop,
            filters := Filters,
            config := Cfg,
            level := Level
        }} ->
            Good = lists:any(
                fun
                    ({_, {F, {log, sub, D}}}) ->
                        F =:= fun logger_filters:domain/2 andalso D =:= Domain;
                    (_) ->
                        false
                end,
                Filters
            ),
            Primary = maps:get(level, logger:get_primary_config()),
            NoticeEnabled =
                lists:member(Level, [all, debug, info, notice]) andalso
                    lists:member(Primary, [all, debug, info, notice]),
            #{
                status =>
                    case Good andalso maps:is_key(file, Cfg) andalso NoticeEnabled of
                        true -> ok;
                        false -> error
                    end,
                file => maps:get(file, Cfg, undefined),
                handler_level => Level,
                primary_level => Primary,
                note => configured_only
            };
        _ ->
            result(error, missing_or_invalid_handler)
    end.

exclusions() ->
    Required = [default, debug_file, info_file, error_file],
    Bad = [Id || Id <- Required, not excludes(Id)],
    case Bad of
        [] -> result(ok);
        _ -> #{status => error, handlers => Bad}
    end.
excludes(Id) ->
    case logger:get_handler_config(Id) of
        {ok, #{filters := Filters}} ->
            lists:all(
                fun(Domain) ->
                    %% Must precede any accepting filter such as debug_only.
                    exclusion_before_accept(Filters, Domain)
                end,
                [[erm, voice], [erm, whisper]]
            );
        _ ->
            false
    end.
exclusion_before_accept([], _) ->
    false;
exclusion_before_accept([{_, {F, {stop, sub, D}}} | Rest], Domain) ->
    case F =:= fun logger_filters:domain/2 andalso D =:= Domain of
        true -> true;
        false -> exclusion_before_accept(Rest, Domain)
    end;
exclusion_before_accept(_, _) ->
    false.

ollama_check(false, _, _) ->
    result(skipped, tcp_probe_not_requested_or_voice_disabled);
ollama_check(true, Settings, Timeout) ->
    bounded(
        fun() ->
            Host0 = maps:get(ollama_host, Settings, "localhost"),
            Host =
                case Host0 of
                    B when is_binary(B) -> binary_to_list(B);
                    _ -> Host0
                end,
            Port = maps:get(ollama_port, Settings, 11434),
            case gen_tcp:connect(Host, Port, [binary, {active, false}], Timeout) of
                {ok, Socket} ->
                    gen_tcp:close(Socket),
                    #{status => ok, scope => tcp_only, host => Host, port => Port};
                {error, Reason} ->
                    #{
                        status => error,
                        scope => tcp_only,
                        reason => Reason,
                        host => Host,
                        port => Port
                    }
            end
        end,
        Timeout
    ).

result(Status) -> #{status => Status}.
result(Status, Reason) -> #{status => Status, reason => Reason}.
overall(Checks, Enabled) ->
    case lists:any(fun(#{status := S}) -> S =:= error end, maps:values(Checks)) of
        true -> degraded;
        false when Enabled =:= false -> disabled;
        false -> ok
    end.

%% Explicit opt-in write probe. Return the marker for searching both files.
log_probe() ->
    Marker = integer_to_binary(erlang:unique_integer([positive, monotonic])),
    logger:notice("Voice health log probe ~ts", [Marker], #{domain => [erm, voice]}),
    logger:notice("Whisper health log probe ~ts", [Marker], #{domain => [erm, whisper]}),
    Sync = [{Id, sync(Id)} || Id <- [erm_voice_file, erm_whisper_file]],
    #{
        marker => Marker,
        filesync => Sync,
        note => <<"Filesync is not delivery proof; find this marker in each configured log.">>
    }.
sync(Id) ->
    try
        logger_std_h:filesync(Id)
    catch
        _:_ -> {error, unavailable}
    end.
