%%%-------------------------------------------------------------------
%%% @doc
%%%  Filterable world clock list showing Zone | Time | Abbrev | UTC Offset
%%%  Mirrors erm_dose patterns: wx_object, gproc registration, sizers, events.
%%%  Requires GNU date in PATH for TZ conversions.
%%%
%%%  show()  -> opens or focuses the window
%%%  close() -> hides the window
%%%
%%%-------------------------------------------------------------------
-module(erm_zones).
-author("Steven Joseph <steven@stevenjoseph.in>").

-behaviour(wx_object).

-include_lib("wx/include/wx.hrl").
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

-define(TIMER_INTERVAL_MS, 1000).
-define(WINDOW_TITLE, "erm_zones").
-define(GPROC_NAME, {?MODULE, erm_zones}).

-record(state, {
    parent,
    panel,
    %% wxListCtrl
    list,
    %% wxTextCtrl
    filter_txt,
    %% all zones
    zones_all = [],
    %% filtered zones
    zones_view = [],
    timer_ref
}).

%% Curated default list (same spirit as your Python)
zones_default() ->
    [
        "Australia/Sydney",
        "America/Los_Angeles",
        "UTC",
        "US/Eastern",
        "Europe/Amsterdam",
        "Asia/Calcutta",
        "Asia/Riyadh",
        "Asia/Kuala_Lumpur",
        "Asia/Singapore",
        "Europe/Rome",
        "Asia/Ho_Chi_Minh",
        "Africa/Lagos"
    ].

%% You can extend this to many more (e.g., read from /usr/share/zoneinfo)
zones_all() ->
    zones_default().

start(Config) ->
    wx_object:start_link(?MODULE, Config, []).

show() ->
    case gproc:lookup_local_name({n, l, ?GPROC_NAME}) of
        undefined -> start([]);
        Pid -> wx_object:call(Pid, show)
    end.

close() ->
    case gproc:lookup_local_name({n, l, ?GPROC_NAME}) of
        undefined -> ok;
        Pid -> wx_object:call(Pid, close)
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% wx_object callbacks

init(_Config) ->
    wx:new(),
    Frame = wxFrame:new(
        wx:null(),
        ?wxID_ANY,
        ?WINDOW_TITLE,
        [
            {style,
                (?wxDEFAULT_FRAME_STYLE bor ?wxWANTS_CHARS) band
                    (bnot ?wxSYSTEM_MENU)}
        ]
    ),
    Panel = wxPanel:new(Frame, []),

    %% Controls
    FilterLbl = wxStaticText:new(Panel, ?wxID_ANY, "Filter zones:"),
    FilterTxt = wxTextCtrl:new(Panel, ?wxID_ANY, [{value, ""}]),

    List = wxListCtrl:new(Panel, ?wxID_ANY, [{style, ?wxLC_REPORT bor ?wxLC_SINGLE_SEL}]),
    ok = wxListCtrl:insertColumn(List, 0, "Zone", []),
    ok = wxListCtrl:insertColumn(List, 1, "Time", []),
    ok = wxListCtrl:insertColumn(List, 2, "Abbrev", []),
    ok = wxListCtrl:insertColumn(List, 3, "UTC Offset", []),

    %% Layout
    TopSizer = wxBoxSizer:new(?wxVERTICAL),
    FilterRow = wxBoxSizer:new(?wxHORIZONTAL),
    wxSizer:add(FilterRow, FilterLbl, [{flag, ?wxALIGN_CENTER_VERTICAL bor ?wxALL}, {border, 5}]),
    wxSizer:add(FilterRow, FilterTxt, [{proportion, 1}, {flag, ?wxEXPAND bor ?wxALL}, {border, 5}]),
    wxSizer:add(TopSizer, FilterRow, [{flag, ?wxEXPAND}]),
    wxSizer:add(TopSizer, List, [{proportion, 1}, {flag, ?wxEXPAND bor ?wxALL}, {border, 5}]),
    wxPanel:setSizer(Panel, TopSizer),

    %% Events
    wxTextCtrl:connect(FilterTxt, command_text_updated, []),
    wxFrame:connect(Frame, close_window),

    %% Prepare state
    Zones = zones_all(),
    State0 = #state{
        parent = Frame,
        panel = Panel,
        list = List,
        filter_txt = FilterTxt,
        zones_all = Zones,
        zones_view = Zones
    },

    %% Populate list and start timer
    populate_list(State0),
    fit_columns(List),
    wxFrame:show(Frame),

    gproc:reg_other({n, l, ?GPROC_NAME}, self()),
    erlang:send_after(?TIMER_INTERVAL_MS, self(), tick),
    {Frame, State0}.

