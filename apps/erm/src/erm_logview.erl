-module(erm_logview).
-author("Steven Joseph <steven@stevenjoseph.in>").

-behaviour(wx_object).

-include_lib("wx/include/wx.hrl").
-include_lib("kernel/include/file.hrl").
-include_lib("kernel/include/logger.hrl").

-export([
    start/1,
    init/1,
    terminate/2,
    code_change/3,
    handle_info/2,
    handle_call/3,
    handle_cast/2,
    handle_event/2
]).
-export([show/0, close/0]).

-record(state, {
    parent,
    panel,
    config = [],
    %% wxTextCtrl (multiline)
    text,
    %% wxStatusBar
    status,
    %% wxButton
    open_btn,
    %% wxCheckBox
    tail_chk,
    %% wxButton "Save to IPFS"
    save_btn,
    %% wxButton "Copy CID"
    copy_btn,
    %% wxButton
    clear_btn,
    %% wxSpinCtrl for initial tail bytes
    tail_bytes_spin,
    %% wxTimer for tailing
    timer,
    %% boolean
    tailing = false,
    %% loaded log file path
    path = undefined,
    %% file handle for tailing
    fh = undefined,
    %% inode to detect rotation
    inode = undefined,
    %% last read size / offset
    size = 0,
    %% last IPFS CID
    last_cid = undefined
}).

-define(TIMER_MS, 500).
-define(DEFAULT_TAIL_BYTES, 65536).

start(Config) -> wx_object:start_link(?MODULE, Config, []).

show() ->
    case whereis(?MODULE) of
        undefined -> start([]);
        Pid -> wx_object:call(Pid, show)
    end.

close() ->
    case whereis(?MODULE) of
        undefined -> ok;
        Pid -> wx_object:call(Pid, close)
    end.

init(Config) ->
    register(?MODULE, self()),
    Env = persistent_term:get(erm_wx_env),
    wx:set_env(Env),
    wx:batch(fun() -> do_init(Config) end).

%% ------------------------------------------------------------------
%% UI
%% ------------------------------------------------------------------

