-module(erm_workout).
-author("Steven Joseph <steven@damagebdd.com>").

-behaviour(wx_object).

-include_lib("wx/include/wx.hrl").
-include_lib("kernel/include/logger.hrl").

-export([start/1, show/0, close/0]).
-export([
    init/1, terminate/2, code_change/3, handle_call/3, handle_cast/2, handle_info/2, handle_event/2
]).

-record(state, {
    frame,
    panel,
    %% wxGrid for data entry
    grid,
    %% wxTextCtrl for week label (e.g., "Week 6")
    week_txt,
    %% wxChoice for Day 1/2/3
    day_choice,
    save_btn,
    cancel_btn
}).

-define(COLS, ["Exercise", "Sets", "Reps", "Load", "Result", "RPE"]).
-define(DEFAULT_ROWS, 18).

start(Config) -> wx_object:start_link(?MODULE, Config, []).

show() ->
    case gproc:lookup_local_name({?MODULE, workout}) of
        undefined -> start([]);
        Pid -> wx_object:call(Pid, show)
    end.

close() ->
    case gproc:lookup_local_name({?MODULE, workout}) of
        undefined -> ok;
        Pid -> wx_object:call(Pid, close)
    end.

init(_Config) ->
    wx:new(),
    Frame = wxFrame:new(wx:null(), ?wxID_ANY, "erm_workout", [
        {style, ?wxDEFAULT_FRAME_STYLE bor ?wxWANTS_CHARS}
    ]),
    Panel = wxPanel:new(Frame, []),

    %% Top controls (Week + Day)
    WeekLbl = wxStaticText:new(Panel, ?wxID_ANY, "Week", []),
    WeekTxt = wxTextCtrl:new(Panel, ?wxID_ANY, [{value, "6"}]),
    DayLbl = wxStaticText:new(Panel, ?wxID_ANY, "Day", []),
    DayChoice = wxChoice:new(Panel, ?wxID_ANY, [{choices, ["1", "2", "3"]}]),
    wxChoice:setSelection(DayChoice, 0),

    %% Grid for entry
    Grid = wxGrid:new(Panel, ?wxID_ANY),
    wxGrid:createGrid(Grid, ?DEFAULT_ROWS, length(?COLS)),
    lists:foreach(
        fun({I, Label}) -> wxGrid:setColLabelValue(Grid, I, Label) end,
        lists:zip(lists:seq(0, length(?COLS) - 1), ?COLS)
    ),
    wxGrid:enableEditing(Grid, true),
    wxGrid:autoSizeColumns(Grid),

    %% Buttons
    SaveBtn = wxButton:new(Panel, ?wxID_ANY, [{label, "Save"}]),
    CancelBtn = wxButton:new(Panel, ?wxID_ANY, [{label, "Cancel"}]),
    AddRowBtn = wxButton:new(Panel, ?wxID_ANY, [{label, "+ Row"}]),
    DelRowBtn = wxButton:new(Panel, ?wxID_ANY, [{label, "- Row"}]),

    %% Layout
    Top = wxBoxSizer:new(?wxHORIZONTAL),
    wxSizer:add(Top, WeekLbl, [{flag, ?wxALL}, {border, 5}]),
    wxSizer:add(Top, WeekTxt, [{flag, ?wxALL}, {border, 5}]),
    wxSizer:add(Top, DayLbl, [{flag, ?wxALL}, {border, 5}]),
    wxSizer:add(Top, DayChoice, [{flag, ?wxALL}, {border, 5}]),

    Btns = wxBoxSizer:new(?wxHORIZONTAL),
    wxSizer:add(Btns, AddRowBtn, [{flag, ?wxALL}, {border, 5}]),
    wxSizer:add(Btns, DelRowBtn, [{flag, ?wxALL}, {border, 5}]),
    wxSizer:addStretchSpacer(Btns, []),
    wxSizer:add(Btns, CancelBtn, [{flag, ?wxALL}, {border, 5}]),
    wxSizer:add(Btns, SaveBtn, [{flag, ?wxALL}, {border, 5}]),

    Root = wxBoxSizer:new(?wxVERTICAL),
    wxSizer:add(Root, Top, [{flag, ?wxEXPAND bor ?wxALL}, {border, 5}]),
    wxSizer:add(Root, Grid, [{proportion, 1}, {flag, ?wxEXPAND bor ?wxALL}, {border, 5}]),
    wxSizer:add(Root, Btns, [{flag, ?wxEXPAND bor ?wxALL}, {border, 5}]),

    wxPanel:setSizer(Panel, Root),
    wxFrame:setSize(Frame, {100, 100, 900, 600}),
    wxFrame:center(Frame),
    wxFrame:show(Frame),

    %% Wire events
    wxButton:connect(SaveBtn, command_button_clicked, []),
    wxButton:connect(CancelBtn, command_button_clicked, []),
    wxButton:connect(AddRowBtn, command_button_clicked, []),
    wxButton:connect(DelRowBtn, command_button_clicked, []),
    wxFrame:connect(Frame, close_window, []),

    gproc:reg_other({n, l, {?MODULE, workout}}, self()),

    {Frame, #state{
        frame = Frame,
        panel = Panel,
        grid = Grid,
        week_txt = WeekTxt,
        day_choice = DayChoice,
        save_btn = SaveBtn,
        cancel_btn = CancelBtn
    }}.

