%%%-------------------------------------------------------------------
%%% playlist.erl — simple playlist manager (gen_server)
%%%-------------------------------------------------------------------
%%% API used by erm_mpv:
%%% start_link/0
%%% all/0 -> [{Idx, #track{}}]
%%% get_by_index/1 -> {ok, #track{}} | error
%%% set_current/1
%%% current/0 -> {ok, #track{}} | error
%%% prev/0 | next/0
%%% toggle_like_current/0
%%% clear/0
%%% update_cid/2
%%% rescan_all/0
%%% add_files/1 | add_files/2
%%%-------------------------------------------------------------------
-module(playlist).
-behaviour(gen_server).
-include("erm_playlist.hrl").
-include_lib("kernel/include/logger.hrl").

-export([start_link/0]).
-export([
    all/0,
    get_by_index/1,
    set_current/1,
    current/0,
    prev/0,
    next/0,
    toggle_like_current/0,
    clear/0,
    update_cid/2,
    rescan_all/0,
    add_files/1, add_files/2
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(TAB, ?MODULE).

-record(st, {
    order = [] :: [integer()],
    cur = undefined :: undefined | integer(),
    src_dirs = [] :: [file:filename_all()]
}).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% ——— Public API ———
all() -> gen_server:call(?MODULE, all).
get_by_index(I) when is_integer(I) -> gen_server:call(?MODULE, {get_by_index, I}).
set_current(Id) -> gen_server:cast(?MODULE, {set_current, Id}).
current() -> gen_server:call(?MODULE, current).
prev() -> gen_server:call(?MODULE, prev).
next() -> gen_server:call(?MODULE, next).
toggle_like_current() -> gen_server:call(?MODULE, toggle_like_current).
clear() -> gen_server:call(?MODULE, clear).
update_cid(Id, Cid) -> gen_server:cast(?MODULE, {update_cid, Id, Cid}).
rescan_all() -> gen_server:cast(?MODULE, rescan_all).
add_files(Paths) when is_list(Paths) -> gen_server:cast(?MODULE, {add_files, Paths}).
add_files(Dir, Recurse) when is_list(Dir) ->
    Files = media_scan:collect_files(Dir, Recurse),
    add_files(Files).
step(_, _, _) ->
    ok.

%% ——— gen_server ———
init([]) ->
    ets:new(?TAB, [named_table, ordered_set, public, {keypos, #track.id}]),
    {ok, #st{}}.

handle_call(all, _From, S = #st{order = Order}) ->
    Tracks = [
        {Idx, ets:lookup_element(?TAB, Id, 2)}
     || {Idx, Id} <- lists:zip(lists:seq(0, length(Order) - 1), Order)
    ],
    {reply, Tracks, S};
handle_call({get_by_index, I}, _From, S = #st{order = Order}) ->
    case lists:nthtail(I, Order) of
        [Id | _] -> {reply, {ok, ets:lookup_element(?TAB, Id, 2)}, S};
        _ -> {reply, error, S}
    end;
handle_call(current, _From, S = #st{cur = undefined}) ->
    {reply, error, S};
handle_call(current, _From, S = #st{cur = Id}) ->
    {reply, {ok, ets:lookup_element(?TAB, Id, 2)}, S};
handle_call(prev, _From, S = #st{order = Order, cur = Cur}) ->
    NewId = step(-1, Cur, Order),
    {reply, ok, S#st{cur = NewId}};
handle_call(next, _From, S = #st{order = Order, cur = Cur}) ->
    NewId = step(+1, Cur, Order),
    {reply, ok, S#st{cur = NewId}};
handle_call(toggle_like_current, _From, S = #st{cur = undefined}) ->
    {reply, ok, S};
handle_call(toggle_like_current, _From, S = #st{cur = Id}) ->
    [T0] = ets:lookup(?TAB, Id),
    T = T0#track{liked = not T0#track.liked},
    ets:insert(?TAB, T),
    {reply, ok, S};
handle_call(clear, _From, S) ->
    {reply, ok, S}.
handle_cast(_Msg, S) -> {noreply, S}.
handle_info(_Msg, S) ->
    {noreply, S}.

terminate(_Reason, _S) -> ok.
code_change(_V, S, _Extra) -> {ok, S}.
