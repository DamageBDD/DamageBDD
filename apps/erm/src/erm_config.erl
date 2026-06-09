-module(erm_config).
-author("Steven Joseph <steven@stevenjoseph.in>").

%% A wx UI to view & edit Erlang sys.config with tabs per application.
%% Patterned after erm_dose (wx_object, show/close helpers, small state machine).

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
-export([load/1, save/1]).

-define(WIN_TITLE, "erm_config: sys.config editor").
-define(DEFAULT_CONFIG_FILE, "./sys.config").

%% Control IDs
-define(ID_SAVE, 9001).
-define(ID_RELOAD, 9002).

-record(state, {
    %% wxFrame
    parent,
    %% wxPanel
    panel,
    %% wxNotebook
    notebook,
    %% wxStatusBar
    status,
    %% sys.config path
    file,
    %% [{App, [{Key,Val}|...] }]
    data = [],
    %% #{CtrlId => {App, Key}}
    ctrls = #{},
    dirty = false
}).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Public API

start(Config) -> wx_object:start_link(?MODULE, Config, []).

show() ->
    case catch gproc:lookup_local_name({?MODULE, instance}) of
        undefined -> start([]);
        {'EXIT', _} -> start([]);
        Pid when is_pid(Pid) -> wx_object:call(Pid, show)
    end.

close() ->
    case catch gproc:lookup_local_name({?MODULE, instance}) of
        undefined -> ok;
        {'EXIT', _} -> ok;
        Pid when is_pid(Pid) -> wx_object:call(Pid, close)
    end.

%% Load sys.config terms from File.
load(File) when is_list(File) ->
    case file:consult(File) of
        {ok, Terms} -> {ok, normalize_terms(Terms)};
        Error -> Error
    end.

