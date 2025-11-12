%% ecai_index_snapshot.erl
%% Periodically snapshot the in-memory index to disk, atomically.
-module(ecai_index_snapshot).
-behaviour(gen_server).

-export([
    start_link/2,
    start_link/3,
    stop/0,
    force/0
]).
-export([init/1, handle_info/2, handle_call/3, handle_cast/2, terminate/2, code_change/3]).

-include_lib("kernel/include/logger.hrl").
%% ecai_index_snapshot.erl
-record(state, {ctx_fun, path, interval_ms}).

start_link(CtxFun, Path) -> start_link(CtxFun, Path, 60000).
start_link(CtxFun, Path, IntervalMs) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, {CtxFun, Path, IntervalMs}, []).

init({CtxFun, Path, Interval}) ->
    erlang:send_after(Interval, self(), tick),
    {ok, #state{ctx_fun = CtxFun, path = Path, interval_ms = Interval}}.

handle_info(tick, S = #state{ctx_fun = CtxFun, path = Path, interval_ms = Ms}) ->
    Ctx = CtxFun(),
    ok = atomic_save(Ctx, Path),
    erlang:send_after(Ms, self(), tick),
    {noreply, S}.

stop() -> gen_server:call(?MODULE, stop).
force() -> gen_server:call(?MODULE, force).

handle_call(force, _From, S = #state{ctx_fun = CtxFun, path = Path}) ->
    Ctx = CtxFun(),
    {reply, atomic_save(Ctx, Path), S};
handle_call(stop, _From, S) ->
    {stop, normal, ok, S};
handle_call(_, _, S) ->
    {reply, ok, S}.
handle_cast(_, S) -> {noreply, S}.
terminate(_, _) -> ok.
code_change(_, S, _) -> {ok, S}.

atomic_save(Ctx, Path) ->
    Tmp = Path ++ ".tmp",
    case ecai_search:save(Ctx, Tmp) of
        ok ->
            file:rename(Tmp, Path),
            ok;
        Error ->
            ?LOG_WARNING("index snapshot failed: ~p", [Error]),
            Error
    end.
