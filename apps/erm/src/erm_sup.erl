%%-------------------------------------------------------------------
%% @doc ERM top-level supervisor.
%%
%% The GTK4 session is supervised independently from the legacy Erlang/wx
%% workers. This is important because gtknode4 is a separate local C-node and
%% must remain usable when wx is absent or deliberately disabled.
%% @end
%%%-------------------------------------------------------------------

-module(erm_sup).

-author("Steven Joseph <steven@stevenjoseph.in>").
-copyright("Steven Joseph <steven@stevenjoseph.in>").
-license("Apache-2.0").

-behaviour(supervisor).

-include_lib("kernel/include/logger.hrl").

-export([
    start_link/0,
    sync_gtknode4/0,
    start_gtknode4/0,
    stop_gtknode4/0,
    gtknode4_status/0,
    sync_lens/0,
    start_lens/0,
    start_lens/1,
    stop_lens/0,
    lens_status/0,
    sync_optional/0,
    optional_status/0,
    start_gtknode4_child/1
]).
-export([init/1]).

-define(SERVER, ?MODULE).

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 10,
        period => 10
    },

    %% GTK4 and Lens are optional subsystems. Do not start them directly from
    %% supervisor init: an optional child that fails during initial startup
    %% would abort the entire ERM application. The bootstrap worker reconciles
    %% them dynamically after erm_sup itself is live and retries failures.
    case enabled() of
        false ->
            ?LOG_NOTICE("erm is disabled by configuration; starting empty supervisor", []),
            {ok, {SupFlags, []}};

        true ->
            MediaSpecs = media_specs(),
            LegacySpecs = legacy_specs(),
            OptionalSpecs = [optional_services_child_spec()],
            Children = MediaSpecs ++ LegacySpecs ++ OptionalSpecs,

            ?LOG_DEBUG("erm core child specifications: ~p", [Children]),
            {ok, {SupFlags, Children}}
    end.

enabled() ->
    case application:get_env(erm, enabled, true) of
        true ->
            true;
        false ->
            false;
        Invalid ->
            ?LOG_WARNING("Ignoring invalid erm.enabled value: ~p; defaulting to true", [Invalid]),
            true
    end.
%%%===================================================================
%%% GTK4 session
%%%===================================================================

