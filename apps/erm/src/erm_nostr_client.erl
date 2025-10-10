-module(erm_nostr_client).
-behaviour(wx_object).

-include_lib("wx/include/wx.hrl").
-include_lib("kernel/include/logger.hrl").
-export([start/1, handle_event/2]).
-export([init/1, handle_info/2, handle_call/3, handle_cast/2, terminate/2, code_change/3]).
-export([
    post_note/1,
    post_note/2
]).

-record(state, {
    frame,
    config,
    listbox,
    relay = "wss://relay.damus.io",
    panel,
    editor,
    btn_post,
    btn_cancel,
    btn_media,
    btn_emoji,
    btn_gif,
    %% new
    account_selector
}).
-export([show/0]).
-export([close/0]).
-export([update_font/2]).

start(Config) -> wx_object:start_link(?MODULE, Config, []).
init(Config) ->
    wx:batch(fun() -> do_init(Config) end).

do_init(Config) ->
    Env = persistent_term:get(erm_wx_env),
    wx:set_env(Env),
    %% --- Frame & Panel ---
    Frame = wxFrame:new(wx:null(), -1, "NostrMini", [{size, {820, 640}}]),
    Panel = wxPanel:new(Frame, []),

    %% --- Root layout ---
    Root = wxBoxSizer:new(?wxVERTICAL),
    %% --- ACCOUNT SELECTOR ---
    Accounts = ["Account 1", "Account 2", "Account 3"],
    AccountSelector = wxChoice:new(Panel, ?wxID_ANY, [{choices, Accounts}]),
    %% default selection
    wxChoice:setSelection(AccountSelector, 0),
    wxSizer:add(
        Root,
        AccountSelector,
        [{flag, ?wxLEFT bor ?wxRIGHT bor ?wxTOP bor ?wxEXPAND}, {border, 8}]
    ),

    %% --- HEADER: avatar + title ---
    Header = wxBoxSizer:new(?wxHORIZONTAL),
    %% Replace "profile.png" with your path or load from binary
    FallbackBmp =
        wxArtProvider:getBitmap("wxART_INFORMATION", [
            {client, "wxART_OTHER"},
            {size, {40, 40}}
        ]),
    Avatar = wxStaticBitmap:new(Panel, ?wxID_ANY, FallbackBmp, []),

    Title = wxStaticText:new(Panel, ?wxID_ANY, "What's on your mind?", []),
    TitleFont = wxFont:new(11, ?wxFONTFAMILY_DEFAULT, ?wxFONTSTYLE_NORMAL, ?wxFONTWEIGHT_BOLD),
    wxWindow:setFont(Title, TitleFont),
    wxSizer:add(Header, Avatar, [{flag, ?wxALL bor ?wxALIGN_CENTER_VERTICAL}, {border, 8}]),
    wxSizer:add(Header, Title, [{flag, ?wxLEFT bor ?wxALIGN_CENTER_VERTICAL}, {border, 4}]),
    wxSizer:add(Root, Header, [{flag, ?wxLEFT bor ?wxRIGHT bor ?wxTOP bor ?wxEXPAND}, {border, 8}]),

    %% --- BODY: list (timeline) on top, editor below (like composer) ---
    Body = wxBoxSizer:new(?wxVERTICAL),

    %% Your existing listbox (can be a feed or drafts)
    ListBox = wxListBox:new(Panel, -1, [{size, {800, 220}}]),
    wxSizer:add(Body, ListBox, [
        {proportion, 0}, {flag, ?wxLEFT bor ?wxRIGHT bor ?wxEXPAND}, {border, 8}
    ]),

    %% Editor wrapper to give nice padding and dark theme-ish border
    EditorWrap = wxPanel:new(Panel, []),
    EditorSizer = wxBoxSizer:new(?wxVERTICAL),

    %% --- MULTILINE EDITOR ---
    Editor =
        wxTextCtrl:new(
            EditorWrap,
            ?wxID_ANY,
            [
                {value, ""},
                {size, {800, 260}},
                %% RICH2 is MSW-only; harmless to drop
                {style, ?wxTE_MULTILINE bor ?wxTE_PROCESS_ENTER bor ?wxTE_WORDWRAP}
            ]
        ),

    %% make sure it's editable and focused
    wxTextCtrl:setEditable(Editor, true),
    wxWindow:setFocus(Editor),
    wxTextCtrl:setInsertionPointEnd(Editor),

    wxWindow:setToolTip(Editor, "Type something…  (Ctrl+Enter to Post, Shift+Enter for newline)"),

    %% --- TOOL ROW: media, emoji, GIF, grid ---
    ToolsRow = wxBoxSizer:new(?wxHORIZONTAL),

    %% Small helper to make a compact tool button
    MakeBtn = fun(Label) ->
        wxButton:new(
            EditorWrap,
            ?wxID_ANY,
            [
                {label, Label},
                {style, ?wxBU_EXACTFIT}
            ]
        )
    end,
    BtnMedia = MakeBtn("📎 Media"),
    BtnEmoji = MakeBtn("😊 Emoji"),
    BtnGIF = MakeBtn("GIFs"),
    BtnGrid = MakeBtn("⋯"),

    %% Actions row on the right: Cancel / Post
    BtnCancel = wxButton:new(EditorWrap, ?wxID_ANY, [{label, "Cancel"}]),
    BtnPost = wxButton:new(EditorWrap, ?wxID_ANY, [{label, "Post"}]),
    wxWindow:setToolTip(BtnPost, "Post (Ctrl+Enter)"),

    %% Assemble ToolsRow
    lists:foreach(
        fun(B) -> wxSizer:add(ToolsRow, B, [{flag, ?wxALL}, {border, 4}]) end,
        [BtnMedia, BtnEmoji, BtnGIF, BtnGrid]
    ),
    wxSizer:addStretchSpacer(ToolsRow, []),
    wxSizer:add(ToolsRow, BtnCancel, [{flag, ?wxALL}, {border, 4}]),
    wxSizer:add(ToolsRow, BtnPost, [{flag, ?wxALL}, {border, 4}]),

    %% Pack editor card
    wxSizer:add(EditorSizer, Editor, [{proportion, 1}, {flag, ?wxEXPAND bor ?wxALL}, {border, 6}]),
    wxSizer:add(EditorSizer, ToolsRow, [
        {flag, ?wxEXPAND bor ?wxLEFT bor ?wxRIGHT bor ?wxBOTTOM}, {border, 2}
    ]),
    wxPanel:setSizer(EditorWrap, EditorSizer),

    wxSizer:add(Body, EditorWrap, [
        {proportion, 1}, {flag, ?wxLEFT bor ?wxRIGHT bor ?wxBOTTOM bor ?wxEXPAND}, {border, 8}
    ]),
    wxSizer:add(Root, Body, [{proportion, 1}, {flag, ?wxEXPAND}]),

    %% Apply to panel
    wxPanel:setSizer(Panel, Root),

    %% --- Show & events ---
    wxFrame:show(Frame),
    wxFrame:connect(Frame, close_window),

    %% Keep Enter for posting but allow Shift+Enter for newline
    %wxTextCtrl:connect(Editor, key_down),
    wxTextCtrl:connect(Editor, command_text_enter),
    wxWindow:connect(BtnPost, command_button_clicked),
    wxWindow:connect(BtnCancel, command_button_clicked),
    wxWindow:connect(BtnMedia, command_button_clicked),
    wxWindow:connect(BtnEmoji, command_button_clicked),
    wxWindow:connect(BtnGIF, command_button_clicked),
    wxWindow:connect(BtnGrid, command_button_clicked),
    wxWindow:connect(AccountSelector, command_choice_selected),

    %% Kick off any initial fetch you had
    self() ! fetch,

    %% State
    State = #state{
        frame = Frame,
        config = Config,
        panel = Panel,
        listbox = ListBox,
        editor = Editor,
        btn_post = BtnPost,
        btn_cancel = BtnCancel,
        btn_media = BtnMedia,
        btn_emoji = BtnEmoji,
        btn_gif = BtnGIF,
        account_selector = AccountSelector
    },

    %% Global key routing (optional)
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
handle_event(#wx{event = #wxCommand{type = command_text_enter}}, State) ->
    Text = wxTextCtrl:getValue(State#state.editor),
    Account = wxChoice:getStringSelection(State#state.account_selector),
    post_note(Account, Text),
    wxTextCtrl:clear(State#state.editor),
    {noreply, State};
handle_event(
    #wx{
        event = #wxCommand{
            type = command_choice_selected,
            cmdString = Sel
        }
    },
    State
) ->
    ?LOG_INFO("Account switched to: ~s", [Sel]),
    {noreply, State};
handle_event(#wx{event = #wxClose{}}, State) ->
    wxFrame:destroy(State#state.frame),
    {stop, normal, State};
handle_event(_Ev = #wx{event = #wxKey{keyCode = 27}}, State = #state{frame = Frame}) ->
    ?LOG_DEBUG("Got Escape Key ~n", []),
    wxWindow:hide(Frame),
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
post_note(_Account, _Text) ->
    ok.
