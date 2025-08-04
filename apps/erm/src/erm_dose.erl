-module(erm_dose).
-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

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
-export([update_font/2]).

-record(state, {parent, config, panel, font, status, text, slider, dirty, strain_select}).

-define(TIMER_INTERVAL, 1000).
-define(FONT_SIZE, 24).

%% 1 second update interval

start(Config) -> wx_object:start_link(?MODULE, Config, []).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

init(Config) ->
    wx:new(),
    wx:batch(fun() -> do_init(Config) end).

set_window_size_and_position(Frame) ->
    % Get screen size
    % Create a wxDisplay object for the primary display
    Display = wxDisplay:new(),
    % Get screen size from wxDisplay object
    ScreenSize = wxDisplay:getGeometry(Display),
    % Print the screen size
    ?LOG_DEBUG("Screen size: ~p~n", [ScreenSize]),
    % Calculate window dimensions
    {_, _, ScreenWidth, ScreenHeight} = ScreenSize,
    WindowWidth = round(ScreenWidth * 0.5),
    % 20% of screen height
    WindowHeight = round(ScreenHeight * 0.5),
    % Set window size and position
    wxFrame:setSize(Frame, {0, ScreenHeight - WindowHeight, WindowWidth, WindowHeight}),
    wxFrame:center(Frame),
    ok.