terminate(_Reason, #state{parent = Frame}) ->
    catch wxFrame:destroy(Frame),
    wx:destroy().

code_change(_OldVsn, _NewVsn, State) ->
    {ok, State}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Events

handle_event(#wx{event = #wxCommand{type = command_text_updated}}, State0 = #state{}) ->
    Filter = string:lowercase(wxTextCtrl:getValue(State0#state.filter_txt)),
    All = State0#state.zones_all,
    View = [Z || Z <- All, string:find(string:lowercase(Z), Filter) =/= nomatch],
    State1 = State0#state{zones_view = View},
    populate_list(State1),
    {noreply, State1};
handle_event(#wx{event = #wxClose{}}, State = #state{parent = Frame}) ->
    wxWindow:hide(Frame),
    {noreply, State};
handle_event(Ev, State) ->
    ?LOG_DEBUG("Unhandled event: ~p", [Ev]),
    {noreply, State}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Gen_server-ish

handle_info(tick, State0 = #state{}) ->
    update_times(State0),
    erlang:send_after(?TIMER_INTERVAL_MS, self(), tick),
    {noreply, State0};
handle_info(Msg, State) ->
    ?LOG_DEBUG("Info ~p", [Msg]),
    {noreply, State}.

handle_call(show, _From, State = #state{parent = Frame}) ->
    wxFrame:show(Frame),
    {reply, ok, State};
handle_call(close, _From, State = #state{parent = Frame}) ->
    wxFrame:hide(Frame),
    {reply, ok, State};
handle_call(Msg, _From, State) ->
    ?LOG_DEBUG("Call ~p", [Msg]),
    {reply, ok, State}.

handle_cast(Msg, State) ->
    ?LOG_DEBUG("Cast ~p", [Msg]),
    {noreply, State}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% UI helpers

populate_list(#state{list = List, zones_view = Zones}) ->
    wxListCtrl:deleteAllItems(List),
    lists:foreach(
        fun(Zone) ->
            _Idx = wxListCtrl:insertItem(List, 999999, Zone),
            ok
        end,
        Zones
    ).

fit_columns(List) ->
    %% autosize to header/content
    wxListCtrl:setColumnWidth(List, 0, -2),
    wxListCtrl:setColumnWidth(List, 1, -2),
    wxListCtrl:setColumnWidth(List, 2, -2),
    wxListCtrl:setColumnWidth(List, 3, -2),
    ok.

update_times(State = #state{list = List, zones_view = Zones}) ->
    Epoch = erlang:system_time(second),
    lists:foldl(
        fun(Zone, Row) ->
            {TimeStr, Abbr, Off} = zone_line(Zone, Epoch),
            ok = wxListCtrl:setItem(List, Row, 1, TimeStr),
            ok = wxListCtrl:setItem(List, Row, 2, Abbr),
            ok = wxListCtrl:setItem(List, Row, 3, Off),
            Row + 1
        end,
        0,
        Zones
    ),
    ok.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Time conversion via GNU date
%%
%% We ask GNU date to render a fixed epoch under TZ=<Zone>:
%%   TZ=Europe/Rome date -d @1695000000 '+%Y-%m-%d %H:%M:%S %Z %z'
%% Returns like: "2025-09-18 10:20:00 CEST +0200"
%% We split into time, abbrev, and numeric offset -> "UTC+02:00"

zone_line(Zone, Epoch) ->
    Cmd = io_lib:format(
        "TZ=~ts date -d @~ts '+%Y-%m-%d %H:%M:%S %Z %z'",
        [Zone, integer_to_list(Epoch)]
    ),
    Out0 = os:cmd(lists:flatten(Cmd)),
    Out = string:trim(Out0),
    %% Expect 4 tokens: Date, Time, Abbrev, +HHMM
    case string:tokens(Out, " ") of
        [Date, Time, Abbrev, OffsetHM] ->
            {DateTime, OffStr} = {Date ++ " " ++ Time, human_offset(OffsetHM)},
            {DateTime, Abbrev, OffStr};
        _ ->
            %% Fallback: just echo what we got, best effort
            {Out, "", ""}
    end.

human_offset(Offset) when is_binary(Offset) ->
    human_offset(binary_to_list(Offset));
human_offset(Offset) when is_list(Offset) ->
    case Offset of
        "+0000" ->
            "UTC+00:00";
        "-0000" ->
            "UTC+00:00";
        [Sign, H1, H2, M1, M2] when (Sign == $+ orelse Sign == $-) ->
            lists:flatten(io_lib:format("UTC~c~c~c:~c~c", [Sign, H1, H2, M1, M2]));
        _ ->
            Offset
    end;
human_offset(Other) ->
    Other.
