%%%-------------------------------------------------------------------
%%% playlist.erl — simple playlist manager (gen_server)
%%%-------------------------------------------------------------------
%%% Owns the ERM media playlist order and metadata.
%%%
%%% Default media dirs are read from:
%%%   1. application env: {erm, media_dirs}
%%%   2. ERM_MEDIA_DIRS=/path/one:/path/two
%%%   3. ~/Music, ~/Videos, ~/Downloads
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
    shuffle/0,
    load_default/0,
    load_default/1,
    default_media_dirs/0,
    toggle_like_current/0,
    clear/0,
    update_cid/2,
    rescan_all/0,
    add_files/1,
    add_files/2
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

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% ——— Public API ———
all() -> gen_server:call(?MODULE, all).
get_by_index(I) when is_integer(I), I >= 0 -> gen_server:call(?MODULE, {get_by_index, I});
get_by_index(_) -> error.
set_current(Id) -> gen_server:call(?MODULE, {set_current, Id}).
current() -> gen_server:call(?MODULE, current).
prev() -> gen_server:call(?MODULE, prev).
next() -> gen_server:call(?MODULE, next).
shuffle() -> gen_server:call(?MODULE, shuffle).
load_default() -> load_default(shuffle).
load_default(Mode) -> gen_server:call(?MODULE, {load_default, Mode}, infinity).
default_media_dirs() -> default_dirs().
toggle_like_current() -> gen_server:call(?MODULE, toggle_like_current).
clear() -> gen_server:call(?MODULE, clear).
update_cid(Id, Cid) -> gen_server:call(?MODULE, {update_cid, Id, Cid}).
rescan_all() -> gen_server:call(?MODULE, rescan_all, infinity).
add_files(Paths) -> gen_server:call(?MODULE, {add_files, Paths}, infinity).
add_files(Dir, Recurse) -> gen_server:call(?MODULE, {add_dir, Dir, Recurse}, infinity).