%% Save current data back to File (with timestamped .bak backup)
save(_State = #state{file = File, data = Data}) -> save(File, Data).

save(File, Data) ->
    _ = ensure_backup(File),
    TermStr = io_lib:format("~p.~n", [denormalize_terms(Data)]),
    file:write_file(File, TermStr).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% wx_object callbacks

init(Config) ->
    %Env = persistent_term:get(erm_wx_env),
    %wx:set_env(Env),
    File = proplists:get_value(file, Config, ?DEFAULT_CONFIG_FILE),
    Data0 =
        case load(File) of
            {ok, D} -> D;
            {error, _} -> []
        end,
    wx:batch(fun() -> do_init(File, Data0) end).

terminate(_Reason, #state{parent = Frame}) ->
    catch wxFrame:destroy(Frame),
    wx:destroy().

code_change(_Vsn, _OldState, State) -> {stop, ignore, State}.

handle_info(Msg, State) ->
    ?LOG_DEBUG("erm_config info: ~p", [Msg]),
    {noreply, State}.

handle_call(show, _From, State = #state{parent = Frame}) ->
    wxFrame:show(Frame),
    {reply, ok, State};
handle_call(close, _From, State = #state{parent = Frame}) ->
    wxFrame:hide(Frame),
    {reply, ok, State};
handle_call(get_state, _From, State) ->
    {reply, State, State};
handle_call(_Msg, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) -> {noreply, State}.

handle_event(#wx{id = _Id, event = #wxClose{}}, State = #state{parent = Frame}) ->
    wxFrame:hide(Frame),
    {noreply, State};
%% Save button clicked
handle_event(
    #wx{id = ?ID_SAVE, event = #wxCommand{type = command_button_clicked}},
    State0 = #state{}
) ->
    case do_collect(State0) of
        {ok, State1} ->
            case save(State1) of
                ok ->
                    set_status(State1, "Saved."),
                    {noreply, State1#state{dirty = false}};
                {error, Reason} ->
                    set_status(State1, io_lib:format("Save failed: ~p", [Reason])),
                    {noreply, State1}
            end;
        {error, E, BadCtrlId} ->
            highlight_invalid(BadCtrlId),
            set_status(State0, io_lib:format("Parse error: ~p", [E])),
            {noreply, State0}
    end;
%% Reload button clicked
handle_event(
    #wx{id = ?ID_RELOAD, event = #wxCommand{type = command_button_clicked}},
    State = #state{file = File}
) ->
    {ok, Data} = load(File),
    NewState = rebuild(State#state{data = Data, dirty = false}),
    set_status(NewState, "Reloaded."),
    {noreply, NewState};
%% Any text update in an editor
handle_event(
    #wx{event = #wxCommand{type = command_text_updated}},
    State = #state{}
) ->
    {noreply, State#state{dirty = true}};
handle_event(Ev, State) ->
    ?LOG_DEBUG("Unhandled event ~p", [Ev]),
    {noreply, State}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% UI construction

do_init(File, Data0) ->
    Frame = wxFrame:new(
        wx:null(),
        ?wxID_ANY,
        ?WIN_TITLE,
        [{style, ?wxDEFAULT_FRAME_STYLE bor ?wxWANTS_CHARS}]
    ),
    Panel = wxPanel:new(Frame, []),
    NB = wxNotebook:new(Panel, ?wxID_ANY, []),
    Status = wxFrame:createStatusBar(Frame),

    %% Top bar with Save/Reload
    BtnSizer = wxBoxSizer:new(?wxHORIZONTAL),
    SaveBtn = wxButton:new(Panel, ?ID_SAVE, [{label, "Save"}]),
    ReloadBtn = wxButton:new(Panel, ?ID_RELOAD, [{label, "Reload"}]),
    wxSizer:add(BtnSizer, SaveBtn, [{flag, ?wxALL}, {border, 5}]),
    wxSizer:add(BtnSizer, ReloadBtn, [{flag, ?wxALL}, {border, 5}]),

    %% Main sizer
    Root = wxBoxSizer:new(?wxVERTICAL),
    wxSizer:add(Root, BtnSizer, [{flag, ?wxEXPAND bor ?wxALL}, {border, 3}]),
    wxSizer:add(Root, NB, [{proportion, 1}, {flag, ?wxEXPAND bor ?wxALL}, {border, 3}]),

    wxPanel:setSizer(Panel, Root),

    State0 = #state{
        parent = Frame,
        panel = Panel,
        notebook = NB,
        status = Status,
        file = File,
        data = Data0,
        ctrls = #{},
        dirty = false
    },
    State1 = populate_notebook(State0),

    wxFrame:fit(Frame),
    center_and_show(Frame),
    catch gproc:reg_other({n, l, {?MODULE, instance}}, self()),
    {Frame, State1}.

rebuild(State = #state{notebook = NB}) ->
    %% Clear tabs and rebuild from current data
    Tabs = wxNotebook:getPageCount(NB),
    lists:foreach(fun(_) -> wxNotebook:deletePage(NB, 0) end, lists:seq(1, Tabs)),
    populate_notebook(State#state{ctrls = #{}}).

populate_notebook(State0 = #state{notebook = NB, data = Data}) ->
    lists:foldl(
        fun({App, AppCfg}, StAcc) -> add_app_tab(StAcc, NB, App, AppCfg) end,
        State0,
        Data
    ).

add_app_tab(State0 = #state{}, NB, App, AppCfg) ->
    %% Scrollable page per app
    Page = wxScrolledWindow:new(NB, ?wxID_ANY, [{style, ?wxVSCROLL bor ?wxHSCROLL}]),
    wxScrolledWindow:setScrollRate(Page, 5, 5),

    Grid = wxFlexGridSizer:new(0, 2, 6, 6),
    wxFlexGridSizer:addGrowableCol(Grid, 1),

    {RowsState, Ctrls} = build_kv_grid(State0, Page, Grid, App, to_kv_list(AppCfg)),

    PageSizer = wxBoxSizer:new(?wxVERTICAL),
    wxSizer:add(PageSizer, Grid, [{proportion, 1}, {flag, ?wxEXPAND bor ?wxALL}, {border, 8}]),
    wxWindow:setSizer(Page, PageSizer),

    ok = wxNotebook:addPage(NB, Page, atom_to_list(App)),
    RowsState#state{ctrls = maps:merge(RowsState#state.ctrls, Ctrls)}.

build_kv_grid(State0, Parent, Grid, App, KVs) ->
    lists:foldl(
        fun({K, V}, {St, AccCtrls}) ->
            Label = wxStaticText:new(Parent, ?wxID_ANY, fmt("~p", [K]), []),
            Txt = wxTextCtrl:new(Parent, ?wxID_ANY, [
                {value, fmt("~p", [V])}, {style, ?wxTE_PROCESS_ENTER}
            ]),
            wxSizer:add(Grid, Label, [{flag, ?wxALIGN_CENTER_VERTICAL}]),
            wxSizer:add(Grid, Txt, [{proportion, 1}, {flag, ?wxEXPAND}]),
            wxTextCtrl:connect(Txt, command_text_updated, []),
            {St, AccCtrls#{wxWindow:getId(Txt) => {App, K}}}
        end,
        {State0, #{}},
        KVs
    ).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Helpers

center_and_show(Frame) ->
    wxFrame:center(Frame),
    wxFrame:show(Frame).

set_status(#state{parent = Frame}, Str) when is_list(Str) ->
    wxFrame:setStatusText(Frame, Str),
    ok;
set_status(State, Str) ->
    set_status(State, io_lib:format("~ts", [Str])).

fmt(Fmt, Args) -> lists:flatten(io_lib:format(Fmt, Args)).

ensure_backup(File) ->
    case filelib:is_file(File) of
        true ->
            Backup = backup_name(File),
            _ = file:copy(File, Backup),
            ok;
        false ->
            ok
    end.

backup_name(File) ->
    {{Y, M, D}, {H, Mi, S}} = calendar:local_time(),
    Dir = filename:dirname(File),
    Base = filename:basename(File),
    TS = io_lib:format("~4..0B~2..0B~2..0B-~2..0B~2..0B~2..0B", [Y, M, D, H, Mi, S]),
    filename:join(Dir, fmt("~s.~s.bak", [Base, TS])).

%% Turn whatever came from sys.config into canonical [{App, [{K,V}...]}]
normalize_terms(Terms) when is_list(Terms) -> lists:map(fun normalize_app/1, Terms).

normalize_app({App, Map}) when is_map(Map) -> {App, maps:to_list(Map)};
normalize_app({App, List}) when is_list(List) -> {App, normalize_kvs(List)};
normalize_app(Other) -> Other.

normalize_kvs(List) ->
    lists:map(
        fun
            ({K, V}) -> {K, V};
            (K) -> {K, true}
        end,
        List
    ).

%% Reverse of normalize_terms
denormalize_terms(Norm) ->
    %% By default, write as list of {App, [{K,V}...]}
    Norm.

%% Ensure app cfg is list of {K,V}
to_kv_list(Map) when is_map(Map) -> maps:to_list(Map);
to_kv_list(List) when is_list(List) -> normalize_kvs(List).

%% Walk the UI controls, parse values and update State#state.data
do_collect(State = #state{ctrls = Ctrls, data = Data, notebook = NB}) ->
    try
        Data1 = lists:foldl(
            fun({CtrlId, {App, Key}}, AccData) ->
                Txt = wx:typeCast(wxWindow:findWindowById(CtrlId, [{parent, NB}]), wxTextCtrl),
                Str = wxTextCtrl:getValue(Txt),
                case parse_term(Str) of
                    {ok, Term} -> update_cfg(App, Key, Term, AccData);
                    {error, _} = E -> throw({parse_error, E, CtrlId})
                end
            end,
            Data,
            maps:to_list(Ctrls)
        ),
        {ok, State#state{data = Data1}}
    catch
        throw:{parse_error, E, BadCtrlId} -> {error, E, BadCtrlId}
    end.

update_cfg(App, Key, Val, Data) ->
    lists:keyreplace(
        App,
        1,
        Data,
        case lists:keyfind(App, 1, Data) of
            false -> {App, [{Key, Val}]};
            {App, KVs} -> {App, lists:keystore(Key, 1, KVs, {Key, Val})}
        end
    ).

parse_term(Str) when is_binary(Str) -> parse_term(binary_to_list(Str));
parse_term(Str) when is_list(Str) ->
    case erl_scan:string(Str ++ ".") of
        {ok, Tokens, _} ->
            case erl_parse:parse_term(Tokens) of
                {ok, Term} -> {ok, Term};
                {error, _} = E -> E
            end;
        {error, _} = E ->
            E
    end.

highlight_invalid(CtrlId) ->
    try
        Ctrl = wxWindow:findWindowById(CtrlId),
        wxWindow:setBackgroundColour(Ctrl, {255, 220, 220}),
        wxWindow:refresh(Ctrl)
    catch
        _:_ -> ok
    end.
