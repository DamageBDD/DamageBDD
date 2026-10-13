%%%-------------------------------------------------------------------
%%% @doc Supervised ERM media autoplay/progression worker.
%%%
%%% The worker must never replace a live MPV playlist merely because the ERM
%%% OTP application restarted. It first inspects the surviving MPV session;
%%% when media is already loaded it only synchronises playlist position.
%%%
%%% When MPV is genuinely idle, the persisted playlist progression is resumed
%%% from the saved current item. A new default playlist is built only when no
%%% persisted queue exists.
%%%-------------------------------------------------------------------
-module(erm_media_autoplay).
-behaviour(gen_server).

-include("erm_playlist.hrl").
-include_lib("kernel/include/logger.hrl").

-export([start_link/0, play_default/0, playlist_path/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(IPC_PATH, ipc_path()).
-define(BOOT_DELAY_MS, 750).
-define(RETRY_DELAY_MS, 5000).
-define(SYNC_DELAY_MS, 2000).
-define(MPV_TIMEOUT_MS, 3000).

-record(st, {
    playlist_file,
    retry_ms = ?RETRY_DELAY_MS,
    sync_ms = ?SYNC_DELAY_MS
}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

play_default() ->
    gen_server:cast(?MODULE, play_default).

playlist_path() ->
    default_playlist_file().

init([]) ->
    erlang:send_after(?BOOT_DELAY_MS, self(), play_default),
    erlang:send_after(?SYNC_DELAY_MS, self(), sync_progress),
    {ok, #st{playlist_file = default_playlist_file()}}.

handle_call(play_default, _From, S) ->
    {Reply, S1} = do_play_default(S),
    {reply, Reply, S1};
handle_call(_Req, _From, S) ->
    {reply, ok, S}.

handle_cast(play_default, S) ->
    {_Reply, S1} = do_play_default(S),
    {noreply, S1};
handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info(play_default, S) ->
    {_Reply, S1} = do_play_default(S),
    {noreply, S1};
handle_info(sync_progress, S = #st{sync_ms = SyncMs}) ->
    _ = sync_progress_from_mpv(),
    erlang:send_after(SyncMs, self(), sync_progress),
    {noreply, S};
handle_info(_Msg, S) ->
    {noreply, S}.

terminate(_Reason, _S) -> ok.
code_change(_OldVsn, S, _Extra) -> {ok, S}.

%%%===================================================================
%%% Startup / progression preservation
%%%===================================================================

do_play_default(S = #st{retry_ms = RetryMs}) ->
    case ensure_playlist() of
        ok ->
            case mpv_status() of
                {ok, Status} ->
                    case status_has_loaded_media(Status) of
                        true ->
                            _ = sync_full_playlist_from_mpv(Status),
                            ?LOG_INFO(
                                "ERM autoplay preserving existing MPV playback path=~p position=~p",
                                [status_value(path, Status), status_value(time_pos, Status)]
                            ),
                            {ok, S};
                        false ->
                            resume_or_build_playlist(S)
                    end;
                {error, Reason} ->
                    %% An uncertain IPC state is never grounds for replacing a
                    %% possibly-live playlist. Retry instead of issuing loadlist.
                    ?LOG_WARNING(
                        "ERM autoplay cannot verify MPV state (~p); preserving playback and retrying",
                        [Reason]
                    ),
                    erlang:send_after(RetryMs, self(), play_default),
                    {{error, Reason}, S}
            end;
        {error, Reason} ->
            ?LOG_WARNING("Playlist process unavailable: ~p; retrying", [Reason]),
            erlang:send_after(RetryMs, self(), play_default),
            {{error, Reason}, S}
    end.

resume_or_build_playlist(S = #st{playlist_file = PlaylistFile, retry_ms = RetryMs}) ->
    case resumable_tracks() of
        {ok, []} ->
            Mode = default_playlist_mode(),
            case playlist:load_default(Mode) of
                {ok, 0} ->
                    ?LOG_WARNING(
                        "ERM media autoplay found no media files in default dirs ~p",
                        [playlist:default_media_dirs()]
                    ),
                    {{error, no_media}, S};
                {ok, Count} ->
                    start_progression(Count, Mode, PlaylistFile, S);
                {error, Reason} ->
                    schedule_retry({playlist_load_failed, Reason}, RetryMs, S)
            end;
        {ok, Tracks} ->
            %% progression/0 starts at the saved current track and retains
            %% only the unplayed tail. Loading it resumes queue position after
            %% a real MPV loss; it is
            %% never called during a normal OTP restart with live MPV.
            start_tracks(Tracks, resumed, PlaylistFile, S);
        {error, Reason} ->
            schedule_retry({playlist_progression_failed, Reason}, RetryMs, S)
    end.

start_progression(Count, Mode, PlaylistFile, S) ->
    case resumable_tracks() of
        {ok, Tracks} ->
            case start_tracks(Tracks, Mode, PlaylistFile, S) of
                {ok, S1} ->
                    ?LOG_INFO(
                        "ERM media autoplay started tracks=~p mode=~p playlist=~s",
                        [Count, Mode, PlaylistFile]
                    ),
                    {ok, S1};
                Error ->
                    Error
            end;
        {error, Reason} ->
            schedule_retry({playlist_progression_failed, Reason}, S#st.retry_ms, S)
    end.

start_tracks([], _Mode, _PlaylistFile, S) ->
    {{error, no_media}, S};
start_tracks(Tracks, Mode, PlaylistFile, S = #st{retry_ms = RetryMs}) ->
    case write_m3u(PlaylistFile, Tracks) of
        ok ->
            case load_playlist_if_idle(PlaylistFile) of
                ok ->
                    ?LOG_INFO(
                        "ERM media playlist loaded without replacing live playback tracks=~p mode=~p",
                        [length(Tracks), Mode]
                    ),
                    {ok, S};
                {preserved, Status} ->
                    _ = sync_playlist_from_status(Status),
                    ?LOG_INFO("MPV became active before load; kept existing playback", []),
                    {ok, S};
                {error, Reason} ->
                    schedule_retry({mpv_autoplay_failed, Reason}, RetryMs, S)
            end;
        {error, Reason} ->
            schedule_retry({playlist_write_failed, PlaylistFile, Reason}, RetryMs, S)
    end.

load_playlist_if_idle(PlaylistFile) ->
    %% Double-check immediately before the destructive loadlist operation. This
    %% closes the race where MPV starts/resumes between the initial status probe
    %% and playlist preparation.
    case mpv_status() of
        {ok, Status} ->
            case status_has_loaded_media(Status) of
                true ->
                    {preserved, Status};
                false ->
                    case mpv_command(load_list, [PlaylistFile]) of
                        ok -> ok;
                        {ok, _} -> ok;
                        {error, _Reason} = Error -> Error;
                        Other -> {error, {unexpected_mpv_load_reply, Other}}
                    end
            end;
        {error, Reason} ->
            {error, {mpv_status_unavailable_before_load, Reason}}
    end.

schedule_retry(Reason, RetryMs, S) ->
    ?LOG_WARNING("ERM media autoplay deferred: ~p; retrying", [Reason]),
    erlang:send_after(RetryMs, self(), play_default),
    {{error, Reason}, S}.

%%%===================================================================
%%% MPV -> playlist position synchronisation
%%%===================================================================

sync_progress_from_mpv() ->
    case mpv_status() of
        {ok, Status} -> sync_playlist_from_status(Status);
        {error, _Reason} -> ok
    end.

sync_full_playlist_from_mpv(Status) ->
    %% The persistent Erlang playlist is the long-lived logical queue and keeps
    %% the already-played prefix needed by Previous/history. MPV may legitimately
    %% hold only the remaining tail after a user selected an arbitrary position.
    %% Never replace a non-empty logical queue with that shorter live tail.
    case safe_playlist_call(all, []) of
        Existing when is_list(Existing), Existing =/= [] ->
            sync_playlist_from_status(Status);
        _ ->
            import_playlist_from_mpv(Status)
    end.

import_playlist_from_mpv(Status) ->
    case mpv_command(get_property, [<<"playlist">>]) of
        {ok, Entries} when is_list(Entries) ->
            Paths = [Path || Entry <- Entries, {ok, Path} <- [mpv_playlist_entry_path(Entry)]],
            CurrentPath = status_value(path, Status),
            case Paths of
                [] ->
                    sync_playlist_from_status(Status);
                _ ->
                    case safe_playlist_call(sync_from_paths, [Paths, CurrentPath]) of
                        {ok, _Count} -> ok;
                        {error, _Reason} = Error -> Error;
                        _Other -> ok
                    end
            end;
        _ ->
            %% Older MPV/proxy combinations may not expose the full playlist.
            %% Current-path synchronisation still preserves the saved cursor.
            sync_playlist_from_status(Status)
    end.

mpv_playlist_entry_path(Entry) when is_map(Entry) ->
    case first_map_value([filename, "filename", <<"filename">>], Entry, undefined) of
        Path when is_binary(Path), byte_size(Path) > 0 -> {ok, Path};
        Path when is_list(Path), Path =/= [] -> {ok, Path};
        _ -> error
    end;
mpv_playlist_entry_path(_Entry) ->
    error.

sync_playlist_from_status(Status) ->
    case status_path(Status) of
        {ok, Path} ->
            case safe_playlist_call(sync_current_path, [Path]) of
                {ok, _Track} -> ok;
                {error, {track_not_in_playlist, _}} -> ok;
                {error, _Reason} = Error -> Error;
                _Other -> ok
            end;
        error ->
            ok
    end.

status_has_loaded_media(Status) ->
    case status_path(Status) of
        {ok, _Path} -> status_value(idle_active, Status) =/= true;
        error -> false
    end.

status_path(Status) ->
    case status_value(path, Status) of
        Path when is_binary(Path), byte_size(Path) > 0 -> {ok, Path};
        Path when is_list(Path), Path =/= [] -> {ok, Path};
        _ -> error
    end.

status_value(Key, Status) when is_map(Status) ->
    Keys = status_keys(Key),
    first_map_value(Keys, Status, undefined).

status_keys(path) -> [path, "path", <<"path">>];
status_keys(time_pos) -> [time_pos, "time-pos", <<"time-pos">>];
status_keys(idle_active) -> [idle_active, "idle-active", <<"idle-active">>];
status_keys(Key) -> [Key].

first_map_value([], _Map, Default) ->
    Default;
first_map_value([Key | Rest], Map, Default) ->
    case maps:find(Key, Map) of
        {ok, Value} -> Value;
        error -> first_map_value(Rest, Map, Default)
    end.

%%%===================================================================
%%% Integration helpers
%%%===================================================================

ensure_playlist() ->
    case whereis(playlist) of
        undefined ->
            case playlist:start_link() of
                {ok, _Pid} -> ok;
                {error, {already_started, _Pid}} -> ok;
                {error, Reason} -> {error, Reason}
            end;
        _Pid ->
            ok
    end.

resumable_tracks() ->
    case safe_playlist_call(progression, []) of
        Tracks when is_list(Tracks) -> {ok, Tracks};
        {error, _Reason} = Error -> Error;
        Other -> {error, {unexpected_playlist_progression_reply, Other}}
    end.

mpv_status() ->
    case ensure_mpv_owner() of
        ok ->
            case mpv_command(status, []) of
                {ok, Status} when is_map(Status) -> {ok, Status};
                Status when is_map(Status) -> {ok, Status};
                {error, _Reason} = Error -> Error;
                Other -> {error, {unexpected_mpv_status_reply, Other}}
            end;
        {error, _Reason} = Error ->
            Error
    end.

ensure_mpv_owner() ->
    try erm_mpv_proc:ensure_started(?IPC_PATH) of
        ok -> ok;
        {ok, _} -> ok;
        {error, _Reason} = Error -> Error;
        Other -> {error, {unexpected_mpv_ensure_reply, Other}}
    catch
        Class:Reason:Stacktrace -> {error, {exception, Class, Reason, Stacktrace}}
    end.

mpv_command(Function, Args) ->
    try erm_mpv_proc:command(Function, Args, ?MPV_TIMEOUT_MS) of
        Reply -> Reply
    catch
        Class:Reason:Stacktrace -> {error, {exception, Class, Reason, Stacktrace}}
    end.

safe_playlist_call(Function, Args) ->
    try apply(playlist, Function, Args) of
        Reply -> Reply
    catch
        Class:Reason:Stacktrace -> {error, {exception, Class, Reason, Stacktrace}}
    end.

default_playlist_mode() ->
    case application:get_env(erm, media_playlist_mode, shuffle) of
        keep_order ->
            keep_order;
        shuffle ->
            shuffle;
        random ->
            random;
        latest ->
            latest;
        random_latest ->
            random_latest;
        random_album ->
            random_album;
        random_artist ->
            random_artist;
        random_genre ->
            random_genre;
        random_genere ->
            random_genre;
        random_directory ->
            random_directory;
        {shuffle_by, Key} ->
            {shuffle_by, Key};
        Invalid ->
            ?LOG_WARNING("Ignoring invalid media_playlist_mode=~p; using shuffle", [Invalid]),
            shuffle
    end.

default_playlist_file() ->
    Tmp = getenv_default("TMPDIR", "/tmp"),
    filename:join(Tmp, "erm-default-playlist.m3u8").

ipc_path() ->
    getenv_default("MPV_IPC", "/tmp/mpv.sock").

getenv_default(Name, Default) ->
    case os:getenv(Name) of
        false -> Default;
        "" -> Default;
        Value -> Value
    end.

write_m3u(Path, Tracks) ->
    Body = ["#EXTM3U\n" | [track_line(T) || T <- Tracks]],
    file:write_file(Path, unicode:characters_to_binary(Body)).

track_line(#track{path = Path}) ->
    [Path, "\n"].
