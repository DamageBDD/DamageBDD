%% Supervised, node-local fs coordinator. This is an operator tool, not a sandbox.
-module(damage_reload).
-behaviour(gen_server).
-export([start/0, stop/0, reconfigure/0, status/0, reload/0, pause/0, resume/0]).
-export([
    start_link/1,
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).
-include_lib("kernel/include/logger.hrl").

start() ->
    case damage_reload_config:read() of
        disabled ->
            {ok, disabled};
        {error, _} = Error ->
            Error;
        {ok, Cfg} ->
            Spec = #{
                id => ?MODULE,
                start => {?MODULE, start_link, [Cfg]},
                restart => transient,
                shutdown => 10000,
                type => worker,
                modules => [?MODULE]
            },
            case supervisor:start_child(damage_sup, Spec) of
                {ok, Pid} -> {ok, Pid};
                {error, {already_started, Pid}} -> {ok, Pid};
                {error, already_present} -> supervisor:restart_child(damage_sup, ?MODULE);
                Error -> Error
            end
    end.

stop() ->
    case supervisor:terminate_child(damage_sup, ?MODULE) of
        ok -> supervisor:delete_child(damage_sup, ?MODULE);
        {error, not_found} -> ok;
        Error -> Error
    end.

reconfigure() ->
    %% Validate first: a typo must not tear down a working development reloader.
    case damage_reload_config:read() of
        {error, _} = Error ->
            Error;
        _ ->
            case stop() of
                ok -> start();
                Error -> Error
            end
    end.

status() -> call(status).
reload() -> call(reload).
pause() -> call(pause).
resume() -> call(resume).

call(Request) ->
    case whereis(?MODULE) of
        undefined -> {error, not_running};
        Pid -> gen_server:call(Pid, Request, 30000)
    end.

start_link(Cfg) -> gen_server:start_link({local, ?MODULE}, ?MODULE, Cfg, []).

init(Cfg0) ->
    process_flag(trap_exit, true),
    %% Different coordinator lifetimes never share BEAM output. A cancelled OS
    %% build may still be shutting down when reconfigure starts a new coordinator.
    Cfg =
        case maps:get(mode, Cfg0) of
            rebar ->
                Session =
                    integer_to_list(erlang:system_time(nanosecond)) ++ "-" ++
                        integer_to_list(erlang:unique_integer([positive, monotonic])),
                Cfg0#{build_dir := filename:join(maps:get(build_dir, Cfg0), Session)};
            sources ->
                Cfg0
        end,
    self() ! setup,
    %% Names are bounded by config validation, not derived from source file names.
    Dirs = maps:get(watch_dirs, Cfg),
    Watchers = [
        {list_to_atom("damage_reload_fs_" ++ integer_to_list(I)), D, undefined}
     || {I, D} <- lists:zip(lists:seq(1, length(Dirs)), Dirs)
    ],
    {ok, #{
        cfg => Cfg,
        watchers => Watchers,
        observed => undefined,
        pending => none,
        worker => none,
        job_timer => undefined,
        debounce => undefined,
        poll => undefined,
        retry => undefined,
        paused => false,
        dirty => false,
        force => false,
        last_result => starting
    }}.

handle_call(status, _From, S) ->
    Ws = [
        {Name, Dir, is_pid(Pid) andalso is_process_alive(Pid)}
     || {Name, Dir, Pid} <- maps:get(watchers, S)
    ],
    Reply = #{
        configuration => maps:get(cfg, S),
        watchers => Ws,
        paused => maps:get(paused, S),
        building => maps:get(worker, S) =/= none,
        pending_modules => pending_modules(maps:get(pending, S)),
        last_result => maps:get(last_result, S)
    },
    {reply, Reply, S};
handle_call(reload, _From, S) ->
    {reply, {ok, queued}, queue(S, true)};
