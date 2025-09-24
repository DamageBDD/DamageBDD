%%%-------------------------------------------------------------------
%%% playlist.erl — ETS-backed playlist with CID/like
%%%-------------------------------------------------------------------
-module(playlist).
-behaviour(gen_server).
-export([
    start_link/0,
    add_file/1,
    add/2,
    all/0,
    get_by_index/1,
    current/0,
    set_current/1,
    next/0,
    prev/0,
    clear/0,
    update_cid/2,
    toggle_like_current/0,
    rescan_all/0
]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(track, {id, path, cid = undefined, liked = false}).
-define(TAB, playlist_tab).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    process_flag(trap_exit, true),
    ets:new(?TAB, [ordered_set, public, named_table]),
    put(current, undefined),
    {ok, #{}}.

add_file(Path) -> add(Path, undefined).
add(Path, Cid) ->
    Id = erlang:phash2(Path),
    T = #track{id = Id, path = Path, cid = Cid},
    ets:insert(?TAB, {Id, T}),
    ok.

all() ->
    Ts = ets:tab2list(?TAB),
    lists:zip(lists:seq(0, length(Ts) - 1), [T || {_, T} <- Ts]).

get_by_index(Idx) ->
    Ts = [T || {_, T} <- ets:tab2list(?TAB)],
    case lists:nthtail(Idx, Ts) of
        [T | _] -> {ok, T};
        _ -> error
    end.

current() ->
    case get(current) of
        undefined -> error;
        Id -> {ok, element(2, hd(ets:lookup(?TAB, Id)))}
    end.
set_current(Id) ->
    put(current, Id),
    case ets:lookup(?TAB, Id) of
        [{_, T}] -> social_reporter:now_playing(T);
        _ -> ok
    end,
    ok.

next() ->
    case current() of
        {ok, T} ->
            Ts = [X || {_, X} <- ets:tab2list(?TAB)],
            case lists:dropwhile(fun(X) -> X#track.id =/= T#track.id end, Ts) of
                [_Cur, Nxt | _] ->
                    mpv_ipc:load_file(Nxt#track.path),
                    set_current(Nxt#track.id);
                _ ->
                    ok
            end;
        error ->
            ok
    end.

prev() ->
    case current() of
        {ok, T} ->
            Ts = [X || {_, X} <- ets:tab2list(?TAB)],
            Rev = lists:reverse(Ts),
            case lists:dropwhile(fun(X) -> X#track.id =/= T#track.id end, Rev) of
                [_Cur, Prev | _] ->
                    mpv_ipc:load_file(Prev#track.path),
                    set_current(Prev#track.id);
                _ ->
                    ok
            end;
        error ->
            ok
    end.

clear() ->
    ets:delete_all_objects(?TAB),
    put(current, undefined),
    ok.

update_cid(Id, Cid) ->
    case ets:lookup(?TAB, Id) of
        [{_, T}] ->
            ets:insert(?TAB, {Id, T#track{cid = Cid}}),
            ok;
        _ ->
            ok
    end.

toggle_like_current() ->
    case current() of
        {ok, T = #track{id = Id, liked = L}} ->
            ets:insert(?TAB, {Id, T#track{liked = not L}}),
            ok;
        error ->
            ok
    end.

rescan_all() -> ok.

handle_call(_C, _F, S) -> {reply, ok, S}.
handle_cast(_M, S) -> {noreply, S}.
handle_info(_I, S) -> {noreply, S}.
terminate(_, _) -> ok.
code_change(_, S, _) -> {ok, S}.
