%%%-------------------------------------------------------------------
%%% @doc ERM Lens public entrypoint.
%%%
%%% Lens is an optional ERM subsystem. In a normal release it is supervised
%%% by erm_sup. Direct start/0 remains available for development shells.
%%%
%%% show/0 is intentionally synchronous: it ensures the Lens supervisor and
%%% GTK4 stack are available, asks the UI to build/show immediately, and
%%% returns a useful error instead of silently dropping a cast.
%%%-------------------------------------------------------------------
-module(erm_lens).

-include_lib("kernel/include/logger.hrl").

-export([
    start/0,
    start/1,
    start_standalone/0,
    start_standalone/1,
    start_link/1,
    stop/0,
    show/0,
    status/0,
    child_spec/1,
    defaults/0
]).

-define(UI_CALL_TIMEOUT, 10000).
-define(GTK_READY_TIMEOUT, 8000).
-define(UI_START_TIMEOUT, 5000).

defaults() ->
    Home =
        case os:getenv("HOME") of
            false -> "/tmp";
            V -> V
        end,
    Priv =
        case code:priv_dir(erm) of
            {error, _} -> filename:absname("priv");
            V2 -> V2
        end,
    #{
        enabled => true,
        show_on_start => false,
        relays => [
            <<"wss://relay.damus.io">>,
            <<"wss://nos.lol">>,
            <<"wss://relay.primal.net">>
        ],
        window_seconds => 172800,
        refresh_ms => 60000,
        max_events => 4000,
        max_store_bytes => 67108864,
        relay_backoff_ms => 30000,
        relay_backoff_max_ms => 300000,
        media_script => filename:join(Priv, "lens_media.py"),
        cache_dir => filename:join([Home, ".cache", "erm-lens"]),
        load_images => true,
        media_hosts => [],
        page_size => 6,
        nostr_pubkey => undefined,
        signer => undefined,
        wallet_adapter => undefined,
        network => <<"ae_uat">>,
        registry => undefined,
        tokens => [],
        allow_mainnet => false
    }.

child_spec(C0) ->
    C = merged_config(C0),
    #{
        id => erm_lens_sup,
        start => {?MODULE, start_link, [C]},
        %% Lens is optional. If its private supervision tree exhausts its
        %% restart budget, keep ERM alive and allow erm_sup:sync_lens/0 to
        %% re-create it after the underlying problem has been fixed.
        restart => lens_restart_policy(C),
        shutdown => 10000,
        type => supervisor,
        modules => [erm_lens_sup]
    }.