handle_call(pause, _From, S) ->
    {reply, ok, S#{paused := true}};
handle_call(resume, _From, S) ->
    {reply, ok, queue(S#{paused := false}, true)};
handle_call(_, _, S) ->
    {reply, {error, bad_request}, S}.

handle_cast(_, S) -> {noreply, S}.

handle_info(setup, S) ->
    Cfg = maps:get(cfg, S),
    %% Optional tooling failures never make damage_app's startup fail.
    Result =
        try
            {module, fs} = code:ensure_loaded(fs),
            {ok, _} = application:ensure_all_started(crypto),
            {ok, _} = application:ensure_all_started(compiler),
            case maps:get(mode, Cfg) of
                rebar -> {ok, _} = application:ensure_all_started(erlexec);
                sources -> ok
            end,
            {ok, damage_reload_build:snapshot(Cfg)}
        catch
            Class:Reason -> {error, {Class, Reason}}
        end,
    case Result of
        {ok, Baseline} ->
            ?LOG_WARNING(
                "Local code reload enabled mode=~p paths=~p; trusted operator sources only",
                [maps:get(mode, Cfg), maps:get(watch_dirs, Cfg)]
            ),
            S1 = maintain_watchers(S#{observed := Baseline, last_result := watching}),
            S2 = arm_poll(S1),
            case maps:get(load_on_start, Cfg) of
                true -> {noreply, queue(S2, true)};
                false -> {noreply, S2}
            end;
        {error, Why} ->
            ?LOG_WARNING("Code reload unavailable: ~p (node startup continues)", [Why]),
            %% Remain inspectable and stoppable. Reconfigure after fixing prerequisites.
            {noreply, S#{paused := true, last_result := {unavailable, Why}}}
    end;
handle_info({_, {fs, file_event}, {Path, Flags}}, S) ->
    case changed_event(Path, Flags, maps:get(cfg, S)) of
        true -> {noreply, queue(S, false)};
        false -> {noreply, S}
    end;
handle_info({timeout, Ref, debounce}, #{debounce := Ref} = S) ->
    {noreply, start_work(S#{debounce := undefined})};
handle_info({timeout, Ref, poll}, #{poll := Ref} = S) ->
    %% Reconciliation covers dropped events and event-manager restarts. fs remains
    %% the low-latency event source; content hashes prevent no-op recompilation.
    S1 = arm_poll(maintain_watchers(S#{poll := undefined})),
    {noreply, start_work(S1)};
handle_info({timeout, Ref, retry}, #{retry := Ref} = S) ->
    {noreply, start_work(S#{retry := undefined})};
handle_info({build_result, Pid, Result}, #{worker := {Pid, Mon}} = S) ->
    unlink(Pid),
    erlang:demonitor(Mon, [flush]),
    cancel(maps:get(job_timer, S)),
    S1 = S#{worker := none, job_timer := undefined},
    case maps:get(dirty, S1) of
        true -> {noreply, queue(S1#{dirty := false, pending := none}, true)};
        false -> {noreply, accept_result(Result, S1)}
    end;
handle_info({timeout, Ref, job}, #{job_timer := Ref, worker := {Pid, Mon}} = S) ->
    %% Only the compilation worker is terminated; never an application worker.
    unlink(Pid),
    exit(Pid, kill),
    erlang:demonitor(Mon, [flush]),
    {noreply, worker_failed(build_timeout, S#{worker := none, job_timer := undefined})};
handle_info({'DOWN', Mon, process, Pid, Why}, #{worker := {Pid, Mon}} = S) ->
    unlink(Pid),
    cancel(maps:get(job_timer, S)),
    {noreply, worker_failed({worker_exit, Why}, S#{worker := none, job_timer := undefined})};
handle_info({'EXIT', Pid, Why}, S) ->
    Ws = maps:get(watchers, S),
    case lists:keymember(Pid, 3, Ws) of
        true ->
            ?LOG_WARNING("Code reload fs watcher exited: ~p; retrying on reconciliation", [Why]),
            Ws1 = [
                {N, D,
                    case P of
                        Pid -> undefined;
                        _ -> P
                    end}
             || {N, D, P} <- Ws
            ],
            {noreply, S#{watchers := Ws1}};
        false ->
            {noreply, S}
    end;
handle_info(_, S) ->
    {noreply, S}.

queue(S, Force) ->
    S1 = S#{force := maps:get(force, S) orelse Force},
    case maps:get(worker, S1) of
        none ->
            cancel(maps:get(debounce, S1)),
            Ref = erlang:start_timer(maps:get(debounce_ms, maps:get(cfg, S1)), self(), debounce),
            S1#{debounce := Ref};
        _ ->
            S1#{dirty := true}
    end.

start_work(#{paused := true} = S) ->
    S;
start_work(#{debounce := D} = S) when D =/= undefined -> S;
start_work(#{worker := W} = S) when W =/= none -> S;
start_work(S) ->
    Cfg = maps:get(cfg, S),
    Parent = self(),
    Observed = maps:get(observed, S),
    Pending = maps:get(pending, S),
    Force = maps:get(force, S),
    {Pid, Mon} = spawn_opt(
        fun() ->
            process_flag(trap_exit, true),
            Result =
                try
                    damage_reload_build:prepare(Cfg, Observed, Pending, Force)
                catch
                    Class:Why:Stack -> {scan_failed, {Class, Why, Stack}}
                end,
            Parent ! {build_result, self(), Result}
        end,
        [link, monitor]
    ),
    Ref = erlang:start_timer(maps:get(build_timeout_ms, Cfg) + 15000, self(), job),
    S#{worker := {Pid, Mon}, job_timer := Ref, force := false, dirty := false}.

accept_result({unchanged, Fp}, S) ->
    S#{observed := Fp};
accept_result({stale, _}, S) ->
    queue(S#{pending := none, last_result := source_changed_during_build}, true);
accept_result({failed, Fp, Why}, S) ->
    failed(Why, S#{observed := Fp, pending := none});
accept_result({scan_failed, Why}, S) ->
    failed(Why, S#{pending := none});
accept_result({candidate, Fp, Objects}, #{paused := true} = S) ->
    S#{pending := {Fp, Objects}, last_result := paused};
accept_result({candidate, Fp, Objects}, S) ->
    Cfg = maps:get(cfg, S),
    %% Re-check immediately before publication, including deferred retry attempts.
    Current =
        try
            {ok, damage_reload_build:snapshot(Cfg)}
        catch
            Class:Why -> {error, {Class, Why}}
        end,
    case Current of
        {ok, Fp} ->
            case damage_reload_build:publish(Cfg, Objects) of
                {ok, Ms} ->
                    case Ms of
                        [] -> ok;
                        _ -> ?LOG_INFO("Code reload published modules=~p", [Ms])
                    end,
                    S#{observed := Fp, pending := none, last_result := {loaded, Ms}};
                {deferred, Ms} ->
                    Last = {deferred, Ms},
                    case maps:get(last_result, S) of
                        Last ->
                            ok;
                        _ ->
                            ?LOG_NOTICE("Code reload deferred: processes still use old code ~p", [
                                Ms
                            ])
                    end,
                    cancel(maps:get(retry, S)),
                    Ref = erlang:start_timer(maps:get(retry_ms, Cfg), self(), retry),
                    S#{observed := Fp, pending := {Fp, Objects}, retry := Ref, last_result := Last};
                {error, Why1} ->
                    failed(Why1, S#{observed := Fp, pending := none})
            end;
        {ok, _} ->
            queue(S#{pending := none}, true);
        {error, Why2} ->
            failed(Why2, S#{pending := none})
    end.

failed(Why, S) ->
    ?LOG_WARNING("Code reload rejected; current code retained: ~p", [Why]),
    S#{last_result := {error, Why}}.

worker_failed(Why, S) ->
    %% Avoid hammering a persistently failing compiler on each reconciliation tick.
    Observed =
        try
            damage_reload_build:snapshot(maps:get(cfg, S))
        catch
            _:_ -> maps:get(observed, S)
        end,
    S1 = failed(Why, S#{observed := Observed, pending := none}),
    case maps:get(dirty, S1) of
        true -> queue(S1#{dirty := false}, true);
        false -> S1
    end.

arm_poll(S) ->
    Ref = erlang:start_timer(maps:get(rescan_ms, maps:get(cfg, S)), self(), poll),
    S#{poll := Ref}.

maintain_watchers(S) ->
    S#{watchers := [maintain_watcher(W) || W <- maps:get(watchers, S)]}.

maintain_watcher({Name, Dir, Pid}) when is_pid(Pid) ->
    case is_process_alive(Pid) of
        true ->
            %% Re-adding a handler already present is harmless; a restarted event
            %% manager needs a fresh subscription. Reconciliation also covers gaps.
            _ = subscribe(Name),
            {Name, Dir, Pid};
        false ->
            maintain_watcher({Name, Dir, undefined})
    end;
maintain_watcher({Name, Dir, undefined}) ->
    try fs:start_link(Name, Dir) of
        {ok, Pid} ->
            case subscribe(Name) of
                ok -> ok;
                Error -> ?LOG_WARNING("Code reload fs subscribe ~p: ~p", [Dir, Error])
            end,
            {Name, Dir, Pid};
        Error ->
            ?LOG_WARNING("Code reload fs unavailable for ~p: ~p", [Dir, Error]),
            {Name, Dir, undefined}
    catch
        Class:Why ->
            ?LOG_WARNING("Code reload fs failed for ~p: ~p", [Dir, {Class, Why}]),
            {Name, Dir, undefined}
    end.

subscribe(Name) ->
    try
        fs:subscribe(Name)
    catch
        Class:Why -> {error, {Class, Why}}
    end.

changed_event(P0, Flags, Cfg) ->
    try
        P =
            case P0 of
                B when is_binary(B) -> unicode:characters_to_list(B);
                L when is_list(L) -> L
            end,
        Write = lists:any(
            fun(F) ->
                lists:member(
                    F,
                    [
                        modified,
                        created,
                        removed,
                        deleted,
                        renamed,
                        moved_to,
                        moved_from,
                        mustscansubdirs,
                        userdropped,
                        kerneldropped,
                        rootchanged
                    ]
                )
            end,
            Flags
        ),
        Write andalso (damage_reload_build:interesting(P, Cfg) orelse filelib:is_dir(P))
    catch
        _:_ -> false
    end.

pending_modules(none) -> [];
pending_modules({_, Objects}) -> [M || {M, _, _} <- Objects].

cancel(undefined) ->
    ok;
cancel(Ref) ->
    _ = erlang:cancel_timer(Ref),
    ok.

terminate(_, S) ->
    lists:foreach(fun cancel/1, [maps:get(K, S) || K <- [job_timer, debounce, poll, retry]]),
    case maps:get(worker, S) of
        {Pid, _} -> exit(Pid, kill);
        none -> ok
    end,
    %% Stop only fs trees owned by this coordinator, not the global fs application.
    lists:foreach(
        fun
            ({_, _, P}) when is_pid(P) -> exit(P, shutdown);
            (_) -> ok
        end,
        maps:get(watchers, S)
    ),
    ok.

code_change(_, S, _) -> {ok, S}.
