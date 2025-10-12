%%--------------------------------------------------------------------
%% damage_mm_sup.erl
%%--------------------------------------------------------------------
-module(damage_mm_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).
-export([add/2, del/1, where/1, list/0, reconcile_from_env/0]).

-include_lib("gproc/include/gproc.hrl").

%% API
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    %% one_for_one: each damage_mm is independent
    {ok, {{one_for_one, 10, 10}, []}}.

%% Add a market-maker if not running
add(Symbol, Rules) when is_list(Symbol), is_list(Rules) ->
    case gproc:whereis_name({n, l, {damage_mm, Symbol}}) of
        undefined ->
            ChildSpec = child_spec(Symbol, Rules),
            supervisor:start_child(?MODULE, ChildSpec);
        Pid when is_pid(Pid) ->
            {ok, Pid}
    end.

%% Remove a market-maker if running
del(Symbol) when is_list(Symbol) ->
    Id = {damage_mm, Symbol},
    case supervisor:terminate_child(?MODULE, Id) of
        ok ->
            _ = supervisor:delete_child(?MODULE, Id),
            ok;
        {error, not_found} ->
            ok
    end.

%% Lookup a running MM pid by symbol
where(Symbol) when is_list(Symbol) ->
    gproc:whereis_name({n, l, {damage_mm, Symbol}}).

%% List currently supervised MMs (as {Symbol,Pid})
list() ->
    Children = supervisor:which_children(?MODULE),
    [
        case C of
            {{damage_mm, Sym}, Pid, worker, _Mods} -> {Sym, Pid};
            _ -> C
        end
     || C <- Children
    ].

%% Optional: reconcile with current app env (sys.config / set_env)
%% - Starts missing, stops extra
reconcile_from_env() ->
    Target =
        case application:get_env(damage, market_rules) of
            %% [{"SYM", [{price_precision,4},{min_qty,100.0}]}]
            {ok, L} when is_list(L) -> L;
            _ -> []
        end,
    TargetSyms = [S || {S, _} <- Target],
    Running = [Sym || {Sym, _Pid} <- list()],
    %% Start missing
    _Started = [
        begin
            Rules = proplists:get_value(Sym, Target, []),
            add(Sym, Rules)
        end
     || Sym <- TargetSyms,
        not lists:member(Sym, Running)
    ],
    %% Stop extras
    _Stopped = [
        del(Sym)
     || Sym <- Running,
        not lists:member(Sym, TargetSyms)
    ],
    ok.

%% ---- helpers ----
child_spec(Symbol, Rules) ->
    #{
        id => {damage_mm, Symbol},
        start => {damage_mm, start_link, [[{symbol, Symbol}, {rules, Rules}]]},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [damage_mm]
    }.