do_init(Config) ->
    Frame =
        wxFrame:new(
            wx:null(),
            ?wxID_ANY,
            "erm_dose",
            [
                {style, (?wxDEFAULT_FRAME_STYLE bor ?wxWANTS_CHARS) band (bnot ?wxSYSTEM_MENU)}
            ]
        ),
    Panel = wxPanel:new(Frame, []),
    wxWindow:connect(Panel, paint, []),
    wxWindow:connect(Panel, activate, []),
    ButtonStyle = {style, ?wxEXPAND},
    DoseButton = wxButton:new(Panel, ?wxID_ANY, [{label, "Dose"}, ButtonStyle]),
    CancelButton = wxButton:new(Panel, ?wxID_ANY, [{label, "Cancel"}, ButtonStyle]),
    IncButton = wxButton:new(Panel, ?wxID_ANY, [{label, "+"}, ButtonStyle]),
    DecButton = wxButton:new(Panel, ?wxID_ANY, [{label, "-"}, ButtonStyle]),
    StrainChoice = wxChoice:new(Panel, ?wxID_ANY, [{choices, ["Blue Dream", "Master Kush"]}]),
    wxChoice:setSelection(StrainChoice, 0),
    %% Setup sizers
    % 4 rows, 10 columns, spacing 5
    %Sizer = wxFlexGridSizer:new(1),
    %% Setup slider with range from 0 to 100
    %% and a start value of 25
    Min = 0,
    Max = 100,
    StartValue = 50,
    %% Horizontal slider (default) with label
    Slider =
        wxSlider:new(
            Panel,
            1,
            StartValue,
            Min,
            Max,
            [{style, ?wxSL_HORIZONTAL bor ?wxSL_LABELS bor ?wxSL_AUTOTICKS}]
        ),
    wxSlider:setPageSize(Slider, 1),
    wxSlider:setLineSize(Slider, 1),
    wxSlider:setThumbLength(Slider, 1),
    Label =
        wxStaticText:new(Panel, ?wxID_ANY, "Dosage in milli grams (mg)", [{style, ?wxALIGN_CENTER}]),
    StrainLabel = wxStaticText:new(Panel, ?wxID_ANY, "Strain", [{style, ?wxALIGN_LEFT}]),
    Dose =
        wxTextCtrl:new(Panel, ?wxID_ANY, [
            {value, integer_to_list(StartValue)}, {style, ?wxTE_CENTER}
        ]),
    Font = wxFont:new(?FONT_SIZE, ?wxFONTFAMILY_DEFAULT, ?wxFONTSTYLE_NORMAL, ?wxFONTWEIGHT_BOLD),
    %TextFont = wxFont:new(300, ?wxFONTFAMILY_DEFAULT, ?wxFONTSTYLE_NORMAL, ?wxFONTWEIGHT_BOLD),
    TextFont = erm_fonts:get_font(Frame, 9, 500),
    ButtonFont = erm_fonts:get_font(Frame, 9, 100),
    wxTextCtrl:setFont(Dose, TextFont),
    wxStaticText:setFont(Label, Font),
    wxSlider:setFont(Slider, Font),
    wxButton:setFont(DoseButton, ButtonFont),
    wxButton:setFont(CancelButton, ButtonFont),
    wxButton:setFont(IncButton, ButtonFont),
    wxButton:setFont(DecButton, ButtonFont),
    wxTextCtrl:connect(Dose, command_text_updated, []),
    wxTextCtrl:connect(Dose, command_text_enter, []),
    wxTextCtrl:connect(Dose, text_maxlen, []),
    SzFlags = [{proportion, 1}, {flag, ?wxEXPAND}, {border, 5}],
    %wxPanel:setBackgroundColour(Frame, ?wxRED),
    Sizer = wxFlexGridSizer:new(4, 1, 5, 5),
    StrainSizer = wxBoxSizer:new(?wxHORIZONTAL),
    wxSizer:add(StrainSizer, StrainLabel, [{proportion, 0}, {flag, ?wxALL}, {border, 5}]),
    wxSizer:add(StrainSizer, StrainChoice, [{proportion, 1}, {flag, ?wxALL}, {border, 5}]),
    wxSizer:add(Sizer, Label, [{proportion, 1}]),
    wxSizer:add(Sizer, Dose, SzFlags),
    wxSizer:add(Sizer, StrainSizer, SzFlags),
    SliderSzFlags = [{proportion, 0}, {flag, ?wxALIGN_CENTER_VERTICAL}, {border, 5}],
    SliderSizer = wxBoxSizer:new(?wxHORIZONTAL),
    wxSizer:add(SliderSizer, DecButton, SliderSzFlags),
    wxSizer:add(SliderSizer, Slider, [{proportion, 1}, {flag, ?wxALL}, {border, 5}]),
    wxSizer:add(SliderSizer, IncButton, SliderSzFlags),
    wxSizer:add(Sizer, SliderSizer, [{flag, ?wxEXPAND}, {border, 5}]),
    ButtonSzFlags = [{proportion, 1}, {flag, ?wxEXPAND bor ?wxALL}, {border, 5}],
    ButtonSizer = wxBoxSizer:new(?wxHORIZONTAL),
    wxSizer:add(ButtonSizer, CancelButton, ButtonSzFlags),
    wxSizer:add(ButtonSizer, DoseButton, ButtonSzFlags),
    wxSizer:add(Sizer, ButtonSizer, [{flag, ?wxEXPAND bor ?wxALL}, {border, 5}]),
    wxFlexGridSizer:addGrowableCol(Sizer, 0),
    wxFlexGridSizer:addGrowableRow(Sizer, 1),
    %wxFlexGridSizer:setFlexibleDirection(Sizer, ?wxBOTH),
    wxFrame:setSizerAndFit(Panel, Sizer),
    wxTextCtrl:connect(Dose, key_up, []),
    wxButton:connect(Slider, key_up, []),
    wxSlider:connect(Slider, command_slider_updated, [{skip, false}]),
    wxButton:connect(IncButton, command_button_clicked, []),
    wxButton:connect(DecButton, command_button_clicked, []),
    wxButton:connect(DoseButton, key_up, []),
    wxButton:connect(CancelButton, key_up, []),
    wxButton:connect(DoseButton, command_button_clicked, []),
    wxButton:connect(CancelButton, command_button_clicked, []),
    wxPanel:connect(Panel, key_up, []),
    wxFrame:connect(Frame, key_up, []),
    wxSizer:setSizeHints(Sizer, Frame),
    set_window_size_and_position(Frame),
    wxFrame:show(Frame),
    %wxFrame:connect(Frame, close_window),
    ?LOG_DEBUG("Frame ~p", [Frame]),
    gproc:reg_other({n, l, {?MODULE, erm_dose}}, self()),
    State =
        #state{
            parent = Frame,
            config = Config,
            panel = Panel,
            status = "stared",
            text = Dose,
            slider = Slider,
            strain_select = StrainChoice
        },
    wx:batch(fun() -> update_panel(State) end),
    wxSlider:setFocus(Slider),
    wxTextCtrl:setSelection(Dose, 0, 0),
    %wxWindow:connect(Panel, size, [{userData, Dose}]),
    {Frame, State}.

close() ->
    case gproc:lookup_local_name({?MODULE, erm_dose}) of
        undefined -> ok;
        Pid -> wx_object:call(Pid, close)
    end.

show() ->
    case gproc:lookup_local_name({?MODULE, erm_dose}) of
        undefined -> start([]);
        Pid -> wx_object:call(Pid, show)
    end.

