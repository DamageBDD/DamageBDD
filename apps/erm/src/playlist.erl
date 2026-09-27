%%%-------------------------------------------------------------------
%%% playlist.erl — persistent ERM playlist manager
%%%-------------------------------------------------------------------
%%% Owns playlist order, current/previous position and media metadata.
%%%
%%% Important lifecycle property:
%%%   Playlist state is persisted independently of the playlist gen_server so
%%%   restarting the ERM OTP application does not reset queue order or current
%%%   position while the detached MPV process continues playing.
%%%
%%% Random selection APIs do not mutate queue position. Queue-reordering APIs
%%% preserve the current item and only reorder the unplayed tail, preventing a
%%% live playback session from being logically rewound.
%%%-------------------------------------------------------------------
-module(playlist).
-behaviour(gen_server).

-include("erm_playlist.hrl").
-include_lib("kernel/include/file.hrl").
-include_lib("kernel/include/logger.hrl").

-export([start_link/0]).
-export([
    all/0,
    progression/0,
    position/0,
    previous/0,
    get_by_index/1,
    set_current/1,
    sync_current_path/1,
    sync_from_paths/2,
    current/0,
    peek_prev/0,
    peek_next/0,
    prev/0,
    next/0,
    shuffle/0,
    shuffle_by/1,
    random/0,
    random_by/1,
    random_by_album/0,
    random_by_artist/0,
    random_by_genre/0,
    random_latest/0,
    random_by_directory/0,
    load_default/0,
    load_default/1,
    default_media_dirs/0,
    toggle_like_current/0,
    clear/0,
    update_cid/2,
    rescan_all/0,
    add_files/1,
    add_files/2,
    state_file/0
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
-define(STATE_VERSION, 2).
-define(DEFAULT_LATEST_WINDOW, 100).

-record(st, {
    order = [] :: [integer()],
    cur = undefined :: undefined | integer(),
    previous = undefined :: undefined | integer(),
    src_dirs = [] :: [file:filename_all()],
    mode = keep_order :: term(),
    state_file = undefined :: undefined | file:filename_all()
}).

%%%===================================================================
%%% Public API
%%%===================================================================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

all() -> gen_server:call(?MODULE, all).
progression() -> gen_server:call(?MODULE, progression).
position() -> gen_server:call(?MODULE, position).
previous() -> gen_server:call(?MODULE, previous).
get_by_index(I) when is_integer(I), I >= 0 -> gen_server:call(?MODULE, {get_by_index, I});
get_by_index(_) -> error.
set_current(Id) -> gen_server:call(?MODULE, {set_current, Id}).
sync_current_path(Path) -> gen_server:call(?MODULE, {sync_current_path, Path}).
sync_from_paths(Paths, CurrentPath) ->
    gen_server:call(?MODULE, {sync_from_paths, Paths, CurrentPath}, infinity).
current() -> gen_server:call(?MODULE, current).
peek_prev() -> gen_server:call(?MODULE, peek_prev).
peek_next() -> gen_server:call(?MODULE, peek_next).
prev() -> gen_server:call(?MODULE, prev).
next() -> gen_server:call(?MODULE, next).
shuffle() -> gen_server:call(?MODULE, shuffle).
shuffle_by(Key) -> gen_server:call(?MODULE, {shuffle_by, normalize_random_key(Key)}).
random() -> random_by(track).
random_by(Key) -> gen_server:call(?MODULE, {random_by, normalize_random_key(Key)}).
random_by_album() -> random_by(album).
random_by_artist() -> random_by(artist).
random_by_genre() -> random_by(genre).
random_latest() -> random_by(latest).
random_by_directory() -> random_by(directory).
load_default() -> load_default(shuffle).
load_default(Mode) -> gen_server:call(?MODULE, {load_default, normalize_load_mode(Mode)}, infinity).
default_media_dirs() -> default_dirs().
toggle_like_current() -> gen_server:call(?MODULE, toggle_like_current).
clear() -> gen_server:call(?MODULE, clear).
update_cid(Id, Cid) -> gen_server:call(?MODULE, {update_cid, Id, Cid}).
rescan_all() -> gen_server:call(?MODULE, rescan_all, infinity).
add_files(Paths) -> gen_server:call(?MODULE, {add_files, Paths}, infinity).
add_files(Dir, Recurse) -> gen_server:call(?MODULE, {add_dir, Dir, Recurse}, infinity).

state_file() ->
    case application:get_env(erm, playlist_state_file) of
        {ok, Value} -> normalize_path(Value);
        undefined -> filename:join([state_home(), "erm", "playlist.term"])
    end.

%%%===================================================================
%%% gen_server
%%%===================================================================

init([]) ->
    _ = ensure_table(),
    seed_rand(),
    StateFile = state_file(),
    S0 = #st{state_file = StateFile},
    case restore_state(StateFile, S0) of
        {ok, S1} ->
            ?LOG_INFO(
                "Restored ERM playlist state tracks=~p current=~p previous=~p file=~s",
                [length(S1#st.order), S1#st.cur, S1#st.previous, StateFile]
            ),
            {ok, S1};
        {error, enoent} ->
            {ok, S0};
        {error, Reason} ->
            ?LOG_WARNING("Could not restore ERM playlist state ~s: ~p", [StateFile, Reason]),
            {ok, S0}
    end.

handle_call(all, _From, S = #st{order = Order}) ->
    {reply, indexed_tracks(Order), S};
handle_call(progression, _From, S = #st{order = Order, cur = Cur}) ->
    %% Resume from the saved current item and continue only through the
    %% unplayed tail. The already-played prefix remains available to prev/0
    %% but is not replayed after a backend restart.
    {reply, tracks_for_order(progression_from_current(Order, Cur)), S};
handle_call(position, _From, S = #st{order = Order, cur = Cur}) ->
    Reply =
        case index_of(Cur, Order, 0) of
            not_found -> error;
            Index -> {ok, Index}
        end,
    {reply, Reply, S};
handle_call(previous, _From, S = #st{previous = undefined}) ->
    {reply, error, S};
handle_call(previous, _From, S = #st{previous = Id}) ->
    {reply, lookup_track(Id), S};
handle_call({get_by_index, I}, _From, S = #st{order = Order}) ->
    case nth_id(I, Order) of
        {ok, Id} -> {reply, lookup_track(Id), S};
        error -> {reply, error, S}
    end;
handle_call({set_current, Id}, _From, S) ->
    case lookup_track(Id) of
        {ok, _T} ->
            S1 = persist(set_current_id(Id, S)),
            {reply, ok, S1};
        error ->
            {reply, error, S}
    end;
handle_call({sync_current_path, Path0}, _From, S) ->
    Path = normalize_path(Path0),
    case find_track_by_path(Path) of
        {ok, T = #track{id = Id}} ->
            S1 =
                case S#st.cur =:= Id of
                    true -> S;
                    false -> persist(set_current_id(Id, S))
                end,
            {reply, {ok, T}, S1};
        error ->
            {reply, {error, {track_not_in_playlist, Path}}, S}
    end;
handle_call({sync_from_paths, Paths0, CurrentPath0}, _From, S) ->
    Paths = uniq_keep_order([normalize_path(P) || P <- normalize_paths(Paths0)]),
    ExistingByPath = tracks_by_path(),
    ets:delete_all_objects(?TAB),
    Ids = [insert_or_keep_track(P, ExistingByPath) || P <- Paths, is_media_ref(P)],
    CurrentId = current_id_for_path(CurrentPath0, Ids),
    S1 = persist(S#st{
        order = Ids,
        previous = preserve_id_or_undefined(S#st.previous, Ids),
        cur = CurrentId,
        mode = mpv_live
    }),
    {reply, {ok, length(Ids)}, S1};
handle_call(current, _From, S = #st{cur = undefined}) ->
    {reply, error, S};
handle_call(current, _From, S = #st{cur = Id}) ->
    {reply, lookup_track(Id), S};
handle_call(peek_prev, _From, S = #st{order = Order, cur = Cur}) ->
    {reply, peek_step(-1, Cur, Order), S};
handle_call(peek_next, _From, S = #st{order = Order, cur = Cur}) ->
    {reply, peek_step(1, Cur, Order), S};
handle_call(prev, _From, S = #st{order = Order, cur = Cur}) ->
    reply_step(-1, Cur, Order, S);
handle_call(next, _From, S = #st{order = Order, cur = Cur}) ->
    reply_step(1, Cur, Order, S);
handle_call(shuffle, _From, S = #st{order = Order, cur = Cur}) ->
    Order1 = reorder_future(track, Order, Cur),
    S1 = persist(S#st{order = Order1, mode = shuffle}),
    {reply, ok, S1};
handle_call({shuffle_by, Key}, _From, S = #st{order = Order, cur = Cur}) ->
    case valid_random_key(Key) of
        true ->
            Order1 = reorder_future(Key, Order, Cur),
            S1 = persist(S#st{order = Order1, mode = {shuffle_by, Key}}),
            {reply, ok, S1};
        false ->
            {reply, {error, {bad_random_key, Key}}, S}
    end;
handle_call({random_by, Key}, _From, S = #st{order = Order}) ->
    Tracks = tracks_for_order(Order),
    {reply, random_track_by(Key, Tracks), S};
handle_call({load_default, Mode}, _From, S) ->
    Dirs = default_dirs(),
    Files = collect_dirs(Dirs, true),
    {Count, S1} = rebuild(Files, Dirs, Mode, S),
    S2 = persist(S1),
    ?LOG_INFO(
        "Loaded default ERM media playlist mode=~p tracks=~p current=~p from=~p",
        [Mode, Count, S2#st.cur, Dirs]
    ),
    {reply, {ok, Count}, S2};
handle_call(toggle_like_current, _From, S = #st{cur = undefined}) ->
    {reply, ok, S};
handle_call(toggle_like_current, _From, S = #st{cur = Id}) ->
    case ets:lookup(?TAB, Id) of
        [T0] ->
            T = T0#track{liked = not T0#track.liked},
            ets:insert(?TAB, T),
            {reply, ok, persist(S)};
        [] ->
            {reply, error, persist(S#st{cur = undefined})}
    end;
handle_call(clear, _From, S) ->
    ets:delete_all_objects(?TAB),
    S1 = persist(S#st{order = [], cur = undefined, previous = undefined}),
    {reply, ok, S1};
handle_call({update_cid, Id, Cid}, _From, S) ->
    case ets:lookup(?TAB, Id) of
        [T0] ->
            ets:insert(?TAB, T0#track{cid = Cid}),
            {reply, ok, persist(S)};
        [] ->
            {reply, error, S}
    end;
handle_call(rescan_all, _From, S = #st{src_dirs = []}) ->
    Dirs = default_dirs(),
    Files = collect_dirs(Dirs, true),
    {Count, S1} = rebuild(Files, Dirs, keep_order, S),
    {reply, {ok, Count}, persist(S1)};
handle_call(rescan_all, _From, S = #st{src_dirs = Dirs}) ->
    Files = collect_dirs(Dirs, true),
    {Count, S1} = rebuild(Files, Dirs, keep_order, S),
    {reply, {ok, Count}, persist(S1)};
handle_call({add_files, Paths0}, _From, S) ->
    Paths = normalize_paths(Paths0),
    {Count, S1} = add_paths(Paths, S),
    {reply, {ok, Count}, persist(S1)};
handle_call({add_dir, Dir0, Recurse}, _From, S = #st{src_dirs = Dirs0}) ->
    Dir = normalize_path(Dir0),
    Files = collect_dir(Dir, Recurse),
    {Count, S1} = add_paths(Files, S),
    Dirs1 = uniq_keep_order(Dirs0 ++ [Dir]),
    {reply, {ok, Count}, persist(S1#st{src_dirs = Dirs1})};
handle_call(_Req, _From, S) ->
    {reply, error, S}.

handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info(_Msg, S) ->
    {noreply, S}.

terminate(_Reason, S) ->
    _ = save_state(S),
    ok.

code_change(_V, S, _Extra) ->
    {ok, S}.

%%%===================================================================
%%% Position/progression helpers
%%%===================================================================

set_current_id(Id, S = #st{cur = Id}) ->
    S;
set_current_id(Id, S = #st{cur = Cur}) ->
    S#st{previous = Cur, cur = Id}.

peek_step(_Delta, _Cur, []) ->
    error;
peek_step(Delta, Cur, Order) ->
    lookup_track(step(Delta, Cur, Order)).

reply_step(_Delta, _Cur, [], S) ->
    S1 = persist(S#st{previous = S#st.cur, cur = undefined}),
    {reply, error, S1};
reply_step(Delta, Cur, Order, S) ->
    NewId = step(Delta, Cur, Order),
    case lookup_track(NewId) of
        {ok, T} ->
            S1 = persist(set_current_id(NewId, S)),
            {reply, {ok, T}, S1};
        error ->
            {reply, error, S}
    end.

step(_Delta, undefined, [Id | _]) ->
    Id;
step(Delta, Cur, Order) ->
    Len = length(Order),
    case index_of(Cur, Order, 0) of
        not_found -> hd(Order);
        Pos -> lists:nth(((Pos + Delta + Len) rem Len) + 1, Order)
    end.

progression_from_current([], _Cur) ->
    [];
progression_from_current(Order, undefined) ->
    Order;
progression_from_current(Order, Cur) ->
    case split_at_current(Order, Cur) of
        {_Prefix, []} -> Order;
        {_Prefix, [Cur | Tail]} -> [Cur | Tail]
    end.

split_at_current(Order, Cur) ->
    split_at_current(Order, Cur, []).

split_at_current([], _Cur, PrefixRev) ->
    {lists:reverse(PrefixRev), []};
split_at_current([Cur | Rest], Cur, PrefixRev) ->
    {lists:reverse(PrefixRev), [Cur | Rest]};
split_at_current([Id | Rest], Cur, PrefixRev) ->
    split_at_current(Rest, Cur, [Id | PrefixRev]).

index_of(undefined, _List, _Idx) -> not_found;
index_of(_Needle, [], _Idx) -> not_found;
index_of(Needle, [Needle | _], Idx) -> Idx;
index_of(Needle, [_ | Rest], Idx) -> index_of(Needle, Rest, Idx + 1).

nth_id(I, Order) ->
    case catch lists:nth(I + 1, Order) of
        Id when is_integer(Id) -> {ok, Id};
        _ -> error
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

tracks_for_order(Order) ->
    [T || Id <- Order, {ok, T} <- [lookup_track(Id)]].

%%%===================================================================
%%% Random selection and queue ordering
%%%===================================================================

normalize_random_key(genere) -> genre;
normalize_random_key(Key) -> Key.

valid_random_key(track) -> true;
valid_random_key(random) -> true;
valid_random_key(album) -> true;
valid_random_key(artist) -> true;
valid_random_key(genre) -> true;
valid_random_key(directory) -> true;
valid_random_key(latest) -> true;
valid_random_key(_) -> false.

random_track_by(_Key, []) ->
    error;
random_track_by(Key0, Tracks) ->
    Key = normalize_random_key(Key0),
    case Key of
        track -> random_track(Tracks);
        random -> random_track(Tracks);
        latest -> random_latest_track(Tracks);
        album -> random_group_track(album, Tracks);
        artist -> random_group_track(artist, Tracks);
        genre -> random_group_track(genre, Tracks);
        directory -> random_group_track(directory, Tracks);
        _ -> {error, {bad_random_key, Key}}
    end.

random_track(Tracks) ->
    {ok, lists:nth(rand:uniform(length(Tracks)), Tracks)}.

random_group_track(Key, Tracks) ->
    Groups = group_tracks(Key, Tracks),
    case maps:to_list(Groups) of
        [] -> error;
        GroupList ->
            {_GroupKey, Members} = lists:nth(rand:uniform(length(GroupList)), GroupList),
            random_track(Members)
    end.

random_latest_track(Tracks) ->
    Sorted = lists:sort(fun newer_track/2, Tracks),
    Window = latest_window(),
    Candidates = lists:sublist(Sorted, erlang:min(Window, length(Sorted))),
    random_track(Candidates).

latest_window() ->
    case application:get_env(erm, playlist_latest_window, ?DEFAULT_LATEST_WINDOW) of
        N when is_integer(N), N > 0 -> N;
        _ -> ?DEFAULT_LATEST_WINDOW
    end.

newer_track(A, B) ->
    case A#track.mtime =:= B#track.mtime of
        true -> A#track.path =< B#track.path;
        false -> A#track.mtime > B#track.mtime
    end.

reorder_future(_Key, [], _Cur) ->
    [];
reorder_future(Key, Order, undefined) ->
    reorder_ids(Key, Order);
reorder_future(Key, Order, Cur) ->
    case split_at_current(Order, Cur) of
        {_Prefix, []} -> reorder_ids(Key, Order);
        {Prefix, [Cur | Tail]} -> Prefix ++ [Cur | reorder_ids(Key, Tail)]
    end.

reorder_ids(track, Ids) -> shuffle_list(Ids);
reorder_ids(random, Ids) -> shuffle_list(Ids);
reorder_ids(latest, Ids) ->
    Tracks = tracks_for_order(Ids),
    [T#track.id || T <- lists:sort(fun newer_track/2, Tracks)];
reorder_ids(Key, Ids) when Key =:= album; Key =:= artist; Key =:= genre; Key =:= directory ->
    Tracks = tracks_for_order(Ids),
    Groups = group_tracks(Key, Tracks),
    Keys = shuffle_list(maps:keys(Groups)),
    lists:append([[T#track.id || T <- maps:get(GroupKey, Groups)] || GroupKey <- Keys]);
reorder_ids(_Key, Ids) -> Ids.

group_tracks(Key, Tracks) ->
    Reversed = lists:foldl(
        fun(T, Acc) ->
            GroupKey = group_value(Key, T),
            maps:update_with(GroupKey, fun(Members) -> [T | Members] end, [T], Acc)
        end,
        #{},
        Tracks
    ),
    maps:map(fun(_GroupKey, Members) -> lists:reverse(Members) end, Reversed).

group_value(album, #track{album = Value, directory = Dir}) ->
    normalized_group(Value, fallback_album(Dir));
group_value(artist, #track{artist = Value, directory = Dir}) ->
    normalized_group(Value, fallback_artist(Dir));
group_value(genre, #track{genre = Value}) ->
    normalized_group(Value, "unknown");
group_value(directory, #track{directory = Value, path = Path}) ->
    normalized_group(Value, filename:dirname(Path)).

normalized_group(undefined, Fallback) -> string:lowercase(to_text(Fallback));
normalized_group([], Fallback) -> string:lowercase(to_text(Fallback));
normalized_group(<<>>, Fallback) -> string:lowercase(to_text(Fallback));
normalized_group(Value, _Fallback) -> string:lowercase(string:trim(to_text(Value))).

fallback_album(undefined) -> "unknown";
fallback_album(Dir) -> filename:basename(Dir).

fallback_artist(undefined) -> "unknown";
fallback_artist(Dir) -> filename:basename(filename:dirname(Dir)).

shuffle_list([]) -> [];
shuffle_list(List) ->
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

%%%===================================================================
%%% Rebuild/add/metadata
%%%===================================================================

normalize_load_mode(random_album) -> {shuffle_by, album};
normalize_load_mode(random_artist) -> {shuffle_by, artist};
normalize_load_mode(random_genre) -> {shuffle_by, genre};
normalize_load_mode(random_genere) -> {shuffle_by, genre};
normalize_load_mode(random_directory) -> {shuffle_by, directory};
normalize_load_mode(random_latest) -> latest;
normalize_load_mode(Mode) -> Mode.

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

rebuild(Files0, Dirs, Mode, S = #st{order = OldOrder, cur = OldCur, previous = OldPrevious}) ->
    Files = [P || P <- uniq_keep_order([normalize_path(P0) || P0 <- Files0]), is_media_file(P)],
    ExistingByPath = tracks_by_path(),
    ets:delete_all_objects(?TAB),
    Ids0 = [insert_or_keep_track(P, ExistingByPath) || P <- Files],
    ValidOldOrder = [Id || Id <- OldOrder, lists:member(Id, Ids0)],
    NewIds = [Id || Id <- Ids0, not lists:member(Id, ValidOldOrder)],
    BaseOrder =
        case Mode of
            keep_order -> ValidOldOrder ++ NewIds;
            shuffle -> shuffle_list(Ids0);
            random -> shuffle_list(Ids0);
            latest -> reorder_ids(latest, Ids0);
            {shuffle_by, Key} -> reorder_ids(Key, Ids0);
            _ -> Ids0
        end,
    Cur = preserve_id_or_first(OldCur, BaseOrder),
    Previous = preserve_id_or_undefined(OldPrevious, BaseOrder),
    {length(Ids0), S#st{
        order = BaseOrder,
        cur = Cur,
        previous = Previous,
        src_dirs = Dirs,
        mode = Mode
    }}.

preserve_id_or_first(Id, Order) ->
    case lists:member(Id, Order) of
        true -> Id;
        false -> first_or_undefined(Order)
    end.

preserve_id_or_undefined(Id, Order) ->
    case lists:member(Id, Order) of
        true -> Id;
        false -> undefined
    end.

insert_or_keep_track(Path, ExistingByPath) ->
    Id = stable_id(Path),
    T =
        case maps:get(Path, ExistingByPath, undefined) of
            Old = #track{} -> refresh_track_file_fields(Old#track{id = Id, path = Path});
            undefined -> new_track(Id, Path)
        end,
    ets:insert(?TAB, T),
    Id.

new_track(Id, Path) ->
    Tags =
        case has_uri_scheme(Path) of
            true -> #{};
            false -> probe_metadata(Path)
        end,
    Dir = filename:dirname(Path),
    #track{
        id = Id,
        path = Path,
        cid = undefined,
        liked = false,
        artist = maps:get(artist, Tags, fallback_artist(Dir)),
        album = maps:get(album, Tags, fallback_album(Dir)),
        genre = maps:get(genre, Tags, undefined),
        directory = Dir,
        mtime = file_mtime(Path)
    }.

refresh_track_file_fields(T = #track{path = Path}) ->
    Dir = filename:dirname(Path),
    T#track{directory = Dir, mtime = file_mtime(Path)}.

probe_metadata(Path) ->
    case os:find_executable("ffprobe") of
        false -> #{};
        Ffprobe ->
            Cmd = lists:flatten([
                shell_quote(Ffprobe),
                " -v error -show_entries ",
                "format_tags=artist,album,genre:stream_tags=artist,album,genre ",
                "-of default=noprint_wrappers=1 ",
                shell_quote(Path),
                " 2>/dev/null"
            ]),
            parse_ffprobe_tags(os:cmd(Cmd))
    end.

parse_ffprobe_tags(Text) ->
    lists:foldl(fun parse_tag_line/2, #{}, string:split(Text, "\n", all)).

parse_tag_line(Line0, Acc) ->
    Line = string:trim(Line0),
    case string:split(Line, "=", leading) of
        [Key0, Value0] ->
            Key = normalize_tag_key(Key0),
            Value = string:trim(Value0),
            case {Key, Value, maps:is_key(Key, Acc)} of
                {undefined, _, _} -> Acc;
                {_, [], _} -> Acc;
                {_, _, true} -> Acc;
                {_, _, false} -> maps:put(Key, Value, Acc)
            end;
        _ ->
            Acc
    end.

normalize_tag_key(Key0) ->
    Key1 = string:lowercase(string:trim(Key0)),
    Tokens = string:tokens(Key1, ":."),
    Tail =
        case Tokens of
            [] -> Key1;
            _ -> lists:last(Tokens)
        end,
    case Tail of
        "artist" -> artist;
        "album" -> album;
        "genre" -> genre;
        _ -> undefined
    end.

file_mtime(Path) ->
    case file:read_file_info(Path, [{time, posix}]) of
        {ok, #file_info{mtime = MTime}} when is_integer(MTime) -> MTime;
        _ -> 0
    end.

find_track_by_path(Path) ->
    case [T || T = #track{path = TrackPath} <- ets:tab2list(?TAB), TrackPath =:= Path] of
        [T | _] -> {ok, T};
        [] -> error
    end.

current_id_for_path(undefined, Ids) ->
    first_or_undefined(Ids);
current_id_for_path(null, Ids) ->
    first_or_undefined(Ids);
current_id_for_path(<<>>, Ids) ->
    first_or_undefined(Ids);
current_id_for_path([], Ids) ->
    first_or_undefined(Ids);
current_id_for_path(CurrentPath0, Ids) ->
    CurrentPath = normalize_path(CurrentPath0),
    case find_track_by_path(CurrentPath) of
        {ok, #track{id = Id}} -> Id;
        error -> first_or_undefined(Ids)
    end.

lookup_track(Id) ->
    case ets:lookup(?TAB, Id) of
        [T = #track{}] -> {ok, T};
        [] -> error
    end.

tracks_by_path() ->
    maps:from_list([{T#track.path, T} || T = #track{} <- ets:tab2list(?TAB)]).

stable_id(Path) ->
    erlang:phash2(Path, 16#7fffffff).

first_or_undefined([]) -> undefined;
first_or_undefined([Id | _]) -> Id.

%%%===================================================================
%%% Persistent state
%%%===================================================================

persist(S) ->
    _ = save_state(S),
    S.

save_state(#st{state_file = undefined}) ->
    ok;
save_state(S = #st{state_file = Path}) ->
    Snapshot = #{
        version => ?STATE_VERSION,
        order => S#st.order,
        cur => S#st.cur,
        previous => S#st.previous,
        src_dirs => S#st.src_dirs,
        mode => S#st.mode,
        tracks => [track_to_map(T) || T = #track{} <- ets:tab2list(?TAB)]
    },
    Bin = term_to_binary(Snapshot, [compressed]),
    Tmp = Path ++ ".tmp." ++ integer_to_list(erlang:unique_integer([positive])),
    case filelib:ensure_dir(Path) of
        ok ->
            case file:write_file(Tmp, Bin, [binary]) of
                ok ->
                    case file:rename(Tmp, Path) of
                        ok -> ok;
                        {error, Reason} ->
                            _ = file:delete(Tmp),
                            {error, Reason}
                    end;
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

restore_state(Path, S0) ->
    case file:read_file(Path) of
        {ok, Bin} ->
            try binary_to_term(Bin, [safe]) of
                Snapshot when is_map(Snapshot) -> restore_snapshot(Snapshot, S0);
                Other -> {error, {bad_playlist_state, Other}}
            catch
                Class:Reason:Stacktrace -> {error, {bad_playlist_state, Class, Reason, Stacktrace}}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

restore_snapshot(Snapshot, S0) ->
    Version = maps:get(version, Snapshot, 1),
    case Version =< ?STATE_VERSION of
        true ->
            Tracks0 = maps:get(tracks, Snapshot, []),
            Tracks = [T || Map <- Tracks0, {ok, T} <- [map_to_track(Map)]],
            ets:delete_all_objects(?TAB),
            ets:insert(?TAB, Tracks),
            Existing = maps:from_list([{T#track.id, true} || T <- Tracks]),
            Order0 = maps:get(order, Snapshot, []),
            Order = uniq_keep_order([Id || Id <- Order0, maps:is_key(Id, Existing)]),
            Cur = preserve_id_or_undefined(maps:get(cur, Snapshot, undefined), Order),
            Previous = preserve_id_or_undefined(maps:get(previous, Snapshot, undefined), Order),
            {ok, S0#st{
                order = Order,
                cur = Cur,
                previous = Previous,
                src_dirs = maps:get(src_dirs, Snapshot, []),
                mode = maps:get(mode, Snapshot, keep_order)
            }};
        false ->
            {error, {unsupported_playlist_state_version, Version}}
    end.

track_to_map(T) ->
    #{
        id => T#track.id,
        path => T#track.path,
        cid => T#track.cid,
        liked => T#track.liked,
        artist => T#track.artist,
        album => T#track.album,
        genre => T#track.genre,
        directory => T#track.directory,
        mtime => T#track.mtime
    }.

map_to_track(Map) when is_map(Map) ->
    case maps:get(path, Map, undefined) of
        Path0 when is_binary(Path0); is_list(Path0) ->
            Path = normalize_path(Path0),
            Id = maps:get(id, Map, stable_id(Path)),
            {ok, #track{
                id = Id,
                path = Path,
                cid = maps:get(cid, Map, undefined),
                liked = maps:get(liked, Map, false),
                artist = maps:get(artist, Map, undefined),
                album = maps:get(album, Map, undefined),
                genre = maps:get(genre, Map, undefined),
                directory = maps:get(directory, Map, filename:dirname(Path)),
                mtime = maps:get(mtime, Map, file_mtime(Path))
            }};
        _ ->
            error
    end;
map_to_track(_) ->
    error.

state_home() ->
    case os:getenv("XDG_STATE_HOME") of
        false -> fallback_state_home();
        "" -> fallback_state_home();
        Dir -> Dir
    end.

fallback_state_home() ->
    case os:getenv("HOME") of
        false -> filename:absname(".erm-state");
        "" -> filename:absname(".erm-state");
        Home -> filename:join([Home, ".local", "state"])
    end.

%%%===================================================================
%%% Media discovery/path helpers
%%%===================================================================

ensure_table() ->
    case ets:info(?TAB) of
        undefined -> ets:new(?TAB, [named_table, ordered_set, public, {keypos, #track.id}]);
        _ -> ?TAB
    end.

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

is_media_ref(Path0) ->
    Path = normalize_path(Path0),
    has_uri_scheme(Path) orelse is_media_file(Path).

is_media_file(Path0) ->
    Path = normalize_path(Path0),
    Ext = string:lowercase(filename:extension(Path)),
    lists:member(Ext, media_exts()).

has_uri_scheme(Path) when is_list(Path) ->
    case string:find(Path, "://") of
        nomatch -> false;
        _ -> true
    end.

media_exts() ->
    [
        ".mp3", ".flac", ".wav", ".ogg", ".oga", ".opus", ".m4a", ".aac", ".alac",
        ".ape", ".wv", ".tta", ".spx", ".mp2", ".mpga", ".mka", ".caf", ".wma",
        ".mp4", ".m4v", ".mkv", ".webm", ".avi", ".mov", ".wmv", ".flv", ".3gp",
        ".3g2", ".mpeg", ".mpg", ".m2ts", ".mts", ".vob", ".ogv", ".ts"
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

normalize_dirs(Bin) when is_binary(Bin) -> [normalize_path(Bin)];
normalize_dirs([]) -> [];
normalize_dirs([H | _] = Dir) when is_integer(H) -> [normalize_path(Dir)];
normalize_dirs(Dirs) when is_list(Dirs) -> uniq_keep_order([normalize_path(D) || D <- Dirs]);
normalize_dirs(Dir) -> [normalize_path(Dir)].

normalize_paths(Bin) when is_binary(Bin) -> [normalize_path(Bin)];
normalize_paths([]) -> [];
normalize_paths([H | _] = Path) when is_integer(H) -> [normalize_path(Path)];
normalize_paths(Paths) when is_list(Paths) -> [normalize_path(P) || P <- Paths].

normalize_path(Bin) when is_binary(Bin) -> normalize_path(binary_to_list(Bin));
normalize_path(Path) when is_list(Path) ->
    case has_uri_scheme(Path) of
        true -> Path;
        false -> filename:absname(Path)
    end.

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

shell_quote(Value) ->
    Text = to_text(Value),
    [$' | shell_quote_chars(Text)] ++ [$'].

shell_quote_chars([]) -> [];
shell_quote_chars([$' | Rest]) -> [$', $\\, $', $' | shell_quote_chars(Rest)];
shell_quote_chars([Ch | Rest]) -> [Ch | shell_quote_chars(Rest)].

to_text(Value) when is_binary(Value) -> unicode:characters_to_list(Value);
to_text(Value) when is_atom(Value) -> atom_to_list(Value);
to_text(Value) when is_list(Value) -> lists:flatten(Value);
to_text(Value) -> lists:flatten(io_lib:format("~p", [Value])).
