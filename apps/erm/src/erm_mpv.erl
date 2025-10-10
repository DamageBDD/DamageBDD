%%%-------------------------------------------------------------------
%%% ecai_mpv_front.erl — WX GUI frontend for MPV with IPFS caching
%%%-------------------------------------------------------------------
%%% Social reporting added: posts "Now Playing" to Discord/Instagram via social_reporter
%%%-------------------------------------------------------------------
%%% Features
%%%  - Recursively scan folders for media files
%%%  - Enqueue into MPV via JSON IPC
%%%  - Big playback controls (Play/Pause/Next/Prev, Seek, Volume)
%%%  - Info lookup (reads basic tags; placeholder for ECAI mapping)
%%%  - Local IPFS add + pin for offline playback; share button copies ipfs://CID
%%%  - Like ★ toggle stored in ETS + JSON
%%%  - Playlist management by IPFS CIDs
%%%  - Minimal deps: inets (httpc), crypto, public_key, jsx (JSON)
%%%
%%% Usage (overview)
%%%   1) Start IPFS daemon locally: `ipfs daemon`
%%%   2) Start MPV with IPC: `mpv --idle=yes --keep-open=yes --input-ipc-server=/tmp/mpv.sock`
%%%   3) erl -pa _build/default/lib/*/ebin -s inets start -s ecai_mpv_front start
%%%
%%% Notes
%%%   - MPV IPC defaults to /tmp/mpv.sock; override via env MPV_IPC=/path/to/socket.
%%%   - IPFS API defaults to http://127.0.0.1:5001; override via env IPFS_API.
%%%-------------------------------------------------------------------
-module(erm_mpv).
-behaviour(wx_object).
-include_lib("wx/include/wx.hrl").
-include_lib("erm.hrl").
-include_lib("kernel/include/logger.hrl").

-export([show/0]).
-export([close/0]).

-export([start/1, start_link/0]).
-export([
    init/1, handle_event/2, handle_info/2, handle_call/3, handle_cast/2, terminate/2, code_change/3
]).

-record(state, {
    frame,
    panel,
    btn_prev,
    btn_play,
    btn_next,
    btn_like,
    btn_share,
    btn_add,
    btn_rescan,
    btn_ipfs_add,
    btn_clear,
    vol_slider,
    seek_slider,
    %% wxListCtrl for playlist
    list,
    status_text,
    %% mpv_ipc handle
    ipc,
    playlist_pid,
    current_id = undefined
}).

-define(APP_TITLE, "ECAI MPV Front").
-define(IPC_PATH, os:getenv("MPV_IPC", "/tmp/mpv.sock")).
-define(IPFS_API, os:getenv("IPFS_API", "http://127.0.0.1:5001")).
-define(BTN_STYLE, ?wxBU_EXACTFIT bor ?wxBU_AUTODRAW).

start(Config) -> wx_object:start_link(?MODULE, Config, []).

start_link() -> wx_object:start_link(?MODULE, [], []).

init([]) ->
    Env = persistent_term:get(erm_wx_env),
    wx:set_env(Env),

    mpv_ipc:ensure_started(),
    media_scan:ensure_started(),
    ipfs_client:ensure_started(?IPFS_API),
    playlist_sup:ensure_started(),
    {ok, Ply} = playlist:start_link(),
    social_reporter:ensure_started(),
    {ok, Ipc} = mpv_ipc:connect(?IPC_PATH),
    %% Register a gproc local name so other processes can find us
    Frame = wxFrame:new(wx:null(), ?wxID_ANY, ?APP_TITLE, [{size, {1100, 720}}]),
    Panel = wxPanel:new(Frame, []),

    FontBig = wxFont:new(14, ?wxFONTFAMILY_SWISS, ?wxFONTSTYLE_NORMAL, ?wxFONTWEIGHT_BOLD),

    %% Controls
    BtnPrev = wxButton:new(Panel, ?wxID_ANY, [{label, "⏮"}, {style, ?BTN_STYLE}]),
    BtnPlay = wxButton:new(Panel, ?wxID_ANY, [{label, "⏯"}, {style, ?BTN_STYLE}]),
    BtnNext = wxButton:new(Panel, ?wxID_ANY, [{label, "⏭"}, {style, ?BTN_STYLE}]),
    BtnLike = wxButton:new(Panel, ?wxID_ANY, [{label, "☆ Like"}]),
    BtnShare = wxButton:new(Panel, ?wxID_ANY, [{label, "Share (IPFS)"}]),

    BtnAdd = wxButton:new(Panel, ?wxID_ANY, [{label, "Add Folder"}]),
    BtnRescan = wxButton:new(Panel, ?wxID_ANY, [{label, "Rescan"}]),
    BtnIpAdd = wxButton:new(Panel, ?wxID_ANY, [{label, "Add→IPFS"}]),
    BtnClear = wxButton:new(Panel, ?wxID_ANY, [{label, "Clear"}]),

    Vol = wxSlider:new(Panel, ?wxID_ANY, 50, 0, 100, []),
    Seek = wxSlider:new(Panel, ?wxID_ANY, 0, 0, 1000, [{style, ?wxSL_HORIZONTAL}]),

    List = wxListCtrl:new(Panel, [{style, ?wxLC_REPORT bor ?wxLC_SINGLE_SEL}]),
    wxListCtrl:insertColumn(List, 0, "Title", [{width, 480}]),
    wxListCtrl:insertColumn(List, 1, "CID", [{width, 360}]),
    wxListCtrl:insertColumn(List, 2, "Liked", [{width, 80}]),

    Status = wxStaticText:new(Panel, ?wxID_ANY, "Ready"),
    wxWindow:setFont(Status, FontBig),

    %% Layout
    Top = wxBoxSizer:new(?wxVERTICAL),
    Row1 = wxBoxSizer:new(?wxHORIZONTAL),
    [
        wxSizer:add(Row1, B, [{flag, ?wxALL}, {border, 5}])
     || B <- [BtnPrev, BtnPlay, BtnNext, BtnLike, BtnShare, BtnAdd, BtnRescan, BtnIpAdd, BtnClear]
    ],
    wxSizer:add(Top, Row1, [{flag, ?wxEXPAND}]),

    wxSizer:add(Top, Seek, [{flag, ?wxEXPAND bor ?wxALL}, {border, 5}]),

    Row2 = wxBoxSizer:new(?wxHORIZONTAL),
    wxSizer:add(Row2, wxStaticText:new(Panel, ?wxID_ANY, "Volume"), [
        {flag, ?wxALIGN_CENTER_VERTICAL bor ?wxALL}, {border, 5}
    ]),
    wxSizer:add(Row2, Vol, [{proportion, 1}, {flag, ?wxEXPAND bor ?wxALL}, {border, 5}]),
    wxSizer:add(Top, Row2, [{flag, ?wxEXPAND}]),

    wxSizer:add(Top, List, [{proportion, 1}, {flag, ?wxEXPAND bor ?wxALL}, {border, 5}]),
    wxSizer:add(Top, Status, [{flag, ?wxALL}, {border, 5}]),

    wxPanel:setSizer(Panel, Top),
    wxFrame:show(Frame),

    %% Wire events
    [wxPanel:connect(Panel, Evt, []) || Evt <- [key_down, key_up]],
    [
        wxButton:connect(B, command_button_clicked, [])
     || B <- [BtnPrev, BtnPlay, BtnNext, BtnLike, BtnShare, BtnAdd, BtnRescan, BtnIpAdd, BtnClear]
    ],
    wxSlider:connect(Vol, command_slider_updated, []),
    wxSlider:connect(Seek, command_slider_updated, []),
    wxListCtrl:connect(List, command_list_item_selected, []),
    gproc:reg_other({n, l, {?MODULE, erm_mpv}}, self()),

    {Frame, #state{
        frame = Frame,
        panel = Panel,
        btn_prev = BtnPrev,
        btn_play = BtnPlay,
        btn_next = BtnNext,
        btn_like = BtnLike,
        btn_share = BtnShare,
        btn_add = BtnAdd,
        btn_rescan = BtnRescan,
        btn_ipfs_add = BtnIpAdd,
        btn_clear = BtnClear,
        vol_slider = Vol,
        seek_slider = Seek,
        list = List,
        status_text = Status,
        ipc = Ipc,
        playlist_pid = Ply
    }}.
close() ->
    case gproc:lookup_local_name({?MODULE, erm_mpv}) of
        undefined -> ok;
        Pid -> wx_object:call(Pid, close)
    end.

show() ->
    case gproc:lookup_local_name({?MODULE, erm_mpv}) of
        undefined -> start([]);
        Pid -> wx_object:call(Pid, show)
    end.

handle_event(
    #wx{event = #wxCommand{type = command_button_clicked}, id = Id}, S = #state{frame = F}
) ->
    %% Buttons dispatch by label
    B0 = wxWindow:findWindowById(Id, [{parent, F}]),
    Btn = wx:typeCast(B0, wxButton),
    case wxButton:getLabel(Btn) of
        "⏮" ->
            playlist:prev(),
            {noreply, S};
        "⏯" ->
            mpv_ipc:toggle_pause(),
            {noreply, S};
        "⏭" ->
            playlist:next(),
            {noreply, S};
        "☆ Like" ->
            playlist:toggle_like_current(),
            refresh_playlist(S),
            {noreply, S};
        "Share (IPFS)" ->
            share_current(S),
            {noreply, S};
        "Add Folder" ->
            add_folder(S),
            {noreply, S};
        "Rescan" ->
            rescan(S),
            {noreply, S};
        "Add→IPFS" ->
            add_current_to_ipfs(S),
            {noreply, S};
        "Clear" ->
            playlist:clear(),
            refresh_playlist(S),
            {noreply, S};
        L ->
            ?LOG_INFO("Unknown button ~ts", [L]),
            {noreply, S}
    end;
handle_event(
    #wx{event = #wxCommand{type = command_slider_updated, commandInt = Val}, id = Id},
    S = #state{vol_slider = Vol, seek_slider = Seek}
) ->
    VolId = wxWindow:getId(Vol),
    SeekId = wxWindow:getId(Seek),
    case true of
        _ when Id =:= VolId ->
            mpv_ipc:set_volume(Val),
            {noreply, S};
        _ when Id =:= SeekId ->
            mpv_ipc:seek_percent(Val / 10),
            {noreply, S};
        _ ->
            {noreply, S}
    end;
handle_event(#wx{event = #wxList{type = command_list_item_selected, itemIndex = Idx}}, S) ->
    case playlist:get_by_index(Idx) of
        {ok, Track} ->
            mpv_ipc:load_file(Track#track.path),
            playlist:set_current(Track#track.id),
            update_status(S, Track),
            {noreply, S};
        error ->
            {noreply, S}
    end;
handle_event(E, S) ->
    ?LOG_DEBUG("Unhandled ~p", [E]),
    {noreply, S}.

handle_info({mpv, status, Map}, S) ->
    maybe_update_seek(S, Map),
    {noreply, S};
handle_info(_Msg, S) ->
    {noreply, S}.

handle_call(_Req, _From, S) -> {reply, ok, S}.
handle_cast(_Msg, S) -> {noreply, S}.
terminate(_Reason, _S) -> ok.
code_change(_V, S, _Extra) -> {ok, S}.

%% Helpers
add_folder(S = #state{list = _List}) ->
    Dlg = wxDirDialog:new(S#state.frame, [
        {title, "Pick media folder"}, {style, ?wxDD_DIR_MUST_EXIST}
    ]),
    case wxDirDialog:showModal(Dlg) of
        ?wxID_OK ->
            Dir = wxDirDialog:getPath(Dlg),
            spawn(fun() -> media_scan:scan_and_index(Dir) end),
            refresh_playlist(S),
            ok;
        _ ->
            ok
    end,
    wxDialog:destroy(Dlg).

rescan(S) ->
    playlist:rescan_all(),
    refresh_playlist(S).

add_current_to_ipfs(S) ->
    case playlist:current() of
        {ok, T} ->
            {ok, Cid} = ipfs_client:add_and_pin(T#track.path),
            playlist:update_cid(T#track.id, Cid),
            refresh_playlist(S),
            ok;
        error ->
            ok
    end.

share_current(S) ->
    case playlist:current() of
        {ok, T} when T#track.cid =/= undefined ->
            Url = ipfs_client:gateway_url(T#track.cid),
            copy_to_clipboard(Url),
            update_status(S, io_lib:format("Shared: ~s", [Url]));
        {ok, _} ->
            update_status(S, "Add to IPFS first (Add→IPFS)!");
        error ->
            ok
    end.

refresh_playlist(_S = #state{list = List}) ->
    wxListCtrl:deleteAllItems(List),
    Tracks = playlist:all(),
    lists:foreach(
        fun({Idx, T}) ->
            _ = wxListCtrl:insertItem(List, Idx, display_title(T)),
            wxListCtrl:setItem(
                List,
                Idx,
                1,
                case T#track.cid of
                    undefined -> "-";
                    C -> C
                end
            ),
            wxListCtrl:setItem(
                List,
                Idx,
                2,
                case T#track.liked of
                    true -> "★";
                    _ -> ""
                end
            )
        end,
        Tracks
    ).

update_status(_S = #state{status_text = Txt}, Str) when is_list(Str) ->
    wxStaticText:setLabel(Txt, lists:flatten(Str));
update_status(S, T = #track{}) ->
    wxStaticText:setLabel(S#state.status_text, io_lib:format("Now: ~s", [display_title(T)])).

display_title(T) -> filename:basename(T#track.path).

maybe_update_seek(#state{seek_slider = Seek}, Map) ->
    case {maps:get("percent-pos", Map, undefined)} of
        {P} when is_number(P) -> wxSlider:setValue(Seek, trunc(P * 10));
        _ -> ok
    end.

copy_to_clipboard(Str) ->
    %% Simple X11 copy fallback via xclip; no-op if missing
    Cmd = io_lib:format(
        "bash -lc 'command -v xclip >/dev/null && printf %s ~s | xclip -selection clipboard'", [Str]
    ),
    os:cmd(lists:flatten(Cmd)).
