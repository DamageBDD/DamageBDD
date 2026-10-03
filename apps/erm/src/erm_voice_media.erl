%% Voice media adapter: typed actions, existing MPV owner, persistent playlist.
-module(erm_voice_media).
-include("erm_playlist.hrl").
-export([execute/2, select_song/2]).

execute(#{action := play}, _Opts) ->
    case cmd(status, []) of
        {ok, #{idle_active := false, path := Path}} when is_binary(Path); is_list(Path) ->
            cmd(play, []);
        {ok, _} -> play_current();
        Error -> Error
    end;
execute(#{action := pause}, _Opts) -> cmd(pause, []);
execute(#{action := stop}, _Opts) -> cmd(stop, []);
execute(#{action := next}, _Opts) -> navigate(peek_next);
execute(#{action := previous}, _Opts) -> navigate(peek_prev);
execute(#{action := volume, value := N}, _Opts) when is_integer(N), N >= 0, N =< 100 ->
    cmd(set_volume, [N]);
execute(#{action := play_song, query := Query}, _Opts) ->
    case playlist:all() of
        Tracks when is_list(Tracks) ->
            case select_song(Query, Tracks) of
                {ok, Track} -> play_track(Track);
                Error -> Error
            end;
        Other -> {error, {playlist_unavailable, Other}}
    end;
execute(#{action := show_player}, _Opts) -> erm_mpv:show();
execute(#{action := hide_player}, _Opts) -> erm_mpv:close();
execute(#{action := now_playing}, _Opts) ->
    case cmd(status, []) of
        {ok, #{idle_active := false, path := Path}} when is_binary(Path); is_list(Path) ->
            _ = playlist:sync_current_path(Path),
            case playlist:current() of
                {ok, T} ->
                    case text(T#track.path) =:= text(Path) of
                        true -> {ok, #{title => title(T), artist => text(T#track.artist)}};
                        false -> {error, playback_not_in_playlist}
                    end;
                _ -> {error, playback_not_in_playlist}
            end;
        {ok, _} -> {error, nothing_playing};
        Error -> Error
    end;
execute(_, _) -> {error, unsupported_media_action}.

cmd(F, Args) ->
    case get(erm_voice_job_ref) of
        undefined -> erm_mpv_proc:command(F, Args, 3000);
        Ref ->
            case gen_server:call(erm_voice, {media_permit, Ref}, 1000) of
                true -> erm_mpv_proc:command(F, Args, 3000);
                false -> {error, cancelled}
            end
    end.
sync_current() ->
    case cmd(get_property, [<<"path">>]) of
        {ok, Path} when is_binary(Path); is_list(Path) -> playlist:sync_current_path(Path);
        _ -> ok
    end.
navigate(F) ->
    sync_current(),
    case apply(playlist, F, []) of
        {ok, T} -> play_track(T);
        _ -> {error, no_playlist_track}
    end.
play_current() ->
    case playlist:current() of
        {ok, T} -> play_track(T);
        _ ->
            case playlist:get_by_index(0) of
                {ok, T} -> play_track(T);
                _ -> {error, empty_playlist}
            end
    end.

%% Keep the selected track AND the rest of the queue. Never turn it into a
%% singleton loadfile, which would break automatic next-track playback.
play_track(T = #track{id = Id}) ->
    Tracks = playlist:all(),
    Tail = lists:dropwhile(fun({_, X}) -> X#track.id =/= Id end, Tracks),
    case Tail of
        [] -> {error, track_not_in_playlist};
        _ ->
            case valid_path(text(T#track.path)) of
                false -> {error, invalid_playlist_path};
                true ->
                    Paths = [text(X#track.path) || {_, X} <- Tail,
                                                  valid_path(text(X#track.path))],
                    Skipped = length(Tail) - length(Paths),
                    case Skipped of
                        0 -> ok;
                        _ -> subsystem_log(warning, "Voice queue skipped ~p unavailable entries", [Skipped])
                    end,
                    load_tail(T, Paths)
            end
    end.
valid_path(<<>>) -> false;
valid_path(P) -> binary:match(P, [<<"\n">>, <<"\r">>, <<0>>]) =:= nomatch
                andalso (filelib:is_regular(P) orelse binary:match(P, <<"://">>) =/= nomatch).
load_tail(T, Paths) ->
    Dir = filename:basedir(user_cache, "erm"),
    File = filename:join(Dir, "voice-progression.m3u8"),
    case filelib:ensure_dir(File) of
        ok ->
            %% Prefix relative local paths with an absolute directory; '#' in
            %% a local filename must not become an M3U comment.
            Body = ["#EXTM3U\n" | [[m3u_path(P), "\n"] || P <- Paths]],
            case file:write_file(File, Body) of
                ok ->
                    case cmd(load_list, [unicode:characters_to_binary(File)]) of
                        ok -> finish_load(T);
                        {ok, _} -> finish_load(T);
                        Error -> Error
                    end;
                Error -> Error
            end;
        Error -> Error
    end.
m3u_path(P) ->
    case binary:match(P, <<"://">>) of
        nomatch -> filename:absname(P);
        _ -> P
    end.
finish_load(T) ->
    case cmd(play, []) of
        ok -> commit(T);
        {ok, _} -> commit(T);
        Error -> Error
    end.
commit(T) ->
    case playlist:set_current(T#track.id) of
        ok -> {ok, #{playing => title(T), artist => text(T#track.artist)}};
        Error -> {error, {playing_but_playlist_sync_failed, Error}}
    end.

%% Search actual playlist metadata. A model may supply a search phrase, never
%% a filesystem path/URL or an invented track id. Ties need clarification.
select_song(Query, Tracks) ->
    Q = words(Query),
    Scored = [{score(Q, T), T} || {_, T = #track{}} <- Tracks],
    Ranked = lists:reverse(lists:keysort(1, [{S, T} || {S, T} <- Scored, S > 0])),
    case Ranked of
        [] -> {error, song_not_found};
        [{S, _}, {S, _} | _] ->
            {error, {ambiguous_song, [#{title => title(T), artist => text(T#track.artist)}
                                     || {_, T} <- lists:sublist(Ranked, 5)]}};
        [{_, T} | _] -> {ok, T}
    end.
score([], _) -> 0;
score(Q, T) ->
    Title = words(title(T)), Artist = words(text(T#track.artist)),
    %% "by" is a speech separator only; keep other title words intact.
    Search = [W || W <- Q, W =/= <<"by">>],
    case Search =/= [] andalso lists:all(fun(W) -> lists:member(W, Title ++ Artist) end, Search) of
        false -> 0;
        true when Q =:= Title -> 1000;
        true -> 100 + length([W || W <- Search, lists:member(W, Title)])
    end.
title(#track{path = P}) -> text(filename:rootname(filename:basename(P))).
words(T) -> binary:split(erm_voice_boundary:normalize(T), <<" ">>, [global, trim_all]).
text(undefined) -> <<>>;
text(T) -> unicode:characters_to_binary(T).

subsystem_log(Level, Format, Args) ->
    logger:log(Level, Format, Args, #{domain => [erm, voice]}).
