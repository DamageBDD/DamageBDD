-module(erm_launcher).

-include_lib("wx/include/wx.hrl").
-include_lib("kernel/include/logger.hrl").

-behaviour(wx_object).

-export(
    [
        start/1,
        init/1,
        terminate/2,
        code_change/3,
        handle_info/2,
        handle_call/3,
        handle_cast/2,
        handle_event/2
    ]
).
-export([show/0]).
-export([close/0]).

-record(state, {
    frame,
    panel,
    sizer,
    config = #{},
    % 'top' or 'bottom'
    search_bar_pos = top,
    % 'top' or 'bottom'
    favorites_row_pos = top,
    apps = [],
    filtered_apps = [],
    favorites = []
}).

%%% API Functions %%%

start(Config) -> wx_object:start_link(?MODULE, Config, []).

%%% wx_object Callbacks %%%
get_favourites() ->
    get_apps().
get_apps() ->
    [
        #{
            module => erm_dose,
            icon => create_bitmap("Dose"),
            label => "dose"
        }
    ].

init(Config) ->
    wx:new(),
    wx:batch(fun() -> do_init(Config) end).

do_init(Config) ->
    wx:new(),
    Resolution =
        case os:getenv("RESOLUTION") of
            false ->
                {1280, 720};
            %{1024, 576},
            StrRes ->
                [WStr, HStr] = string:lexemes(StrRes, "x"),
                {list_to_integer(WStr), list_to_integer(HStr)}
        end,
    Frame =
        wxFrame:new(
            wx:null(),
            ?wxID_ANY,
            "erm_launcher",
            [
                {size, Resolution},
                {style, (?wxDEFAULT_FRAME_STYLE bor ?wxWANTS_CHARS) band (bnot ?wxSYSTEM_MENU)}
            ]
        ),
    Panel = wxPanel:new(Frame),
    Sizer = wxBoxSizer:new(?wxVERTICAL),
    % Read metadata from YAML
    Favorites = get_favourites(),
    % Search bar
    SearchCtrl = wxTextCtrl:new(Panel, -1, [{style, ?wxTE_PROCESS_ENTER}]),
    wxSizer:add(Sizer, SearchCtrl, [{flag, ?wxEXPAND}]),
    Apps = get_apps(),
    % FlexGrid for apps
    GridSizer = wxFlexGridSizer:new(4, 5, 10, 10),
    add_apps_to_grid(Apps, Panel, GridSizer),
    wxSizer:add(Sizer, GridSizer, [{flag, ?wxEXPAND}]),
    % Favorites row
    FavoritesSizer = wxBoxSizer:new(?wxHORIZONTAL),
    add_favorites_to_row(Favorites, Panel, FavoritesSizer),
    wxSizer:add(Sizer, FavoritesSizer, [{flag, ?wxEXPAND}]),
    wxPanel:setSizer(Panel, Sizer),
    wxFrame:connect(Frame, close_window),
    wxFrame:show(Frame),
    gproc:reg_other({n, l, {?MODULE, erm_launcher}}, self()),
    {
        Frame,
        #state{
            frame = Frame,
            panel = Panel,
            sizer = Sizer,
            config = Config,
            apps = Apps,
            filtered_apps = Apps,
            favorites = Favorites
        }
    }.

close() ->
    case gproc:lookup_local_name({?MODULE, erm_launcher}) of
        undefined -> ok;
        Pid -> wx_object:call(Pid, close)
    end.

show() ->
    case gproc:lookup_local_name({?MODULE, erm_launcher}) of
        undefined -> start([]);
        Pid -> wx_object:call(Pid, show)
    end.
show(AppModule) ->
    case catch AppModule:show() of
        ok -> ok;
        Res -> ?LOG_ERROR("Error: Unable to show app ~p ~p~n", [AppModule, Res])
    end.