start() ->
    start(application:get_env(erm, lens, #{})).

%% Normal startup is supervised-only. The old implicit standalone fallback
%% could leave an erm_lens_sup registered before erm_sup booted, causing the
%% entire ERM application to fail with {already_started, Pid}.
start(C0) ->
    with_config(C0, fun start_configured/1).

start_configured(C) ->
    case maps:get(enabled, C, true) of
        false ->
            ?LOG_INFO("ERM Lens start requested but Lens is disabled", []),
            {error, disabled};
        true ->
            case ensure_erm_application() of
                ok -> start_under_erm(C);
                {error, _} = Error -> Error
            end
    end.

%% Explicit development escape hatch. Never called implicitly by show/0.
start_standalone() ->
    start_standalone(application:get_env(erm, lens, #{})).

start_standalone(C0) ->
    with_config(C0, fun(C) ->
        case maps:get(enabled, C) of
            false -> {error, disabled};
            true -> do_start_standalone(C)
        end
    end).

start_link(C0) ->
    with_config(C0, fun(C) ->
        case maps:get(enabled, C) of
            false -> {error, disabled};
            true -> start_link_configured(maps:remove(enabled, C))
        end
    end).

start_link_configured(C) ->
    log_optional_dependency(ssl),
    log_optional_dependency(gun),
    case whereis(erm_lens_sup) of
        undefined ->
            ?LOG_INFO("Starting ERM Lens supervision tree", []),
            erm_lens_sup:start_link(C);
        Existing ->
            %% If erm_sup is invoking this child start MFA, the existing
            %% registered supervisor is an unmanaged development leftover.
            %% Stop it and create a fresh child with the configured state.
            case whereis(erm_sup) of
                Parent when Parent =:= self() ->
                    ?LOG_WARNING(
                        "Reclaiming unmanaged ERM Lens supervisor pid=~p before supervised startup",
                        [Existing]
                    ),
                    case reclaim_standalone(Existing) of
                        ok -> erm_lens_sup:start_link(C);
                        {error, _} = Error -> Error
                    end;
                _ ->
                    {error, {already_started, Existing}}
            end
    end.

show() ->
    case ensure_started() of
        {ok, _Pid} ->
            case ensure_ui_backend() of
                ok ->
                    case await_ui() of
                        ok ->
                            call_ui(show);
                        {error, UiReason} = UiError ->
                            ?LOG_WARNING("ERM Lens UI process did not become ready: ~p", [UiReason]),
                            UiError
                    end;
                {error, Reason} = Error ->
                    ?LOG_WARNING("ERM Lens cannot show: GTK backend unavailable: ~p", [Reason]),
                    Error
            end;
        {error, Reason} = Error ->
            ?LOG_WARNING("ERM Lens cannot show: subsystem unavailable: ~p", [Reason]),
            Error
    end.

status() ->
    SupStatus =
        case whereis(erm_sup) of
            undefined -> standalone_lens_status();
            _ -> bounded_status(erm_sup, lens_status, standalone_lens_status())
        end,
    UiStatus =
        case whereis(erm_lens_ui) of
            undefined -> not_started;
            _ -> bounded_status(erm_lens_ui, status, {error, ui_status_timeout})
        end,
    GtkStatus = #{
        gtknode4_sup => whereis(gtknode4_sup),
        gtknode4 => whereis(gtknode4),
        gtkgs => whereis(gtkgs),
        controller_status => safe_process_call(gtknode4, status),
        port_status => safe_process_call(gtknode4_port, status)
    },
    Optional = bounded_status(erm_sup, optional_status, not_started),
    #{
        application => application_status(erm),
        supervisor => SupStatus,
        optional_services => Optional,
        ui => UiStatus,
        feed => safe_process_call(erm_lens_feed, status),
        sync => safe_process_call(erm_lens_sync, status),
        gtk => GtkStatus
    }.

stop() ->
    case whereis(erm_sup) of
        undefined ->
            stop_standalone();
        _ ->
            Result = safe_apply(erm_sup, stop_lens, [], {error, erm_sup_stop_failed}),
            ?LOG_INFO("ERM Lens stop result: ~p", [Result]),
            Result
    end.

%%%===================================================================
%%% Internal
%%%===================================================================

ensure_started() ->
    %% show/0 must not bypass enabled=false by stripping it before start_lens/1.
    start(application:get_env(erm, lens, #{})).

start_under_erm(C) ->
    case whereis(erm_sup) of
        undefined ->
            {error, erm_sup_not_running};
        _ ->
            case
                safe_apply(
                    erm_sup, start_lens, [maps:remove(enabled, C)], {error, start_lens_failed}
                )
            of
                {ok, Pid} = OK when is_pid(Pid) -> OK;
                {error, already_present} -> current_lens_pid();
                {error, {unmanaged_process_already_started, _}} = Unmanaged -> Unmanaged;
                Other -> Other
            end
    end.

do_start_standalone(C) ->
    case whereis(erm_sup) of
        Pid when is_pid(Pid) ->
            {error, {erm_sup_running, use_start_or_show}};
        undefined ->
            case whereis(erm_lens_sup) of
                undefined ->
                    case start_link(C) of
                        {ok, Pid} = OK ->
                            unlink(Pid),
                            ?LOG_WARNING(
                                "ERM Lens started outside erm_sup; development-only process pid=~p",
                                [Pid]
                            ),
                            OK;
                        Error ->
                            Error
                    end;
                Pid ->
                    {ok, Pid}
            end
    end.

current_lens_pid() ->
    case whereis(erm_lens_sup) of
        Pid when is_pid(Pid) -> {ok, Pid};
        undefined -> {error, lens_not_started}
    end.

ensure_erm_application() ->
    case whereis(erm_sup) of
        Pid when is_pid(Pid) -> ok;
        undefined ->
            case {node(), local_cnode_requires_distribution()} of
                {nonode@nohost, true} ->
                    {error, {erm_not_ready, erlang_distribution_not_started}};
                _ ->
                    ?LOG_INFO(
                        "ERM Lens requested before erm_sup; ensuring ERM application is started", []
                    ),
                    case application:ensure_all_started(erm) of
                        {ok, _Apps} ->
                            case whereis(erm_sup) of
                                P when is_pid(P) -> ok;
                                undefined -> {error, erm_sup_not_running}
                            end;
                        {error, Reason} ->
                            {error, {erm_start_failed, Reason}}
                    end
            end
    end.

local_cnode_requires_distribution() ->
    C = options_map(application:get_env(erm, gtknode4, #{})),
    maps:get(enabled, C, false) =:= true andalso maps:get(mode, C, local_cnode) =:= local_cnode.

reclaim_standalone(Pid) ->
    %% A trapping supervisor ignores an unlinked shutdown signal; do not report
    %% success while its registered name is still owned by the old process.
    try gen_server:stop(Pid, shutdown, 10000) of
        ok -> ok
    catch
        exit:noproc -> ok;
        exit:{noproc, _} -> ok;
        exit:_ -> {error, stale_lens_shutdown_failed}
    end.

stop_standalone() ->
    case whereis(erm_lens_sup) of
        undefined -> ok;
        Pid -> gen_server:stop(Pid, normal, 10000)
    end.

standalone_lens_status() ->
    case whereis(erm_lens_sup) of
        undefined -> stopped;
        Pid -> {running, Pid}
    end.

ensure_ui_backend() ->
    case whereis(gtkgs) of
        Pid when is_pid(Pid) -> await_gtknode4_ready();
        undefined ->
            case whereis(erm_sup) of
                undefined ->
                    {error, gtkgs_not_started};
                _ ->
                    case safe_apply(erm_sup, start_gtknode4, [], {error, gtknode4_start_failed}) of
                        {ok, _} -> await_gtkgs();
                        {error, disabled} -> {error, gtknode4_disabled};
                        Error -> {error, {gtknode4_start_failed, Error}}
                    end
            end
    end.

await_ui() ->
    End = erlang:monotonic_time(millisecond) + ?UI_START_TIMEOUT,
    await_ui(End).

await_ui(End) ->
    case whereis(erm_lens_ui) of
        Pid when is_pid(Pid) -> ok;
        undefined ->
            case End - erlang:monotonic_time(millisecond) of
                Left when Left =< 0 -> {error, ui_start_timeout};
                _ ->
                    timer:sleep(25),
                    await_ui(End)
            end
    end.

await_gtkgs() ->
    End = erlang:monotonic_time(millisecond) + ?GTK_READY_TIMEOUT,
    await_gtkgs(End).

await_gtkgs(End) ->
    case whereis(gtkgs) of
        Pid when is_pid(Pid) -> await_gtknode4_ready();
        undefined ->
            case End - erlang:monotonic_time(millisecond) of
                Left when Left =< 0 -> {error, gtkgs_start_timeout};
                _ ->
                    timer:sleep(50),
                    await_gtkgs(End)
            end
    end.

await_gtknode4_ready() ->
    case whereis(gtknode4) of
        undefined ->
            {error, gtknode4_not_started};
        _ ->
            try gtknode4:await_ready(?GTK_READY_TIMEOUT) of
                ok -> ok;
                Other -> {error, {gtknode4_not_ready, Other}}
            catch
                error:undef -> {error, gtknode4_api_unavailable};
                Class:Reason -> {error, {gtknode4_ready_failed, Class, Reason}}
            end
    end.

call_ui(Request) ->
    case safe_ui_call(Request, {error, ui_call_failed}) of
        {ok, _} = OK -> OK;
        ok -> ok;
        {error, _} = Error -> Error;
        Other -> Other
    end.

safe_ui_call(Request, Default) ->
    case whereis(erm_lens_ui) of
        undefined ->
            {error, ui_not_started};
        _ ->
            try gen_server:call(erm_lens_ui, Request, ?UI_CALL_TIMEOUT) of
                Reply -> Reply
            catch
                exit:Reason ->
                    ?LOG_WARNING("ERM Lens UI call ~p exited: ~p", [Request, Reason]),
                    case Default of
                        {error, Tag} -> {error, {Tag, Reason}};
                        _ -> Default
                    end
            end
    end.

log_optional_dependency(App) ->
    case application:ensure_all_started(App) of
        {ok, _} ->
            ?LOG_DEBUG("ERM Lens dependency ready: ~p", [App]);
        {error, Reason} ->
            %% Do not fail the Lens supervisor. Relay/media paths already
            %% isolate I/O failures and can recover when dependencies appear.
            ?LOG_WARNING("ERM Lens optional dependency ~p unavailable: ~p", [App, Reason])
    end.

merged_config(C0) ->
    case erm_lens_config:normalize(C0) of
        {ok, C} -> C;
        {error, Reason} -> error(Reason)
    end.

with_config(C0, Fun) ->
    case erm_lens_config:normalize(C0) of
        {ok, C} -> Fun(C);
        {error, _} = Error -> Error
    end.

options_map(Map) when is_map(Map) -> Map;
options_map(List) when is_list(List) -> maps:from_list(List);
options_map(undefined) -> #{};
options_map(Other) -> error({bad_lens_config, Other}).

lens_restart_policy(C) ->
    case maps:get(supervisor_restart, C, temporary) of
        Policy when Policy =:= permanent; Policy =:= transient; Policy =:= temporary -> Policy;
        Invalid ->
            ?LOG_WARNING("Ignoring invalid ERM Lens supervisor restart policy: ~p", [Invalid]),
            temporary
    end.

application_status(App) ->
    case lists:keyfind(App, 1, application:which_applications()) of
        false -> stopped;
        {App, Description, Vsn} -> #{state => running, description => Description, vsn => Vsn}
    end.

safe_process_call(Module, Function) ->
    case whereis(Module) of
        undefined -> not_started;
        _ -> bounded_status(Module, Function, {error, status_timeout})
    end.

safe_apply(M, F, A, Default) ->
    try apply(M, F, A) of
        Result -> Result
    catch
        Class:Reason:Stacktrace ->
            ?LOG_WARNING(
                "ERM Lens helper ~p:~p/~p failed: ~p:~p stack=~p",
                [M, F, length(A), Class, erm_lens_diagnostics:summary(Reason),
                 erm_lens_diagnostics:stack(Stacktrace)]
            ),
            Default
    end.

%% Read-only diagnostics may time out independently; never let a hung optional
%% supervisor make the public status command wait indefinitely.
bounded_status(Module, Function, Default) ->
    {Pid, Mon} = erm_lens_worker:start(lens_status_result, fun() ->
        safe_apply(Module, Function, [], Default)
    end),
    try
        receive
            {lens_status_result, Pid, Result} -> Result;
            {'DOWN', Mon, process, Pid, _} -> Default
        after 1000 ->
            exit(Pid, kill),
            Default
        end
    after
        erlang:demonitor(Mon, [flush])
    end.
