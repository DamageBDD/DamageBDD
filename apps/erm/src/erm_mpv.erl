%%%-------------------------------------------------------------------
%%% @doc GTK4/gtkgs frontend for the ERM MPV player.
%%%
%%% The frontend owns only logical UI objects. The native widgets belong to
%%% gtkgs/gtknode4 and the MPV operating-system process belongs to
%%% erm_mpv_proc. UI creation is deferred until the C-node handshake is ready,
%%% which keeps the ERM supervision tree healthy while GTK starts.
%%% @end
%%%-------------------------------------------------------------------
-module(erm_mpv).
-behaviour(gen_server).

-include_lib("erm.hrl").
-include_lib("kernel/include/logger.hrl").

-export([show/0, close/0, start/1, start_link/0]).
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(SERVER, ?MODULE).
-define(APP_TITLE, "ERM Media").
-define(UI_RETRY_MS, 1000).
-define(REFRESH_MS, 1000).
-define(MPV_RETRY_MS, 2000).
-define(MPV_RETRY_MAX_MS, 30000).
-define(SEEK_DEBOUNCE_MS, 120).
-define(VOLUME_DEBOUNCE_MS, 80).
-define(DEFAULT_VOLUME, 50).

-record(state, {
    window = undefined,
    ui_monitor = undefined,
    ipc = undefined,
    ipc_monitor = undefined,
    volume = ?DEFAULT_VOLUME,
    ui_retry = undefined,
    refresh_timer = undefined,
    mpv_timer = undefined,
    mpv_retry_ms = ?MPV_RETRY_MS,
    seek_timer = undefined,
    pending_seek = undefined,
    volume_timer = undefined,
    pending_volume = undefined,
    mpv_errors = #{}
}).

%%%===================================================================
%%% Public API
%%%===================================================================

start(Config) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, options_map(Config), []).

