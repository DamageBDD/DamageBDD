-module(nosternity_gui).

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
-export([fetch_notes/1, create_list/1, render_list_item/2]).

-record(state, {parent, config, panel, font, note_list, react_button, share_button}).

%% Records for Nostr notes

-record(note, {id, content, author, timestamp}).

start(Config) -> wx_object:start_link(?MODULE, Config, []).

%% API to start the application

init(Config) ->
    Env = persistent_term:get(erm_wx_env),
    wx:set_env(Env),
    wx:batch(fun() -> do_init(Config) end).

do_init(Config) ->
    WxFrame = wxFrame:new(wx:null(), ?wxID_ANY, "erm_nostr", [{size, {600, 300}}]),
    Panel = wxScrolledWindow:new(WxFrame, [{style, ?wxVSCROLL}, {size, {600, 300}}]),
    wxScrolledWindow:setScrollbars(Panel, 5, 5, 600, 300),
    wxScrolledWindow:setScrollRate(Panel, 5, 5),
    create_list({Panel, []}),
    wxFrame:connect(WxFrame, close_window, []),
    wxPanel:connect(Panel, scrollwin_bottom, [{callback, fun scroll_event/2}]),
    wxPanel:connect(Panel, scrollwin_top, [{callback, fun scroll_event/2}]),
    wxPanel:connect(Panel, scrollwin_lineup, [{callback, fun scroll_event/2}]),
    wxPanel:connect(Panel, scrollwin_linedown, []),
    wxPanel:connect(Panel, scrollwin_pageup, []),
    wxPanel:connect(Panel, scrollwin_pagedown, []),
    wxPanel:connect(Panel, key_up, []),
    wxFrame:connect(WxFrame, key_up, []),
    wxFrame:show(WxFrame),
    State = #state{parent = WxFrame, config = Config, panel = Panel},
    gproc:reg_other({n, l, {?MODULE, nostr_feed}}, self()),
    {WxFrame, State}.

create_list({Parent, _Notes}) ->
    Sizer = wxBoxSizer:new(?wxVERTICAL),
    wxPanel:setSizer(Parent, Sizer),
    %% Initial load of notes
    Notes = fetch_notes(0),
    lists:map(
        fun(Note) ->
            Widget = render_list_item(Parent, Note),
            wxSizer:add(Sizer, Widget, [{proportion, 1}, {flag, ?wxEXPAND bor ?wxALL}, {border, 5}])
        end,
        Notes
    ),
    {Sizer, 0}.

scroll_event(Event, {Sizer, Offset}) ->
    ScrollPos = wxScrolledWindow:getScrollPos(wxWindow:getParent(Event), ?wxVERTICAL),
    MaxScroll = wxScrolledWindow:getScrollRange(wxWindow:getParent(Event), ?wxVERTICAL),
    ?LOG_DEBUG("Scroll event ~p ~p ~p", [Event, Sizer, Offset]),
    %% Load more items if near bottom
    if
        ScrollPos > MaxScroll - 50 ->
            NewNotes = fetch_notes(Offset + 10),
            lists:map(
                fun(Note) ->
                    Widget = render_list_item(wxWindow:getParent(Event), Note),
                    wxSizer:add(Sizer, Widget, 0, ?wxEXPAND + ?wxALL, 5)
                end,
                NewNotes
            ),
            wxPanel:layout(wxWindow:getParent(Event)),
            {Sizer, Offset + 10};
        true ->
            {Sizer, Offset}
    end.

render_list_item(Parent, #note{id = Id, content = Content, author = Author, timestamp = Timestamp}) ->
    ItemPanel = wxPanel:new(Parent),
    ItemSizer = wxBoxSizer:new(?wxHORIZONTAL),
    NoteId = wxStaticText:new(ItemPanel, ?wxID_ANY, integer_to_list(Id), [{style, ?wxALIGN_LEFT}]),
    AuthorText = wxStaticText:new(ItemPanel, ?wxID_ANY, Author, [{style, ?wxALIGN_LEFT}]),
    ContentText = wxStaticText:new(ItemPanel, ?wxID_ANY, Content, [{style, ?wxALIGN_LEFT}]),
    TimestampText = wxStaticText:new(ItemPanel, ?wxID_ANY, Timestamp, [{style, ?wxALIGN_RIGHT}]),
    ReactionButton = wxButton:new(ItemPanel, ?wxID_ANY, [{label, "React"}]),
    ShareButton = wxButton:new(ItemPanel, ?wxID_ANY, [{label, "Share"}]),
    SzFlags = [{proportion, 0}, {flag, ?wxALIGN_CENTER_VERTICAL}, {border, 15}],
    wxSizer:add(ItemSizer, NoteId, SzFlags),
    wxSizer:add(ItemSizer, AuthorText, SzFlags),
    wxSizer:add(ItemSizer, ContentText, SzFlags),
    wxSizer:add(ItemSizer, TimestampText, SzFlags),
    wxSizer:add(ItemSizer, ReactionButton, SzFlags),
    wxSizer:add(ItemSizer, ShareButton, SzFlags),
    wxPanel:setSizer(ItemPanel, ItemSizer),
    ItemPanel.

close() ->
    case gproc:lookup_local_name({?MODULE, nostr_feed}) of
        undefined -> ok;
        Pid -> wx_object:call(Pid, shutdown)
    end.

show() ->
    case gproc:lookup_local_name({?MODULE, nostr_feed}) of
        undefined -> start([]);
        Pid -> wx_object:call(Pid, show)
    end.

fetch_notes(Offset) ->
    %% Mock data for simplicity; replace with actual fetching logic
    lists:map(
        fun(N) ->
            #note{
                id = Offset + N,
                content = "Note " ++ integer_to_list(Offset + N),
                author = "Author" ++ integer_to_list(N),
                timestamp = "2024-12-28 10:" ++ integer_to_list(N * 10)
            }
        end,
        lists:seq(1, 20)
    ).

handle_event(
    #wx{id = Id, event = #wxCommand{type = command_button_clicked}},
    State = #state{parent = Parent}
) ->
    B0 = wxWindow:findWindowById(Id, [{parent, Parent}]),
    Butt = wx:typeCast(B0, wxButton),
    handle_button_click(wxButton:getLabel(Butt), State);
handle_event(_Ev = #wx{event = #wxKey{keyCode = 27}}, State = #state{parent = Frame}) ->
    ?LOG_DEBUG("Got Escape Key ~n", []),
    wxWindow:close(Frame),
    {stop, normal, State};
handle_event(_Ev = #wx{event = #wxClose{}}, State = #state{parent = Frame}) ->
    ?LOG_DEBUG("Got wxClose Key ~n", []),
    wxWindow:close(Frame),
    ?LOG_DEBUG("handled wxClose Key ~n", []),
    {stop, normal, State};
handle_event(Ev = #wx{}, State) ->
    ?LOG_DEBUG("Got unhandled Event ~p~n", [Ev]),
    {noreply, State}.

handle_info(Msg, State) ->
    ?LOG_DEBUG("Got Info ~p~n", [Msg]),
    {noreply, State}.

handle_button_click(1, State) ->
    %% Handle React button click
    io:format("React button clicked.~n"),
    State;
handle_button_click(2, State) ->
    %% Handle Share button click
    io:format("Share button clicked.~n"),
    State;
handle_button_click(_, State) ->
    %% Default handler for unrecognized buttons
    State.

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