%% ——— gen_server ———
init([]) ->
    _ = ensure_table(),
    {ok, #st{}}.

handle_call(all, _From, S = #st{order = Order}) ->
    Tracks = indexed_tracks(Order),
    {reply, Tracks, S};
handle_call({get_by_index, I}, _From, S = #st{order = Order}) ->
    case nth_id(I, Order) of
        {ok, Id} -> {reply, lookup_track(Id), S};
        error -> {reply, error, S}
    end;
handle_call({set_current, Id}, _From, S) ->
    case lookup_track(Id) of
        {ok, _T} -> {reply, ok, S#st{cur = Id}};
        error -> {reply, error, S}
    end;
handle_call(current, _From, S = #st{cur = undefined}) ->
    {reply, error, S};
handle_call(current, _From, S = #st{cur = Id}) ->
    {reply, lookup_track(Id), S};
handle_call(prev, _From, S = #st{order = Order, cur = Cur}) ->
    reply_step(-1, Cur, Order, S);
handle_call(next, _From, S = #st{order = Order, cur = Cur}) ->
    reply_step(1, Cur, Order, S);
handle_call(shuffle, _From, S = #st{order = Order}) ->
    Order1 = shuffle_list(Order),
    Cur1 = first_or_undefined(Order1),
    {reply, ok, S#st{order = Order1, cur = Cur1}};
handle_call({load_default, Mode}, _From, S) ->
    Dirs = default_dirs(),
    Files = collect_dirs(Dirs, true),
    {Count, S1} = rebuild(Files, Dirs, Mode, S),
    ?LOG_INFO("Loaded default ERM media playlist: ~p tracks from ~p", [Count, Dirs]),
    {reply, {ok, Count}, S1};
handle_call(toggle_like_current, _From, S = #st{cur = undefined}) ->
    {reply, ok, S};
handle_call(toggle_like_current, _From, S = #st{cur = Id}) ->
    case ets:lookup(?TAB, Id) of
        [T0] ->
            T = T0#track{liked = not T0#track.liked},
            ets:insert(?TAB, T),
            {reply, ok, S};
        [] ->
            {reply, error, S#st{cur = undefined}}
    end;
handle_call(clear, _From, S) ->
    ets:delete_all_objects(?TAB),
    {reply, ok, S#st{order = [], cur = undefined}};
handle_call({update_cid, Id, Cid}, _From, S) ->
    case ets:lookup(?TAB, Id) of
        [T0] ->
            ets:insert(?TAB, T0#track{cid = Cid}),
            {reply, ok, S};
        [] ->
            {reply, error, S}
    end;
handle_call(rescan_all, _From, S = #st{src_dirs = []}) ->
    Dirs = default_dirs(),
    Files = collect_dirs(Dirs, true),
    {Count, S1} = rebuild(Files, Dirs, keep_order, S),
    {reply, {ok, Count}, S1};
handle_call(rescan_all, _From, S = #st{src_dirs = Dirs}) ->
    Files = collect_dirs(Dirs, true),
    {Count, S1} = rebuild(Files, Dirs, keep_order, S),
    {reply, {ok, Count}, S1};
handle_call({add_files, Paths0}, _From, S) ->
    Paths = normalize_paths(Paths0),
    {Count, S1} = add_paths(Paths, S),
    {reply, {ok, Count}, S1};
handle_call({add_dir, Dir0, Recurse}, _From, S = #st{src_dirs = Dirs0}) ->
    Dir = normalize_path(Dir0),
    Files = collect_dir(Dir, Recurse),
    {Count, S1} = add_paths(Files, S),
    Dirs1 = uniq_keep_order(Dirs0 ++ [Dir]),
    {reply, {ok, Count}, S1#st{src_dirs = Dirs1}};
handle_call(_Req, _From, S) ->
    {reply, error, S}.

handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info(_Msg, S) ->
    {noreply, S}.

terminate(_Reason, _S) -> ok.
code_change(_V, S, _Extra) -> {ok, S}.

%% ——— Internal helpers ———
ensure_table() ->
    case ets:info(?TAB) of
        undefined -> ets:new(?TAB, [named_table, ordered_set, public, {keypos, #track.id}]);
        _ -> ?TAB
    end.

indexed_tracks(Order) ->
    indexed_tracks(Order, 0, []).

indexed_tracks([], _Idx, Acc) ->
    lists:reverse(Acc);
indexed_tracks([Id | Rest], Idx, Acc) ->
    case lookup_track(Id) of
        {ok, T} -> indexed_tracks(Rest, Idx + 1, [{Idx, T} | Acc]);
        error -> indexed_tracks(Rest, Idx, Acc)
    end.

nth_id(I, Order) ->
    case catch lists:nth(I + 1, Order) of
        Id when is_integer(Id) -> {ok, Id};
        _ -> error
    end.

lookup_track(Id) ->
    case ets:lookup(?TAB, Id) of
        [T = #track{}] -> {ok, T};
        [] -> error
    end.

reply_step(_Delta, _Cur, [], S) ->
    {reply, error, S#st{cur = undefined}};
reply_step(Delta, Cur, Order, S) ->
    NewId = step(Delta, Cur, Order),
    case lookup_track(NewId) of
        {ok, T} -> {reply, {ok, T}, S#st{cur = NewId}};
        error -> {reply, error, S#st{cur = undefined}}
    end.

step(_Delta, undefined, [Id | _]) ->
    Id;
step(Delta, Cur, Order) ->
    Len = length(Order),
    case index_of(Cur, Order, 0) of
        not_found -> hd(Order);
        Pos -> lists:nth(((Pos + Delta + Len) rem Len) + 1, Order)
    end.

index_of(_Needle, [], _Idx) -> not_found;
index_of(Needle, [Needle | _], Idx) -> Idx;
index_of(Needle, [_ | Rest], Idx) -> index_of(Needle, Rest, Idx + 1).

first_or_undefined([]) -> undefined;
first_or_undefined([Id | _]) -> Id.

add_paths(Paths0, S = #st{order = Order0, cur = Cur0}) ->
    Paths = [P || P <- uniq_keep_order([normalize_path(P0) || P0 <- Paths0]), is_media_file(P)],
    ExistingByPath = tracks_by_path(),
    Ids = [insert_or_keep_track(P, ExistingByPath) || P <- Paths],
    Order1 = uniq_keep_order(Order0 ++ Ids),
    Cur1 =
        case Cur0 of
            undefined -> first_or_undefined(Order1);
            _ -> Cur0
        end,
    {length(Ids), S#st{order = Order1, cur = Cur1}}.

rebuild(Files0, Dirs, Mode, S) ->
    Files = [P || P <- uniq_keep_order([normalize_path(P0) || P0 <- Files0]), is_media_file(P)],
    ExistingByPath = tracks_by_path(),
    ets:delete_all_objects(?TAB),
    Ids0 = [insert_or_keep_track(P, ExistingByPath) || P <- Files],
    Ids =
        case Mode of
            shuffle -> shuffle_list(Ids0);
            random -> shuffle_list(Ids0);
            keep_order -> Ids0;
            _ -> Ids0
        end,
    Cur = first_or_undefined(Ids),
    {length(Ids), S#st{order = Ids, cur = Cur, src_dirs = Dirs}}.

insert_or_keep_track(Path, ExistingByPath) ->
    Id = stable_id(Path),
    T =
        case maps:get(Path, ExistingByPath, undefined) of
            Old = #track{} -> Old#track{id = Id, path = Path};
            undefined -> #track{id = Id, path = Path, cid = undefined, liked = false}
        end,
    ets:insert(?TAB, T),
    Id.

tracks_by_path() ->
    maps:from_list([{T#track.path, T} || T = #track{} <- ets:tab2list(?TAB)]).

stable_id(Path) ->
    erlang:phash2(Path, 16#7fffffff).

shuffle_list([]) ->
    [];
shuffle_list(List) ->
    seed_rand(),
    [X || {_, X} <- lists:sort([{rand:uniform(), X} || X <- List])].

seed_rand() ->
    rand:seed(
        exsplus,
        {
            erlang:phash2(erlang:monotonic_time()),
            erlang:unique_integer([positive]),
            erlang:phash2({node(), self()})
        }
    ).

collect_dirs(Dirs, Recurse) ->
    lists:append([collect_dir(D, Recurse) || D <- Dirs]).

collect_dir(Dir0, Recurse) ->
    Dir = normalize_path(Dir0),
    case filelib:is_dir(Dir) of
        true -> collect_dir_1(Dir, Recurse);
        false -> []
    end.

collect_dir_1(Dir, Recurse) ->
    case file:list_dir(Dir) of
        {ok, Names} ->
            Paths = [filename:join(Dir, Name) || Name <- Names],
            Files = [P || P <- Paths, filelib:is_file(P), is_media_file(P)],
            Dirs = [P || P <- Paths, Recurse =:= true, filelib:is_dir(P)],
            Files ++ lists:append([collect_dir_1(D, true) || D <- Dirs]);
        {error, Reason} ->
            ?LOG_DEBUG("Skipping media dir ~p: ~p", [Dir, Reason]),
            []
    end.

is_media_file(Path0) ->
    Path = normalize_path(Path0),
    Ext = string:lowercase(filename:extension(Path)),
    lists:member(Ext, media_exts()).

media_exts() ->
    [
        ".mp3",
        ".flac",
        ".wav",
        ".ogg",
        ".oga",
        ".opus",
        ".m4a",
        ".aac",
        ".alac",
        ".mp4",
        ".m4v",
        ".mkv",
        ".webm",
        ".avi",
        ".mov",
        ".wmv",
        ".flv",
        ".3gp"
    ].

default_dirs() ->
    case application:get_env(erm, media_dirs) of
        {ok, Dirs} -> normalize_dirs(Dirs);
        undefined -> default_dirs_from_env()
    end.

default_dirs_from_env() ->
    case os:getenv("ERM_MEDIA_DIRS") of
        false -> fallback_home_dirs();
        "" -> fallback_home_dirs();
        Env -> normalize_dirs(string:tokens(Env, ":,"))
    end.

fallback_home_dirs() ->
    Home =
        case os:getenv("HOME") of
            false -> ".";
            H -> H
        end,
    normalize_dirs([
        filename:join(Home, "Music"),
        filename:join(Home, "Videos"),
        filename:join(Home, "Downloads")
    ]).

normalize_dirs(Bin) when is_binary(Bin) ->
    [normalize_path(Bin)];
normalize_dirs([]) ->
    [];
normalize_dirs([H | _] = Dir) when is_integer(H) ->
    [normalize_path(Dir)];
normalize_dirs(Dirs) when is_list(Dirs) ->
    uniq_keep_order([normalize_path(D) || D <- Dirs]);
normalize_dirs(Dir) ->
    [normalize_path(Dir)].

normalize_paths(Bin) when is_binary(Bin) ->
    [normalize_path(Bin)];
normalize_paths([]) ->
    [];
normalize_paths([H | _] = Path) when is_integer(H) ->
    [normalize_path(Path)];
normalize_paths(Paths) when is_list(Paths) ->
    [normalize_path(P) || P <- Paths].

normalize_path(Bin) when is_binary(Bin) ->
    filename:absname(binary_to_list(Bin));
normalize_path(Path) when is_list(Path) ->
    filename:absname(Path).

uniq_keep_order(List) ->
    {_Seen, Out} = lists:foldl(
        fun(Item, {Seen, Acc}) ->
            case maps:is_key(Item, Seen) of
                true -> {Seen, Acc};
                false -> {Seen#{Item => true}, [Item | Acc]}
            end
        end,
        {#{}, []},
        List
    ),
    lists:reverse(Out).
