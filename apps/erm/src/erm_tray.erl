%%--------------------------------------------------------------------
%% erm_tray.erl — system tray icon for erm (wxTaskBarIcon + erlexec)
%%--------------------------------------------------------------------
-module(erm_tray).
-behaviour(gen_server).

-include_lib("wx/include/wx.hrl").
-include_lib("kernel/include/logger.hrl").

%% API
-export([
    start_link/0, start_link/1,
    set_tooltip/1,
    set_icon/1,
    update_menu/1,
    notify/2,
    open/1
]).

%% gen_server
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-record(state, {
    wx,
    tbi,
    icon :: wxIcon:wxIcon() | undefined,
    tooltip :: iodata() | undefined,
    menu_spec :: list(),
    on_menu :: fun((term()) -> any()) | {module(), atom(), list()} | undefined
}).

%%%===================================================================
%%% Public API
%%%===================================================================

start_link() -> start_link([]).
start_link(Opts) when is_list(Opts) -> gen_server:start_link({local, ?MODULE}, ?MODULE, Opts, []).

set_tooltip(Text) -> gen_server:cast(?MODULE, {set_tooltip, Text}).
set_icon(Path) -> gen_server:cast(?MODULE, {set_icon, Path}).
update_menu(MS) -> gen_server:cast(?MODULE, {update_menu, MS}).
notify(T, M) -> gen_server:cast(?MODULE, {notify, T, M}).
open(Target) -> gen_server:cast(?MODULE, {open, Target}).

%%%===================================================================
%%% gen_server
%%%===================================================================

init(Config) ->
    process_flag(trap_exit, true),
    wx:batch(fun() -> do_init(Config) end).
do_init(Opts) ->
    Env = persistent_term:get(erm_wx_env),
    wx:set_env(Env),
    %% Use CreatePopupMenu callback – right click is handled by wx
    TBI = wxTaskBarIcon:new([{createPopupMenu, fun create_popup/0}]),

    %% We only need menu selection + (optional) left double-click
    wxTaskBarIcon:connect(TBI, taskbar_right_dclick),
    wxTaskBarIcon:connect(TBI, taskbar_left_dclick),

    Tooltip = proplists:get_value(tooltip, Opts, "erm"),
    IconPath = proplists:get_value(icon, Opts, undefined),
    OnMenu = proplists:get_value(on_menu, Opts, fun tray_handle/1),

    ensure_id_table(),

    Menu0 = proplists:get_value(menu, Opts, [
        {submenu, {apps, "Apps"}, [
            {{app_start, erm}, "Start ERM"},
            {{app_stop, erm}, "Stop ERM"},
            {{app_start, damage}, "Start Damage"},
            {{app_stop, damage}, "Stop Damage"}
        ]},
        {submenu, {logs, "Logs"}, [
            {{logs, erm}, "ERM Logs"},
            {{logs, damage}, "Damage Logs"}
        ]},
        sep,
        {quit, "Quit"}
    ]),

    Icon =
        case load_icon_opt(IconPath) of
            undefined ->
                ?LOG_WARNING("erm_tray: icon path ~p invalid; using fallback icon", [IconPath]),
                fallback_icon();
            I ->
                I
        end,

    maybe_set_icon(TBI, Icon, Tooltip),

    %% Make menu available to CreatePopupMenu callback
    put(menu_spec, Menu0),

    {ok, #state{
        tbi = TBI,
        icon = Icon,
        tooltip = Tooltip,
        menu_spec = Menu0,
        on_menu = OnMenu
    }}.

handle_call(_Req, _From, S) ->
    {reply, ok, S}.

