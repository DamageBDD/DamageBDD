%%%-------------------------------------------------------------------
%%% @doc
%%% A small GS-style compatibility layer implemented with Erlang wx.
%%%
%%% The module keeps the parts of GS that are useful for application
%%% architecture:
%%%   * hierarchical objects
%%%   * owner-local object names
%%%   * create/config/read/destroy operations
%%%   * create_tree/2
%%%   * message-based events delivered to the owner process
%%%
%%% It is intentionally not a complete emulation of the retired GS API.
%%% Supported object types are: window, frame, button, label, entry,
%%% editor and listbox.
%%%
%%% Events have this shape:
%%%     {wxgs, IdOrName, EventType, Data, Args}
%%%
%%% A logical object reference has this shape:
%%%     {wxgs_ref, ServerPid, IntegerId}
%%%-------------------------------------------------------------------
-module(wxgs).
-behaviour(gen_server).

-include_lib("wx/include/wx.hrl").

-export([
    start/0,
    start_link/0,
    stop/0,
    stop/1,
    server/0,

    create/2,
    create/3,
    create/4,
    create_tree/2,
    config/2,
    read/2,
    destroy/1,
    message_dialog/3
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(SERVER, ?MODULE).
-define(FIRST_ID, 1000).
-define(FIRST_NATIVE_ID, 2000).

-record(object, {
    id,
    native_id,
    name = undefined,
    owner,
    type,
    wx_ref,
    container = undefined,
    sizer = undefined,
    parent = root,
    children = [],
    data = [],
    options = #{}
}).

-record(state, {
    next_id = ?FIRST_ID,
    next_native_id = ?FIRST_NATIVE_ID,
    objects = #{},
    names = #{},
    owner_monitors = #{}
}).

-type server_ref() :: pid().
-type object_ref() :: {wxgs_ref, pid(), pos_integer()}.
-type object_name() :: atom().
-type object_key() :: object_ref() | object_name().
-type option() :: atom() | tuple().
-type options() :: option() | [option()].

-export_type([server_ref/0, object_ref/0, object_key/0, option/0, options/0]).

%%%===================================================================
%%% Public API
%%%===================================================================

-spec start() -> server_ref().
start() ->
    case whereis(?SERVER) of
        undefined ->
            case gen_server:start({local, ?SERVER}, ?MODULE, [], []) of
                {ok, Pid} -> Pid;
                {error, {already_started, Pid}} -> Pid;
                {error, Reason} -> error({wxgs_start_failed, Reason})
            end;
        Pid ->
            Pid
    end.

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec stop() -> ok.
stop() ->
    case whereis(?SERVER) of
        undefined -> ok;
        Pid -> stop(Pid)
    end.

-spec stop(server_ref()) -> ok.
stop(Server) when is_pid(Server) ->
    gen_server:stop(Server).

-spec server() -> server_ref().
server() ->
    case whereis(?SERVER) of
        undefined -> error(wxgs_not_started);
        Pid -> Pid
    end.

-spec create(atom(), server_ref() | object_key()) -> object_ref() | {error, term()}.
create(Type, Parent) ->
    create(Type, Parent, []).

-spec create(atom(), server_ref() | object_key(), options()) -> object_ref() | {error, term()}.
create(Type, Parent, Options) ->
    Server = server_for(Parent),
    gen_server:call(
        Server,
        {create, self(), Type, undefined, Parent, normalize_options(Options)},
        infinity
    ).

-spec create(atom(), object_name(), server_ref() | object_key(), options()) ->
    object_ref() | {error, term()}.
create(Type, Name, Parent, Options) when is_atom(Name) ->
    Server = server_for(Parent),
    gen_server:call(
        Server,
        {create, self(), Type, Name, Parent, normalize_options(Options)},
        infinity
    ).

-spec create_tree(server_ref() | object_key(), list()) -> {ok, [object_ref()]} | {error, term()}.
create_tree(Parent, Tree) when is_list(Tree) ->
    try
        {ok, [create_tree_node(Parent, Node) || Node <- Tree]}
    catch
        Class:Reason:Stacktrace ->
            {error, {Class, Reason, Stacktrace}}
    end.

-spec config(object_key(), options()) -> ok | {error, term()}.
config(Object, Options) ->
    Server = server_for(Object),
    gen_server:call(Server, {config, self(), Object, normalize_options(Options)}, infinity).

-spec read(object_key(), atom() | tuple()) -> term().
read(Object, Key) ->
    Server = server_for(Object),
    gen_server:call(Server, {read, self(), Object, Key}, infinity).

-spec destroy(object_key()) -> ok | {error, term()}.
destroy(Object) ->
    Server = server_for(Object),
    gen_server:call(Server, {destroy, self(), Object}, infinity).

%% @doc Show a modal wx message dialog while keeping native wx calls
%% inside the wxgs server process. Parent may be a wxgs object reference
%% or an owner-local object name.
%%
%% Options:
%%   {caption, Text}
%%   {style, integer() | atom() | [atom()]}
%%   {pos, {X, Y}}
%%
%% Style atoms include: ok, cancel, yes_no, help, information, warning,
%% error, question, no_icon, no_default, cancel_default, yes_default,
%% ok_default and stay_on_top.
-spec message_dialog(object_key(), unicode:chardata(), options()) ->
    integer() | {error, term()}.
message_dialog(Parent, Message, Options) ->
    Server = server_for(Parent),
    gen_server:call(
        Server,
        {message_dialog, self(), Parent, Message, normalize_options(Options)},
        infinity
    ).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    process_flag(trap_exit, true),
    _ = wx:new(),
    {ok, #state{}}.

handle_call({create, Owner, Type, Name, ParentRef, Options}, _From, State0) ->
    case safe_create(Owner, Type, Name, ParentRef, Options, State0) of
        {ok, Ref, State} -> {reply, Ref, State};
        {error, Reason} -> {reply, {error, Reason}, State0}
    end;
handle_call({config, Owner, Ref, Options}, _From, State0) ->
    case resolve_object_id(Owner, Ref, State0) of
        {ok, Id} ->
            case safe_config(Id, Options, State0) of
                {ok, State} -> {reply, ok, State};
                {error, Reason} -> {reply, {error, Reason}, State0}
            end;
        Error ->
            {reply, Error, State0}
    end;
handle_call({read, Owner, Ref, Key}, _From, State) ->
    case resolve_object(Owner, Ref, State) of
        {ok, Object} ->
            {reply, safe_read(Object, Key, State), State};
        Error ->
            {reply, Error, State}
    end;
handle_call({destroy, Owner, Ref}, _From, State0) ->
    case resolve_object_id(Owner, Ref, State0) of
        {ok, Id} ->
            {reply, ok, do_destroy(Id, State0)};
        Error ->
            {reply, Error, State0}
    end;
handle_call({message_dialog, Owner, ParentRef, Message, Options}, _From, State) ->
    case resolve_object(Owner, ParentRef, State) of
        {ok, ParentObject} ->
            {reply, safe_message_dialog(ParentObject, Message, Options), State};
        Error ->
            {reply, Error, State}
    end;
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_call}, State}.

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info(
    #wx{userData = Id, event = #wxCommand{type = command_button_clicked}},
    State
) ->
    deliver_event(Id, click, [], State),
    {noreply, State};
handle_info(
    #wx{userData = Id, event = #wxCommand{type = command_text_enter, cmdString = Text}},
    State
) ->
    deliver_event(Id, keypress, ['Return', Text], State),
    {noreply, State};
handle_info(
    #wx{
        userData = Id,
        event = #wxCommand{
            type = command_listbox_selected,
            commandInt = Index,
            cmdString = Text
        }
    },
    State
) ->
    deliver_event(Id, click, [Index, Text, true], State),
    {noreply, State};
