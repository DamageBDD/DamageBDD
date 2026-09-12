%%%-------------------------------------------------------------------
%%% @doc GTK4/gtkgs frontend for the ERM MPV player.
%%%
%%% The frontend owns only logical UI objects. The native widgets belong to
%%% gtkgs/gtknode4 and the MPV operating-system process belongs to
%%% erm_mpv_proc. UI creation is deferred until the C-node handshake is ready,
%%% which keeps the ERM supervision tree healthy while GTK starts. MPV itself
%%% is kept hidden by erm_mpv_proc and all controls use bounded owner-mediated
%%% IPC calls.
%%% @end
%%%-------------------------------------------------------------------
-module(erm_mpv).
-behaviour(gen_server).

-include_lib("erm.hrl").
-include_lib("kernel/include/logger.hrl").
-include("erm_log.hrl").

-export([
    show/0,
    close/0,
    start/1,
    start_link/0,
    set_layout/1,
    reload_layout/0,
    set_theme/1,
    reload_theme/0,
    stop_mpv/0,
    restart_mpv/0
]).
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
-define(MPV_CMD_TIMEOUT_MS, 3000).
-define(SEEK_DEBOUNCE_MS, 120).
-define(VOLUME_DEBOUNCE_MS, 80).
-define(DEFAULT_VOLUME, 50).
-define(DEFAULT_LAYOUT, classic).
-define(DEFAULT_THEME, "cyberpunk").
-define(LOG_DOMAIN, ?ERM_LOG_DOMAIN_MPV_UI).
-define(LOG_META, ?ERM_LOG_META(?LOG_DOMAIN)).