handle_event(#wx{event = #wxClose{}}, State = #state{frame = Frame}) ->
    io:format("~p Not Closing Launcher window ~n", [self()]),
    ok = wxFrame:setStatusText(Frame, "Not Closing Launcher...", []),
    {noreply, State};
handle_event(
    #wx{event = #wxCommand{type = command_button_clicked}, obj = Button, userData = Module}, State
) ->
    ?LOG_DEBUG("call show ~p ~p", [Module, Button]),
    show(Module),
    ?LOG_DEBUG("call show done ~p", [Module]),
    {noreply, State};
handle_event(
    #wx{event = #wxCommand{type = command_text_updated}, obj = SearchCtrl},
    #state{apps = Apps} = State
) ->
    Query = wxTextCtrl:getValue(SearchCtrl),
    FilteredApps = filter_apps(Query, Apps),
    update_grid(FilteredApps, State),
    {noreply, State}.

%% Callbacks handled as normal gen_server callbacks

handle_info(Msg, State) ->
    ?LOG_DEBUG("Got Info ~p~n", [Msg]),
    {noreply, State}.

handle_call(show, From, State = #state{frame = Frame}) ->
    ?LOG_DEBUG("closing ~p ~p", [From, State]),
    wxFrame:show(Frame),
    {reply, ok, State};
handle_call(close, From, State = #state{frame = Frame}) ->
    ?LOG_DEBUG("closing ~p ~p", [From, State]),
    wxFrame:hide(Frame),
    {reply, ok, State};
handle_call(Msg, _From, State) ->
    ?LOG_DEBUG("Got Call ~p~n", [Msg]),
    {reply, ok, State}.

handle_cast(Msg, State) ->
    ?LOG_DEBUG("Got cast ~p~n", [Msg]),
    {noreply, State}.

code_change(_, _, State) -> {stop, ignore, State}.

terminate(_Reason, _State = #state{frame = Frame}) ->
    wxFrame:destroy(Frame),
    wx:destroy().

%%% Helper Functions %%%

create_bitmap(Label) ->
    Bmp = wxBitmap:new(140, 30),
    DC = wxMemoryDC:new(),
    wxMemoryDC:selectObject(DC, Bmp),
    wxDC:setBackground(DC, ?wxWHITE_BRUSH),
    wxDC:clear(DC),
    wxDC:setTextForeground(DC, ?wxBLUE),
    wxDC:drawLabel(DC, Label, {5, 5, 130, 20}, [{alignment, ?wxALIGN_CENTER}]),
    wxMemoryDC:destroy(DC),
    Bmp.

add_apps_to_grid(Apps, Panel, GridSizer) ->
    lists:foreach(
        fun(#{module := Module, label := Label, icon := Icon} = _App) ->
            Button = wxBitmapButton:new(Panel, -1, Icon),
            wxSizer:add(GridSizer, Button, []),
            wxButton:connect(Button, command_button_clicked, [{userData, Module}]),
            wxButton:setToolTip(Button, Label)
        end,
        Apps
    ).

add_favorites_to_row(Favorites, Panel, Sizer) ->
    lists:foreach(
        fun(#{module := _Module, label := Label, icon := Icon} = _App) ->
            Button = wxBitmapButton:new(Panel, -1, Icon),
            wxSizer:add(Sizer, Button, []),
            wxButton:setToolTip(Button, Label)
        end,
        Favorites
    ).

filter_apps(Query, Apps) ->
    lists:filter(
        fun(App) ->
            Name = maps:get(name, App, ""),
            string:find(string:lowercase(Name), string:lowercase(Query)) =/= not_found
        end,
        Apps
    ).

update_grid(FilteredApps, State) ->
    GridSizer = wxFlexGridSizer:new(4, 5, 10, 10),
    add_apps_to_grid(FilteredApps, State#state.panel, GridSizer),
    wxSizer:replace(State#state.sizer, GridSizer),
    wxPanel:layout(State#state.panel),
    proportional_resize_with_alignments(State#state.panel).

create_box(Parent) ->
    Win = wxWindow:new(Parent, ?wxID_ANY, [
        {style, ?wxBORDER_SIMPLE},
        {size, {50, 25}}
    ]),
    wxWindow:setBackgroundColour(Win, ?wxWHITE),
    Win.
proportional_resize_with_alignments(Parent) ->
    % rows, cols, vgap, hgap
    GridSizer = wxGridSizer:new(3, 3, 2, 2),

    wxSizer:add(
        GridSizer,
        create_box(Parent),
        [{proportion, 0}, {flag, ?wxSHAPED bor ?wxALIGN_TOP bor ?wxALIGN_LEFT}]
    ),
    wxSizer:add(
        GridSizer,
        create_box(Parent),
        [{proportion, 0}, {flag, ?wxSHAPED bor ?wxALIGN_TOP bor ?wxALIGN_CENTER_HORIZONTAL}]
    ),
    wxSizer:add(
        GridSizer,
        create_box(Parent),
        [{proportion, 0}, {flag, ?wxSHAPED bor ?wxALIGN_TOP bor ?wxALIGN_RIGHT}]
    ),
    wxSizer:add(
        GridSizer,
        create_box(Parent),
        [{proportion, 0}, {flag, ?wxSHAPED bor ?wxALIGN_CENTER_VERTICAL bor ?wxALIGN_LEFT}]
    ),
    wxSizer:add(
        GridSizer,
        create_box(Parent),
        [{proportion, 0}, {flag, ?wxSHAPED bor ?wxALIGN_CENTER}]
    ),
    wxSizer:add(
        GridSizer,
        create_box(Parent),
        [{proportion, 0}, {flag, ?wxSHAPED bor ?wxALIGN_CENTER_VERTICAL bor ?wxALIGN_RIGHT}]
    ),
    wxSizer:add(
        GridSizer,
        create_box(Parent),
        [{proportion, 0}, {flag, ?wxSHAPED bor ?wxALIGN_BOTTOM bor ?wxALIGN_LEFT}]
    ),
    wxSizer:add(
        GridSizer,
        create_box(Parent),
        [{proportion, 0}, {flag, ?wxSHAPED bor ?wxALIGN_BOTTOM bor ?wxALIGN_CENTER_HORIZONTAL}]
    ),
    wxSizer:add(
        GridSizer,
        create_box(Parent),
        [{proportion, 0}, {flag, ?wxSHAPED bor ?wxALIGN_BOTTOM bor ?wxALIGN_RIGHT}]
    ),
    GridSizer.
