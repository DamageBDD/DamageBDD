%% Isolated OTP owner of a bootstrap process and then one automation service.
%% External failures are state transitions, not damage_sup restart storms.
-module(damage_webdriver_service).
-behaviour(gen_server).
-include_lib("kernel/include/logger.hrl").
-include_lib("kernel/include/file.hrl").
-export([start_link/1, command/2, probe_json/2]).
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3,
    format_status/1
]).

start_link(B) ->
    gen_server:start_link({local, damage_webdriver_runtime_config:name(B)}, ?MODULE, B, []).
init(B) ->
    process_flag(trap_exit, true),
    self() ! bootstrap,
    {ok, #{
        backend => B,
        phase => idle,
        config => undefined,
        pid => undefined,
        os_pid => undefined,
        timer => undefined,
        failures => 0,
        health_errors => 0,
        sessions => #{},
        manifest => #{},
        last_error => undefined,
        generation => make_ref()
    }}.

handle_call(status, _, S) ->
    View = maps:with([backend, phase, failures, health_errors, last_error, os_pid], S),
    Selected = maps:get(<<"selected">>, maps:get(manifest, S), #{}),
    Versions = maps:with(
        [
            <<"chrome_version">>,
            <<"node_version">>,
            <<"appium_version">>,
            <<"uiautomator2_version">>,
            <<"xcuitest_version">>
        ],
        Selected
    ),
    {reply, View#{active_sessions => map_size(maps:get(sessions, S)), versions => Versions}, S};
handle_call(connection, _, #{phase := ready, pid := P} = S) when is_pid(P) ->
    {reply,
        {ok, #{
            endpoint => endpoint(S),
            pid => self(),
            generation => maps:get(generation, S),
            manifest => maps:with(
                [<<"chrome">>, <<"version">>, <<"chromedriver_dir">>, <<"android_chromedriver">>],
                maps:get(manifest, S)
            )
        }},
        S};
handle_call(connection, _, #{phase := P} = S) when
    P =:= idle; P =:= installing; P =:= starting; P =:= backoff
->
    {reply, {error, starting}, S};
handle_call(connection, _, S) ->
    {reply, {error, {webdriver_backend_unavailable, maps:get(phase, S), maps:get(last_error, S)}},
        S};
handle_call({claim, {Expected, Generation}}, {Pid, _}, #{phase := ready} = S) ->
    Sessions = maps:get(sessions, S),
    Config = maps:get(config, S),
    case Expected =:= self() andalso Generation =:= maps:get(generation, S) of
        false ->
            {reply, {error, webdriver_backend_changed}, S};
        true ->
            case map_size(Sessions) < maps:get(max_sessions, Config) of
                true ->
                    Ref = erlang:monitor(process, Pid),
                    {reply, {ok, self()}, S#{sessions => Sessions#{Ref => Pid}}};
                false ->
                    {reply, {error, webdriver_capacity_exhausted}, S}
            end
    end;
handle_call({release, Generation}, {Pid, _}, S) ->
    case Generation =:= maps:get(generation, S) of
        true ->
            Sessions = maps:filter(
                fun(Ref, Owner) ->
                    case Owner =:= Pid of
                        true ->
                            erlang:demonitor(Ref, [flush]),
                            false;
                        false ->
                            true
                    end
                end,
                maps:get(sessions, S)
            ),
            {reply, ok, S#{sessions => Sessions}};
        false ->
            {reply, ok, S}
    end;
handle_call({claim, _}, _, S) ->
    {reply, {error, webdriver_backend_not_ready}, S};
handle_call(Action, _, S) when Action =:= restart; Action =:= stop ->
    case map_size(maps:get(sessions, S)) of
        0 ->
            case stop_process(cancel(S)) of
                {ok, S1} ->
                    case Action of
                        restart ->
                            self() ! bootstrap,
                            {reply, ok, S1#{phase => idle, failures => 0, last_error => undefined}};
                        stop ->
                            {reply, ok, S1#{phase => stopped}}
                    end;
                {error, S1} ->
                    {reply, {error, webdriver_shutdown_failed}, S1#{phase => failed}}
            end;
        _ ->
            {reply, {error, webdriver_sessions_active}, S}
    end;
handle_call(_, _, S) ->
    {reply, {error, bad_call}, S}.
handle_cast({invalidate, Client, Generation}, S) ->
    case
        Generation =:= maps:get(generation, S) andalso
            lists:member(Client, maps:values(maps:get(sessions, S)))
    of
        true -> {noreply, failed(webdriver_session_state_uncertain, S)};
        false -> {noreply, S}
    end;
handle_cast(_, S) ->
    {noreply, S}.

handle_info(bootstrap, #{phase := idle} = S) ->
    {noreply, bootstrap(S)};
handle_info({timeout, Ref, tick}, #{timer := Ref} = S) ->
    {noreply, tick(S#{timer => undefined})};
%% erlexec's monitor uses the OS pid in the reference slot, not an Erlang ref.
handle_info(
    {'DOWN', Os, process, Pid, Reason}, #{pid := Pid, os_pid := Os, phase := installing} = S
) ->
    S1 = cancel(S#{pid => undefined, os_pid => undefined}),
    case Reason of
        normal -> {noreply, start_service(S1)};
        _ -> {noreply, failed(install_error(S1), S1)}
    end;
handle_info({'DOWN', Os, process, Pid, _}, #{pid := Pid, os_pid := Os} = S) when is_pid(Pid) ->
    {noreply, failed(webdriver_process_exited, S#{pid => undefined, os_pid => undefined})};
handle_info({'DOWN', Ref, process, _, _}, S) when is_reference(Ref) ->
    {noreply, S#{sessions => maps:remove(Ref, maps:get(sessions, S))}};
handle_info({Stream, Os, Data}, #{os_pid := Os} = S) when Stream =:= stdout; Stream =:= stderr ->
    private_log(S, Data),
    {noreply, S};
handle_info({'EXIT', _, _}, S) ->
    {noreply, S};
handle_info(_, S) ->
    {noreply, S}.
terminate(_, S) ->
    _ = stop_process(cancel(S)),
    ok.
code_change(_, S, _) -> {ok, S}.
format_status(Status) ->
    Status#{
        state => redacted_webdriver_service,
        message => redacted,
        reason => redacted
    }.

bootstrap(S) ->
    case damage_webdriver_runtime_config:load(maps:get(backend, S)) of
        {ok, #{enabled := false} = C} ->
            S#{config => C, phase => disabled};
        {error, Why} ->
            S#{phase => failed, last_error => Why};
        {ok, C} ->
            S1 = S#{config => C},
            try
                ok = damage_webdriver_runtime_config:private_dir(maps:get(dir, C)),
                Request = filename:join(maps:get(dir, C), "request.json"),
                Tmp = Request ++ "." ++ integer_to_list(erlang:unique_integer([positive])),
                ok = file:write_file(Tmp, jsx:encode(maps:get(request, C)), [exclusive]),
                ok = file:change_mode(Tmp, 8#600),
                ok = file:rename(Tmp, Request),
                _ = file:delete(filename:join(maps:get(dir, C), "error.json")),
                Helper = filename:join([code:priv_dir(damage), "webdriver", "bootstrap.py"]),
                true = filelib:is_regular(Helper),
                Python = executable(maps:get(python, C)),
                case start_program([Python, "-I", Helper, "--request", Request], base_env(C), S1) of
                    {ok, S2} -> schedule(maps:get(bootstrap_ms, C), S2#{phase => installing});
                    {error, S2} -> failed(webdriver_bootstrap_start_failed, S2)
                end
            catch
                _:_ -> failed(webdriver_bootstrap_setup_failed, S1)
            end
    end.

start_service(S) ->
    C = maps:get(config, S),
    try
        {ok, Bin} = file:read_file(filename:join(maps:get(dir, C), "runtime.json")),
        true = byte_size(Bin) =< 2097152,
        M = jsx:decode(Bin, [return_maps]),
        true = maps:get(<<"schema">>, M) =:= 1,
        true = maps:get(<<"backend">>, M) =:= atom_to_binary(maps:get(backend, S), utf8),
        %% Do not attach to or stop an already running, unrelated service.
        case port_free(maps:get(port, C)) of
            false ->
                failed(webdriver_port_in_use, S);
            true ->
                Cmd = command(C, M),
                Env = [{str(K), str(V)} || {K, V} <- maps:to_list(maps:get(<<"env">>, M))],
                case start_program(Cmd, Env, S) of
                    {ok, S1} ->
                        schedule(300, S1#{
                            phase => starting,
                            manifest => M,
                            generation => make_ref(),
                            health_errors => 0,
                            started => erlang:monotonic_time(millisecond)
                        });
                    {error, S1} ->
                        failed(webdriver_process_start_failed, S1)
                end
        end
    catch
        _:_ -> failed(invalid_webdriver_manifest, S)
    end.

command(#{backend := chromedriver, port := Port, base_path := Base}, M) ->
    %% Omit --allowed-ips: ChromeDriver's default is local connections only.
    [
        str(maps:get(<<"chromedriver">>, M)),
        "--port=" ++ integer_to_list(Port),
        "--url-base=" ++ Base,
        "--log-level=WARNING"
    ];
command(#{backend := appium, port := Port, base_path := Base}, M) ->
    [str(V) || V <- maps:get(<<"argv">>, M)] ++
        [
            "--address",
            "127.0.0.1",
            "--port",
            integer_to_list(Port),
            "--base-path",
            Base,
            "--log-level",
            "warn",
            "--log-no-colors",
            "--shutdown-timeout",
            "5000"
        ] ++
        case maps:get(<<"chromedriver_autodownload">>, M, false) of
            true -> ["--allow-insecure", "uiautomator2:chromedriver_autodownload"];
            false -> []
        end;
command(#{backend := fixture, port := Port, python := Python, base_path := "/"}, M) ->
    [
        executable(Python),
        "-E",
        "-s",
        str(maps:get(<<"script">>, M)),
        "--bind",
        "127.0.0.1",
        "--port",
        integer_to_list(Port)
    ].

start_program(Cmd, Env, S) ->
    try
        exec:run_link(
            Cmd,
            [
                monitor,
                {group, 0},
                kill_group,
                {kill_timeout, 5},
                {stdin, null},
                stdout,
                stderr,
                {env, [clear | Env]},
                {cd, maps:get(dir, maps:get(config, S))}
            ],
            5000
        )
    of
        {ok, Pid, OsPid} -> {ok, S#{pid => Pid, os_pid => OsPid}};
        _ -> {error, S}
    catch
        _:_ -> {error, S}
    end.

stop_process(#{pid := undefined} = S) ->
    {ok, S};
stop_process(#{pid := Pid} = S) ->
    try exec:stop_and_wait(Pid, 7000) of
        {error, _} ->
            case is_process_alive(Pid) of
                false -> {ok, S#{pid => undefined, os_pid => undefined}};
                true -> {error, S}
            end;
        _ExitStatus ->
            {ok, S#{pid => undefined, os_pid => undefined}}
    catch
        _:_ -> {error, S}
    end.

tick(#{phase := backoff} = S) ->
    bootstrap(S#{phase => idle});
tick(#{phase := installing} = S) ->
    failed(webdriver_install_timeout, S);
tick(#{phase := Phase, config := C} = S) when Phase =:= starting; Phase =:= ready ->
    Now = erlang:monotonic_time(millisecond),
    case probe(S) of
        true ->
            S1 =
                case Phase of
                    starting ->
                        ?LOG_NOTICE("WebDriver ~p ready", [maps:get(backend, S)]),
                        S#{phase => ready, ready_since => Now, last_error => undefined};
                    ready ->
                        S
                end,
            %% A briefly healthy crash-loop must not reset the restart budget.
            Failures =
                case Now - maps:get(ready_since, S1, Now) >= 60000 of
                    true -> 0;
                    false -> maps:get(failures, S1)
                end,
            schedule(maps:get(health_ms, C), S1#{health_errors => 0, failures => Failures});
        false when Phase =:= starting ->
            case Now - maps:get(started, S) >= maps:get(ready_ms, C) of
                true -> failed(webdriver_startup_timeout, S);
                false -> schedule(500, S)
            end;
        false ->
            N = maps:get(health_errors, S) + 1,
            case N >= maps:get(health_failures, C) of
                true -> failed(webdriver_health_failed, S#{health_errors => N});
                false -> schedule(maps:get(health_ms, C), S#{health_errors => N})
            end
    end;
tick(S) ->
    S.

failed(Why, S0) ->
    S = cancel(S0),
    maps:foreach(
        fun(_Ref, Pid) -> Pid ! {webdriver_backend_lost, self()} end, maps:get(sessions, S)
    ),
    ?LOG_WARNING("WebDriver ~p unavailable: ~p", [maps:get(backend, S), Why]),
    case stop_process(S) of
        {error, S1} ->
            S1#{phase => failed, last_error => webdriver_shutdown_failed};
        {ok, S1} ->
            N = maps:get(failures, S1) + 1,
            maps:foreach(fun(Ref, _) -> erlang:demonitor(Ref, [flush]) end, maps:get(sessions, S1)),
            S2 = S1#{failures => N, last_error => Why, sessions => #{}},
            C = maps:get(config, S2),
            case N >= maps:get(max_failures, C) of
                true ->
                    S2#{phase => failed};
                false ->
                    Delay = erlang:min(
                        maps:get(max_restart_ms, C),
                        maps:get(restart_ms, C) * (1 bsl erlang:min(N - 1, 16))
                    ),
                    schedule(Delay, S2#{phase => backoff})
            end
    end.

probe(S) ->
    %% A separate httpc profile prevents inherited application proxy settings
    %% from sending local driver health checks to an external proxy.
    try
        {ok, _} = application:ensure_all_started(inets),
        case inets:start(httpc, [{profile, damage_webdriver_health}]) of
            {ok, _} -> ok;
            {error, {already_started, _}} -> ok
        end,
        Path =
            case maps:get(backend, S) of
                fixture -> "/health";
                _ -> "/status"
            end,
        URL = binary_to_list(endpoint(S)) ++ Path,
        case
            httpc:request(
                get,
                {URL, []},
                [
                    {timeout, 1500},
                    {connect_timeout, 1000},
                    {autoredirect, false}
                ],
                [{body_format, binary}],
                damage_webdriver_health
            )
        of
            {ok, {{_, 200, _}, _, Body}} when byte_size(Body) =< 65536 ->
                Json = jsx:decode(Body, [return_maps]),
                probe_json({maps:get(backend, S), maps:get(phase, S)}, Json);
            _ ->
                false
        end
    catch
        _:_ -> false
    end.
probe_json({fixture, _}, #{<<"fixture">> := true, <<"ready">> := true}) ->
    true;
probe_json({B, starting}, #{<<"value">> := #{<<"ready">> := true}}) when B =/= fixture -> true;
probe_json({B, ready}, #{<<"value">> := #{<<"ready">> := R}}) when B =/= fixture, is_boolean(R) ->
    true;
probe_json(_, _) ->
    false.

endpoint(#{config := C}) ->
    list_to_binary(
        "http://127.0.0.1:" ++ integer_to_list(maps:get(port, C)) ++
            string:trim(maps:get(base_path, C), trailing, "/")
    ).
port_free(Port) ->
    case gen_tcp:listen(Port, [{ip, {127, 0, 0, 1}}, {active, false}, {reuseaddr, false}]) of
        {ok, Socket} ->
            gen_tcp:close(Socket),
            true;
        _ ->
            false
    end.
base_env(C) ->
    [
        {"PATH", "/usr/local/bin:/usr/bin:/bin"},
        {"HOME", maps:get(dir, C)},
        {"LANG", "C.UTF-8"},
        {"SHELL", "/bin/sh"}
    ].
executable(Path) ->
    case filename:pathtype(Path) of
        absolute ->
            true = filelib:is_regular(Path),
            Path;
        _ ->
            case os:find_executable(Path) of
                false -> error(missing_executable);
                P -> P
            end
    end.
str(B) when is_binary(B) -> unicode:characters_to_list(B);
str(S) when is_list(S) -> S.
schedule(Ms, S) -> S#{timer => erlang:start_timer(Ms, self(), tick)}.
cancel(#{timer := undefined} = S) ->
    S;
cancel(#{timer := Ref} = S) ->
    erlang:cancel_timer(Ref),
    S#{timer => undefined}.
install_error(S) ->
    try
        {ok, B} = file:read_file(filename:join(maps:get(dir, maps:get(config, S)), "error.json")),
        true = byte_size(B) < 1024,
        #{<<"code">> := Code} = jsx:decode(B, [return_maps]),
        true = byte_size(Code) =< 64,
        match = re:run(Code, <<"^[a-z_]+$">>, [{capture, none}]),
        {webdriver_install_failed, Code}
    catch
        _:_ -> webdriver_install_failed
    end.

%% Driver output stays in a private, bounded local log, never a run/IPFS report.
private_log(S, Data0) ->
    try
        C = maps:get(config, S),
        Log = filename:join(maps:get(dir, C), "process.log"),
        Data = binary:part(Data0, 0, erlang:min(byte_size(Data0), 65536)),
        Size =
            case file:read_file_info(Log) of
                {ok, I} -> I#file_info.size;
                _ -> 0
            end,
        case Size + byte_size(Data) > 4194304 of
            true ->
                _ = file:delete(Log ++ ".3"),
                _ = file:rename(Log ++ ".2", Log ++ ".3"),
                _ = file:rename(Log ++ ".1", Log ++ ".2"),
                _ = file:rename(Log, Log ++ ".1");
            false ->
                ok
        end,
        ok = file:write_file(Log, Data, [append]),
        ok = file:change_mode(Log, 8#600)
    catch
        _:_ -> ok
    end.
