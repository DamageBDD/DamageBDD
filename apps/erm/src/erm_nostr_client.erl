-module(erm_nostr_client).
-behaviour(wx_object).

-include_lib("wx/include/wx.hrl").
-include_lib("kernel/include/logger.hrl").
-export([start/1, handle_event/2]).
-export([init/1, handle_info/2, handle_call/3, handle_cast/2, terminate/2, code_change/3]).
-export([post_note/1]).

-record(state, {
    frame,
    config,
    listbox,
    input,
    relay = "wss://relay.damus.io",
    panel,
    editor
}).
-export([show/0]).
-export([close/0]).
-export([update_font/2]).

start(Config) -> wx_object:start_link(?MODULE, Config, []).
init(Config) ->
    wx:new(),
    wx:batch(fun() -> do_init(Config) end).

do_init(Config) ->
    Frame = wxFrame:new(wx:null(), -1, "NostrMini", []),
    Panel = wxPanel:new(Frame),
    VBox = wxBoxSizer:new(?wxVERTICAL),
    ListBox = wxListBox:new(Panel, -1, [{size, {400, 300}}]),
    Input =
        wxTextCtrl:new(Panel, ?wxID_ANY, [
            {value, ""}, {style, ?wxTE_CENTER}
        ]),
    wxSizer:add(VBox, ListBox, [{proportion, 1}, {flag, ?wxEXPAND}]),
    wxSizer:add(VBox, Input, [{flag, ?wxEXPAND}]),
    wxPanel:setSizer(Panel, VBox),
    wxFrame:show(Frame),
    wxFrame:connect(Frame, close_window),
    wxTextCtrl:connect(Input, command_text_enter),
    self() ! fetch,
    State =
        #state{
            frame = Frame,
            config = Config,
            panel = Panel,
            listbox = ListBox,
            editor = Input
        },
    wxPanel:connect(ListBox, key_up, []),
    wxPanel:connect(Panel, key_up, []),
    wxFrame:connect(Frame, key_up, []),
    {Frame, State}.
close() ->
    case gproc:lookup_local_name({?MODULE, erm_nostr_client}) of
        undefined -> ok;
        Pid -> wx_object:call(Pid, close)
    end.

show() ->
    case gproc:lookup_local_name({?MODULE, erm_nostr_client}) of
        undefined -> start([]);
        Pid -> wx_object:call(Pid, show)
    end.
update_font(Frame, TextCtrl) ->
    ?LOG_DEBUG("Frame ~p ~p", [Frame, TextCtrl]),
    Font = erm_fonts:get_font(Frame, 20, 10),
    %% Set the font on the TextCtrl
    wxTextCtrl:setFont(TextCtrl, Font),
    %% Clean up the font object
    wxFont:destroy(Font).
handle_event(#wx{event = #wxClose{}}, State) ->
    wxFrame:destroy(State#state.frame),
    {stop, normal, State};
handle_event(_Ev = #wx{event = #wxKey{keyCode = 27}}, State = #state{frame = Frame}) ->
    ?LOG_DEBUG("Got Escape Key ~n", []),
    wxWindow:hide(Frame),
    {noreply, State};
handle_event(#wx{event = #wxCommand{type = command_text_enter}}, State = #state{input = Input}) ->
    Text = wxTextCtrl:getValue(Input),
    post_note(Text),
    wxTextCtrl:clear(Input),
    {noreply, State};
handle_event(_, State) ->
    {noreply, State}.

handle_call(_, _From, State) ->
    {reply, ok, State}.
handle_cast(_, State) ->
    {noreply, State}.
handle_info(fetch, State = #state{listbox = ListBox}) ->
    % Just mock some notes here
    Notes = [
        <<"nostr is fun!">>,
        <<"hello world">>,
        <<"decentralized social ftw">>
    ],
    wxListBox:clear(ListBox),
    lists:foreach(fun(Note) -> wxListBox:append(ListBox, Note) end, Notes),
    {noreply, State};
handle_info(_, State) ->
    {noreply, State}.

terminate(_, _State) -> ok.
code_change(_, State, _) -> {ok, State}.

post_note(_Text) ->
    ok.