handle_cast({set_tooltip, Text}, S) ->
    {noreply, S#state{tooltip = Text}};
handle_cast({set_icon, Path}, S = #state{tbi = TBI, tooltip = TT}) ->
    case load_icon(Path) of
        {ok, Icon} ->
            maybe_set_icon(TBI, Icon, TT),
            {noreply, S#state{icon = Icon}};
        {error, R} ->
            ?LOG_ERROR("erm_tray: failed to load icon ~p (~p). Keeping previous.", [Path, R]),
            {noreply, S}
    end;
handle_cast({update_menu, MenuSpec}, S) ->
    put(menu_spec, MenuSpec),
    {noreply, S#state{menu_spec = MenuSpec}};
handle_cast({notify, Title, Msg}, S) ->
    run_cmd(notify_cmd(Title, Msg)),
    {noreply, S};
handle_cast({open, Target}, S) ->
    run_cmd(open_cmd(Target)),
    {noreply, S}.

%% Left double-click default action
handle_info(#wx{event = #wxTaskBarIcon{type = taskbar_left_dclick}}, S) ->
    dispatch_menu(open_dashboard, S),
    {noreply, S};
%% Menu item selected
handle_info(#wx{event = #wxCommand{type = taskbar_right_dclick, commandInt = Id}}, S) ->
    ?LOG_DEBUG("erm_tray: right click event ~p", [Id]),
    case ets:lookup(?MODULE, Id) of
        [{Id, Term}] -> dispatch_menu(Term, S);
        [] -> ok
    end,
    {noreply, S};
handle_info(Other, S) ->
    ?LOG_DEBUG("erm_tray: other event ~p", [Other]),
    {noreply, S}.

terminate(_Why, #state{tbi = TBI}) ->
    catch wxTaskBarIcon:removeIcon(TBI),
    catch wxTaskBarIcon:destroy(TBI),
    ok.

code_change(_Old, S, _Extra) -> {ok, S}.

%%%===================================================================
%%% Popup menu (CreatePopupMenu callback)
%%%===================================================================

create_popup() ->
    Spec =
        case get(menu_spec) of
            undefined -> default_menu();
            M -> M
        end,
    Menu = wxMenu:new(),
    build_menu_items(Menu, Spec),
    Menu.

default_menu() ->
    [
        {open_dashboard, "Open Dashboard"},
        sep,
        {quit, "Quit"}
    ].

%%%===================================================================
%%% Menu helpers
%%%===================================================================

build_menu_items(_Menu, []) ->
    ok;
build_menu_items(Menu, [sep | Rest]) ->
    wxMenu:appendSeparator(Menu),
    build_menu_items(Menu, Rest);
build_menu_items(Menu, [{submenu, {IdTerm, Label}, SubSpec} | Rest]) ->
    Sub = wxMenu:new(),
    build_menu_items(Sub, SubSpec),
    Id = reg_id(IdTerm),
    wxMenu:appendSubMenu(Menu, Id, Label, Sub),
    build_menu_items(Menu, Rest);
build_menu_items(Menu, [{IdTerm, Label} | Rest]) ->
    Id = reg_id(IdTerm),
    wxMenu:append(Menu, Id, Label, ""),
    build_menu_items(Menu, Rest).

dispatch_menu({app_start, App}, _S) ->
    maybe_start_app(App),
    notify("ERM Tray", io_lib:format("Started ~p", [App]));
dispatch_menu({app_stop, App}, _S) ->
    _ = application:stop(App),
    notify("ERM Tray", io_lib:format("Stopped ~p", [App]));
dispatch_menu({logs, App}, _S) ->
    _ = open_logs(App),
    ok;
dispatch_menu(open_dashboard, _S) ->
    open("http://localhost:8080"),
    ok;
dispatch_menu(quit, _S) ->
    init:stop();
dispatch_menu(Term, #state{on_menu = undefined}) ->
    ?LOG_INFO("erm_tray: menu clicked ~p (no handler)", [Term]),
    ok;
dispatch_menu(Term, #state{on_menu = Fun}) when is_function(Fun, 1) ->
    catch Fun({menu, Term});
dispatch_menu(Term, #state{on_menu = {M, F, A}}) ->
    catch erlang:apply(M, F, [{menu, Term} | A]).

%%%===================================================================
%%% ID mapping
%%%===================================================================

ensure_id_table() ->
    case ets:info(?MODULE) of
        undefined -> ets:new(?MODULE, [named_table, public, {read_concurrency, true}]);
        _ -> ok
    end.

reg_id(Term) ->
    Id = (erlang:phash2(Term, 16#0FFFFFFF)) bor 1,
    ensure_id_table(),
    case ets:lookup(?MODULE, Id) of
        [] -> ets:insert(?MODULE, {Id, Term});
        _ -> ok
    end,
    Id.

%%%===================================================================
%%% Icons
%%%===================================================================

maybe_set_icon(_TBI, undefined, _TT) ->
    ok;
maybe_set_icon(TBI, Icon, undefined) ->
    _ = wxTaskBarIcon:setIcon(TBI, Icon),
    ok;
maybe_set_icon(TBI, Icon, TT) ->
    _ = wxTaskBarIcon:setIcon(TBI, Icon, [{tooltip, TT}]),
    ok.

load_icon_opt(undefined) ->
    undefined;
load_icon_opt(Path) ->
    case load_icon(Path) of
        {ok, I} -> I;
        _ -> undefined
    end.

load_icon(Path) ->
    try
        Icon = wxIcon:new(),
        ok = wxIcon:loadFile(Icon, Path, [{type, ?wxBITMAP_TYPE_ANY}]),
        {ok, Icon}
    catch
        C:R:S ->
            {error, {C, R, S}}
    end.

fallback_icon() ->
    case find_fallback_bitmap() of
        {ok, Path} ->
            Img = wxImage:new(Path),
            Bmp = wxBitmap:new(Img),
            Icon = wxIcon:new(),
            ok = wxIcon:copyFromBitmap(Icon, Bmp),
            Icon;
        error ->
            Img2 = wxImage:new(16, 16),
            ok = wxImage:setRGB(Img2, {0, 0, 16, 16}, 40, 120, 220),
            Icon2 = wxIcon:new(),
            ok = wxIcon:copyFromBitmap(Icon2, wxBitmap:new(Img2)),
            Icon2
    end.

find_fallback_bitmap() ->
    Priv = code:priv_dir(erm),
    Candidates = [
        filename:join(Priv, "icons/erm_fallback_22.bmp"),
        filename:join(Priv, "icons/erm_fallback_16.bmp")
    ],
    first_existing(Candidates).

first_existing([]) ->
    error;
first_existing([P | Ps]) ->
    case filelib:is_file(P) of
        true -> {ok, P};
        false -> first_existing(Ps)
    end.

%%%===================================================================
%%% erlexec helpers (shell form)
%%%===================================================================

%% Run a *shell string* via exec:run/2 (shell form).
%% Ensures we pass a flat *charlist* (no binaries) to erlexec.
run_cmd(CmdIO) ->
    %% flatten -> binary -> charlist (unicode-aware)
    CmdStr = unicode:characters_to_list(iolist_to_binary(CmdIO)),
    case catch exec:run(CmdStr, [sync, stdout, stderr]) of
        {ok, _} = OK ->
            OK;
        {error, E} ->
            ?LOG_ERROR("erm_tray: exec error ~p for ~ts", [E, CmdStr]),
            {error, E};
        {'EXIT', E} ->
            ?LOG_ERROR("erm_tray: exec exit ~p for ~ts", [E, CmdStr]),
            {error, E}
    end.

%% POSIX-safe single-quote -> returns a *list* (no binaries)
sh_quote(IO) ->
    EscBin = binary:replace(iolist_to_binary(IO), <<"'">>, <<"'\"'\"'">>, [global]),
    [$'] ++ unicode:characters_to_list(EscBin) ++ [$'].

notify_cmd(Title, Msg) ->
    case os:type() of
        {unix, linux} ->
            ["notify-send ", sh_quote(Title), " ", sh_quote(Msg)];
        {unix, darwin} ->
            %% osascript one-liner (no nested io_lib:format needed)
            [
                "osascript -e ",
                "display notification ",
                sh_quote(Msg),
                " with title ",
                sh_quote(Title)
            ];
        {win32, _} ->
            [
                "powershell -NoProfile -Command ",
                sh_quote(
                    io_lib:format(
                        "New-BurntToastNotification -Text @('~s','~s')", [Title, Msg]
                    )
                )
            ]
    end.

open_cmd(Target) ->
    QT = sh_quote(Target),
    case os:type() of
        {unix, linux} -> ["xdg-open ", QT, " >/dev/null 2>&1 &"];
        {unix, darwin} -> ["open ", QT, " >/dev/null 2>&1 &"];
        {win32, _} -> ["cmd /c start \"\" ", QT]
    end.

terminal_cmd(CmdStr) ->
    Q = sh_quote(CmdStr),
    case find_available_terminal() of
        "xfce4-terminal" -> ["xfce4-terminal -e ", Q];
        "gnome-terminal" -> ["gnome-terminal -- sh -lc ", Q];
        "alacritty" -> ["alacritty -e sh -lc ", Q];
        "kitty" -> ["kitty -e sh -lc ", Q];
        "konsole" -> ["konsole -e ", Q];
        "xterm" -> ["xterm -e ", Q];
        undefined -> ["sh -lc ", Q]
    end.

find_available_terminal() ->
    first_exec([
        "alacritty",
        "kitty",
        "xfce4-terminal",
        "gnome-terminal",
        "konsole",
        "xterm"
    ]).

first_exec([]) ->
    undefined;
first_exec([Cmd | Rest]) ->
    case os:find_executable(Cmd) of
        false -> first_exec(Rest);
        _Path -> Cmd
    end.

%%%===================================================================
%%% App helpers
%%%===================================================================

maybe_start_app(App) ->
    case application:start(App) of
        ok ->
            ok;
        {error, {already_started, _}} ->
            ok;
        Err ->
            ?LOG_ERROR("start ~p failed: ~p", [App, Err]),
            Err
    end.

open_logs(App) ->
    Path = get_log_path(App),
    ok = ensure_log_file(Path),
    CmdStr = lists:flatten(io_lib:format("exec tail -n 200 -F ~ts", [Path])),
    run_cmd(terminal_cmd(CmdStr)).

get_log_path(App) ->
    LogMap =
        case application:get_env(erm, tray_logs) of
            {ok, M} when is_map(M) -> M;
            _ -> #{}
        end,
    Default = filename:absname(filename:join("log", atom_to_list(App) ++ ".log")),
    maps:get(App, LogMap, Default).

ensure_log_file(Path) ->
    ok = filelib:ensure_dir(Path),
    case filelib:is_file(Path) of
        true -> ok;
        false -> file:write_file(Path, <<>>)
    end.

%%--------------------------------------------------------------------
%% Tray menu handler
%%--------------------------------------------------------------------
tray_handle({menu, open_dashboard}) ->
    erm_tray:open("http://localhost:8080");
tray_handle({menu, restart}) ->
    application:stop(erm),
    application:start(erm);
tray_handle({menu, quit}) ->
    init:stop();
tray_handle({menu, Other}) ->
    ?LOG_INFO("Unhandled tray menu ~p", [Other]),
    ok.