do_init(Config) ->
    Frame = wxFrame:new(wx:null(), ?wxID_ANY, "ERM Log Viewer", [{size, {1100, 700}}]),
    Panel = wxPanel:new(Frame, []),

    %% Controls
    OpenBtn = wxButton:new(Panel, ?wxID_OPEN, [{label, "Open…"}]),
    TailChk = wxCheckBox:new(Panel, ?wxID_ANY, "Follow (tail)"),
    SaveBtn = wxButton:new(Panel, ?wxID_SAVE, [{label, "Save to IPFS"}]),
    CopyBtn = wxButton:new(Panel, ?wxID_ANY, [{label, "Copy CID"}]),
    ClearBtn = wxButton:new(Panel, ?wxID_ANY, [{label, "Clear"}]),
    wxWindow:disable(CopyBtn),

    TailBytesLbl = wxStaticText:new(Panel, ?wxID_ANY, "Tail bytes:"),

    TailBytesSpin = wxSpinCtrl:new(Panel),
    wxSpinCtrl:setRange(TailBytesSpin, 1024, 104857600),
    wxSpinCtrl:setValue(TailBytesSpin, ?DEFAULT_TAIL_BYTES),

    Text = wxTextCtrl:new(Panel, ?wxID_ANY, [
        {style, ?wxTE_MULTILINE bor ?wxTE_RICH2 bor ?wxTE_DONTWRAP bor ?wxTE_READONLY}
    ]),

    %% Fonts (reuse your erm_fonts if present, else fallback)
    catch begin
        Font = erm_fonts:get_font(Frame, 10, 400),
        wxTextCtrl:setFont(Text, Font)
    end,

    %% Layout
    TopSizer = wxBoxSizer:new(?wxVERTICAL),
    Toolbar = wxBoxSizer:new(?wxHORIZONTAL),
    wxSizer:add(Toolbar, OpenBtn, [{flag, ?wxALL}, {border, 4}]),
    wxSizer:add(Toolbar, TailChk, [{flag, ?wxALIGN_CENTER_VERTICAL bor ?wxALL}, {border, 4}]),
    wxSizer:add(Toolbar, TailBytesLbl, [{flag, ?wxALIGN_CENTER_VERTICAL bor ?wxALL}, {border, 4}]),
    wxSizer:add(Toolbar, TailBytesSpin, [{flag, ?wxALL}, {border, 4}]),

    wxSizer:addSpacer(Toolbar, 20, []),
    wxSizer:add(Toolbar, SaveBtn, [{flag, ?wxALL}, {border, 4}]),
    wxSizer:add(Toolbar, CopyBtn, [{flag, ?wxALL}, {border, 4}]),
    wxSizer:addSpacer(Toolbar, 10, []),
    wxSizer:add(Toolbar, ClearBtn, [{flag, ?wxALL}, {border, 4}]),

    wxSizer:add(TopSizer, Toolbar, [{flag, ?wxEXPAND}]),
    wxSizer:add(TopSizer, Text, [{proportion, 1}, {flag, ?wxEXPAND bor ?wxALL}, {border, 4}]),

    wxPanel:setSizer(Panel, TopSizer),

    %% Status bar
    Status = wxFrame:createStatusBar(Frame, []),
    wxStatusBar:setStatusText(Status, "Ready", []),

    %% Events
    wxButton:connect(OpenBtn, command_button_clicked, []),
    wxCheckBox:connect(TailChk, command_checkbox_clicked, []),
    wxButton:connect(SaveBtn, command_button_clicked, []),
    wxButton:connect(CopyBtn, command_button_clicked, []),
    wxButton:connect(ClearBtn, command_button_clicked, []),
    wxFrame:connect(Frame, close_window, []),

    %% Timer for tailing
    Tmr = wxTimer:new(Frame),
    wxTimer:start(Tmr, ?TIMER_MS),
    wxFrame:connect(Frame, timer, []),

    wxFrame:show(Frame),

    State = #state{
        parent = Frame,
        panel = Panel,
        config = Config,
        text = Text,
        status = Status,
        open_btn = OpenBtn,
        tail_chk = TailChk,
        save_btn = SaveBtn,
        copy_btn = CopyBtn,
        clear_btn = ClearBtn,
        tail_bytes_spin = TailBytesSpin,
        timer = Tmr
    },
    {Frame, State}.

%% ------------------------------------------------------------------
%% Event handling
%% ------------------------------------------------------------------

