%%--------------------------------------------------------------------
%% Posture reminder toast (dismiss by mouse-over or keybind)
%%--------------------------------------------------------------------
-module(erm_posture).
-author("Steven Joseph <steven@stevenjoseph.in>").
-license("Apache-2.0").

-include_lib("wx/include/wx.hrl").
-include_lib("kernel/include/logger.hrl").

-behaviour(wx_object).

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
-export([show_now/0, close/0, set_interval/1, snooze/1]).

-record(state, {
    % wxFrame
    parent,
    % wxPanel
    panel,
    % wxStaticText
    label,
    % map: #{interval_min := 20, message := "Neutral spine. Shoulders down & back. Breathe."}
    config = #{},
    timer_ref = undefined,
    visible = false
}).

-define(DEFAULT_INTERVAL_MIN, 20).
-define(TOAST_W, 430).
-define(TOAST_H, 120).

%%% ==================================================================
%%% Public API
%%% ==================================================================

start(Config) ->
    wx_object:start_link(?MODULE, Config, []).

show_now() ->
    case gproc:lookup_local_name({?MODULE, toast}) of
        undefined ->
            start(#{}),
            show_now();
        Pid ->
            wx_object:call(Pid, show_now)
    end.

close() ->
    case gproc:lookup_local_name({?MODULE, toast}) of
        undefined -> ok;
        Pid -> wx_object:call(Pid, close)
    end.

set_interval(Minutes) when is_integer(Minutes), Minutes > 0 ->
    case gproc:lookup_local_name({?MODULE, toast}) of
        undefined -> start(#{interval_min => Minutes});
        Pid -> wx_object:call(Pid, {set_interval, Minutes})
    end.

snooze(Minutes) when is_integer(Minutes), Minutes > 0 ->
    case gproc:lookup_local_name({?MODULE, toast}) of
        undefined -> start(#{interval_min => Minutes});
        Pid -> wx_object:call(Pid, {snooze, Minutes})
    end.

%%% ==================================================================
%%% wx_object callbacks
%%% ==================================================================

init(Config0) ->
    wx:new(),
    gproc:reg_other({n, l, {?MODULE, toast}}, self()),

    %% Merge defaults
    Config = maps:merge(
        #{
            interval_min => ?DEFAULT_INTERVAL_MIN,
            message => "Neutral spine. Shoulders down & back. Breathe. Unclench jaw."
        },
        mapify(Config0)
    ),

    wx:batch(fun() -> do_init(Config) end).

do_init(Config) ->
    %% Frameless, always-on-top toast
    Style = ?wxSTAY_ON_TOP bor ?wxFRAME_TOOL_WINDOW bor ?wxBORDER_NONE bor ?wxWANTS_CHARS,
    Frame = wxFrame:new(wx:null(), ?wxID_ANY, "erm_posture", [{style, Style}]),
    Panel = wxPanel:new(Frame, []),
    wxPanel:setBackgroundColour(Panel, {18, 18, 18}),

    %% Font: try erm_fonts else fallback
    Font =
        try
            erm_fonts:get_font(Frame, 11, 600)
        catch
            _:_ -> wxFont:new(12, ?wxFONTFAMILY_DEFAULT, ?wxFONTSTYLE_NORMAL, ?wxFONTWEIGHT_BOLD)
        end,

    Msg = maps:get(message, Config),
    Label = wxStaticText:new(Panel, ?wxID_ANY, Msg, [{style, ?wxALIGN_CENTER}]),
    wxStaticText:setForegroundColour(Label, {230, 230, 230}),
    case is_reference(Font) of
        % erm_fonts returns a ref handled by wx
        true -> ok;
        false -> wxStaticText:setFont(Label, Font)
    end,

    %% Buttons/keys are optional; we mostly dismiss by hover / ESC/Space
    Sizer = wxBoxSizer:new(?wxVERTICAL),
    wxSizer:add(Sizer, Label, [{proportion, 1}, {flag, ?wxEXPAND bor ?wxALL}, {border, 14}]),
    wxPanel:setSizer(Panel, Sizer),

    set_toast_geometry(Frame),
    hook_events(Frame, Panel),

    %% First schedule
    TimerRef = schedule_in(maps:get(interval_min, Config) * 60 * 1000),

    wxFrame:hide(Frame),
    {Frame, #state{
        parent = Frame, panel = Panel, label = Label, config = Config, timer_ref = TimerRef
    }}.

set_toast_geometry(Frame) ->
    D = wxDisplay:new(),
    {X, Y, W, H} = wxDisplay:getGeometry(D),
    Wx = ?TOAST_W,
    Hy = ?TOAST_H,
    %% bottom-right corner with margin
    Margin = 24,
    wxFrame:setBackgroundColour(Frame, {18, 18, 18}),
    wxFrame:setSize(Frame, {X + W - Wx - Margin, Y + H - Hy - Margin, Wx, Hy}),
    ok.

hook_events(Frame, Panel) ->
    %% Dismiss on hover (mouse enters), key up, and click anywhere
    wxWindow:connect(Panel, enter_window, []),
    wxWindow:connect(Panel, left_up, []),
    wxFrame:connect(Frame, key_up, []),
    wxFrame:connect(Frame, activate, []),
    ok.

schedule_in(Ms) when Ms > 0 ->
    erlang:send_after(Ms, self(), tick).

%%% ==================================================================
%%% Event Handlers
%%% ==================================================================

handle_event(#wx{event = #wxMouse{type = enter_window}}, State = #state{}) ->
    %% Mouse-over dismiss
    maybe_hide(State);
handle_event(#wx{event = #wxMouse{type = left_up}}, State) ->
    %% Click dismiss
    maybe_hide(State);
handle_event(#wx{event = #wxKey{keyCode = KC}}, State) when
    KC =:= 27; KC =:= 32; KC =:= $p; KC =:= $P
->
    %% Esc / Space / P to dismiss
    maybe_hide(State);
handle_event(#wx{event = #wxActivate{active = true}}, State) ->
    %% Keep on top when activated
    wxFrame:raise(State#state.parent),
    {noreply, State};
handle_event(Ev, State) ->
    ?LOG_DEBUG("Unhandled event ~p", [Ev]),
    {noreply, State}.

maybe_hide(State = #state{parent = Frame, visible = true}) ->
    wxFrame:hide(Frame),
    {noreply, State#state{visible = false}};
maybe_hide(State) ->
    {noreply, State}.

%%% ==================================================================
%%% Gen callbacks
%%% ==================================================================

handle_info(tick, State = #state{config = Cfg}) ->
    %% Show toast
    Frame = State#state.parent,
    set_toast_geometry(Frame),
    wxFrame:show(Frame),
    wxFrame:raise(Frame),
    %% Reschedule next tick
    TRef = schedule_in(maps:get(interval_min, Cfg) * 60 * 1000),
    {noreply, State#state{visible = true, timer_ref = TRef}};
handle_info(Msg, State) ->
    ?LOG_DEBUG("Info ~p", [Msg]),
    {noreply, State}.

handle_call(show_now, _From, State = #state{}) ->
    self() ! tick,
    {reply, ok, State};
handle_call({set_interval, Min}, _From, State = #state{config = Cfg, timer_ref = TRef}) ->
    cancel_timer(TRef),
    NewCfg = Cfg#{interval_min => Min},
    NewRef = schedule_in(Min * 60 * 1000),
    {reply, ok, State#state{config = NewCfg, timer_ref = NewRef}};
handle_call({snooze, Min}, _From, State = #state{timer_ref = TRef}) ->
    cancel_timer(TRef),
    NewRef = schedule_in(Min * 60 * 1000),
    %% If currently visible, hide until snooze ends
    maybe_hide(State),
    {reply, ok, State#state{timer_ref = NewRef}};
handle_call(close, _From, State = #state{parent = Frame}) ->
    wxFrame:hide(Frame),
    {reply, ok, State#state{visible = false}};
handle_call(Msg, _From, State) ->
    ?LOG_DEBUG("Call ~p", [Msg]),
    {reply, ok, State}.

handle_cast(Msg, State) ->
    ?LOG_DEBUG("Cast ~p", [Msg]),
    {noreply, State}.

code_change(_, _, State) -> {stop, ignore, State}.

terminate(_Reason, #state{parent = Frame}) ->
    wxFrame:destroy(Frame),
    wx:destroy(),
    ok.

%%% ==================================================================
%%% Helpers
%%% ==================================================================

cancel_timer(undefined) ->
    ok;
cancel_timer(Ref) when is_reference(Ref) ->
    erlang:cancel_timer(Ref),
    ok.

mapify(M) when is_map(M) -> M;
mapify(List) when is_list(List) ->
    maps:from_list(List);
mapify(_) ->
    #{}.