handle_event(#wx{id = _Id, event = #wxClose{}}, State = #state{frame = F}) ->
    wxFrame:hide(F),
    {noreply, State};
handle_event(
    #wx{event = #wxCommand{type = command_button_clicked}},
    State = #state{grid = Grid, frame = F, week_txt = WeekTxt, day_choice = DayChoice}
) ->
    %% Determine which button by label
    {ok, Win} = wxWindow:findFocus(),
    Btn = wx:typeCast(Win, wxButton),
    Label = wxButton:getLabel(Btn),
    case Label of
        "Save" ->
            save_workout(Grid, WeekTxt, DayChoice),
            wxFrame:hide(F),
            {noreply, State};
        "Cancel" ->
            wxFrame:hide(F),
            {noreply, State};
        "+ Row" ->
            add_row(Grid),
            {noreply, State};
        "- Row" ->
            del_row(Grid),
            {noreply, State};
        _ ->
            {noreply, State}
    end;
handle_event(Ev = #wx{}, State) ->
    ?LOG_DEBUG("Unhandled ~p", [Ev]),
    {noreply, State}.

handle_call(show, _From, State = #state{frame = F}) ->
    wxFrame:show(F),
    {reply, ok, State};
handle_call(close, _From, State = #state{frame = F}) ->
    wxFrame:hide(F),
    {reply, ok, State};
handle_call(_, _From, State) ->
    {reply, ok, State}.
handle_cast(_, State) -> {noreply, State}.
handle_info(_, State) -> {noreply, State}.
code_change(_, _, State) -> {ok, State}.
terminate(_Reason, _State = #state{frame = F}) ->
    wxFrame:destroy(F),
    wx:destroy().

%% Helpers
add_row(Grid) ->
    R = wxGrid:getNumberRows(Grid),
    ok = wxGrid:appendRows(Grid, 1),
    wxGrid:autoSizeColumns(Grid),
    R.

del_row(Grid) ->
    R = wxGrid:getNumberRows(Grid),
    case R of
        0 -> ok;
        _ -> wxGrid:deleteRows(Grid, R - 1, 1)
    end,
    ok.

save_workout(Grid, WeekTxt, DayChoice) ->
    WeekStr = string:trim(wxTextCtrl:getValue(WeekTxt)),
    DayStr = wxChoice:getStringSelection(DayChoice),
    Rows = wxGrid:getNumberRows(Grid),
    Cols = wxGrid:getNumberCols(Grid),
    %% Collect non-empty rows (must have Exercise)
    DataRows = [row_to_list(Grid, R, Cols) || R <- lists:seq(0, Rows - 1)],
    NonEmpty = [R || R = [Ex | _] <- DataRows, string:trim(Ex) =/= ""],
    Timestamp = erlang:localtime(),
    {Date, {Hh, Mi, _}} = Timestamp,
    {Y, Mm, Dd} = Date,
    FileBase = io_lib:format("~4..0B-~2..0B-~2..0B_week~s_day~s", [Y, Mm, Dd, WeekStr, DayStr]),
    Home = os:getenv("HOME"),
    Dir = filename:join([Home, "Org", "workouts"]),
    ok = filelib:ensure_dir(filename:join(Dir, "dummy")),
    Csv = filename:join(Dir, lists:flatten(FileBase) ++ ".csv"),
    Org = filename:join(Dir, lists:flatten(FileBase) ++ ".org"),
    ok = write_csv(Csv, NonEmpty),
    ok = write_org(Org, WeekStr, DayStr, NonEmpty, {Hh, Mi}),
    ?LOG_INFO("Saved ~p rows to ~s and ~s", [length(NonEmpty), Csv, Org]),
    ok.

row_to_list(Grid, Row, Cols) ->
    [string:trim(wxGrid:getCellValue(Grid, Row, C)) || C <- lists:seq(0, Cols - 1)].

write_csv(Path, Rows) ->
    Header = string:join(?COLS, ",") ++ "\n",
    Lines = [string:join(Row, ",") ++ "\n" || Row <- Rows],
    file:write_file(Path, [Header | Lines]).

write_org(Path, WeekStr, DayStr, Rows, {Hh, Mi}) ->
    Header = io_lib:format("* Week ~s Day ~s (~2..0B:~2..0B)~n", [WeekStr, DayStr, Hh, Mi]),
    TableHdr = "| Exercise | Sets | Reps | Load | Result | RPE |\n|-\n",
    Body = [io_lib:format("| ~s | ~s | ~s | ~s | ~s | ~s |\n", Row) || Row <- Rows],
    file:write_file(Path, [Header, TableHdr | Body]).