handle_event(#wx{id = ?wxID_OPEN, event = #wxCommand{type = command_button_clicked}}, State) ->
    {noreply, open_dialog(State)};
handle_event(#wx{id = BtnId, event = #wxCommand{type = command_button_clicked}}, State) ->
    SaveId = wxWindow:getId(State#state.save_btn),
    CopyId = wxWindow:getId(State#state.copy_btn),
    ClearId = wxWindow:getId(State#state.clear_btn),
    case BtnId of
        Id when Id =:= SaveId -> {noreply, do_save_ipfs(State)};
        Id when Id =:= CopyId -> {noreply, copy_cid_to_clipboard(State)};
        Id when Id =:= ClearId ->
            wxTextCtrl:clear(State#state.text),
            wxStatusBar:setStatusText(State#state.status, "Cleared", []),
            {noreply, State#state{size = 0}};
        _ ->
            {noreply, State}
    end;
handle_event(#wx{id = CbId, event = #wxCommand{type = command_checkbox_clicked}}, State) ->
    TailId = wxWindow:getId(State#state.tail_chk),
    case CbId of
        Id when Id =:= TailId ->
            Tailing = wxCheckBox:getValue(State#state.tail_chk),
            wxStatusBar:setStatusText(
                State#state.status,
                if
                    Tailing -> "Following…";
                    true -> "Paused"
                end,
                []
            ),
            {noreply, State#state{tailing = Tailing}};
        _ ->
            {noreply, State}
    end;
handle_event(#wx{event = #wxClose{}}, State) ->
    {stop, normal, cleanup(State)};
handle_event(Wx = #wx{}, State) ->
    case wxEvent:getEventType(Wx) of
        timer -> {noreply, maybe_tail(State)};
        _ -> {noreply, State}
    end;
handle_event(Ev, State) ->
    ?LOG_DEBUG("Unhandled event ~p", [Ev]),
    {noreply, State}.

%% ------------------------------------------------------------------
%% Calls / Casts / Infos
%% ------------------------------------------------------------------

handle_call(show, _From, State = #state{parent = Frame}) ->
    wxFrame:show(Frame),
    {reply, ok, State};
handle_call(close, _From, State = #state{parent = Frame}) ->
    wxFrame:hide(Frame),
    {reply, ok, State};
handle_call(_Req, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) -> {noreply, State}.

handle_info(_Msg, State) -> {noreply, State}.

code_change(_, _, State) -> {ok, State}.

terminate(_Reason, State) -> cleanup(State).

cleanup(State = #state{fh = Fh, timer = Tmr, parent = Frame}) ->
    catch (Fh =/= undefined andalso file:close(Fh)),
    catch wxTimer:stop(Tmr),
    catch wxFrame:destroy(Frame),
    catch wx:destroy(),
    State.

%% ------------------------------------------------------------------
%% File open & tail logic
%% ------------------------------------------------------------------

open_dialog(State = #state{parent = Frame, tail_bytes_spin = Spin, text = Text}) ->
    Dlg = wxFileDialog:new(Frame, [
        {message, "Open log file"}, {style, ?wxFD_OPEN bor ?wxFD_FILE_MUST_EXIST}
    ]),
    Ret = wxFileDialog:showModal(Dlg),
    case Ret of
        ?wxID_OK ->
            Path = wxFileDialog:getPath(Dlg),
            wxTextCtrl:clear(Text),
            TailBytes = wxSpinCtrl:getValue(Spin),
            State2 = open_file(Path, TailBytes, State),
            wxFileDialog:destroy(Dlg),
            State2;
        _ ->
            wxFileDialog:destroy(Dlg),
            State
    end.

open_file(Path, TailBytes, State) ->
    case file:read_file_info(Path) of
        {ok, #file_info{inode = Inode, size = Sz}} ->
            Mode = [read, raw, binary],
            case file:open(Path, Mode) of
                {ok, Fh} ->
                    {StartOff, Prefetch} =
                        case Sz > TailBytes of
                            true -> {Sz - TailBytes, TailBytes};
                            false -> {0, Sz}
                        end,
                    _ = prefill_text(Fh, StartOff, Prefetch, State#state.text),
                    wxStatusBar:setStatusText(
                        State#state.status, io_lib:format("Opened ~s (~p bytes)", [Path, Sz]), []
                    ),
                    State#state{path = Path, fh = Fh, inode = Inode, size = Sz};
                {error, R} ->
                    wxStatusBar:setStatusText(
                        State#state.status, io_lib:format("Open failed: ~p", [R]), []
                    ),
                    State
            end;
        Error ->
            wxStatusBar:setStatusText(
                State#state.status, io_lib:format("Stat failed: ~p", [Error]), []
            ),
            State
    end.

prefill_text(Fh, StartOff, Bytes, TextCtrl) ->
    case file:pread(Fh, StartOff, Bytes) of
        {ok, Bin} ->
            Str = unicode:characters_to_list(Bin),
            wxTextCtrl:appendText(TextCtrl, Str),
            ok;
        _ ->
            ok
    end.

maybe_tail(State = #state{tailing = false}) ->
    State;
%% nothing open
maybe_tail(State = #state{fh = undefined, tailing = true}) ->
    State;
maybe_tail(
    State = #state{path = Path, fh = Fh, inode = Inode, size = LastSz, text = Text, status = Status}
) ->
    case file:read_file_info(Path) of
        {ok, #file_info{inode = Inode2, size = Sz}} ->
            %% Rotation or truncation
            case {Inode2 =/= Inode, Sz < LastSz} of
                {true, _} ->
                    wxStatusBar:setStatusText(Status, "Log rotated, reopening…", []),
                    catch file:close(Fh),
                    open_file(Path, ?DEFAULT_TAIL_BYTES, State#state{fh = undefined});
                {_, true} ->
                    wxStatusBar:setStatusText(Status, "Log truncated, resetting offset…", []),
                    Data = read_delta(Fh, 0, Sz),
                    append_if_any(Text, Data),
                    State#state{size = Sz};
                _ ->
                    case Sz > LastSz of
                        true ->
                            Data = read_delta(Fh, LastSz, Sz - LastSz),
                            append_if_any(Text, Data),
                            State#state{size = Sz};
                        false ->
                            State
                    end
            end;
        _ ->
            State
    end.

read_delta(Fh, Off, Len) ->
    case file:pread(Fh, Off, Len) of
        {ok, Bin} -> Bin;
        eof -> <<>>;
        _ -> <<>>
    end.

append_if_any(_TextCtrl, <<>>) ->
    ok;
append_if_any(TextCtrl, Bin) ->
    Str = unicode:characters_to_list(Bin),
    wxTextCtrl:appendText(TextCtrl, Str),
    caret_to_end(TextCtrl).

caret_to_end(TextCtrl) ->
    {From, To} = wxTextCtrl:getSelection(TextCtrl),
    Len = wxTextCtrl:getLastPosition(TextCtrl),
    %% Keep selection if user selected text; otherwise follow caret
    case From =:= To of
        true -> wxTextCtrl:setInsertionPoint(TextCtrl, Len);
        false -> ok
    end.

%% ------------------------------------------------------------------
%% IPFS: save full log file or current selection to IPFS and expose CID
%% ------------------------------------------------------------------

do_save_ipfs(State = #state{text = Text, path = Path, status = Status, copy_btn = CopyBtn}) ->
    {SelFrom, SelTo} = wxTextCtrl:getSelection(Text),
    CID =
        case SelFrom =:= SelTo of
            true ->
                %% No selection
                case Path of
                    undefined ->
                        Tmp = tmpfile_path(),
                        Val = wxTextCtrl:getValue(Text),
                        ok = file:write_file(Tmp, unicode:characters_to_binary(Val)),
                        ipfs_add(Tmp);
                    P ->
                        ipfs_add(P)
                end;
            false ->
                TextSel = wxTextCtrl:getRange(Text, SelFrom, SelTo),
                Tmp = tmpfile_path(),
                ok = file:write_file(Tmp, unicode:characters_to_binary(TextSel)),
                ipfs_add(Tmp)
        end,
    case CID of
        {ok, C} ->
            wxStatusBar:setStatusText(Status, io_lib:format("Saved to IPFS: ~s", [C]), []),
            wxWindow:enable(CopyBtn),
            State#state{last_cid = C};
        {error, Reason} ->
            wxStatusBar:setStatusText(Status, io_lib:format("IPFS add failed: ~p", [Reason]), []),
            State
    end.

copy_cid_to_clipboard(State = #state{last_cid = undefined}) ->
    State;
copy_cid_to_clipboard(State = #state{last_cid = CID, status = Status}) ->
    Clp = wxClipboard:new(),
    ok = wxClipboard:open(Clp),
    _ = wxClipboard:setData(Clp, wxTextDataObject:new(CID)),
    wxClipboard:close(Clp),
    wxStatusBar:setStatusText(Status, "CID copied to clipboard", []),
    State.

%% ------------------------------------------------------------------
%% Helpers
%% ------------------------------------------------------------------

tmpfile_path() ->
    FN = io_lib:format("/tmp/erm_log_~p_~p.log", [
        erlang:phash2(self()), erlang:system_time(millisecond)
    ]),
    lists:flatten(FN).

ipfs_add(Path) ->
    %% Use ipfs CLI; expects daemon running. Returns {ok, CID} or {error, Reason}
    Cmd = io_lib:format('ipfs add --cid-version=1 --raw-leaves -Q "~s"', [Path]),
    try os:cmd(lists:flatten(Cmd)) of
        Out ->
            case string:trim(Out) of
                "" -> {error, empty_output};
                C -> {ok, C}
            end
    catch
        C:R -> {error, {C, R}}
    end.