handle_info(
    #wx{
        userData = Id,
        event = #wxCommand{
            type = command_listbox_doubleclicked,
            commandInt = Index,
            cmdString = Text
        }
    },
    State
) ->
    deliver_event(Id, doubleclick, [Index, Text, true], State),
    {noreply, State};
handle_info(#wx{userData = Id, event = #wxSize{type = size, size = {W, H}}}, State) ->
    deliver_event(Id, configure, [W, H], State),
    {noreply, State};
handle_info(#wx{userData = Id, event = #wxClose{type = close_window}}, State0) ->
    deliver_event(Id, destroy, [], State0),
    {noreply, do_destroy(Id, State0)};
handle_info({'DOWN', _MonitorRef, process, Owner, _Reason}, State0) ->
    Ids = [Id || {Id, #object{owner = Pid}} <- maps:to_list(State0#state.objects), Pid =:= Owner],
    State1 = lists:foldl(fun do_destroy/2, State0, Ids),
    {noreply, State1#state{owner_monitors = maps:remove(Owner, State1#state.owner_monitors)}};
handle_info({'EXIT', _Pid, _Reason}, State) ->
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State0) ->
    Ids = maps:keys(State0#state.objects),
    _ = lists:foldl(fun do_destroy/2, State0, Ids),
    catch wx:destroy(),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Modal dialogs
%%%===================================================================

safe_message_dialog(#object{wx_ref = ParentWx}, Message, Options) ->
    try
        Caption = text_option(caption, Options, "wxgs"),
        Style = dialog_style(proplists:get_value(style, Options, [ok, information])),
        DialogOptions0 = [{caption, Caption}, {style, Style}],
        DialogOptions =
            case proplists:get_value(pos, Options, undefined) of
                undefined -> DialogOptions0;
                Pos -> [{pos, Pos} | DialogOptions0]
            end,
        Dialog = wxMessageDialog:new(ParentWx, to_chardata(Message), DialogOptions),
        try
            wxDialog:showModal(Dialog)
        after
            wxMessageDialog:destroy(Dialog)
        end
    catch
        Class:Reason:Stacktrace ->
            {error, {message_dialog_failed, Class, Reason, Stacktrace}}
    end.

dialog_style(Style) when is_integer(Style) ->
    Style;
dialog_style(Style) when is_atom(Style) ->
    dialog_style_atom(Style);
dialog_style(Styles) when is_list(Styles) ->
    lists:foldl(fun(Style, Acc) -> Acc bor dialog_style_atom(Style) end, 0, Styles).

dialog_style_atom(ok) -> ?wxOK;
dialog_style_atom(cancel) -> ?wxCANCEL;
dialog_style_atom(yes_no) -> ?wxYES_NO;
dialog_style_atom(help) -> ?wxHELP;
dialog_style_atom(information) -> ?wxICON_INFORMATION;
dialog_style_atom(warning) -> ?wxICON_WARNING;
dialog_style_atom(error) -> ?wxICON_ERROR;
dialog_style_atom(question) -> ?wxICON_QUESTION;
dialog_style_atom(no_icon) -> ?wxICON_NONE;
dialog_style_atom(no_default) -> ?wxNO_DEFAULT;
dialog_style_atom(cancel_default) -> ?wxCANCEL_DEFAULT;
dialog_style_atom(yes_default) -> ?wxYES_DEFAULT;
dialog_style_atom(ok_default) -> ?wxOK_DEFAULT;
dialog_style_atom(stay_on_top) -> ?wxSTAY_ON_TOP;
dialog_style_atom(Other) -> error({bad_dialog_style, Other}).

%%%===================================================================
%%% Tree creation
%%%===================================================================

create_tree_node(Parent, {Type, Name, Options, Children}) when
    is_atom(Type), is_atom(Name), is_list(Children)
->
    Ref = expect_ref(create(Type, Name, Parent, Options)),
    _ = [create_tree_node(Ref, Child) || Child <- Children],
    Ref;
create_tree_node(Parent, {Type, Name, Options}) when
    is_atom(Type), is_atom(Name), is_list(Options)
->
    expect_ref(create(Type, Name, Parent, Options));
create_tree_node(Parent, {Type, Options, Children}) when
    is_atom(Type), is_list(Options), is_list(Children)
->
    Ref = expect_ref(create(Type, Parent, Options)),
    _ = [create_tree_node(Ref, Child) || Child <- Children],
    Ref;
create_tree_node(Parent, {Type, Options}) when is_atom(Type) ->
    expect_ref(create(Type, Parent, Options));
create_tree_node(_Parent, BadNode) ->
    error({bad_tree_node, BadNode}).

expect_ref({wxgs_ref, _, _} = Ref) -> Ref;
expect_ref({error, Reason}) -> error(Reason).

%%%===================================================================
%%% Creation
%%%===================================================================

safe_create(Owner, Type, Name, ParentRef, Options, State0) ->
    try do_create(Owner, Type, Name, ParentRef, Options, State0) of
        Result -> Result
    catch
        Class:Reason:Stacktrace ->
            {error, {create_failed, Type, Class, Reason, Stacktrace}}
    end.

do_create(Owner, Type, Name, ParentRef, Options, State0) ->
    ok = validate_type(Type),
    ok = validate_name(Owner, Name, State0),
    {ParentId, ParentObject} = resolve_parent(Owner, Type, ParentRef, State0),
    Id = State0#state.next_id,
    NativeId = State0#state.next_native_id,
    ParentWx = parent_window(ParentObject),
    {WxRef, Container, Sizer} = create_native(Type, NativeId, ParentWx, Options),

    Object0 = #object{
        id = Id,
        native_id = NativeId,
        name = Name,
        owner = Owner,
        type = Type,
        wx_ref = WxRef,
        container = Container,
        sizer = Sizer,
        parent = ParentId,
        data = proplists:get_value(data, Options, []),
        options = options_map(Options)
    },

    connect_events(Object0),
    apply_initial_window_options(Object0, Options),
    add_to_parent(ParentObject, Object0, Options),

    Objects0 = State0#state.objects,
    Objects1 = maps:put(Id, Object0, Objects0),
    Objects2 = add_child_to_parent(ParentId, Id, Objects1),
    Names1 = add_name(Owner, Name, Id, State0#state.names),
    Monitors1 = ensure_owner_monitor(Owner, State0#state.owner_monitors),
    State = State0#state{
        next_id = Id + 1,
        next_native_id = next_native_id(Type, NativeId),
        objects = Objects2,
        names = Names1,
        owner_monitors = Monitors1
    },
    {ok, make_ref_handle(Id), State}.

validate_type(Type) when
    Type =:= window;
    Type =:= frame;
    Type =:= button;
    Type =:= label;
    Type =:= entry;
    Type =:= editor;
    Type =:= listbox
->
    ok;
validate_type(Type) ->
    error({unsupported_object_type, Type}).

validate_name(_Owner, undefined, _State) ->
    ok;
validate_name(Owner, Name, #state{names = Names}) when is_atom(Name) ->
    case maps:is_key({Owner, Name}, Names) of
        true -> error({name_already_exists, Name});
        false -> ok
    end.

resolve_parent(_Owner, window, ParentRef, _State) when is_pid(ParentRef) ->
    case ParentRef =:= self() of
        true -> {root, root};
        false -> error({bad_window_parent, ParentRef})
    end;
resolve_parent(_Owner, window, root, _State) ->
    {root, root};
resolve_parent(_Owner, window, wxgs, _State) ->
    {root, root};
resolve_parent(Owner, _Type, ParentRef, State) ->
    case resolve_object(Owner, ParentRef, State) of
        {ok, #object{id = Id, sizer = Sizer} = Parent} when Sizer =/= undefined ->
            {Id, Parent};
        {ok, #object{type = ParentType}} ->
            error({not_a_container, ParentType});
        {error, Reason} ->
            error(Reason)
    end.

parent_window(root) ->
    wx:null();
parent_window(#object{container = Container}) ->
    Container.

create_native(window, Id, _ParentWx, Options) ->
    Title = text_option(title, Options, "wxgs window"),
    Size = size_option(Options, {900, 640}),
    Style = proplists:get_value(style, Options, ?wxDEFAULT_FRAME_STYLE),
    Frame = wxFrame:new(wx:null(), Id, Title, [{size, Size}, {style, Style}]),
    Panel = wxPanel:new(Frame, [{winid, ?wxID_ANY}]),
    FrameSizer = wxBoxSizer:new(?wxVERTICAL),
    _ = wxSizer:add(FrameSizer, Panel, [{proportion, 1}, {flag, ?wxEXPAND}]),
    ok = wxWindow:setSizer(Frame, FrameSizer),
    Sizer = wxBoxSizer:new(orientation(Options)),
    ok = wxWindow:setSizer(Panel, Sizer),
    {Frame, Panel, Sizer};
create_native(frame, Id, ParentWx, Options) ->
    PanelOptions0 = [{winid, Id}],
    PanelOptions = maybe_add_size(PanelOptions0, Options),
    Panel = wxPanel:new(ParentWx, PanelOptions),
    Sizer = wxBoxSizer:new(orientation(Options)),
    ok = wxWindow:setSizer(Panel, Sizer),
    {Panel, Panel, Sizer};
create_native(button, Id, ParentWx, Options) ->
    Label = label_option(Options, "Button"),
    ConstructorOptions = [{label, Label} | common_constructor_options(Options)],
    Button = wxButton:new(ParentWx, Id, ConstructorOptions),
    {Button, undefined, undefined};
create_native(label, Id, ParentWx, Options) ->
    Label = label_option(Options, ""),
    ConstructorOptions = common_constructor_options(Options),
    StaticText = wxStaticText:new(ParentWx, Id, Label, ConstructorOptions),
    {StaticText, undefined, undefined};
create_native(entry, Id, ParentWx, Options) ->
    Value = text_option(text, Options, ""),
    Style0 = proplists:get_value(style, Options, 0),
    Style = Style0 bor ?wxTE_PROCESS_ENTER,
    ConstructorOptions = [{value, Value}, {style, Style} | common_constructor_options(Options)],
    Entry = wxTextCtrl:new(ParentWx, Id, ConstructorOptions),
    {Entry, undefined, undefined};
create_native(editor, Id, ParentWx, Options) ->
    Value = text_option(text, Options, ""),
    Style0 = proplists:get_value(style, Options, 0),
    Style = Style0 bor ?wxTE_MULTILINE,
    ConstructorOptions = [{value, Value}, {style, Style} | common_constructor_options(Options)],
    Editor = wxTextCtrl:new(ParentWx, Id, ConstructorOptions),
    {Editor, undefined, undefined};
create_native(listbox, Id, ParentWx, Options) ->
    Choices = [to_chardata(Item) || Item <- proplists:get_value(items, Options, [])],
    Style0 = proplists:get_value(style, Options, 0),
    Style = Style0 bor ?wxLB_SINGLE,
    ConstructorOptions = [{choices, Choices}, {style, Style} | common_constructor_options(Options)],
    ListBox = wxListBox:new(ParentWx, Id, ConstructorOptions),
    {ListBox, undefined, undefined}.

common_constructor_options(Options) ->
    lists:filtermap(
        fun
            ({size, Size}) -> {true, {size, Size}};
            ({pos, Pos}) -> {true, {pos, Pos}};
            (_) -> false
        end,
        Options
    ).

maybe_add_size(Options0, Options) ->
    case proplists:get_value(size, Options, undefined) of
        undefined -> Options0;
        Size -> [{size, Size} | Options0]
    end.

orientation(Options) ->
    case proplists:get_value(orient, Options, proplists:get_value(layout, Options, vertical)) of
        horizontal -> ?wxHORIZONTAL;
        vertical -> ?wxVERTICAL;
        ?wxHORIZONTAL -> ?wxHORIZONTAL;
        ?wxVERTICAL -> ?wxVERTICAL;
        Other -> error({bad_orientation, Other})
    end.

connect_events(#object{id = Id, type = window, wx_ref = WxRef}) ->
    ok = wxEvtHandler:connect(WxRef, close_window, [{userData, Id}]),
    ok = wxEvtHandler:connect(WxRef, size, [{skip, true}, {userData, Id}]);
connect_events(#object{id = Id, type = button, wx_ref = WxRef}) ->
    ok = wxEvtHandler:connect(WxRef, command_button_clicked, [{userData, Id}]);
connect_events(#object{id = Id, type = entry, wx_ref = WxRef}) ->
    ok = wxEvtHandler:connect(WxRef, command_text_enter, [{userData, Id}]);
connect_events(#object{id = Id, type = listbox, wx_ref = WxRef}) ->
    ok = wxEvtHandler:connect(WxRef, command_listbox_selected, [{userData, Id}]),
    ok = wxEvtHandler:connect(WxRef, command_listbox_doubleclicked, [{userData, Id}]);
connect_events(_Object) ->
    ok.

apply_initial_window_options(Object, Options) ->
    case proplists:get_value(min_size, Options, undefined) of
        undefined -> ok;
        MinSize -> ok = wxWindow:setMinSize(Object#object.wx_ref, MinSize)
    end,
    case proplists:get_value(enable, Options, true) of
        true ->
            ok;
        false ->
            _ = wxWindow:enable(Object#object.wx_ref, [{enable, false}]),
            ok
    end,
    case proplists:get_value(tooltip, Options, undefined) of
        undefined -> ok;
        Tooltip -> ok = wxWindow:setToolTip(Object#object.wx_ref, Tooltip)
    end,
    case initial_visibility(Options) of
        undefined ->
            ok;
        Bool when is_boolean(Bool) ->
            _ = wxWindow:show(Object#object.wx_ref, [{show, Bool}]),
            ok
    end.

initial_visibility(Options) ->
    case proplists:get_value(map, Options, undefined) of
        undefined -> proplists:get_value(show, Options, undefined);
        Bool -> Bool
    end.

add_to_parent(root, _Object, _Options) ->
    ok;
add_to_parent(#object{sizer = ParentSizer, container = ParentContainer}, Object, Options) ->
    _ = wxSizer:add(ParentSizer, Object#object.wx_ref, sizer_options(Options)),
    _ = wxWindow:layout(ParentContainer),
    ok.

sizer_options(Options) ->
    Proportion = proplists:get_value(proportion, Options, 0),
    Border = proplists:get_value(border, Options, proplists:get_value(margin, Options, 0)),
    Flag = sizer_flag(Options, Border),
    [{proportion, Proportion}, {flag, Flag}, {border, Border}].

sizer_flag(Options, Border) ->
    ExpandFlag =
        case proplists:get_value(expand, Options, false) of
            true -> ?wxEXPAND;
            false -> 0
        end,
    BorderFlag =
        case Border > 0 of
            true -> border_flag(proplists:get_value(border_sides, Options, all));
            false -> 0
        end,
    AlignFlag = align_flag(proplists:get_value(align, Options, none)),
    ExpandFlag bor BorderFlag bor AlignFlag.

border_flag(all) ->
    ?wxALL;
border_flag(left) ->
    ?wxLEFT;
border_flag(right) ->
    ?wxRIGHT;
border_flag(top) ->
    ?wxTOP;
border_flag(bottom) ->
    ?wxBOTTOM;
border_flag(horizontal) ->
    ?wxLEFT bor ?wxRIGHT;
border_flag(vertical) ->
    ?wxTOP bor ?wxBOTTOM;
border_flag(Sides) when is_list(Sides) ->
    lists:foldl(fun(Side, Acc) -> Acc bor border_flag(Side) end, 0, Sides);
border_flag(_) ->
    ?wxALL.

align_flag(none) -> 0;
align_flag(left) -> ?wxALIGN_LEFT;
align_flag(right) -> ?wxALIGN_RIGHT;
align_flag(top) -> ?wxALIGN_TOP;
align_flag(bottom) -> ?wxALIGN_BOTTOM;
align_flag(center) -> ?wxALIGN_CENTER;
align_flag(centre) -> ?wxALIGN_CENTER;
align_flag(center_vertical) -> ?wxALIGN_CENTER_VERTICAL;
align_flag(center_horizontal) -> ?wxALIGN_CENTER_HORIZONTAL;
align_flag(Value) when is_integer(Value) -> Value;
align_flag(_) -> 0.

next_native_id(window, NativeId) -> NativeId + 1;
next_native_id(_Type, NativeId) -> NativeId + 1.

%%%===================================================================
%%% Configuration
%%%===================================================================

safe_config(Id, Options, State0) ->
    try
        Object0 = maps:get(Id, State0#state.objects),
        Object = lists:foldl(fun apply_config_option/2, Object0, Options),
        Objects = maps:put(Id, Object, State0#state.objects),
        layout_parent(Object#object.parent, Objects),
        {ok, State0#state{objects = Objects}}
    catch
        Class:Reason:Stacktrace ->
            {error, {config_failed, Class, Reason, Stacktrace}}
    end.

apply_config_option({data, Data}, Object) ->
    put_stored_option(data, Data, Object#object{data = Data});
apply_config_option({enable, Bool}, Object) when is_boolean(Bool) ->
    _ = wxWindow:enable(Object#object.wx_ref, [{enable, Bool}]),
    put_stored_option(enable, Bool, Object);
apply_config_option({map, Bool}, Object) when is_boolean(Bool) ->
    _ = wxWindow:show(Object#object.wx_ref, [{show, Bool}]),
    put_stored_option(map, Bool, Object);
apply_config_option({show, Bool}, Object) when is_boolean(Bool) ->
    _ = wxWindow:show(Object#object.wx_ref, [{show, Bool}]),
    put_stored_option(show, Bool, Object);
apply_config_option({size, {W, H} = Size}, Object) when is_integer(W), is_integer(H) ->
    ok = wxWindow:setSize(Object#object.wx_ref, Size),
    put_stored_option(size, Size, Object);
apply_config_option({width, Width}, Object) when is_integer(Width) ->
    {_OldWidth, Height} = wxWindow:getSize(Object#object.wx_ref),
    ok = wxWindow:setSize(Object#object.wx_ref, {Width, Height}),
    put_stored_option(width, Width, Object);
apply_config_option({height, Height}, Object) when is_integer(Height) ->
    {Width, _OldHeight} = wxWindow:getSize(Object#object.wx_ref),
    ok = wxWindow:setSize(Object#object.wx_ref, {Width, Height}),
    put_stored_option(height, Height, Object);
apply_config_option({min_size, MinSize}, Object) ->
    ok = wxWindow:setMinSize(Object#object.wx_ref, MinSize),
    put_stored_option(min_size, MinSize, Object);
apply_config_option({tooltip, Tooltip}, Object) ->
    ok = wxWindow:setToolTip(Object#object.wx_ref, Tooltip),
    put_stored_option(tooltip, Tooltip, Object);
apply_config_option({title, Title}, #object{type = window, wx_ref = WxRef} = Object) ->
    ok = wxTopLevelWindow:setTitle(WxRef, Title),
    put_stored_option(title, Title, Object);
apply_config_option({text, Text}, Object) ->
    set_object_text(Object, Text),
    put_stored_option(text, Text, Object);
apply_config_option({label, {text, Text}}, Object) ->
    set_object_label(Object, Text),
    put_stored_option(label, Text, Object);
apply_config_option({label, Text}, Object) ->
    set_object_label(Object, Text),
    put_stored_option(label, Text, Object);
apply_config_option({items, Items}, #object{type = listbox, wx_ref = WxRef} = Object) ->
    ok = wxControlWithItems:clear(WxRef),
    _ = wxControlWithItems:appendStrings(WxRef, [to_chardata(Item) || Item <- Items]),
    put_stored_option(items, Items, Object);
apply_config_option({add, Item}, #object{type = listbox, wx_ref = WxRef} = Object) ->
    _ = wxControlWithItems:append(WxRef, to_chardata(Item)),
    Object;
apply_config_option({selection, clear}, #object{type = listbox, wx_ref = WxRef} = Object) ->
    ok = wxControlWithItems:setSelection(WxRef, ?wxNOT_FOUND),
    Object;
apply_config_option({selection, Index}, #object{type = listbox, wx_ref = WxRef} = Object) when
    is_integer(Index)
->
    ok = wxControlWithItems:setSelection(WxRef, Index),
    Object;
apply_config_option({setfocus, true}, Object) ->
    ok = wxWindow:setFocus(Object#object.wx_ref),
    Object;
apply_config_option(clear, #object{type = listbox, wx_ref = WxRef} = Object) ->
    ok = wxControlWithItems:clear(WxRef),
    Object;
apply_config_option(clear, #object{type = Type, wx_ref = WxRef} = Object) when
    Type =:= entry; Type =:= editor
->
    ok = wxTextCtrl:clear(WxRef),
    Object;
apply_config_option(raise, Object) ->
    ok = wxWindow:raise(Object#object.wx_ref),
    Object;
apply_config_option(lower, Object) ->
    ok = wxWindow:lower(Object#object.wx_ref),
    Object;
apply_config_option({fit, true}, #object{container = Container, sizer = Sizer} = Object) when
    Container =/= undefined, Sizer =/= undefined
->
    _ = wxSizer:fit(Sizer, Container),
    Object;
apply_config_option({Key, Value}, Object) ->
    put_stored_option(Key, Value, Object);
apply_config_option(Atom, Object) when is_atom(Atom) ->
    put_stored_option(Atom, true, Object).

set_object_text(#object{type = Type, wx_ref = WxRef}, Text) when
    Type =:= entry; Type =:= editor
->
    ok = wxTextCtrl:changeValue(WxRef, Text);
set_object_text(#object{type = label} = Object, Text) ->
    set_object_label(Object, Text);
set_object_text(#object{type = button} = Object, Text) ->
    set_object_label(Object, Text);
set_object_text(#object{type = window, wx_ref = WxRef}, Text) ->
    ok = wxTopLevelWindow:setTitle(WxRef, Text);
set_object_text(#object{type = Type}, _Text) ->
    error({text_not_supported, Type}).

set_object_label(#object{type = Type, wx_ref = WxRef}, Text) when
    Type =:= label; Type =:= button
->
    ok = wxControl:setLabel(WxRef, Text);
set_object_label(#object{type = Type}, _Text) ->
    error({label_not_supported, Type}).

put_stored_option(Key, Value, Object) ->
    Object#object{options = maps:put(Key, Value, Object#object.options)}.

layout_parent(root, _Objects) ->
    ok;
layout_parent(ParentId, Objects) ->
    case maps:get(ParentId, Objects, undefined) of
        #object{container = Container} when Container =/= undefined ->
            _ = wxWindow:layout(Container),
            ok;
        _ ->
            ok
    end.

%%%===================================================================
%%% Reading
%%%===================================================================

safe_read(Object, Key, State) ->
    try read_value(Object, Key, State) of
        Value -> Value
    catch
        Class:Reason:Stacktrace ->
            {error, {read_failed, Class, Reason, Stacktrace}}
    end.

read_value(Object, id, _State) ->
    make_ref_handle(Object#object.id);
read_value(Object, native_id, _State) ->
    Object#object.native_id;
read_value(Object, name, _State) ->
    Object#object.name;
read_value(Object, type, _State) ->
    Object#object.type;
read_value(Object, owner, _State) ->
    Object#object.owner;
read_value(Object, data, _State) ->
    Object#object.data;
read_value(Object, native, _State) ->
    Object#object.wx_ref;
read_value(Object, options, _State) ->
    Object#object.options;
read_value(#object{parent = root}, parent, _State) ->
    self();
read_value(#object{parent = ParentId}, parent, _State) ->
    make_ref_handle(ParentId);
read_value(Object, children, _State) ->
    [make_ref_handle(Id) || Id <- Object#object.children];
read_value(Object, size, _State) ->
    wxWindow:getSize(Object#object.wx_ref);
read_value(Object, width, _State) ->
    element(1, wxWindow:getSize(Object#object.wx_ref));
read_value(Object, height, _State) ->
    element(2, wxWindow:getSize(Object#object.wx_ref));
read_value(Object, enable, _State) ->
    wxWindow:isEnabled(Object#object.wx_ref);
read_value(Object, shown, _State) ->
    wxWindow:isShown(Object#object.wx_ref);
read_value(#object{type = window, wx_ref = WxRef}, title, _State) ->
    wxTopLevelWindow:getTitle(WxRef);
read_value(#object{type = Type, wx_ref = WxRef}, text, _State) when
    Type =:= entry; Type =:= editor
->
    wxTextCtrl:getValue(WxRef);
read_value(#object{type = Type, wx_ref = WxRef}, text, _State) when
    Type =:= label; Type =:= button
->
    wxControl:getLabel(WxRef);
read_value(#object{type = Type, wx_ref = WxRef}, label, _State) when
    Type =:= label; Type =:= button
->
    wxControl:getLabel(WxRef);
read_value(#object{type = listbox, wx_ref = WxRef}, items, _State) ->
    Count = wxControlWithItems:getCount(WxRef),
    case Count of
        0 -> [];
        _ -> [wxControlWithItems:getString(WxRef, Index) || Index <- lists:seq(0, Count - 1)]
    end;
read_value(#object{type = listbox, wx_ref = WxRef}, selection, _State) ->
    wxControlWithItems:getSelection(WxRef);
read_value(Object, Key, _State) ->
    maps:get(Key, Object#object.options, {error, {unknown_option, Key}}).

%%%===================================================================
%%% Destruction and ownership
%%%===================================================================

do_destroy(Id, State0 = #state{objects = Objects0}) ->
    case maps:get(Id, Objects0, undefined) of
        undefined ->
            State0;
        Object ->
            State1 = lists:foldl(fun do_destroy/2, State0, Object#object.children),
            detach_from_parent(Object, State1#state.objects),
            destroy_native(Object),
            Objects1 = remove_child_from_parent(Object#object.parent, Id, State1#state.objects),
            Objects = maps:remove(Id, Objects1),
            Names = remove_name(Object, State1#state.names),
            State2 = State1#state{objects = Objects, names = Names},
            maybe_remove_owner_monitor(Object#object.owner, State2)
    end.

detach_from_parent(#object{parent = root}, _Objects) ->
    ok;
detach_from_parent(#object{parent = ParentId, wx_ref = WxRef}, Objects) ->
    case maps:get(ParentId, Objects, undefined) of
        #object{sizer = ParentSizer, container = ParentContainer} ->
            catch wxSizer:detach(ParentSizer, WxRef),
            catch wxWindow:layout(ParentContainer),
            ok;
        _ ->
            ok
    end.

destroy_native(#object{wx_ref = WxRef}) ->
    %% 'Destroy'/1 defers top-level deletion until outstanding events are safe.
    catch wxWindow:'Destroy'(WxRef),
    ok.

maybe_remove_owner_monitor(Owner, State = #state{objects = Objects, owner_monitors = Monitors}) ->
    StillOwnsObjects = lists:any(
        fun({_Id, #object{owner = ObjectOwner}}) -> ObjectOwner =:= Owner end,
        maps:to_list(Objects)
    ),
    case {StillOwnsObjects, maps:get(Owner, Monitors, undefined)} of
        {false, MonitorRef} when is_reference(MonitorRef) ->
            erlang:demonitor(MonitorRef, [flush]),
            State#state{owner_monitors = maps:remove(Owner, Monitors)};
        _ ->
            State
    end.

%%%===================================================================
%%% Object lookup and bookkeeping
%%%===================================================================

resolve_object(Owner, Ref, State) ->
    case resolve_object_id(Owner, Ref, State) of
        {ok, Id} ->
            case maps:get(Id, State#state.objects, undefined) of
                undefined -> {error, {object_not_found, Ref}};
                Object -> {ok, Object}
            end;
        Error ->
            Error
    end.

resolve_object_id(_Owner, {wxgs_ref, Server, Id}, _State) when
    Server =:= self(), is_integer(Id)
->
    {ok, Id};
resolve_object_id(Owner, Name, #state{names = Names}) when is_atom(Name) ->
    case maps:get({Owner, Name}, Names, undefined) of
        undefined -> {error, {name_not_found, Name}};
        Id -> {ok, Id}
    end;
resolve_object_id(_Owner, Ref, _State) ->
    {error, {bad_object_reference, Ref}}.

add_child_to_parent(root, _ChildId, Objects) ->
    Objects;
add_child_to_parent(ParentId, ChildId, Objects0) ->
    Parent = maps:get(ParentId, Objects0),
    Children = Parent#object.children ++ [ChildId],
    maps:put(ParentId, Parent#object{children = Children}, Objects0).

remove_child_from_parent(root, _ChildId, Objects) ->
    Objects;
remove_child_from_parent(ParentId, ChildId, Objects0) ->
    case maps:get(ParentId, Objects0, undefined) of
        undefined ->
            Objects0;
        Parent ->
            Children = lists:delete(ChildId, Parent#object.children),
            maps:put(ParentId, Parent#object{children = Children}, Objects0)
    end.

add_name(_Owner, undefined, _Id, Names) ->
    Names;
add_name(Owner, Name, Id, Names) ->
    maps:put({Owner, Name}, Id, Names).

remove_name(#object{name = undefined}, Names) ->
    Names;
remove_name(#object{owner = Owner, name = Name}, Names) ->
    maps:remove({Owner, Name}, Names).

ensure_owner_monitor(Owner, Monitors) ->
    case maps:get(Owner, Monitors, undefined) of
        undefined -> maps:put(Owner, erlang:monitor(process, Owner), Monitors);
        _ -> Monitors
    end.

make_ref_handle(Id) ->
    {wxgs_ref, self(), Id}.

deliver_event(Id, EventType, Args, #state{objects = Objects}) ->
    case maps:get(Id, Objects, undefined) of
        undefined ->
            ok;
        Object ->
            IdOrName =
                case Object#object.name of
                    undefined -> make_ref_handle(Id);
                    Name -> Name
                end,
            Object#object.owner ! {wxgs, IdOrName, EventType, Object#object.data, Args},
            ok
    end.

%%%===================================================================
%%% Option helpers
%%%===================================================================

server_for({wxgs_ref, Server, _Id}) when is_pid(Server) ->
    Server;
server_for(Server) when is_pid(Server) ->
    Server;
server_for(_NameOrRoot) ->
    server().

normalize_options(Options) when is_list(Options) -> Options;
normalize_options(Option) when is_tuple(Option); is_atom(Option) -> [Option];
normalize_options(undefined) -> [].

options_map(Options) ->
    lists:foldl(
        fun
            ({Key, Value}, Acc) when is_atom(Key) -> maps:put(Key, Value, Acc);
            (Key, Acc) when is_atom(Key) -> maps:put(Key, true, Acc);
            (_, Acc) -> Acc
        end,
        #{},
        Options
    ).

label_option(Options, Default) ->
    case proplists:get_value(label, Options, undefined) of
        {text, Text} -> Text;
        undefined -> text_option(text, Options, Default);
        Text -> Text
    end.

text_option(Key, Options, Default) ->
    case proplists:get_value(Key, Options, Default) of
        {text, Text} -> Text;
        Text -> Text
    end.

size_option(Options, Default) ->
    case proplists:get_value(size, Options, undefined) of
        undefined ->
            Width = proplists:get_value(width, Options, element(1, Default)),
            Height = proplists:get_value(height, Options, element(2, Default)),
            {Width, Height};
        Size ->
            Size
    end.

to_chardata(Value) when is_binary(Value); is_list(Value) -> Value;
to_chardata(Value) -> io_lib:format("~p", [Value]).