%wxFont:new([{pointSize, FontSize}, {family, ?wxFONTFAMILY_SWISS}, {style, ?wxFONTSTYLE_NORMAL},
%{weight, ?wxFONTWEIGHT_NORMAL}]).
update_font(Frame, TextCtrl) ->
    ?LOG_DEBUG("Frame ~p ~p", [Frame, TextCtrl]),
    Font = erm_fonts:get_font(Frame, 20, 10),
    %% Set the font on the TextCtrl
    wxTextCtrl:setFont(TextCtrl, Font),
    %% Clean up the font object
    wxFont:destroy(Font).

%%%%%%%%%%%%
%% Async Events are handled in handle_event as in handle_info

handle_event(
    #wx{id = Id, event = #wxCommand{type = command_button_clicked}},
    State = #state{text = TextCtrl, parent = Parent, slider = Slider}
) ->
    B0 = wxWindow:findWindowById(Id, [{parent, Parent}]),
    Butt = wx:typeCast(B0, wxButton),
    case wxButton:getLabel(Butt) of
        "-" ->
            ?LOG_DEBUG("- Button: clicked~n", []),
            Value = wxSlider:getValue(Slider),
            wxSlider:setValue(Slider, Value - 1),
            wxTextCtrl:setValue(TextCtrl, integer_to_list(Value)),
            {noreply, State};
        "+" ->
            ?LOG_DEBUG("+ Button: clicked~n", []),
            Value = wxSlider:getValue(Slider),
            wxSlider:setValue(Slider, Value + 1),
            wxTextCtrl:setValue(TextCtrl, integer_to_list(Value)),
            {noreply, State};
        "Dose" ->
            ?LOG_DEBUG("Dose Button: clicked~n", []),
            wxWindow:hide(Parent),
            {stop, normal, save_dose(State)};
        "Cancel" ->
            ?LOG_DEBUG("Cancel Button: clicked~n", []),
            wxWindow:hide(Parent),
            {stop, normal, State};
        Label ->
            ?LOG_DEBUG("Button: '~ts' clicked~n", [Label]),
            {noreply, State}
    end;
handle_event(
    _Ev = #wx{event = #wxKey{keyCode = 13}}, State = #state{parent = Parent, dirty = true}
) ->
    ?LOG_DEBUG("Got Enter Key ~n", []),
    wxWindow:hide(Parent),
    {stop, normal, save_dose(State)};
handle_event(_Ev = #wx{event = #wxKey{keyCode = 27}}, State = #state{parent = Frame}) ->
    ?LOG_DEBUG("Got Escape Key ~n", []),
    wxWindow:hide(Frame),
    {noreply, State};
handle_event(
    _Ev = #wx{event = #wxCommand{type = command_slider_updated, commandInt = Value}},
    State = #state{text = TextCtrl}
) ->
    ?LOG_DEBUG("Got slider update  ~p~n", [Value]),
    wxTextCtrl:setValue(TextCtrl, integer_to_list(Value)),
    {noreply, State#state{dirty = true}};
handle_event(Ev = #wx{}, State = #state{}) ->
    ?LOG_DEBUG("Got unhandled Event ~p~n", [Ev]),
    {noreply, State}.

%% Callbacks handled as normal gen_server callbacks

handle_info(Msg, State) ->
    ?LOG_DEBUG("Got Info ~p~n", [Msg]),
    {noreply, State}.

handle_call(get_value, _From, State = #state{slider = Slider}) ->
    {reply, wxSlider:getValue(Slider), State};
handle_call(show, From, State = #state{parent = Frame}) ->
    ?LOG_DEBUG("closing ~p ~p", [From, State]),
    wxFrame:show(Frame),
    {reply, ok, State};
handle_call(close, From, State = #state{parent = Frame}) ->
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

terminate(_Reason, _State = #state{parent = Frame}) ->
    wxFrame:destroy(Frame),
    wx:destroy().

update_panel(State) -> ?LOG_DEBUG("update panel ~p", [State]).

save_dose(State = #state{text = TextCtrl, strain_select = StrainSelect}) ->
    OrgPath = "Org",
    {ok, Timestamp} = datestring:format("<Y-m-d a H:M>", erlang:localtime()),
    Value = wxTextCtrl:getValue(TextCtrl),
    Strain = wxChoice:getStringSelection(StrainSelect),
    Entry = "\n" ++ Timestamp ++ " 0." ++ Value ++ "g" ++ " " ++ Strain,
    ?LOG_DEBUG("save dose ~p", [Entry]),
    file:write_file(filename:join([os:getenv("HOME"), OrgPath, "dose.org"]), Entry, [append]),
    State.