gtknode4_specs() ->
    Config0 = application:get_env(erm, gtknode4, #{}),
    Config = options_map(Config0),
    case maps:get(enabled, Config, false) of
        true ->
            SessionConfig = maps:remove(enabled, Config),
            ?LOG_INFO(
                "Enabling supervised gtknode4 session in ~p mode",
                [maps:get(mode, SessionConfig, local_cnode)]
            ),
            [gtknode4_child_spec(SessionConfig)];
        false ->
            ?LOG_INFO("gtknode4 session is disabled by ERM configuration", []),
            []
    end.

%% Reconcile the live supervision tree with the current application
%% environment. Supervisor init/1 is only evaluated when erm_sup starts, so
%% application:set_env/3 and hot-loaded configuration otherwise have no effect
%% on an already-running ERM supervision tree.
sync_gtknode4() ->
    Config = options_map(application:get_env(erm, gtknode4, #{})),
    case maps:get(enabled, Config, false) of
        true -> start_gtknode4(maps:remove(enabled, Config));
        false -> stop_gtknode4()
    end.

start_gtknode4() ->
    Config = options_map(application:get_env(erm, gtknode4, #{})),
    case maps:get(enabled, Config, false) of
        true -> start_gtknode4(maps:remove(enabled, Config));
        false -> {error, disabled}
    end.

start_gtknode4(SessionConfig) ->
    case gtknode4_status() of
        {running, Pid} ->
            {ok, Pid};
        supervisor_not_running ->
            {error, erm_sup_not_running};
        stopped ->
            ?LOG_INFO("Starting optional gtknode4 stack under erm_sup", []),
            normalize_start_result(
                supervisor:start_child(?SERVER, gtknode4_child_spec(SessionConfig))
            );
        restarting ->
            ?LOG_INFO("Restarting optional gtknode4 stack under erm_sup", []),
            normalize_start_result(supervisor:restart_child(?SERVER, gtknode4_sup))
    end.

stop_gtknode4() ->
    case gtknode4_status() of
        supervisor_not_running ->
            ok;
        stopped ->
            ok;
        _ ->
            case supervisor:terminate_child(?SERVER, gtknode4_sup) of
                ok -> supervisor:delete_child(?SERVER, gtknode4_sup);
                {error, not_found} -> ok;
                Error -> Error
            end
    end.

gtknode4_status() ->
    case whereis(?SERVER) of
        undefined ->
            supervisor_not_running;
        _ ->
            case lists:keyfind(gtknode4_sup, 1, supervisor:which_children(?SERVER)) of
                {gtknode4_sup, Pid, supervisor, _} when is_pid(Pid) -> {running, Pid};
                {gtknode4_sup, undefined, supervisor, _} -> restarting;
                false -> stopped
            end
    end.

gtknode4_child_spec(SessionConfig) ->
    #{
        id => gtknode4_sup,
        %% Route startup through erm_sup so a stale manually-started GTK stack
        %% can be reclaimed instead of crashing the ERM application.
        start => {?MODULE, start_gtknode4_child, [SessionConfig]},
        %% GTK is an optional subsystem. If its own supervisor exhausts its
        %% restart budget, keep ERM alive and allow sync_gtknode4/0 to start a
        %% fresh session after the underlying fault has been corrected.
        restart => gtknode4_restart_policy(SessionConfig),
        shutdown => 10000,
        type => supervisor,
        modules => [gtknode4_sup]
    }.

normalize_start_result({ok, Pid}) -> {ok, Pid};
normalize_start_result({ok, Pid, _Info}) -> {ok, Pid};
normalize_start_result({error, {already_started, Pid}}) ->
    {error, {unmanaged_process_already_started, Pid}};
normalize_start_result({error, already_present}) -> {error, already_present};
normalize_start_result(Other) -> Other.

%% Called as the child start MFA by erm_sup. During a hot-development session
%% an older version of erm_lens/show or a manual GTK test may have left a
%% registered gtknode4_sup outside this supervision tree. Reclaim it here so
%% the optional subsystem cannot abort ERM startup.
start_gtknode4_child(SessionConfig) ->
    case whereis(gtknode4_sup) of
        undefined ->
            gtknode4_sup:start_link(SessionConfig);
        Existing when Existing =:= self() ->
            {error, recursive_gtknode4_supervisor};
        Existing ->
            case whereis(?SERVER) of
                Parent when Parent =:= self() ->
                    ?LOG_WARNING(
                        "Reclaiming unmanaged gtknode4_sup pid=~p before supervised startup",
                        [Existing]
                    ),
                    reclaim_registered_supervisor(gtknode4_sup, Existing),
                    gtknode4_sup:start_link(SessionConfig);
                _ ->
                    {error, {already_started, Existing}}
            end
    end.

gtknode4_restart_policy(SessionConfig) ->
    case maps:get(supervisor_restart, SessionConfig, temporary) of
        Policy when Policy =:= permanent; Policy =:= transient; Policy =:= temporary ->
            Policy;
        Invalid ->
            ?LOG_WARNING("Ignoring invalid gtknode4 supervisor restart policy: ~p", [Invalid]),
            temporary
    end.

%%%===================================================================
%%% ERM Lens optional subsystem
%%%===================================================================

lens_specs() ->
    Config = lens_config(),
    case maps:get(enabled, Config, true) of
        true ->
            LensConfig = maps:remove(enabled, Config),
            ?LOG_INFO("Enabling supervised ERM Lens subsystem", []),
            [erm_lens:child_spec(LensConfig)];
        false ->
            ?LOG_INFO("ERM Lens is disabled by ERM configuration", []),
            []
    end.

sync_lens() ->
    Config = lens_config(),
    case maps:get(enabled, Config, true) of
        true -> start_lens(maps:remove(enabled, Config));
        false -> stop_lens()
    end.

start_lens() ->
    Config = lens_config(),
    case maps:get(enabled, Config, true) of
        true -> start_lens(maps:remove(enabled, Config));
        false -> {error, disabled}
    end.

start_lens(LensConfig) when is_map(LensConfig) ->
    case lens_status() of
        {running, Pid} ->
            {ok, Pid};
        supervisor_not_running ->
            {error, erm_sup_not_running};
        stopped ->
            ?LOG_INFO("Starting ERM Lens under erm_sup", []),
            normalize_start_result(
                supervisor:start_child(?SERVER, erm_lens:child_spec(LensConfig))
            );
        restarting ->
            ?LOG_INFO("Restarting ERM Lens under erm_sup", []),
            normalize_start_result(supervisor:restart_child(?SERVER, erm_lens_sup))
    end;
start_lens(Other) ->
    {error, {bad_lens_config, Other}}.

stop_lens() ->
    case lens_status() of
        supervisor_not_running -> ok;
        stopped -> ok;
        _ ->
            ?LOG_INFO("Stopping ERM Lens", []),
            case supervisor:terminate_child(?SERVER, erm_lens_sup) of
                ok -> supervisor:delete_child(?SERVER, erm_lens_sup);
                {error, not_found} -> ok;
                Error -> Error
            end
    end.

lens_status() ->
    case whereis(?SERVER) of
        undefined ->
            supervisor_not_running;
        _ ->
            case lists:keyfind(erm_lens_sup, 1, supervisor:which_children(?SERVER)) of
                {erm_lens_sup, Pid, supervisor, _} when is_pid(Pid) -> {running, Pid};
                {erm_lens_sup, undefined, supervisor, _} -> restarting;
                false -> stopped
            end
    end.

lens_config() ->
    case application:get_env(erm, lens, #{}) of
        Map when is_map(Map) -> Map;
        List when is_list(List) ->
            try maps:from_list(List)
            catch _:_ ->
                ?LOG_WARNING("Ignoring invalid ERM Lens configuration: ~p", [List]),
                #{enabled => false}
            end;
        undefined -> #{};
        Invalid ->
            ?LOG_WARNING("Ignoring invalid ERM Lens configuration: ~p", [Invalid]),
            #{enabled => false}
    end.

%%%===================================================================
%%% Optional subsystem bootstrap
%%%===================================================================

optional_services_child_spec() ->
    #{
        id => erm_optional_services,
        start => {erm_optional_services, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [erm_optional_services]
    }.

sync_optional() ->
    case whereis(erm_optional_services) of
        undefined -> {error, optional_services_not_started};
        _ -> erm_optional_services:sync()
    end.

optional_status() ->
    case whereis(erm_optional_services) of
        undefined -> not_started;
        _ -> erm_optional_services:status()
    end.

reclaim_registered_supervisor(Name, Pid) ->
    case catch gen_server:stop(Pid, shutdown, 10000) of
        ok -> ok;
        {'EXIT', Reason} ->
            ?LOG_WARNING("Could not stop stale ~p cleanly pid=~p reason=~p", [Name, Pid, Reason]),
            catch exit(Pid, shutdown);
        Other ->
            ?LOG_WARNING("Unexpected stop result for stale ~p pid=~p result=~p", [Name, Pid, Other])
    end,
    wait_unregistered(Name, 100).

wait_unregistered(_Name, 0) -> ok;
wait_unregistered(Name, Attempts) ->
    case whereis(Name) of
        undefined -> ok;
        _ -> timer:sleep(10), wait_unregistered(Name, Attempts - 1)
    end.

%%%===================================================================
%%% GTK-independent media workers
%%%===================================================================

media_specs() ->
    [
        #{
            id => playlist,
            start => {playlist, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [playlist]
        },
        #{
            id => erm_mpv_proc,
            start => {erm_mpv_proc, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [erm_mpv_proc]
        },
        #{
            id => erm_mpv,
            start => {erm_mpv, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [erm_mpv]
        }
    ].

%%%===================================================================
%%% Existing wx-dependent ERM workers
%%%===================================================================

legacy_specs() ->
    case init_wx() of
        ok ->
            Pools = application:get_env(erm, pools, []),
            ?LOG_DEBUG("Starting ERM pools: ~p", [Pools]),
            legacy_worker_specs() ++ pool_specs(Pools);
        {error, Reason} ->
            %% Preserve the old behaviour for wx-dependent workers, but do not
            %% suppress the independent GTK4 subsystem.
            ?LOG_WARNING(
                "wx initialization failed; legacy wx workers are disabled: ~p",
                [Reason]
            ),
            []
    end.

init_wx() ->
    try wx:new() of
        {wx_ref, _, wx, _} ->
            persistent_term:put(erm_wx_env, wx:get_env()),
            ok;
        Other ->
            {error, {unexpected_wx_result, Other}}
    catch
        error:undef ->
            {error, wx_not_available};
        Class:Reason:Stacktrace ->
            {error, {Class, Reason, Stacktrace}}
    end.

legacy_worker_specs() ->
    WhisperSpecs = whisper_child_specs(),
    [
        #{
            id => hlwm_events,
            start => {hlwm_events, start_link, [#{}]},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [hlwm_events]
        },
        #{
            id => erm_media_autoplay,
            start => {erm_media_autoplay, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [erm_media_autoplay]
        },
        #{
            id => erm_dpms,
            start => {erm_dpms, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [erm_dpms]
        }
    ] ++
        WhisperSpecs.

whisper_child_specs() ->
    case application:get_env(erm, whisper_trigger, #{}) of
        Opts0 when is_map(Opts0) ->
            Enabled = maps:get(enabled, Opts0, true),
            Opts = maps:remove(enabled, Opts0),
            whisper_child_specs(Enabled, Opts);
        Invalid ->
            ?LOG_WARNING(
                "Ignoring invalid erm whisper_trigger configuration: ~p",
                [Invalid]
            ),
            []
    end.

whisper_child_specs(false, _Opts) ->
    ?LOG_DEBUG("Whisper trigger disabled by configuration.", []),
    [];
whisper_child_specs(true, Opts) ->
    case whisper_trigger_srv:availability(Opts) of
        {ok, Runtime} ->
            ?LOG_INFO("Whisper trigger available: ~p", [Runtime]),
            [
                #{
                    id => whisper_trigger_srv,
                    start => {whisper_trigger_srv, start_link, [Opts]},
                    restart => permanent,
                    shutdown => 5000,
                    type => worker,
                    modules => [whisper_trigger_srv]
                }
            ];
        {error, Reason} ->
            ?LOG_INFO("Whisper trigger unavailable; not starting: ~p", [Reason]),
            []
    end;
whisper_child_specs(Invalid, _Opts) ->
    ?LOG_WARNING("Ignoring invalid whisper_trigger enabled value: ~p", [Invalid]),
    [].
pool_specs(Pools) when is_list(Pools) ->
    [pool_spec(Pool) || Pool <- Pools].

pool_spec({Name, SizeArgs, WorkerArgs}) when is_atom(Name), is_list(SizeArgs) ->
    PoolArgs = [{name, {local, Name}}, {worker_module, Name}] ++ SizeArgs,
    poolboy:child_spec(Name, PoolArgs, WorkerArgs);
pool_spec(BadSpec) ->
    error({bad_erm_pool_spec, BadSpec}).

options_map(Map) when is_map(Map) ->
    Map;
options_map(List) when is_list(List) ->
    maps:from_list(List);
options_map(undefined) ->
    #{};
options_map(Other) ->
    error({bad_gtknode4_config, Other}).