-record(state, {
    window = undefined,
    ui_monitor = undefined,
    ipc = undefined,
    ipc_monitor = undefined,
    volume = ?DEFAULT_VOLUME,
    playback_state = idle,
    loaded_track_id = undefined,
    loaded_track_path = undefined,
    layout = ?DEFAULT_LAYOUT,
    theme = ?DEFAULT_THEME,
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

stop_mpv() ->
    call_or_start(stop_mpv).

restart_mpv() ->
    call_or_start(restart_mpv).

set_layout(Layout) when Layout =:= classic; Layout =:= compact; Layout =:= playlist ->
    call_or_start({set_layout, Layout});
set_layout(Layout) ->
    {error, {bad_layout, Layout}}.

reload_layout() ->
    call_or_start(reload_layout).

set_theme(Theme0) ->
    case resource_name(Theme0) of
        {ok, Theme} -> call_or_start({set_theme, Theme});
        {error, _Reason} = Error -> Error
    end.

reload_theme() ->
    call_or_start(reload_theme).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init(_Config) ->
    init_logging(),
    process_flag(trap_exit, true),
    Layout = saved_layout(),
    Theme = saved_theme(),
    self() ! build_ui,
    RefreshTimer = erlang:send_after(?REFRESH_MS, self(), refresh_playlist),
    MpvTimer = erlang:send_after(0, self(), connect_mpv),
    {ok, #state{
        layout = Layout,
        theme = Theme,
        refresh_timer = RefreshTimer,
        mpv_timer = MpvTimer
    }}.

handle_call(show, _From, State = #state{window = undefined}) ->
    self() ! build_ui,
    {reply, ok, State};
handle_call(show, _From, State) ->
    _ = ui_config(mpv_window, [{show, true}]),
    {reply, ok, State};
handle_call(close, _From, State) ->
    _ = ui_config(mpv_window, [{show, false}]),
    {reply, ok, State};
handle_call(stop_mpv, _From, State) ->
    {Reply, State1} = stop_playback(State),
    {reply, Reply, State1};
handle_call(restart_mpv, _From, State) ->
    {Reply, State1} = restart_backend(State),
    {reply, Reply, State1};
handle_call({set_layout, Layout}, _From, State) ->
    save_layout(Layout),
    _ = apply_layout(Layout),
    {reply, ok, State#state{layout = Layout}};
handle_call(reload_layout, _From, State) ->
    {reply, apply_layout(State#state.layout), State};
handle_call({set_theme, Theme}, _From, State) ->
    save_theme(Theme),
    Reply = apply_mpv_theme(Theme),
    {reply, Reply, State#state{theme = Theme}};
handle_call(reload_theme, _From, State) ->
    {reply, apply_mpv_theme(State#state.theme), State};
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
            _ = apply_mpv_theme(ReadyState#state.theme),
            _ = apply_layout(ReadyState#state.layout),
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
handle_info(refresh_playlist, State0) ->
    _ = refresh_playlist(State0),
    State1 = refresh_mpv_status(State0),
    Timer = replace_timer(State1#state.refresh_timer, ?REFRESH_MS, refresh_playlist),
    {noreply, State1#state{refresh_timer = Timer}};
handle_info({mpv, status, Status}, State) when is_map(Status) ->
    {noreply, apply_playback_status(Status, State)};
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
    {noreply, play_or_recover(State)};
handle_info({gtkgs, next_button, click, _Data, _Args}, State) ->
    {noreply, play_selected(safe_playlist(next), State)};
%% Playlist and library actions.
handle_info({gtkgs, playlist_list, select, _Data, [Index, _Text, true]}, State) when
    is_integer(Index), Index >= 0
->
    case safe_playlist(get_by_index, [Index]) of
        {ok, Track} ->
            {noreply, play_track(Track, State)};
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
handle_info({gtkgs, seek_scale, change, _Data, [#{value := Value}]}, State) when
    is_number(Value)
->
    Percent = clamp(float(Value) / 10.0, 0.0, 100.0),
    Timer = replace_tagged_timer(
        State#state.seek_timer,
        ?SEEK_DEBOUNCE_MS,
        apply_seek
    ),
    {noreply, State#state{seek_timer = Timer, pending_seek = Percent}};
handle_info({gtkgs, volume_scale, change, _Data, [#{value := Value}]}, State) when
    is_number(Value)
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
handle_info({gtkgs, layout_classic_button, click, _Data, _Args}, State) ->
    save_layout(classic),
    _ = apply_layout(classic),
    {noreply, State#state{layout = classic}};
handle_info({gtkgs, layout_compact_button, click, _Data, _Args}, State) ->
    save_layout(compact),
    _ = apply_layout(compact),
    {noreply, State#state{layout = compact}};
handle_info({gtkgs, layout_playlist_button, click, _Data, _Args}, State) ->
    save_layout(playlist),
    _ = apply_layout(playlist),
    {noreply, State#state{layout = playlist}};
handle_info({gtkgs, stop_button, click, _Data, _Args}, State) ->
    {_Reply, State1} = stop_playback(State),
    {noreply, State1};
handle_info({gtkgs, restart_backend_button, click, _Data, _Args}, State) ->
    {_Reply, State1} = restart_backend(State),
    {noreply, State1};
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

init_logging() ->
    _ = erm_log:ensure_handler(),
    erm_log:set_process_domain(?LOG_DOMAIN).

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
    Tree =
        case load_player_tree() of
            {ok, LoadedTree} ->
                LoadedTree;
            {error, TreeReason} ->
                %% Missing resource files must not trap the media UI in a
                %% one-second retry loop. Use a small built-in fallback so the
                %% player still comes up, while the real layout remains
                %% editable under priv/erm_mpv/layouts/player.term.
                ?LOG_WARNING(
                    "ERM MPV player layout resource unavailable; using built-in fallback: ~p",
                    [TreeReason]
                ),
                builtin_player_tree()
        end,
    try gtkgs:create_tree(Gtkgs, Tree) of
        {ok, [Window]} -> {ok, Window};
        {error, CreateReason} -> {error, CreateReason};
        Other -> {error, {unexpected_create_tree_reply, Other}}
    catch
        Class:ExceptionReason:Stacktrace ->
            {error, {create_tree_failed, Class, ExceptionReason, Stacktrace}}
    end.

builtin_player_tree() ->
    [
        {window, mpv_window,
            [
                {title, ?APP_TITLE},
                {width, 1000},
                {height, 560},
                {min_width, 560},
                {min_height, 340},
                {show, true},
                {wm_class, "erm_mpv"},
                {wm_instance, "erm_mpv"},
                {window_role, "erm_mpv_player"},
                {class, "erm_mpv cp-window"}
            ],
            [
                {frame, player_root,
                    [
                        {orient, vertical},
                        {spacing, 3},
                        {margin, 6},
                        {hexpand, true},
                        {vexpand, true},
                        {class, "cp-root"}
                    ],
                    [
                        {frame, top_strip,
                            [
                                {orient, horizontal},
                                {spacing, 4},
                                {height, 28},
                                {hexpand, true},
                                {vexpand, false},
                                {class, "cp-panel cp-top-strip"}
                            ],
                            [
                                {label, title_label, [
                                    {text, "ERM Media"},
                                    {class, "cp-title"},
                                    {width_chars, 12},
                                    {valign, center}
                                ]},
                                {label, playback_detail, [
                                    {text, "MPV connecting…"},
                                    {class, "cp-status"},
                                    {width_chars, 22},
                                    {valign, center}
                                ]},
                                {label, top_spacer, [{text, ""}, {hexpand, true}, {vexpand, false}]},
                                {button, layout_classic_button, [
                                    {label, "Classic"},
                                    {min_height, 24},
                                    {min_width, 72},
                                    {vexpand, false},
                                    {valign, center},
                                    {class, "cp-layout-button"}
                                ]},
                                {button, layout_compact_button, [
                                    {label, "Compact"},
                                    {min_height, 24},
                                    {min_width, 76},
                                    {vexpand, false},
                                    {valign, center},
                                    {class, "cp-layout-button"}
                                ]},
                                {button, layout_playlist_button, [
                                    {label, "Playlist"},
                                    {min_height, 24},
                                    {min_width, 76},
                                    {vexpand, false},
                                    {valign, center},
                                    {class, "cp-layout-button"}
                                ]}
                            ]},
                        {frame, now_playing_strip,
                            [
                                {orient, horizontal},
                                {spacing, 4},
                                {height, 24},
                                {hexpand, true},
                                {vexpand, false},
                                {class, "cp-panel cp-now-strip"}
                            ],
                            [
                                {label, now_playing, [
                                    {text, "Nothing playing"},
                                    {class, "cp-now-playing"},
                                    {hexpand, true},
                                    {vexpand, false},
                                    {valign, center}
                                ]}
                            ]},
                        {frame, control_strip,
                            [
                                {orient, horizontal},
                                {spacing, 4},
                                {height, 38},
                                {hexpand, true},
                                {vexpand, false},
                                {class, "cp-control-strip"}
                            ],
                            [
                                {button, previous_button, [
                                    {label, "⏮"},
                                    {min_height, 28},
                                    {min_width, 38},
                                    {vexpand, false},
                                    {valign, center},
                                    {class, "cp-button cp-transport"}
                                ]},
                                {button, play_button, [
                                    {label, "⏯"},
                                    {min_height, 30},
                                    {min_width, 50},
                                    {vexpand, false},
                                    {valign, center},
                                    {class, "cp-button-primary cp-transport"}
                                ]},
                                {button, next_button, [
                                    {label, "⏭"},
                                    {min_height, 28},
                                    {min_width, 38},
                                    {vexpand, false},
                                    {valign, center},
                                    {class, "cp-button cp-transport"}
                                ]},
                                {label, elapsed_label, [
                                    {text, "0:00"},
                                    {width_chars, 6},
                                    {vexpand, false},
                                    {valign, center},
                                    {class, "cp-time"}
                                ]},
                                {scale, seek_scale, [
                                    {orient, horizontal},
                                    {min, 0},
                                    {max, 1000},
                                    {step, 1},
                                    {value, 0},
                                    {height, 22},
                                    {hexpand, true},
                                    {vexpand, false},
                                    {valign, center},
                                    {draw_value, false},
                                    {class, "cp-seek"}
                                ]},
                                {label, duration_label, [
                                    {text, "0:00"},
                                    {width_chars, 6},
                                    {vexpand, false},
                                    {valign, center},
                                    {class, "cp-time"}
                                ]},
                                {label, volume_label, [
                                    {text, "Vol"},
                                    {width_chars, 4},
                                    {vexpand, false},
                                    {valign, center},
                                    {class, "cp-dim"}
                                ]},
                                {scale, volume_scale, [
                                    {orient, horizontal},
                                    {min, 0},
                                    {max, 100},
                                    {step, 1},
                                    {value, ?DEFAULT_VOLUME},
                                    {width, 120},
                                    {height, 22},
                                    {vexpand, false},
                                    {valign, center},
                                    {draw_value, false},
                                    {class, "cp-volume"}
                                ]},
                                {label, volume_value, [
                                    {text, volume_text(?DEFAULT_VOLUME)},
                                    {width_chars, 5},
                                    {vexpand, false},
                                    {valign, center},
                                    {class, "cp-time"}
                                ]}
                            ]},
                        {frame, utility_row,
                            [
                                {orient, horizontal},
                                {spacing, 4},
                                {height, 30},
                                {hexpand, true},
                                {vexpand, false},
                                {class, "cp-utility-strip"}
                            ],
                            [
                                {button, like_button, [
                                    {label, "☆"},
                                    {min_height, 24},
                                    {min_width, 38},
                                    {vexpand, false},
                                    {valign, center},
                                    {class, "cp-button"}
                                ]},
                                {button, ipfs_button, [
                                    {label, "IPFS"},
                                    {min_height, 24},
                                    {min_width, 50},
                                    {vexpand, false},
                                    {valign, center},
                                    {class, "cp-button"}
                                ]},
                                {button, share_button, [
                                    {label, "Share"},
                                    {min_height, 24},
                                    {min_width, 58},
                                    {vexpand, false},
                                    {valign, center},
                                    {class, "cp-button"}
                                ]},
                                {button, clear_button, [
                                    {label, "Clear"},
                                    {min_height, 24},
                                    {min_width, 54},
                                    {vexpand, false},
                                    {valign, center},
                                    {class, "cp-button"}
                                ]},
                                {label, utility_spacer, [
                                    {text, ""}, {hexpand, true}, {vexpand, false}
                                ]},
                                {button, close_button, [
                                    {label, "Hide"},
                                    {min_height, 24},
                                    {min_width, 54},
                                    {vexpand, false},
                                    {valign, center},
                                    {class, "cp-button"}
                                ]}
                            ]},
                        {frame, body_row,
                            [
                                {orient, horizontal},
                                {spacing, 6},
                                {hexpand, true},
                                {vexpand, true},
                                {class, "cp-body-row"}
                            ],
                            [
                                {frame, playlist_panel,
                                    [
                                        {orient, vertical},
                                        {spacing, 3},
                                        {hexpand, true},
                                        {vexpand, true},
                                        {class, "cp-panel cp-playlist-panel"}
                                    ],
                                    [
                                        {label, playlist_heading, [
                                            {text, "Playlist"},
                                            {height, 20},
                                            {vexpand, false},
                                            {class, "cp-heading"}
                                        ]},
                                        {listbox, playlist_list, [
                                            {items, []},
                                            {hexpand, true},
                                            {vexpand, true},
                                            {selection, single},
                                            {class, "cp-list"}
                                        ]}
                                    ]},
                                {frame, side_panel,
                                    [
                                        {orient, vertical},
                                        {spacing, 4},
                                        {width, 240},
                                        {min_width, 220},
                                        {vexpand, true},
                                        {class, "cp-panel cp-side-panel"}
                                    ],
                                    [
                                        {label, library_heading, [
                                            {text, "Library"},
                                            {height, 20},
                                            {vexpand, false},
                                            {class, "cp-heading"}
                                        ]},
                                        {entry, folder_entry, [
                                            {placeholder, "Music folder path"},
                                            {hexpand, true},
                                            {vexpand, false},
                                            {class, "cp-entry"}
                                        ]},
                                        {frame, library_button_row,
                                            [
                                                {orient, horizontal},
                                                {spacing, 4},
                                                {height, 28},
                                                {hexpand, true},
                                                {vexpand, false}
                                            ],
                                            [
                                                {button, add_folder_button, [
                                                    {label, "Add"},
                                                    {min_height, 24},
                                                    {min_width, 46},
                                                    {vexpand, false},
                                                    {valign, center},
                                                    {class, "cp-button"}
                                                ]},
                                                {button, rescan_button, [
                                                    {label, "Rescan"},
                                                    {min_height, 24},
                                                    {min_width, 62},
                                                    {vexpand, false},
                                                    {valign, center},
                                                    {class, "cp-button"}
                                                ]}
                                            ]}
                                    ]}
                            ]},
                        {frame, status_strip,
                            [
                                {orient, horizontal},
                                {height, 22},
                                {hexpand, true},
                                {vexpand, false},
                                {class, "cp-status-strip"}
                            ],
                            [
                                {label, status_label, [
                                    {text, "Ready"},
                                    {hexpand, true},
                                    {vexpand, false},
                                    {valign, center},
                                    {class, "cp-status-box"}
                                ]}
                            ]}
                    ]}
            ]}
    ].

apply_layout(Layout) when Layout =:= classic; Layout =:= compact; Layout =:= playlist ->
    case load_layout_rules(Layout) of
        {ok, Rules} ->
            apply_layout_rules(Rules),
            mark_layout_buttons(Layout),
            ok;
        {error, LoadReason} ->
            ?LOG_WARNING("Could not load ERM MPV layout ~p: ~p", [Layout, LoadReason]),
            apply_builtin_layout(Layout),
            mark_layout_buttons(Layout),
            {error, LoadReason}
    end.

apply_layout_rules(Rules) when is_list(Rules) ->
    lists:foreach(fun apply_layout_rule/1, Rules),
    ok.

apply_layout_rule({Widget, Options}) when is_atom(Widget), is_list(Options) ->
    _ = ui_config(Widget, Options),
    ok;
apply_layout_rule({comment, _Text}) ->
    ok;
apply_layout_rule(BadRule) ->
    ?LOG_WARNING("Ignoring bad ERM MPV layout rule: ~p", [BadRule]),
    ok.

%% Last-resort fallback only. The normal layout lives in
%% priv/erm_mpv/layouts/<layout>.term so UI iteration does not require editing
%% and recompiling erm_mpv.erl.
apply_builtin_layout(classic) ->
    _ = ui_config(mpv_window, [{width, 1040}, {height, 620}]),
    _ = ui_config(now_playing_strip, [{show, true}]),
    _ = ui_config(utility_row, [{show, true}]),
    _ = ui_config(side_panel, [{show, true}]),
    ok;
apply_builtin_layout(compact) ->
    _ = ui_config(mpv_window, [{width, 860}, {height, 380}]),
    _ = ui_config(now_playing_strip, [{show, true}]),
    _ = ui_config(utility_row, [{show, true}]),
    _ = ui_config(side_panel, [{show, false}]),
    ok;
apply_builtin_layout(playlist) ->
    _ = ui_config(mpv_window, [{width, 900}, {height, 620}]),
    _ = ui_config(now_playing_strip, [{show, true}]),
    _ = ui_config(utility_row, [{show, false}]),
    _ = ui_config(side_panel, [{show, false}]),
    ok.

mark_layout_buttons(Layout) ->
    _ = ui_config(layout_classic_button, [{label, layout_button_label(classic, Layout)}]),
    _ = ui_config(layout_compact_button, [{label, layout_button_label(compact, Layout)}]),
    _ = ui_config(layout_playlist_button, [{label, layout_button_label(playlist, Layout)}]),
    ok.

layout_button_label(Layout, Layout) ->
    case Layout of
        classic -> "▣ Classic";
        compact -> "▣ Compact";
        playlist -> "▣ Playlist"
    end;
layout_button_label(classic, _Current) ->
    "□ Classic";
layout_button_label(compact, _Current) ->
    "□ Compact";
layout_button_label(playlist, _Current) ->
    "□ Playlist".

saved_layout() ->
    case application:get_env(erm, erm_mpv_layout, ?DEFAULT_LAYOUT) of
        classic -> classic;
        compact -> compact;
        playlist -> playlist;
        _ -> ?DEFAULT_LAYOUT
    end.

save_layout(Layout) when Layout =:= classic; Layout =:= compact; Layout =:= playlist ->
    application:set_env(erm, erm_mpv_layout, Layout).

saved_theme() ->
    case application:get_env(erm, erm_mpv_theme, ?DEFAULT_THEME) of
        Value when is_atom(Value); is_binary(Value); is_list(Value) ->
            case resource_name(Value) of
                {ok, Name} -> Name;
                {error, _} -> ?DEFAULT_THEME
            end;
        _ ->
            ?DEFAULT_THEME
    end.

save_theme(Theme) when is_list(Theme) ->
    application:set_env(erm, erm_mpv_theme, Theme).

apply_mpv_theme(Theme) ->
    CssResult =
        case load_theme_css(Theme) of
            {ok, Css} ->
                {ok, Css};
            {error, ThemeReason} when Theme =:= ?DEFAULT_THEME ->
                ?LOG_WARNING(
                    "Could not load ERM MPV default theme ~ts; using built-in fallback: ~p",
                    [Theme, ThemeReason]
                ),
                {ok, builtin_theme_css()};
            {error, ThemeReason} ->
                {error, ThemeReason}
        end,
    case CssResult of
        {ok, CssBin} ->
            case safe_apply_quiet(gtkgs, set_stylesheet, [erm_mpv_theme, CssBin]) of
                ok ->
                    ok;
                {error, {not_exported, gtkgs, set_stylesheet, 2}} ->
                    ?LOG_WARNING("gtkgs CSS API is not loaded; ERM MPV theme not applied", []),
                    {error, css_api_not_loaded};
                {error, StyleReason} ->
                    ?LOG_WARNING("Could not apply ERM MPV theme ~ts: ~p", [Theme, StyleReason]),
                    {error, StyleReason};
                Other ->
                    ?LOG_DEBUG("gtkgs:set_stylesheet returned ~p", [Other]),
                    ok
            end;
        {error, LoadReason} ->
            ?LOG_WARNING("Could not load ERM MPV theme ~ts: ~p", [Theme, LoadReason]),
            {error, LoadReason}
    end.

load_player_tree() ->
    case consult_resource_term(["layouts", "player.term"]) of
        {ok, [Tree]} when is_list(Tree) -> {ok, Tree};
        {ok, Tree} when is_list(Tree) -> {ok, Tree};
        {ok, Other} -> {error, {bad_player_tree_resource, Other}};
        {error, _LoadReason} = Error -> Error
    end.

load_layout_rules(Layout) when Layout =:= classic; Layout =:= compact; Layout =:= playlist ->
    Filename = atom_to_list(Layout) ++ ".term",
    case consult_resource_term(["layouts", Filename]) of
        {ok, [Rules]} when is_list(Rules) -> {ok, Rules};
        {ok, Rules} when is_list(Rules) -> {ok, Rules};
        {ok, Other} -> {error, {bad_layout_resource, Layout, Other}};
        {error, _LoadReason} = Error -> Error
    end.

load_theme_css(Theme) when is_list(Theme) ->
    read_resource_file(["themes", Theme ++ ".css"]).

consult_resource_term(Parts) ->
    case find_resource_file(Parts) of
        {ok, Path} ->
            try file:consult(Path) of
                {ok, Terms} -> {ok, Terms};
                {error, ConsultReason} -> {error, {Path, ConsultReason}}
            catch
                Class:ExceptionReason:Stacktrace ->
                    {error, {Path, Class, ExceptionReason, Stacktrace}}
            end;
        {error, _FindReason} = Error ->
            Error
    end.

read_resource_file(Parts) ->
    case find_resource_file(Parts) of
        {ok, Path} ->
            try file:read_file(Path) of
                {ok, Bin} -> {ok, Bin};
                {error, FileReason} -> {error, {Path, FileReason}}
            catch
                Class:ExceptionReason:Stacktrace ->
                    {error, {Path, Class, ExceptionReason, Stacktrace}}
            end;
        {error, _FindReason} = Error ->
            Error
    end.

find_resource_file(Parts) ->
    Candidates = [filename:join([Root | Parts]) || Root <- resource_roots()],
    case [Path || Path <- Candidates, filelib:is_regular(Path)] of
        [Path | _] -> {ok, Path};
        [] -> {error, {resource_not_found, Parts, Candidates}}
    end.

resource_roots() ->
    uniq_keep_order(
        configured_resource_roots() ++
            env_resource_roots() ++
            otp_priv_resource_roots() ++
            dev_source_resource_roots()
    ).

configured_resource_roots() ->
    case application:get_env(erm, erm_mpv_resource_dir) of
        {ok, Root} -> [filename:absname(to_text(Root))];
        undefined -> []
    end.

env_resource_roots() ->
    case os:getenv("ERM_MPV_RESOURCE_DIR") of
        false -> [];
        "" -> [];
        Root -> [filename:absname(Root)]
    end.

otp_priv_resource_roots() ->
    case code:priv_dir(erm) of
        {error, bad_name} -> [];
        PrivDir -> [filename:join(PrivDir, "erm_mpv")]
    end.

dev_source_resource_roots() ->
    Cwd =
        case file:get_cwd() of
            {ok, Dir} -> Dir;
            {error, _} -> "."
        end,
    [
        filename:absname(filename:join([Cwd, "apps", "erm", "priv", "erm_mpv"])),
        filename:absname(filename:join([Cwd, "..", "apps", "erm", "priv", "erm_mpv"])),
        filename:absname(filename:join([Cwd, "..", "..", "apps", "erm", "priv", "erm_mpv"]))
    ].

uniq_keep_order(List) ->
    {_Seen, Out} =
        lists:foldl(
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

resource_name(Name) when is_atom(Name) ->
    resource_name(atom_to_list(Name));
resource_name(Name) when is_binary(Name) ->
    resource_name(unicode:characters_to_list(Name));
resource_name(Name) when is_list(Name) ->
    case valid_resource_name(Name) of
        true -> {ok, Name};
        false -> {error, {bad_resource_name, Name}}
    end;
resource_name(Name) ->
    {error, {bad_resource_name, Name}}.

valid_resource_name([]) ->
    false;
valid_resource_name(Name) ->
    length(Name) =< 64 andalso lists:all(fun valid_resource_char/1, Name).

valid_resource_char(C) when C >= $a, C =< $z -> true;
valid_resource_char(C) when C >= $A, C =< $Z -> true;
valid_resource_char(C) when C >= $0, C =< $9 -> true;
valid_resource_char($_) -> true;
valid_resource_char($-) -> true;
valid_resource_char(_) -> false.

builtin_theme_css() ->
    <<
        "\n"
        "window.cp-window {\n"
        "  background: #070a0f;\n"
        "  color: #d8f7ff;\n"
        "}\n"
        "\n"
        ".cp-root {\n"
        "  background: #070a0f;\n"
        "  color: #d8f7ff;\n"
        "  font-family: monospace;\n"
        "  font-size: 11px;\n"
        "}\n"
        "\n"
        ".cp-panel,\n"
        ".cp-control-strip,\n"
        ".cp-utility-strip,\n"
        ".cp-status-strip {\n"
        "  background: #0d141d;\n"
        "  border: 1px solid #203347;\n"
        "  border-radius: 5px;\n"
        "  padding: 3px;\n"
        "}\n"
        "\n"
        ".cp-title {\n"
        "  color: #75f7ff;\n"
        "  font-weight: 800;\n"
        "  letter-spacing: 0.08em;\n"
        "}\n"
        "\n"
        ".cp-now-playing {\n"
        "  color: #f2fbff;\n"
        "  font-weight: 700;\n"
        "}\n"
        "\n"
        ".cp-heading {\n"
        "  color: #ff5fd7;\n"
        "  font-weight: 800;\n"
        "}\n"
        "\n"
        ".cp-status,\n"
        ".cp-dim,\n"
        ".cp-time,\n"
        ".cp-status-box {\n"
        "  color: #9edfff;\n"
        "}\n"
        "\n"
        "button.cp-button,\n"
        "button.cp-layout-button,\n"
        "button.cp-button-primary {\n"
        "  min-height: 20px;\n"
        "  padding: 1px 7px;\n"
        "  border-radius: 4px;\n"
        "}\n"
        "\n"
        "button.cp-button,\n"
        "button.cp-layout-button {\n"
        "  background: #111b27;\n"
        "  color: #d8f7ff;\n"
        "  border: 1px solid #29465e;\n"
        "}\n"
        "\n"
        "button.cp-button-primary {\n"
        "  background: #102838;\n"
        "  color: #75f7ff;\n"
        "  border: 1px solid #4fe4ff;\n"
        "  font-weight: 800;\n"
        "}\n"
        "\n"
        "entry.cp-entry,\n"
        "scrolledwindow.cp-list,\n"
        "scrolledwindow.cp-list > viewport,\n"
        "scrolledwindow.cp-list list,\n"
        "list.cp-list,\n"
        "list.cp-list row,\n"
        "list.cp-list row label {\n"
        "  background: #081018;\n"
        "  color: #e2faff;\n"
        "}\n"
        "\n"
        "list.cp-list row:selected,\n"
        "list.cp-list row:selected label {\n"
        "  background: #123145;\n"
        "  color: #75f7ff;\n"
        "}\n"
        "\n"
        "scale.cp-seek trough,\n"
        "scale.cp-volume trough {\n"
        "  background: #071019;\n"
        "  border: 1px solid #23394c;\n"
        "  min-height: 4px;\n"
        "  border-radius: 3px;\n"
        "}\n"
        "\n"
        "scale.cp-seek highlight,\n"
        "scale.cp-volume highlight {\n"
        "  background: #75f7ff;\n"
        "}\n"
        "\n"
        "scale.cp-seek slider,\n"
        "scale.cp-volume slider {\n"
        "  background: #ff5fd7;\n"
        "  border: 1px solid #ffe6fb;\n"
        "  min-width: 10px;\n"
        "  min-height: 10px;\n"
        "  border-radius: 8px;\n"
        "}\n"
    >>.

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
                        {error, Reason} ->
                            update_status(io_lib:format("Could not add folder: ~p", [Reason]));
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
                            update_status(
                                io_lib:format(
                                    "Pinned to IPFS, but playlist update failed: ~p",
                                    [UpdateReason]
                                )
                            );
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
                {error, Reason} ->
                    update_status(io_lib:format("Share failed: ~p", [Reason]));
                _ ->
                    case copy_to_clipboard(Url) of
                        ok ->
                            update_status(io_lib:format("Copied: ~ts", [to_text(Url)]));
                        {error, ClipboardReason} ->
                            update_status(
                                io_lib:format(
                                    "Clipboard unavailable: ~p", [ClipboardReason]
                                )
                            )
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
    case normalize_mpv_path(Track#track.path) of
        {ok, Path} ->
            case call_mpv(load_file, [Path], State) of
                {error, _Reason, FailedState} ->
                    FailedState;
                {ok, _Reply, ReadyState} ->
                    _ = ui_config(now_playing, [{text, display_title(Track)}]),
                    case safe_playlist(set_current, [Track#track.id]) of
                        {error, PlaylistReason} ->
                            update_status(
                                io_lib:format(
                                    "Playing, but playlist state could not be updated: ~p",
                                    [PlaylistReason]
                                )
                            );
                        _ ->
                            update_status("Playing")
                    end,
                    ReadyState#state{
                        playback_state = playing,
                        loaded_track_id = Track#track.id,
                        loaded_track_path = Path
                    }
            end;
        {error, Reason} ->
            update_status(io_lib:format("Cannot play track: ~p", [Reason])),
            State
    end.

normalize_mpv_path(Path0) ->
    Path = to_text(Path0),
    case Path of
        [] ->
            {error, empty_media_path};
        _ ->
            case media_ref_exists(Path) of
                true -> {ok, unicode:characters_to_binary(Path)};
                false -> {error, {media_path_not_found, Path}}
            end
    end.

media_ref_exists(Path) ->
    has_uri_scheme(Path) orelse filelib:is_regular(Path).

has_uri_scheme(Path) ->
    case string:find(Path, "://") of
        nomatch -> false;
        _ -> true
    end.

play_or_recover(State) ->
    case mpv_status(State) of
        {ok, Status, StatusState} ->
            case status_has_loaded_media(Status) of
                true ->
                    mpv_action(toggle_pause, [], apply_playback_status(Status, StatusState));
                false ->
                    recover_playback(StatusState)
            end;
        {error, StatusReason, StatusState} ->
            %% If MPV is alive but idle/stopped, some properties can be
            %% unavailable. Recover by loading a track rather than only
            %% toggling pause on an empty backend.
            log_mpv_error(status, StatusReason),
            recover_playback(StatusState)
    end.

recover_playback(State) ->
    case first_playable_track() of
        {ok, Track} ->
            play_track(Track, State);
        {error, RecoverReason} ->
            update_status(io_lib:format("Nothing to play: ~p", [RecoverReason])),
            State#state{
                playback_state = idle, loaded_track_id = undefined, loaded_track_path = undefined
            }
    end.

first_playable_track() ->
    case safe_playlist(current) of
        {ok, Track} ->
            {ok, Track};
        _ ->
            case safe_playlist(get_by_index, [0]) of
                {ok, Track} -> {ok, Track};
                _ -> {error, no_playlist_track}
            end
    end.

stop_playback(State) ->
    case call_mpv(stop, [], State) of
        {ok, _Reply, State1} ->
            _ = ui_config(playback_detail, [{text, "Stopped"}]),
            update_status("Stopped"),
            {ok, State1#state{
                playback_state = stopped, loaded_track_id = undefined, loaded_track_path = undefined
            }};
        {error, StopReason, State1} ->
            {{error, StopReason}, State1}
    end.

restart_backend(State) ->
    Reply = safe_apply_quiet(erm_mpv_proc, restart, []),
    State1 = drop_mpv_connection(State#state{
        playback_state = idle,
        loaded_track_id = undefined,
        loaded_track_path = undefined
    }),
    case Reply of
        ok ->
            update_status("MPV backend restarted"),
            {ok, State1};
        {error, RestartReason} ->
            update_status(io_lib:format("MPV backend restart failed: ~p", [RestartReason])),
            {{error, RestartReason}, State1};
        Other ->
            update_status(io_lib:format("MPV backend restart returned: ~p", [Other])),
            {Other, State1}
    end.

mpv_status(State) ->
    case call_mpv(status, [], State) of
        {ok, {ok, Status}, State1} when is_map(Status) -> {ok, Status, State1};
        {ok, Status, State1} when is_map(Status) -> {ok, Status, State1};
        {ok, Other, State1} -> {error, {bad_status_reply, Other}, State1};
        {error, StatusReason, State1} -> {error, StatusReason, State1}
    end.

refresh_mpv_status(State = #state{ipc = undefined}) ->
    State;
refresh_mpv_status(State) ->
    case mpv_status(State) of
        {ok, Status, State1} -> apply_playback_status(Status, State1);
        {error, _StatusReason, State1} -> State1
    end.

apply_playback_status(Status, State) when is_map(Status) ->
    update_playback_status(Status),
    Path0 = map_value(
        [path, "path", <<"path">>, filename, "filename", <<"filename">>],
        Status,
        State#state.loaded_track_path
    ),
    Idle = map_value([idle_active, "idle-active", <<"idle-active">>], Status, undefined),
    Paused = map_value([pause, "pause", <<"pause">>], Status, undefined),
    PlaybackState = playback_state(Idle, Paused, Path0),
    State#state{
        playback_state = PlaybackState,
        loaded_track_path = normalize_loaded_path(Path0, State#state.loaded_track_path)
    }.

status_has_loaded_media(Status) ->
    Path = map_value(
        [path, "path", <<"path">>, filename, "filename", <<"filename">>], Status, undefined
    ),
    Idle = map_value([idle_active, "idle-active", <<"idle-active">>], Status, undefined),
    has_loaded_path(Path) andalso Idle =/= true.

playback_state(true, _Paused, _Path) ->
    idle;
playback_state(_Idle, true, Path) ->
    case has_loaded_path(Path) of
        true -> paused;
        false -> idle
    end;
playback_state(_Idle, false, Path) ->
    case has_loaded_path(Path) of
        true -> playing;
        false -> idle
    end;
playback_state(_Idle, _Paused, Path) ->
    case has_loaded_path(Path) of
        true -> loaded;
        false -> idle
    end.

has_loaded_path(undefined) -> false;
has_loaded_path(null) -> false;
has_loaded_path(<<>>) -> false;
has_loaded_path([]) -> false;
has_loaded_path(_Path) -> true.

normalize_loaded_path(Path, Previous) when
    Path =:= undefined; Path =:= null; Path =:= <<>>; Path =:= []
->
    Previous;
normalize_loaded_path(Path, _Previous) when is_binary(Path) ->
    unicode:characters_to_list(Path);
normalize_loaded_path(Path, _Previous) when is_list(Path) ->
    Path;
normalize_loaded_path(Path, _Previous) ->
    to_text(Path).

update_playback_status(Status) ->
    Percent = map_value(["percent-pos", <<"percent-pos">>, percent_pos], Status, undefined),
    Position = map_value(["time-pos", <<"time-pos">>, time_pos], Status, undefined),
    Duration = map_value([duration, "duration", <<"duration">>], Status, undefined),
    Paused = map_value([pause, "pause", <<"pause">>], Status, undefined),
    Idle = map_value([idle_active, "idle-active", <<"idle-active">>], Status, undefined),
    case Percent of
        Value when is_number(Value) ->
            _ = ui_config(seek_scale, [{value, clamp(Value * 10, 0, 1000)}]);
        _ ->
            ok
    end,
    _ = ui_config(elapsed_label, [{text, duration_text(Position)}]),
    _ = ui_config(duration_label, [{text, duration_text(Duration)}]),
    Detail =
        case {Idle, Paused} of
            {true, _} -> "Idle";
            {_, true} -> "Paused";
            {_, false} -> "Playing";
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
        _Pid ->
            safe_server_call(Request)
    end.

safe_server_call(Request) ->
    try gen_server:call(?SERVER, Request) of
        Reply -> Reply
    catch
        exit:Reason -> {error, {erm_mpv_unavailable, Reason}}
    end.

safe_mpv_connect(Path) ->
    %% Do not call mpv_ipc:connect/1 directly from the UI process. The process
    %% owner is responsible for starting MPV, validating the socket, and bounding
    %% all IPC calls so a wedged socket cannot freeze media controls.
    case safe_apply_quiet(erm_mpv_proc, ensure_started, [Path]) of
        ok ->
            case whereis(erm_mpv_proc) of
                Pid when is_pid(Pid) -> {ok, Pid};
                undefined -> {error, mpv_proc_not_started}
            end;
        {error, Reason} ->
            {error, Reason};
        Other ->
            {error, {unexpected_ensure_started_reply, Other}}
    end.

safe_mpv(Function, Args) ->
    %% Route every command through the MPV process owner. erm_mpv_proc bounds
    %% the IPC call, ensures the socket exists first, and restarts managed MPV
    %% if a command wedges.
    safe_apply_quiet(erm_mpv_proc, command, [Function, Args, ?MPV_CMD_TIMEOUT_MS]).

mpv_action(Function, Args, State) ->
    case call_mpv(Function, Args, State) of
        {ok, _Reply, NextState} -> NextState;
        {error, _Reason, NextState} -> NextState
    end.

call_mpv(Function, Args, State = #state{ipc = undefined}) ->
    case safe_mpv_connect(ipc_path()) of
        {ok, Ipc} ->
            ConnectedState = State#state{
                ipc = Ipc,
                ipc_monitor = monitor_ipc(Ipc),
                mpv_timer = undefined,
                mpv_retry_ms = ?MPV_RETRY_MS,
                mpv_errors = maps:remove(connect, State#state.mpv_errors)
            },
            call_mpv(Function, Args, ConnectedState);
        {error, Reason} ->
            WaitingState = ensure_mpv_connect(State),
            FailedState = report_mpv_error(Function, Reason, WaitingState),
            {error, Reason, FailedState}
    end;
call_mpv(Function, Args, State) ->
    case safe_mpv(Function, Args) of
        {error, Reason} ->
            FaultState = maybe_drop_mpv_connection(Reason, State),
            FailedState = report_mpv_error(Function, Reason, FaultState),
            {error, Reason, FailedState};
        Reply ->
            {ok, Reply, clear_mpv_error(Function, State)}
    end.

ensure_mpv_connect(State = #state{mpv_timer = undefined}) ->
    Timer = erlang:send_after(0, self(), connect_mpv),
    State#state{mpv_timer = Timer};
ensure_mpv_connect(State) ->
    State.

maybe_drop_mpv_connection(Reason, State) ->
    case mpv_connection_fault(Reason) of
        true -> drop_mpv_connection(State);
        false -> State
    end.

mpv_connection_fault(not_connected) -> true;
mpv_connection_fault({mpv_unavailable, _Reason}) -> true;
mpv_connection_fault({mpv_command_timeout, _Function, _Timeout}) -> true;
mpv_connection_fault({mpv_ipc_connect_failed, _Path, _Reason}) -> true;
mpv_connection_fault({disconnected, _Reason}) -> true;
mpv_connection_fault({exception, _Class, _Reason, _Stacktrace}) -> true;
mpv_connection_fault({erm_mpv_proc_unavailable, _Reason}) -> true;
mpv_connection_fault(mpv_proc_not_started) -> true;
mpv_connection_fault(_) -> false.

drop_mpv_connection(State) ->
    demonitor_ipc(State#state.ipc_monitor),
    ensure_mpv_connect(State#state{
        ipc = undefined,
        ipc_monitor = undefined,
        mpv_retry_ms = ?MPV_RETRY_MS,
        playback_state = idle,
        loaded_track_id = undefined,
        loaded_track_path = undefined
    }).

mark_mpv_disconnected(Reason, State) ->
    demonitor_ipc(State#state.ipc_monitor),
    Timer = replace_timer(State#state.mpv_timer, 0, connect_mpv),
    DisconnectedState = State#state{
        ipc = undefined,
        ipc_monitor = undefined,
        mpv_timer = Timer,
        mpv_retry_ms = ?MPV_RETRY_MS,
        playback_state = idle,
        loaded_track_id = undefined,
        loaded_track_path = undefined
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
    ?LOG_WARNING("MPV command ~p failed: ~p:~p~n~p", [
        Function, Class, Reason, Stacktrace
    ]);
log_mpv_error(Function, Reason) ->
    ?LOG_WARNING("MPV command ~p failed: ~p", [Function, Reason]).

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
        false ->
            {error, {not_exported, Module, Function, length(Args)}};
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
    try
        gtkgs:config(Name, Options)
    catch
        _:_ -> {error, ui_not_ready}
    end.

ui_read(Name, Key) ->
    try
        gtkgs:read(Name, Key)
    catch
        _:_ -> {error, ui_not_ready}
    end.

safe_gtknode4_ready() ->
    try gtknode4:await_ready(0) of
        ok -> ok;
        {error, _Reason} = Error -> Error;
        Other -> {error, {unexpected_gtknode4_status, Other}}
    catch
        exit:{noproc, _} -> {error, gtknode4_not_started};
        Class:Reason:Stacktrace -> {error, {gtknode4_status_failed, Class, Reason, Stacktrace}}
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
            try
                open_port({spawn_executable, Xclip}, [
                    binary, exit_status, {args, ["-selection", "clipboard"]}
                ])
            of
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

map_value([], _Map, Default) ->
    Default;
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

cancel_timer(undefined) ->
    ok;
cancel_timer({TimerRef, _Token}) when is_reference(TimerRef) ->
    _ = erlang:cancel_timer(TimerRef),
    ok;
cancel_timer(Timer) ->
    _ = erlang:cancel_timer(Timer),
    ok.

options_map(Map) when is_map(Map) -> Map;
options_map(List) when is_list(List) -> maps:from_list(List);
options_map(undefined) -> #{}.
