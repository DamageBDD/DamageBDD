%% ecai_disk_index_snapshot.erl
%% Periodically export a disk-searchable ECAI index (fixed-width records).
-module(ecai_disk_index_snapshot).
-author("Steven Joseph <steven@damagebdd.com>").

-copyright("Steven Joseph <steven@damagebdd.com>").

-license("Apache-2.0").
-behaviour(gen_server).

-export([start_link/2, start_link/3, stop/0, force/0]).
-export([init/1, handle_info/2, handle_call/3, handle_cast/2, terminate/2, code_change/3]).

-include_lib("kernel/include/logger.hrl").
-import(damage_utils, [ensure_dir/1]).

-record(state, {ctx_fun, path, interval_ms}).

start_link(CtxFun, Path) -> start_link(CtxFun, Path, 600000).
start_link(CtxFun, Path, IntervalMs) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, {CtxFun, Path, IntervalMs}, []).

stop() -> gen_server:call(?MODULE, stop).
force() -> gen_server:call(?MODULE, force, infinity).

init({CtxFun, Path, Interval}) ->
    erlang:send_after(Interval, self(), tick),
    {ok, #state{ctx_fun = CtxFun, path = Path, interval_ms = Interval}}.

handle_info(tick, S = #state{ctx_fun = CtxFun, path = Path, interval_ms = Ms}) ->
    _ = do_export(CtxFun, Path),
    erlang:send_after(Ms, self(), tick),
    {noreply, S}.

handle_call(force, _From, S = #state{ctx_fun = CtxFun, path = Path}) ->
    {reply, do_export(CtxFun, Path), S};
handle_call(stop, _From, S) ->
    {stop, normal, ok, S};
handle_call(_, _, S) ->
    {reply, ok, S}.

handle_cast(_, S) -> {noreply, S}.
terminate(_, _) -> ok.
code_change(_, S, _) -> {ok, S}.

do_export(CtxFun, Path) ->
    Ctx = CtxFun(),
    ensure_dir(filename:dirname(Path)),
    Tmp = Path ++ ".tmp",

    %% **ONE REQUIRED ecai_search API**: export_disk_entries/1
    %% should return: [#{key:=<<33>>,kind:=0,doc_id:=...,off:=...,len:=...}, ...]
    case ecai_search:export_disk_entries(Ctx) of
        {ok, Entries} ->
            case ecai_disk_index:encode(Entries, Tmp, #{fsync => true, sort => true}) of
                ok ->
                    ok = file:rename(Tmp, Path),
                    ?LOG_INFO("disk index exported to ~s (entries=~B)", [Path, length(Entries)]),
                    ok;
                Error ->
                    ?LOG_WARNING("disk index encode failed: ~p", [Error]),
                    Error
            end;
        Error ->
            ?LOG_WARNING("disk index export failed: ~p", [Error]),
            Error
    end.
