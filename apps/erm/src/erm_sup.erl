%%-------------------------------------------------------------------
%% @doc erm top level supervisor.
%% @end
%% https://erlang.org/doc/man/supervisor.html
%%%-------------------------------------------------------------------

-module(erm_sup).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-behaviour(supervisor).

-include_lib("kernel/include/logger.hrl").

-export([start_link/0]).
-export([init/1]).

-define(SERVER, ?MODULE).

start_link() -> supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%% sup_flags() = #{strategy => strategy(),         % optional
%%                 intensity => non_neg_integer(), % optional
%%                 period => pos_integer()}        % optional
%% child_spec() = #{id => child_id(),       % mandatory
%%                  start => mfargs(),      % mandatory
%%                  restart => restart(),   % optional
%%                  shutdown => shutdown(), % optional
%%                  type => worker(),       % optional
%%                  modules => modules()}   % optional

init([]) ->
    {ok, Pools} = application:get_env(erm, pools),
    ?LOG_DEBUG("Starting erm workers ~p~n", [Pools]),
    SupFlags = {one_for_one, 10, 10},
    PoolSpecs =
        lists:map(
            fun({Name, SizeArgs, WorkerArgs}) ->
                PoolArgs = [{name, {local, Name}}, {worker_module, Name}] ++ SizeArgs,
                poolboy:child_spec(Name, PoolArgs, WorkerArgs)
            end,
            Pools
        ),

    %% tray options
    IconPath = filename:join(code:priv_dir(erm), "icons/erm.png"),
    TrayOpts = [
        {icon, IconPath},
        {tooltip, "erm node – ready"},
        {on_menu, fun tray_handle/1},
        {menu, [
            {open_dashboard, "Open Dashboard"},
            sep,
            {restart, "Restart"},
            {quit, "Quit"}
        ]}
    ],

    PoolSpecs0 =
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
                id => erm_tray,
                start => {erm_tray, start_link, [TrayOpts]},
                restart => permanent,
                shutdown => 5000,
                type => worker,
                modules => [erm_tray]
            }
        ] ++
            PoolSpecs,

    ?LOG_DEBUG("Worker definitions ~p~n", [PoolSpecs0]),
    {ok, {SupFlags, PoolSpecs0}}.

%%--------------------------------------------------------------------
%% Tray menu handler
%%--------------------------------------------------------------------
tray_handle({menu, open_dashboard}) ->
    erm_tray:open("http://localhost:8080");
tray_handle({menu, restart}) ->
    application:stop(erm),
    application:start(erm);
tray_handle({menu, quit}) ->
    init:stop();
tray_handle({menu, Other}) ->
    ?LOG_INFO("Unhandled tray menu ~p", [Other]),
    ok.