start_link() ->
    start(#{}).

show() ->
    call_or_start(show).

close() ->
    case whereis(?SERVER) of
        undefined -> ok;
        _Pid -> safe_server_call(close)
    end.

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init(_Config) ->
    process_flag(trap_exit, true),
    self() ! build_ui,
    RefreshTimer = erlang:send_after(?REFRESH_MS, self(), refresh_playlist),
    MpvTimer = erlang:send_after(0, self(), connect_mpv),
    {ok, #state{refresh_timer = RefreshTimer, mpv_timer = MpvTimer}}.

handle_call(show, _From, State = #state{window = undefined}) ->
    self() ! build_ui,
    {reply, ok, State};
handle_call(show, _From, State) ->
    _ = ui_config(mpv_window, [{show, true}]),
    {reply, ok, State};
handle_call(close, _From, State) ->
    _ = ui_config(mpv_window, [{show, false}]),
    {reply, ok, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_call}, State}.

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info(build_ui, State = #state{window = undefined}) ->
    case build_ui() of
        {ok, Window} ->
            cancel_timer(State#state.ui_retry),
            demonitor_ref(State#state.ui_monitor),
            ReadyState = State#state{
                window = Window,
                ui_monitor = monitor_registered_process(gtkgs),
                ui_retry = undefined
            },
            _ = refresh_playlist(ReadyState),
            {noreply, ReadyState};
        {retry, Reason} ->
            ?LOG_DEBUG("gtkgs media UI not ready: ~p", [Reason]),
            Timer = replace_timer(State#state.ui_retry, ?UI_RETRY_MS, build_ui),
            {noreply, State#state{ui_retry = Timer}};
        {error, Reason} ->
            ?LOG_WARNING("Could not build gtkgs media UI: ~p", [Reason]),
            Timer = replace_timer(State#state.ui_retry, ?UI_RETRY_MS, build_ui),
            {noreply, State#state{ui_retry = Timer}}
    end;
handle_info(build_ui, State) ->
    {noreply, State};

handle_info(connect_mpv, State = #state{ipc = undefined}) ->
    case safe_mpv_connect(ipc_path()) of
        {ok, Ipc} ->
            cancel_timer(State#state.mpv_timer),
            demonitor_ipc(State#state.ipc_monitor),
            ?LOG_INFO("Connected to MPV IPC at ~ts", [ipc_path()]),
            _ = ui_config(playback_detail, [{text, "Connected"}]),
            {noreply, State#state{
                ipc = Ipc,
                ipc_monitor = monitor_ipc(Ipc),
                mpv_timer = undefined,
                mpv_retry_ms = ?MPV_RETRY_MS,
                mpv_errors = maps:remove(connect, State#state.mpv_errors)
            }};
        {error, Reason} ->
            Delay = State#state.mpv_retry_ms,
            Timer = replace_timer(State#state.mpv_timer, Delay, connect_mpv),
            FailedState = report_mpv_error(connect, Reason, State),
            {noreply, FailedState#state{
                mpv_timer = Timer,
                mpv_retry_ms = erlang:min(Delay * 2, ?MPV_RETRY_MAX_MS)
            }}
    end;
handle_info(connect_mpv, State) ->
    {noreply, State#state{mpv_timer = undefined}};

handle_info(refresh_playlist, State) ->
    _ = refresh_playlist(State),
    Timer = replace_timer(State#state.refresh_timer, ?REFRESH_MS, refresh_playlist),
    {noreply, State#state{refresh_timer = Timer}};

handle_info({mpv, status, Status}, State) when is_map(Status) ->
    update_playback_status(Status),
    {noreply, State};
handle_info({mpv, disconnected, Reason}, State) ->
    {noreply, mark_mpv_disconnected(Reason, State)};
handle_info(
    {'DOWN', MonitorRef, process, Ipc, Reason},
    State = #state{ipc = Ipc, ipc_monitor = MonitorRef}
) ->
    {noreply, mark_mpv_disconnected({ipc_process_down, Reason}, State)};
handle_info(
    {'DOWN', MonitorRef, port, Ipc, Reason},
    State = #state{ipc = Ipc, ipc_monitor = MonitorRef}
) ->
    {noreply, mark_mpv_disconnected({ipc_port_down, Reason}, State)};
handle_info(
    {'DOWN', MonitorRef, process, _GtkgsPid, Reason},
    State = #state{ui_monitor = MonitorRef}
) ->
    ?LOG_WARNING("gtkgs media UI transport stopped: ~p", [Reason]),
    Timer = replace_timer(State#state.ui_retry, ?UI_RETRY_MS, build_ui),
    {noreply, State#state{
        window = undefined,
        ui_monitor = undefined,
        ui_retry = Timer
    }};

%% Transport controls.
handle_info({gtkgs, previous_button, click, _Data, _Args}, State) ->
    {noreply, play_selected(safe_playlist(prev), State)};
handle_info({gtkgs, play_button, click, _Data, _Args}, State) ->
    {noreply, mpv_action(toggle_pause, [], State)};
handle_info({gtkgs, next_button, click, _Data, _Args}, State) ->
    {noreply, play_selected(safe_playlist(next), State)};
%% Playlist and library actions.
handle_info({gtkgs, playlist_list, select, _Data, [Index, _Text, true]}, State)
    when is_integer(Index), Index >= 0
->
    case safe_playlist(get_by_index, [Index]) of
        {ok, Track} -> {noreply, play_track(Track, State)};
        {error, Reason} ->
            update_status(io_lib:format("Could not select track: ~p", [Reason])),
            {noreply, State};
        Other ->
            update_status(io_lib:format("Unexpected playlist reply: ~p", [Other])),
            {noreply, State}
    end;
handle_info({gtkgs, like_button, click, _Data, _Args}, State) ->
    case safe_playlist(toggle_like_current) of
        {error, Reason} ->
            update_status(io_lib:format("Could not update favourite: ~p", [Reason]));
        _ ->
            _ = refresh_playlist(State)
    end,
    {noreply, State};
handle_info({gtkgs, share_button, click, _Data, _Args}, State) ->
    share_current(State),
    {noreply, State};
handle_info({gtkgs, ipfs_button, click, _Data, _Args}, State) ->
    add_current_to_ipfs(State),
    {noreply, State};
handle_info({gtkgs, rescan_button, click, _Data, _Args}, State) ->
    case safe_playlist(rescan_all) of
        {error, Reason} ->
            update_status(io_lib:format("Playlist rescan failed: ~p", [Reason]));
        _ ->
            _ = refresh_playlist(State),
            update_status("Playlist rescan complete")
    end,
    {noreply, State};
handle_info({gtkgs, clear_button, click, _Data, _Args}, State) ->
    case safe_playlist(clear) of
        {error, Reason} ->
            update_status(io_lib:format("Could not clear playlist: ~p", [Reason]));
        _ ->
            _ = refresh_playlist(State),
            update_status("Playlist cleared")
    end,
    {noreply, State};
handle_info({gtkgs, add_folder_button, click, _Data, _Args}, State) ->
    add_folder_from_entry(State),
    {noreply, State};
handle_info({gtkgs, folder_entry, keypress, _Data, ['Return', _Text]}, State) ->
    add_folder_from_entry(State),
    {noreply, State};

%% Continuous controls. Programmatic GTK changes are suppressed natively, so
%% MPV status updates do not feed back into seek commands.
handle_info({gtkgs, seek_scale, change, _Data, [#{value := Value}]}, State)
    when is_number(Value)
->
    Percent = clamp(float(Value) / 10.0, 0.0, 100.0),
    Timer = replace_tagged_timer(
        State#state.seek_timer,
        ?SEEK_DEBOUNCE_MS,
        apply_seek
    ),
    {noreply, State#state{seek_timer = Timer, pending_seek = Percent}};
handle_info({gtkgs, volume_scale, change, _Data, [#{value := Value}]}, State)
    when is_number(Value)
->
    Volume = clamp(round(Value), 0, 100),
    _ = ui_config(volume_value, [{text, volume_text(Volume)}]),
    Timer = replace_tagged_timer(
        State#state.volume_timer,
        ?VOLUME_DEBOUNCE_MS,
        apply_volume
    ),
    {noreply, State#state{
        volume = Volume,
        volume_timer = Timer,
        pending_volume = Volume
    }};
handle_info(
    {apply_seek, Token},
    State = #state{seek_timer = {_TimerRef, Token}, pending_seek = Percent}
) when is_number(Percent) ->
    NextState = mpv_action(seek_percent, [Percent], State),
    {noreply, NextState#state{seek_timer = undefined, pending_seek = undefined}};
handle_info({apply_seek, _StaleToken}, State) ->
    {noreply, State};
handle_info(
    {apply_volume, Token},
    State = #state{volume_timer = {_TimerRef, Token}, pending_volume = Volume}
) when is_integer(Volume) ->
    NextState = mpv_action(set_volume, [Volume], State),
    {noreply, NextState#state{volume_timer = undefined, pending_volume = undefined}};
handle_info({apply_volume, _StaleToken}, State) ->
    {noreply, State};

handle_info({gtkgs, close_button, click, _Data, _Args}, State) ->
    _ = ui_config(mpv_window, [{show, false}]),
    {noreply, State};
handle_info({gtkgs, mpv_window, destroy, _Data, _Args}, State) ->
    {noreply, State#state{window = undefined}};
handle_info({gtkgs, _Object, _Event, _Data, _Args}, State) ->
    {noreply, State};
handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    cancel_timer(State#state.ui_retry),
    cancel_timer(State#state.refresh_timer),
    cancel_timer(State#state.mpv_timer),
    cancel_timer(State#state.seek_timer),
    cancel_timer(State#state.volume_timer),
    demonitor_ref(State#state.ui_monitor),
    demonitor_ipc(State#state.ipc_monitor),
    case State#state.window of
        undefined -> ok;
        _ -> best_effort(fun() -> gtkgs:destroy(mpv_window) end)
    end,
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% GTK UI
%%%===================================================================

build_ui() ->
    case {whereis(gtkgs), whereis(gtknode4)} of
        {undefined, _} ->
            {retry, gtkgs_not_started};
        {_, undefined} ->
            {retry, gtknode4_not_started};
        {Gtkgs, _Controller} ->
            case safe_gtknode4_ready() of
                ok -> create_ui_tree(Gtkgs);
                {error, Reason} -> {retry, Reason}
            end
    end.

create_ui_tree(Gtkgs) ->
    Tree = [
        {window, mpv_window,
            [
                {title, ?APP_TITLE},
                {width, 920},
                {height, 720},
                {min_width, 360},
                {min_height, 520},
                {show, true}
            ],
            [
                {frame, main_column,
                    [
                        {orient, vertical},
                        {spacing, 12},
                        {margin, 16},
                        {expand, true}
                    ],
                    [
                        {label, title_label,
                            [{text, "ERM Media"}, {class, 'title-1'}, {align, start}]},
                        {label, now_playing,
                            [
                                {text, "Nothing playing"},
                                {class, 'title-3'},
                                {align, start},
                                {wrap, true}
                            ]},
                        {label, playback_detail,
                            [{text, "MPV is connecting…"}, {align, start}, {class, 'dim-label'}]},
                        {frame, transport_row,
                            [{orient, horizontal}, {spacing, 8}, {homogeneous, true}],
                            [
                                touch_button(previous_button, "⏮  Previous", "Previous track"),
                                touch_button(play_button, "⏯  Play / Pause", "Toggle playback"),
                                touch_button(next_button, "Next  ⏭", "Next track")
                            ]},
                        {frame, seek_row,
                            [{orient, horizontal}, {spacing, 8}],
                            [
                                {label, elapsed_label, [{text, "0:00"}, {width_chars, 6}]},
                                {scale, seek_scale,
                                    [
                                        {min, 0},
                                        {max, 1000},
                                        {step, 1},
                                        {value, 0},
                                        {expand, true},
                                        {draw_value, false},
                                        {tooltip, "Playback position"}
                                    ]},
                                {label, duration_label, [{text, "0:00"}, {width_chars, 6}]}
                            ]},
                        {frame, volume_row,
                            [{orient, horizontal}, {spacing, 8}],
                            [
                                {label, volume_label, [{text, "Volume"}, {width_chars, 8}]},
                                {scale, volume_scale,
                                    [
                                        {min, 0},
                                        {max, 100},
                                        {step, 1},
                                        {value, ?DEFAULT_VOLUME},
                                        {expand, true},
                                        {draw_value, false},
                                        {tooltip, "Playback volume"}
                                    ]},
                                {label, volume_value,
                                    [{text, volume_text(?DEFAULT_VOLUME)}, {width_chars, 5}]}
                            ]},
                        {frame, folder_row,
                            [{orient, horizontal}, {spacing, 8}],
                            [
                                {entry, folder_entry,
                                    [
                                        {placeholder, "Music folder path"},
                                        {expand, true},
                                        {tooltip, "Enter a local media folder"}
                                    ]},
                                touch_button(add_folder_button, "Add folder", "Add media recursively"),
                                touch_button(rescan_button, "Rescan", "Rescan playlist folders")
                            ]},
                        {frame, library_row,
                            [{orient, horizontal}, {spacing, 8}, {homogeneous, true}],
                            [
                                touch_button(like_button, "☆  Like", "Like or unlike current track"),
                                touch_button(ipfs_button, "Add to IPFS", "Pin current track to IPFS"),
                                touch_button(share_button, "Share", "Copy the current IPFS URL"),
                                touch_button(clear_button, "Clear", "Clear the playlist"),
                                touch_button(close_button, "Hide", "Hide this window")
                            ]},
                        {label, playlist_heading,
                            [{text, "Playlist"}, {class, heading}, {align, start}]},
                        {listbox, playlist_list,
                            [
                                {items, []},
                                {expand, true},
                                {min_height, 220},
                                {selection, single},
                                {tooltip, "Select a track to play"}
                            ]},
                        {label, status_label,
                            [
                                {text, "Ready"},
                                {align, start},
                                {wrap, true},
                                {class, 'dim-label'}
                            ]}
                    ]}
            ]}
    ],
    try gtkgs:create_tree(Gtkgs, Tree) of
        {ok, [Window]} -> {ok, Window};
        {error, CreateReason} -> {error, CreateReason};
        Other -> {error, {unexpected_create_tree_reply, Other}}
    catch
        Class:ExceptionReason:Stacktrace ->
            {error, {create_tree_failed, Class, ExceptionReason, Stacktrace}}
    end.

touch_button(Name, Label, Tooltip) ->
    {button, Name,
        [
            {label, Label},
            {tooltip, Tooltip},
            {min_height, 48},
            {expand, true}
        ]}.

%%%===================================================================
%%% Media actions
%%%===================================================================

add_folder_from_entry(State) ->
    case ui_read(folder_entry, text) of
        Path0 when is_binary(Path0); is_list(Path0) ->
            Path = string:trim(to_text(Path0)),
            case Path of
                [] ->
                    update_status("Enter a media folder path first");
                _ ->
                    case safe_playlist(add_files, [Path, true]) of
                        {error, Reason} -> update_status(io_lib:format("Could not add folder: ~p", [Reason]));
                        _ ->
                            _ = refresh_playlist(State),
                            update_status(io_lib:format("Added folder: ~ts", [Path]))
                    end
            end;
        Error ->
            update_status(io_lib:format("Could not read folder path: ~p", [Error]))
    end.

add_current_to_ipfs(State) ->
    case safe_playlist(current) of
        {ok, Track} ->
            update_status("Adding current track to IPFS…"),
            case safe_apply(ipfs_client, add_and_pin, [Track#track.path]) of
                {ok, Cid} ->
                    case safe_playlist(update_cid, [Track#track.id, Cid]) of
                        {error, UpdateReason} ->
                            update_status(io_lib:format(
                                "Pinned to IPFS, but playlist update failed: ~p",
                                [UpdateReason]
                            ));
                        _ ->
                            _ = refresh_playlist(State),
                            update_status(io_lib:format("Pinned to IPFS: ~ts", [to_text(Cid)]))
                    end;
                Error ->
                    update_status(io_lib:format("IPFS add failed: ~p", [Error]))
            end;
        _ ->
            update_status("Select a track first")
    end.

share_current(_State) ->
    case safe_playlist(current) of
        {ok, Track} when Track#track.cid =/= undefined ->
            Url = safe_apply(ipfs_client, gateway_url, [Track#track.cid]),
            case Url of
                {error, Reason} -> update_status(io_lib:format("Share failed: ~p", [Reason]));
                _ ->
                    case copy_to_clipboard(Url) of
                        ok -> update_status(io_lib:format("Copied: ~ts", [to_text(Url)]));
                        {error, ClipboardReason} ->
                            update_status(io_lib:format(
                                "Clipboard unavailable: ~p", [ClipboardReason]
                            ))
                    end
            end;
        {ok, _Track} ->
            update_status("Add the current track to IPFS first");
        _ ->
            update_status("Select a track first")
    end.

refresh_playlist(#state{window = undefined}) ->
    ok;
refresh_playlist(_State) ->
    Tracks =
        case safe_playlist(all) of
            Value when is_list(Value) -> Value;
            _ -> []
        end,
    Items = [playlist_item(Index, Track) || {Index, Track} <- Tracks],
    _ = ui_config(playlist_list, [{items, Items}]),
    update_current_labels(),
    ok.

playlist_item(Index, Track) ->
    Liked =
        case Track#track.liked of
            true -> "★";
            _ -> " "
        end,
    Cid =
        case Track#track.cid of
            undefined -> "local";
            Value -> short_cid(Value)
        end,
    io_lib:format("~s  ~3B  ~ts   ·   ~ts", [Liked, Index + 1, display_title(Track), Cid]).

update_current_labels() ->
    case safe_playlist(current) of
        {ok, Track} ->
            _ = ui_config(now_playing, [{text, display_title(Track)}]),
            LikeLabel =
                case Track#track.liked of
                    true -> "★  Liked";
                    _ -> "☆  Like"
                end,
            _ = ui_config(like_button, [{label, LikeLabel}]),
            ok;
        _ ->
            _ = ui_config(now_playing, [{text, "Nothing playing"}]),
            _ = ui_config(like_button, [{label, "☆  Like"}]),
            ok
    end.

play_selected({ok, Track}, State) ->
    play_track(Track, State);
play_selected({error, Reason}, State) ->
    update_status(io_lib:format("Could not change track: ~p", [Reason])),
    State;
play_selected(Other, State) ->
    update_status(io_lib:format("Unexpected playlist reply: ~p", [Other])),
    State.

play_track(Track, State) ->
    case call_mpv(load_file, [Track#track.path], State) of
        {error, _Reason, FailedState} ->
            FailedState;
        {ok, _Reply, ReadyState} ->
            _ = ui_config(now_playing, [{text, display_title(Track)}]),
            case safe_playlist(set_current, [Track#track.id]) of
                {error, PlaylistReason} ->
                    update_status(io_lib:format(
                        "Playing, but playlist state could not be updated: ~p",
                        [PlaylistReason]
                    ));
                _ ->
                    update_status("Playing")
            end,
            ReadyState
    end.

update_playback_status(Status) ->
    Percent = map_value(["percent-pos", <<"percent-pos">>, percent_pos], Status, undefined),
    Position = map_value(["time-pos", <<"time-pos">>, time_pos], Status, undefined),
    Duration = map_value([duration, "duration", <<"duration">>], Status, undefined),
    Paused = map_value([pause, "pause", <<"pause">>], Status, undefined),
    case Percent of
        Value when is_number(Value) ->
            _ = ui_config(seek_scale, [{value, clamp(Value * 10, 0, 1000)}]);
        _ -> ok
    end,
    _ = ui_config(elapsed_label, [{text, duration_text(Position)}]),
    _ = ui_config(duration_label, [{text, duration_text(Duration)}]),
    Detail =
        case Paused of
            true -> "Paused";
            false -> "Playing";
            _ -> "Connected"
        end,
    _ = ui_config(playback_detail, [{text, Detail}]),
    ok.

%%%===================================================================
%%% Safe integration helpers
%%%===================================================================

call_or_start(Request) ->
    case whereis(?SERVER) of
        undefined ->
            case start(#{}) of
                {ok, _Pid} -> safe_server_call(Request);
                {error, {already_started, _Pid}} -> safe_server_call(Request);
                Error -> Error
            end;
        _Pid -> safe_server_call(Request)
    end.

safe_server_call(Request) ->
    try gen_server:call(?SERVER, Request) of
        Reply -> Reply
    catch
        exit:Reason -> {error, {erm_mpv_unavailable, Reason}}
    end.

safe_mpv_connect(Path) ->
    case safe_mpv(connect, [Path]) of
        {ok, Ipc} -> {ok, Ipc};
        {error, Reason} -> {error, Reason};
        Other -> {error, {unexpected_connect_reply, Other}}
    end.

safe_mpv(Function, Args) ->
    safe_apply_quiet(mpv_ipc, Function, Args).

mpv_action(Function, Args, State) ->
    case call_mpv(Function, Args, State) of
        {ok, _Reply, NextState} -> NextState;
        {error, _Reason, NextState} -> NextState
    end.

call_mpv(Function, _Args, State = #state{ipc = undefined}) ->
    WaitingState = ensure_mpv_connect(State),
    FailedState = report_mpv_error(Function, not_connected, WaitingState),
    {error, not_connected, FailedState};
call_mpv(Function, Args, State) ->
    case safe_mpv(Function, Args) of
        {error, Reason} ->
            FailedState = report_mpv_error(Function, Reason, State),
            {error, Reason, FailedState};
        Reply ->
            {ok, Reply, clear_mpv_error(Function, State)}
    end.

ensure_mpv_connect(State = #state{mpv_timer = undefined}) ->
    Timer = erlang:send_after(0, self(), connect_mpv),
    State#state{mpv_timer = Timer};
ensure_mpv_connect(State) ->
    State.

mark_mpv_disconnected(Reason, State) ->
    demonitor_ipc(State#state.ipc_monitor),
    Timer = replace_timer(State#state.mpv_timer, 0, connect_mpv),
    DisconnectedState = State#state{
        ipc = undefined,
        ipc_monitor = undefined,
        mpv_timer = Timer,
        mpv_retry_ms = ?MPV_RETRY_MS
    },
    report_mpv_error(disconnected, Reason, DisconnectedState).

report_mpv_error(Function, Reason, State = #state{mpv_errors = Errors}) ->
    Summary = mpv_error_summary(Reason),
    case maps:get(Function, Errors, undefined) of
        Summary ->
            ok;
        _Previous ->
            log_mpv_error(Function, Reason)
    end,
    update_status(io_lib:format("MPV ~p failed: ~p", [Function, Summary])),
    State#state{mpv_errors = maps:put(Function, Summary, Errors)}.

clear_mpv_error(Function, State = #state{mpv_errors = Errors}) ->
    State#state{mpv_errors = maps:remove(Function, Errors)}.

mpv_error_summary({exception, Class, Reason, _Stacktrace}) ->
    {Class, Reason};
mpv_error_summary(Reason) ->
    Reason.

log_mpv_error(Function, {exception, Class, Reason, Stacktrace}) ->
    ?LOG_WARNING("mpv_ipc:~p failed: ~p:~p~n~p", [
        Function, Class, Reason, Stacktrace
    ]);
log_mpv_error(Function, Reason) ->
    ?LOG_WARNING("mpv_ipc:~p failed: ~p", [Function, Reason]).

safe_apply_quiet(Module, Function, Args) ->
    _ = code:ensure_loaded(Module),
    case erlang:function_exported(Module, Function, length(Args)) of
        false ->
            {error, {not_exported, Module, Function, length(Args)}};
        true ->
            try apply(Module, Function, Args) of
                Reply -> Reply
            catch
                Class:Reason:Stacktrace ->
                    {error, {exception, Class, Reason, Stacktrace}}
            end
    end.

safe_playlist(Function) ->
    safe_playlist(Function, []).

safe_playlist(Function, Args) ->
    safe_apply_quiet(playlist, Function, Args).

safe_apply(Module, Function, Args) ->
    _ = code:ensure_loaded(Module),
    case erlang:function_exported(Module, Function, length(Args)) of
        false -> {error, {not_exported, Module, Function, length(Args)}};
        true ->
            try apply(Module, Function, Args) of
                Reply -> Reply
            catch
                Class:Reason:Stacktrace ->
                    ?LOG_DEBUG("~p:~p/~B failed: ~p:~p~n~p", [
                        Module, Function, length(Args), Class, Reason, Stacktrace
                    ]),
                    {error, {Class, Reason}}
            end
    end.

ui_config(Name, Options) ->
    try gtkgs:config(Name, Options) catch
        _:_ -> {error, ui_not_ready}
    end.

ui_read(Name, Key) ->
    try gtkgs:read(Name, Key) catch
        _:_ -> {error, ui_not_ready}
    end.

safe_gtknode4_ready() ->
    try gtknode4:await_ready(0) of
        ok -> ok;
        {error, _Reason} = Error -> Error;
        Other -> {error, {unexpected_gtknode4_status, Other}}
    catch
        exit:{noproc, _} -> {error, gtknode4_not_started};
        Class:Reason:Stacktrace ->
            {error, {gtknode4_status_failed, Class, Reason, Stacktrace}}
    end.

update_status(Text) ->
    ui_config(status_label, [{text, unicode:characters_to_binary(Text)}]).

best_effort(Fun) ->
    try Fun() of
        _ -> ok
    catch
        _:_ -> ok
    end.

copy_to_clipboard(Value) ->
    case os:find_executable("xclip") of
        false ->
            {error, xclip_not_found};
        Xclip ->
            try open_port({spawn_executable, Xclip}, [
                binary, exit_status, {args, ["-selection", "clipboard"]}
            ]) of
                Port ->
                    write_clipboard_port(
                        Port,
                        unicode:characters_to_binary(to_text(Value))
                    )
            catch
                Class:Reason -> {error, {clipboard_failed, Class, Reason}}
            end
    end.

write_clipboard_port(Port, Data) ->
    try port_command(Port, Data) of
        true -> ok;
        false -> {error, clipboard_port_closed}
    catch
        Class:Reason -> {error, {clipboard_write_failed, Class, Reason}}
    after
        safe_port_close(Port)
    end.

safe_port_close(Port) when is_port(Port) ->
    try erlang:port_close(Port) of
        _ -> ok
    catch
        error:badarg -> ok
    end;
safe_port_close(_Port) ->
    ok.

monitor_ipc(Ipc) when is_pid(Ipc) ->
    erlang:monitor(process, Ipc);
monitor_ipc(Ipc) when is_port(Ipc) ->
    erlang:monitor(port, Ipc);
monitor_ipc(_Ipc) ->
    undefined.

demonitor_ipc(undefined) ->
    ok;
demonitor_ipc(MonitorRef) when is_reference(MonitorRef) ->
    _ = erlang:demonitor(MonitorRef, [flush]),
    ok.

monitor_registered_process(Name) ->
    case whereis(Name) of
        Pid when is_pid(Pid) -> erlang:monitor(process, Pid);
        undefined -> undefined
    end.

demonitor_ref(undefined) ->
    ok;
demonitor_ref(MonitorRef) when is_reference(MonitorRef) ->
    _ = erlang:demonitor(MonitorRef, [flush]),
    ok.

%%%===================================================================
%%% Formatting and utility helpers
%%%===================================================================

display_title(Track) ->
    filename:basename(Track#track.path).

short_cid(Value) ->
    Text = to_text(Value),
    case length(Text) > 16 of
        true -> lists:sublist(Text, 8) ++ "…" ++ lists:nthtail(length(Text) - 6, Text);
        false -> Text
    end.

volume_text(Volume) ->
    io_lib:format("~B%", [Volume]).

duration_text(Value) when is_number(Value), Value >= 0 ->
    Total = trunc(Value),
    Hours = Total div 3600,
    Minutes = (Total rem 3600) div 60,
    Seconds = Total rem 60,
    case Hours of
        0 -> io_lib:format("~B:~2..0B", [Minutes, Seconds]);
        _ -> io_lib:format("~B:~2..0B:~2..0B", [Hours, Minutes, Seconds])
    end;
duration_text(_) ->
    "0:00".

map_value([], _Map, Default) -> Default;
map_value([Key | Rest], Map, Default) ->
    case maps:find(Key, Map) of
        {ok, Value} -> Value;
        error -> map_value(Rest, Map, Default)
    end.

clamp(Value, Min, _Max) when Value < Min -> Min;
clamp(Value, _Min, Max) when Value > Max -> Max;
clamp(Value, _Min, _Max) -> Value.

ipc_path() ->
    getenv_default("MPV_IPC", "/tmp/mpv.sock").

getenv_default(Name, Default) ->
    case os:getenv(Name) of
        false -> Default;
        "" -> Default;
        Value -> Value
    end.

to_text(Value) when is_binary(Value) -> unicode:characters_to_list(Value);
to_text(Value) when is_atom(Value) -> atom_to_list(Value);
to_text(Value) when is_list(Value) -> lists:flatten(Value);
to_text(Value) -> lists:flatten(io_lib:format("~p", [Value])).

replace_timer(undefined, Delay, Message) ->
    erlang:send_after(Delay, self(), Message);
replace_timer(Timer, Delay, Message) ->
    cancel_timer(Timer),
    erlang:send_after(Delay, self(), Message).

replace_tagged_timer(Timer, Delay, Tag) ->
    cancel_timer(Timer),
    Token = make_ref(),
    TimerRef = erlang:send_after(Delay, self(), {Tag, Token}),
    {TimerRef, Token}.

cancel_timer(undefined) -> ok;
cancel_timer({TimerRef, _Token}) when is_reference(TimerRef) ->
    _ = erlang:cancel_timer(TimerRef),
    ok;
cancel_timer(Timer) ->
    _ = erlang:cancel_timer(Timer),
    ok.

options_map(Map) when is_map(Map) -> Map;
options_map(List) when is_list(List) -> maps:from_list(List);
options_map(undefined) -> #{}.
