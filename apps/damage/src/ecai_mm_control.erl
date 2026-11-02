%%%-------------------------------------------------------------------
%%% Opt-in ECAI paper market maker lifecycle, owned by damage_mm_sup.
%%% No execution adapter, API credentials, balances or private settings are
%%% exposed here. A failing DETS/HTTP worker never crashes the node supervisor.
%%%-------------------------------------------------------------------
-module(ecai_mm_control).
-behaviour(gen_server).

-export([start_link/0, reconcile/0, sync/0, status/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(RECHECK_MS, 15000).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Safe to invoke during bootstrap, before this control worker is started.
reconcile() ->
    case whereis(?MODULE) of
        Pid when is_pid(Pid) -> gen_server:cast(Pid, reconcile);
        _ -> ok
    end.

%% Explicit diagnostic/reconciliation call for operators and EUnit.
sync() -> gen_server:call(?MODULE, reconcile, 30000).

status() ->
    case whereis(?MODULE) of
        Pid when is_pid(Pid) ->
            try gen_server:call(Pid, status, 3000)
            catch _:_ -> public_status(#{last_error => <<"controller_unavailable">>}) end;
        _ ->
            public_status(#{last_error => <<"controller_unavailable">>})
    end.

init([]) ->
    self() ! reconcile,
    erlang:send_after(?RECHECK_MS, self(), tick),
    {ok, #{last_error => null}}.

handle_call(status, _From, S) ->
    {reply, public_status(S), S};
handle_call(reconcile, _From, S) ->
    Updated = refresh(S),
    {reply, public_status(Updated), Updated};
handle_call(_, _From, S) ->
    {reply, {error, bad_call}, S}.

handle_cast(reconcile, S) -> {noreply, refresh(S)};
handle_cast(_, S) -> {noreply, S}.

handle_info(reconcile, S) -> {noreply, refresh(S)};
handle_info(tick, S) ->
    Updated = refresh(S),
    erlang:send_after(?RECHECK_MS, self(), tick),
    {noreply, Updated};
handle_info(_, S) -> {noreply, S}.

terminate(_, _) -> ok.
code_change(_, S, _) -> {ok, S}.

refresh(S) ->
    case ecai_mm_settings:desired() of
        {ok, false, _Cfg} ->
            case stop_child() of
                ok -> S#{last_error => null};
                _ -> S#{last_error => <<"paper_worker_stop_failed">>}
            end;
        {ok, true, Cfg} ->
            case try_ensure_started(Cfg) of
                ok -> S#{last_error => null};
                {error, Why} ->
                    %% Do not leave simulated quotes live under stale policy.
                    _ = stop_child(),
                    S#{last_error => Why}
            end;
        {error, _} ->
            _ = stop_child(),
            S#{last_error => <<"invalid_paper_market_maker_configuration">>}
    end.

try_ensure_started(Cfg) ->
    case child_pid() of
        undefined -> start_child(Cfg);
        _Pid -> apply_config(Cfg)
    end.

start_child(Cfg) ->
    Child = #{
        id => ecai_mm,
        start => {ecai_mm, start_link, [Cfg]},
        %% The controller is responsible for bounded restart attempts. An
        %% unusable DETS path must not trigger a supervisor restart storm.
        restart => temporary,
        shutdown => 30000,
        type => worker,
        modules => [ecai_mm]
    },
    try supervisor:start_child(damage_mm_sup, Child) of
        {ok, Pid} when is_pid(Pid) -> ok;
        {ok, Pid, _Info} when is_pid(Pid) -> ok;
        {error, {already_started, _}} -> {error, <<"paper_worker_already_running_elsewhere">>};
        {error, already_present} -> {error, <<"paper_child_already_present">>};
        _ -> {error, <<"paper_worker_start_failed">>}
    catch
        _:_ -> {error, <<"market_maker_supervisor_unavailable">>}
    end.

apply_config(Cfg) ->
    try
        Public = ecai_mm:config(),
        Current = maps:get(values, Public),
        Desired = ecai_mm_config:public(Cfg),
        Changes = maps:filter(
            fun(Key, Value) -> maps:get(Key, Current, '$missing') =/= Value end,
            Desired
        ),
        case map_size(Changes) of
            0 -> ok;
            _ ->
                case ecai_mm:configure(Changes, maps:get(revision, Public)) of
                    {ok, _Updated} -> ok;
                    _ -> {error, <<"paper_configuration_update_failed">>}
                end
        end
    catch
        _:_ -> {error, <<"paper_configuration_update_failed">>}
    end.

stop_child() ->
    case child_entry() of
        false -> ok;
        _ ->
            try
                case supervisor:terminate_child(damage_mm_sup, ecai_mm) of
                    ok -> ok;
                    {error, not_found} -> ok
                end,
                %% A temporary child may already have been removed by OTP.
                case supervisor:delete_child(damage_mm_sup, ecai_mm) of
                    ok -> ok;
                    {error, not_found} -> ok
                end
            catch _:_ -> {error, child_stop_failed} end
    end.

child_pid() ->
    case child_entry() of
        {ecai_mm, Pid, worker, _} when is_pid(Pid) -> Pid;
        _ -> undefined
    end.

child_entry() ->
    try lists:keyfind(ecai_mm, 1, supervisor:which_children(damage_mm_sup))
    catch _:_ -> false end.

public_status(S) ->
    Enabled = application:get_env(ecai, market_maker_enabled, false) =:= true,
    Running = is_pid(child_pid()),
    Error = maps:get(last_error, S, null),
    State =
        case {Enabled, Running, Error} of
            {false, true, _} -> <<"error">>;
            {false, false, _} -> <<"disabled">>;
            {true, true, null} -> <<"running">>;
            {true, _, null} -> <<"starting">>;
            {true, _, _} -> <<"error">>
        end,
    #{enabled => Enabled, running => Running, state => State,
      mode => <<"paper">>, execution_enabled => false, error => Error}.
