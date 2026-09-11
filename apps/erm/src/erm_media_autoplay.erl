%%%-------------------------------------------------------------------
%%% @doc Supervised ERM media autoplay worker.
%%%
%%% Builds a shuffled M3U playlist from all default media directories and
%%% asks erm_mpv_proc to load it through MPV. The MPV process owner provides
%%% command timeouts and restarts the managed MPV session if IPC wedges.
%%% @end
%%%-------------------------------------------------------------------
-module(erm_media_autoplay).
-behaviour(gen_server).

-include("erm_playlist.hrl").
-include_lib("kernel/include/logger.hrl").
-include("erm_log.hrl").

-export([start_link/0, play_default/0, playlist_path/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(BOOT_DELAY_MS, 750).
-define(RETRY_DELAY_MS, 5000).
-define(MPV_CMD_TIMEOUT_MS, 5000).
-define(LOG_DOMAIN, ?ERM_LOG_DOMAIN_MPV_AUTOPLAY).
-define(LOG_META, ?ERM_LOG_META(?LOG_DOMAIN)).

-record(st, {
    playlist_file,
    retry_ms = ?RETRY_DELAY_MS,
    retry_timer = undefined
}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

play_default() ->
    gen_server:cast(?MODULE, play_default).

playlist_path() ->
    default_playlist_file().

init([]) ->
    init_logging(),
    S0 = #st{playlist_file = default_playlist_file()},
    {ok, schedule_play(?BOOT_DELAY_MS, S0)}.

handle_call(play_default, _From, S0) ->
    {Reply, S1} = do_play_default(cancel_retry(S0)),
    {reply, Reply, S1};
handle_call(_Req, _From, S) ->
    {reply, ok, S}.

handle_cast(play_default, S0) ->
    {_Reply, S1} = do_play_default(cancel_retry(S0)),
    {noreply, S1};
handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info({play_default, Token}, S0 = #st{retry_timer = {_TimerRef, Token}}) ->
    {_Reply, S1} = do_play_default(S0#st{retry_timer = undefined}),
    {noreply, S1};
handle_info({play_default, _StaleToken}, S) ->
    {noreply, S};
handle_info(play_default, S0) ->
    %% Compatibility with old untagged timers from hot-code upgrades.
    {_Reply, S1} = do_play_default(cancel_retry(S0)),
    {noreply, S1};
handle_info(_Msg, S) ->
    {noreply, S}.

terminate(_Reason, S) ->
    cancel_timer(S#st.retry_timer),
    ok.

code_change(_OldVsn, S, _Extra) ->
    {ok, S}.

%% ——— Internal helpers ———

init_logging() ->
    _ = erm_log:ensure_handler(),
    erm_log:set_process_domain(?LOG_DOMAIN).

do_play_default(S = #st{playlist_file = PlaylistFile}) ->
    case ensure_playlist() of
        ok ->
            do_play_default_ready(PlaylistFile, S);
        {error, Reason} ->
            ?LOG_WARNING("Playlist process unavailable: ~p; retrying", [Reason]),
            {{error, Reason}, schedule_retry(S)}
    end.

do_play_default_ready(PlaylistFile, S) ->
    case safe_playlist_call(load_default, [shuffle]) of
        {ok, 0} ->
            ?LOG_WARNING(
                "ERM media autoplay found no media files in default dirs ~p",
                [safe_default_media_dirs()]
            ),
            {{error, no_media}, S};
        {ok, Count} when is_integer(Count), Count > 0 ->
            Tracks = current_tracks(),
            case write_m3u(PlaylistFile, Tracks) of
                ok ->
                    case start_mpv_playlist(PlaylistFile) of
                        ok ->
                            ?LOG_INFO(
                                "ERM media autoplay started ~p shuffled tracks from ~s",
                                [Count, PlaylistFile]
                            ),
                            {ok, cancel_retry(S)};
                        {error, Reason} ->
                            ?LOG_WARNING("MPV autoplay failed: ~p; retrying", [Reason]),
                            {{error, Reason}, schedule_retry(S)}
                    end;
                {error, Reason} ->
                    ?LOG_WARNING("Could not write MPV playlist ~s: ~p", [
                        PlaylistFile, Reason
                    ]),
                    {{error, Reason}, schedule_retry(S)}
            end;
        {error, Reason} ->
            ?LOG_WARNING("Could not load default playlist: ~p; retrying", [Reason]),
            {{error, Reason}, schedule_retry(S)};
        Other ->
            ?LOG_WARNING("Unexpected playlist:load_default/1 result: ~p; retrying", [Other]),
            {{error, {unexpected_playlist_load_result, Other}}, schedule_retry(S)}
    end.

ensure_playlist() ->
    case whereis(playlist) of
        undefined ->
            case safe_playlist_start() of
                {ok, _Pid} -> ok;
                {error, {already_started, _Pid}} -> ok;
                {error, Reason} -> {error, Reason};
                Other -> {error, {unexpected_playlist_start_result, Other}}
            end;
        _Pid ->
            ok
    end.

safe_playlist_start() ->
    try playlist:start_link() of
        Reply -> Reply
    catch
        Class:CatchReason:Stacktrace ->
            {error, {exception, Class, CatchReason, Stacktrace}}
    end.

safe_playlist_call(Function, Args) ->
    try apply(playlist, Function, Args) of
        Reply -> Reply
    catch
        Class:CatchReason:Stacktrace ->
            {error, {exception, Class, CatchReason, Stacktrace}}
    end.

safe_default_media_dirs() ->
    try playlist:default_media_dirs() of
        Dirs -> Dirs
    catch
        _:_ -> []
    end.

current_tracks() ->
    case safe_playlist_call(all, []) of
        Tracks0 when is_list(Tracks0) ->
            [T || {_Idx, T} <- Tracks0];
        {error, Reason} ->
            ?LOG_WARNING("Could not read playlist after load: ~p", [Reason]),
            [];
        Other ->
            ?LOG_WARNING("Unexpected playlist:all/0 result after load: ~p", [Other]),
            []
    end.

start_mpv_playlist(PlaylistFile) ->
    case safe_mpv_command(load_list, [PlaylistFile], ?MPV_CMD_TIMEOUT_MS) of
        ok ->
            ok;
        {ok, _} ->
            ok;
        {error, {not_exported, mpv_ipc, load_list, 1}} ->
            ?LOG_WARNING("mpv_ipc:load_list/1 missing; falling back to load_file/1", []),
            fallback_mpv_load_file(PlaylistFile);
        {error, Reason} ->
            {error, {mpv_ipc_load_list_failed, PlaylistFile, Reason}};
        Other ->
            ?LOG_DEBUG("erm_mpv_proc:command(load_list) returned ~p", [Other]),
            ok
    end.

fallback_mpv_load_file(PlaylistFile) ->
    case safe_mpv_command(load_file, [PlaylistFile], ?MPV_CMD_TIMEOUT_MS) of
        ok -> ok;
        {ok, _} -> ok;
        {error, Reason} -> {error, {mpv_ipc_load_file_failed, PlaylistFile, Reason}};
        Other ->
            ?LOG_DEBUG("erm_mpv_proc:command(load_file) returned ~p", [Other]),
            ok
    end.

safe_mpv_command(Function, Args, Timeout) ->
    try erm_mpv_proc:command(Function, Args, Timeout) of
        Reply -> Reply
    catch
        error:undef:Stack ->
            %% Hot-upgrade compatibility: older erm_mpv_proc may not yet export
            %% command/3. Use the old path but keep exception containment.
            ?LOG_WARNING("erm_mpv_proc:command/3 unavailable; using direct mpv_ipc path", []),
            direct_mpv_call(Function, Args, Stack);
        Class:CatchReason:Stack ->
            {error, {exception, Class, CatchReason, Stack}}
    end.

direct_mpv_call(Function, Args, _Stack) ->
    try
        case code:ensure_loaded(mpv_ipc) of
            {module, mpv_ipc} ->
                case erlang:function_exported(mpv_ipc, ensure_started, 0) of
                    true -> _ = mpv_ipc:ensure_started();
                    false -> ok
                end,
                apply(mpv_ipc, Function, Args);
            {error, LoadReason} ->
                {error, {mpv_ipc_not_loaded, LoadReason}}
        end
    catch
        Class:CatchReason:Stacktrace ->
            {error, {exception, Class, CatchReason, Stacktrace}}
    end.

schedule_retry(S = #st{retry_ms = RetryMs}) ->
    schedule_play(RetryMs, S).

schedule_play(Delay, S0) ->
    S = cancel_retry(S0),
    Token = make_ref(),
    TimerRef = erlang:send_after(Delay, self(), {play_default, Token}),
    S#st{retry_timer = {TimerRef, Token}}.

cancel_retry(S = #st{retry_timer = undefined}) ->
    S;
cancel_retry(S = #st{retry_timer = {TimerRef, _Token}}) ->
    cancel_timer(TimerRef),
    S#st{retry_timer = undefined};
cancel_retry(S = #st{retry_timer = TimerRef}) when is_reference(TimerRef) ->
    cancel_timer(TimerRef),
    S#st{retry_timer = undefined}.

cancel_timer(undefined) ->
    ok;
cancel_timer(TimerRef) when is_reference(TimerRef) ->
    _ = erlang:cancel_timer(TimerRef),
    ok;
cancel_timer({TimerRef, _Token}) when is_reference(TimerRef) ->
    cancel_timer(TimerRef).

default_playlist_file() ->
    Tmp = getenv_default("TMPDIR", "/tmp"),
    filename:join(Tmp, "erm-default-random.m3u8").

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
