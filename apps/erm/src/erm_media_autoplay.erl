%%%-------------------------------------------------------------------
%%% @doc Supervised ERM media autoplay worker.
%%%
%%% Builds a shuffled M3U playlist from all default media directories and
%%% tells the existing MPV IPC layer to play that playlist. MPV then owns
%%% continuous playback through the shuffled list.
%%% @end
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
-record(st, {
    playlist_file,
    retry_ms = ?RETRY_DELAY_MS
}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

play_default() ->
    gen_server:cast(?MODULE, play_default).

playlist_path() ->
    default_playlist_file().

init([]) ->
    erlang:send_after(?BOOT_DELAY_MS, self(), play_default),
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
handle_info(_Msg, S) ->
    {noreply, S}.

terminate(_Reason, _S) -> ok.
code_change(_OldVsn, S, _Extra) -> {ok, S}.

%% ——— Internal helpers ———
do_play_default(S = #st{playlist_file = PlaylistFile, retry_ms = RetryMs}) ->
    case ensure_playlist() of
        ok ->
            case playlist:load_default(shuffle) of
                {ok, 0} ->
                    ?LOG_WARNING(
                        "ERM media autoplay found no media files in default dirs ~p",
                        [playlist:default_media_dirs()]
                    ),
                    {{error, no_media}, S};
                {ok, Count} ->
                    Tracks = [T || {_Idx, T} <- playlist:all()],
                    case write_m3u(PlaylistFile, Tracks) of
                        ok ->
                            case start_mpv_playlist(PlaylistFile) of
                                ok ->
                                    ?LOG_INFO(
                                        "ERM media autoplay started ~p shuffled tracks from ~s",
                                        [Count, PlaylistFile]
                                    ),
                                    {ok, S};
                                {error, Reason} ->
                                    ?LOG_WARNING("MPV autoplay failed: ~p; retrying", [Reason]),
                                    erlang:send_after(RetryMs, self(), play_default),
                                    {{error, Reason}, S}
                            end;
                        {error, Reason} ->
                            ?LOG_WARNING("Could not write MPV playlist ~s: ~p", [
                                PlaylistFile, Reason
                            ]),
                            {{error, Reason}, S}
                    end
            end;
        {error, Reason} ->
            ?LOG_WARNING("Playlist process unavailable: ~p; retrying", [Reason]),
            erlang:send_after(RetryMs, self(), play_default),
            {{error, Reason}, S}
    end.

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

start_mpv_playlist(PlaylistFile) ->
    try
        case ensure_mpv_ipc() of
            ok ->
                case safe_mpv_call(connect, [?IPC_PATH]) of
                    {ok, _Ipc} ->
                        load_mpv_playlist(PlaylistFile);
                    ok ->
                        load_mpv_playlist(PlaylistFile);
                    {error, Reason} ->
                        {error, {mpv_ipc_connect_failed, ?IPC_PATH, Reason}};
                    Other ->
                        ?LOG_WARNING("Unexpected MPV IPC connect result: ~p", [Other]),
                        {error, {mpv_ipc_connect_failed, ?IPC_PATH, Other}}
                end;
            {error, Reason} ->
                {error, {mpv_ipc_unavailable, Reason}};
            Other ->
                {error, {mpv_ipc_unavailable, Other}}
        end
    catch
        error:Reason0:Stack0 ->
            {error, {exception, error, Reason0, Stack0}};
        exit:Reason0:Stack0 ->
            {error, {exception, exit, Reason0, Stack0}};
        throw:Reason0:Stack0 ->
            {error, {exception, throw, Reason0, Stack0}}
    end.

load_mpv_playlist(PlaylistFile) ->
    %% Prefer MPV's playlist command.
    %% Fall back to load_file/1 only if load_list/1 has not been added yet.
    Fun =
        case erlang:function_exported(mpv_ipc, load_list, 1) of
            true -> load_list;
            false -> load_file
        end,

    case safe_mpv_call(Fun, [PlaylistFile]) of
        ok ->
            ok;
        {ok, _} ->
            ok;
        {error, Reason} ->
            {error, {mpv_ipc_load_failed, Fun, PlaylistFile, Reason}};
        Other ->
            ?LOG_DEBUG("mpv_ipc:~p returned ~p", [Fun, Other]),
            ok
    end.

safe_mpv_call(Function, Args) ->
    try apply(mpv_ipc, Function, Args) of
        Reply ->
            Reply
    catch
        error:Reason:Stack ->
            {error, {exception, error, Reason, Stack}};
        exit:Reason:Stack ->
            {error, {exception, exit, Reason, Stack}};
        throw:Reason:Stack ->
            {error, {exception, throw, Reason, Stack}}
    end.

ensure_mpv_ipc() ->
    try
        case code:ensure_loaded(mpv_ipc) of
            {module, mpv_ipc} ->
                ensure_mpv_ipc_loaded();
            {error, Reason} ->
                {error, {mpv_ipc_not_loaded, Reason}}
        end
    of
        Reply ->
            Reply
    catch
        error:Reason0:Stack ->
            {error, {exception, error, Reason0, Stack}};
        exit:Reason1:Stack ->
            {error, {exception, exit, Reason1, Stack}};
        throw:Reason2:Stack ->
            {error, {exception, throw, Reason2, Stack}}
    end.

ensure_mpv_ipc_loaded() ->
    case erlang:function_exported(mpv_ipc, ensure_started, 0) of
        true ->
            case safe_mpv_call(ensure_started, []) of
                ok ->
                    ok;
                {ok, _} ->
                    ok;
                {error, Reason} ->
                    {error, Reason};
                Other ->
                    {error, {unexpected_ensure_started_reply, Other}}
            end;
        false ->
            case path_exists(?IPC_PATH) of
                true ->
                    ok;
                false ->
                    {error, {missing_mpv_ipc_socket, ?IPC_PATH}}
            end
    end.

path_exists(Path) ->
    case file:read_file_info(Path) of
        {ok, _Info} -> true;
        {error, _} -> false
    end.

default_playlist_file() ->
    Tmp = getenv_default("TMPDIR", "/tmp"),
    filename:join(Tmp, "erm-default-random.m3u8").

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
