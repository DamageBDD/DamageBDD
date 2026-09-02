%%-------------------------------------------------------------------
%% @doc Supervisor for the optional Core Lightning backend.
%%
%% This supervisor is deliberately NOT a direct child of damage_sup.
%% damage_cln starts it asynchronously and traps its exit, making this
%% subtree a fault-containment zone.
%%-------------------------------------------------------------------
-module(damage_cln_sup).
-behaviour(supervisor).

-export([start_link/0, configured_components/0, init/1]).

start_link() ->
    case configured_components() of
        [] ->
            {error, no_cln_components_configured};
        _ ->
            supervisor:start_link({local, ?MODULE}, ?MODULE, [])
    end.

configured_components() ->
    Pool =
        case {damage_cln:core_configured(), cln_pool_config()} of
            {true, {ok, _, _}} -> [cln_pool];
            _ -> []
        end,
    Websocket =
        case damage_cln:websocket_configured() of
            true -> [cln_websocket];
            false -> []
        end,
    Pool ++ Websocket.

init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 5,
        period => 60
    },

    Children = cln_pool_children() ++ l402_children() ++ websocket_children(),
    logger:notice("CLN backend children configured: ~p", [child_ids(Children)]),
    {ok, {SupFlags, Children}}.

cln_pool_children() ->
    case {damage_cln:core_configured(), cln_pool_config()} of
        {true, {ok, SizeArgs, WorkerArgs}} ->
            [
                poolboy:child_spec(
                    cln,
                    [{name, {local, cln}}, {worker_module, cln}] ++ SizeArgs,
                    WorkerArgs
                )
            ];
        {false, _} ->
            logger:warning(
                "CLN worker pool not started; missing config: ~p",
                [damage_cln:missing_core_config()]
            ),
            [];
        {true, {error, Reason}} ->
            logger:warning("CLN worker pool not started: ~p", [Reason]),
            []
    end.

%% L402 consumes the CLN invoice API. Keep it in the same isolated subtree so
%% a CLN-shaped failure in L402 can never consume damage_sup restart intensity.
l402_children() ->
    case {damage_cln:core_configured(), cln_pool_config()} of
        {true, {ok, _, _}} ->
            [
                #{
                    id => damage_l402,
                    start => {damage_l402, start_link, []},
                    restart => permanent,
                    shutdown => 60000,
                    type => worker,
                    modules => [damage_l402]
                }
            ];
        _ ->
            []
    end.

websocket_children() ->
    case damage_cln:websocket_configured() of
        true ->
            [
                #{
                    id => cln_websocket,
                    start => {cln_ws_mgr, start_link, [[ws]]},
                    restart => permanent,
                    shutdown => 60000,
                    type => worker,
                    modules => [cln_ws_mgr]
                }
            ];
        false ->
            logger:warning(
                "CLN websocket not started; missing config/disabled: ~p",
                [damage_cln:missing_websocket_config()]
            ),
            []
    end.

%% Backward compatible with the existing damage `pools` configuration.
%% Optionally, a dedicated setting can be used:
%%   {cln_pool, {[{size, 2}, {max_overflow, 1}], []}}
cln_pool_config() ->
    case application:get_env(damage, cln_pool) of
        {ok, {SizeArgs, WorkerArgs}} when is_list(SizeArgs), is_list(WorkerArgs) ->
            {ok, SizeArgs, WorkerArgs};
        {ok, Other} ->
            {error, {invalid_cln_pool_config, Other}};
        undefined ->
            cln_pool_from_legacy_pools()
    end.

cln_pool_from_legacy_pools() ->
    case application:get_env(damage, pools, []) of
        Pools when is_list(Pools) ->
            case lists:keyfind(cln, 1, Pools) of
                {cln, SizeArgs, WorkerArgs} when is_list(SizeArgs), is_list(WorkerArgs) ->
                    {ok, SizeArgs, WorkerArgs};
                false ->
                    {error, cln_pool_not_configured};
                Other ->
                    {error, {invalid_cln_pool_entry, Other}}
            end;
        Other ->
            {error, {invalid_pools_config, Other}}
    end.

child_ids(Children) ->
    [child_id(C) || C <- Children].

child_id(#{id := Id}) -> Id;
child_id({Id, _, _, _, _, _}) -> Id;
child_id(Other) -> Other.
