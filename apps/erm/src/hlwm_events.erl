%%%-------------------------------------------------------------------
%%%  hlwm_events.erl
%%%  Event monitor: spawns `herbstclient --idle` and parses events
%%%-------------------------------------------------------------------
-module(hlwm_events).
-author("Steven Joseph <steven@damagebdd.com>").

-copyright("Steven Joseph <steven@damagebdd.com>").

-license("Apache-2.0").
-include_lib("kernel/include/logger.hrl").
-behaviour(gen_server).
-define(NOTIFY_ID, "42").
-define(NOTIFY_TIMEOUT, "1000").

-export([start_link/1, get_or_start/1]).
-export([init/1, handle_call/3, handle_info/2, handle_cast/2, terminate/2, code_change/3]).
-export([
    ensure_tmux_terminal/1,
    ensure_tmux_terminal/2,
    window_exists/2,
    launch_st_tmux/1
]).
-export([test/0]).

-record(state, {
    port,
    hooks = #{},
    events = [],
    max_events = 256,
    %% WinId => #{title := ..., class := ..., instance := ...}
    clients = #{},
    %% names to launch once hlwm is ready
    pending_windows = []
}).
notify_dunst(Msg) ->
    RunOpts = [sync, stderr],
    {ok, []} = exec:run(
        [
            "/usr/sbin//notify-send",
            "-t",
            ?NOTIFY_TIMEOUT,
            "-r",
            ?NOTIFY_ID,
            "-a",
            "erm",
            Msg
        ],
        RunOpts
    ).

init([Ctx]) ->
    process_flag(trap_exit, true),

    Port = open_port(
        {spawn, "herbstclient --idle"},
        [{line, 1024}, exit_status, use_stdio, stderr_to_stdout]
    ),

    gproc:reg({n, l, {hlwm_events, monitor}}),

    DeskHook =
        fun(Evt) ->
            case maps:get(type, Evt, undefined) of
                "tag_changed" ->
                    Name = maps:get(name, Evt, ""),
                    notify_dunst(io_lib:format("Workspace: ~s", [Name])),
                    ok;
                _ ->
                    ok
            end
        end,

    Pending = maps:get(start_windows, Ctx, []),
    Clients = refresh_clients(),

    {ok, #state{
        port = Port,
        hooks = #{desktop_notify => DeskHook},
        clients = Clients,
        pending_windows = Pending
    }}.

get_or_start(Context) ->
    case gproc:where({n, l, {hlwm_events, monitor}}) of
        undefined ->
            {ok, Pid} = gen_server:start_link(?MODULE, [Context], []),
            Pid;
        Pid ->
            Pid
    end.

ensure_tmux_terminal(Name) ->
    Pid = get_or_start(#{start_windows => [to_list(Name)]}),
    ensure_tmux_terminal(Pid, Name).

ensure_tmux_terminal(Pid, Name0) ->
    Name = to_list(Name0),
    gen_server:call(Pid, {ensure_tmux_terminal, Name}).

window_exists(Pid, Name0) ->
    Name = to_list(Name0),
    gen_server:call(Pid, {window_exists, Name}).
start_link(Context) -> gen_server:start_link(?MODULE, [Context], []).

handle_call({ensure_tmux_terminal, Name}, _From, S = #state{clients = Clients}) ->
    case client_exists(Name, Clients) of
        true ->
            {reply, ok, S};
        false ->
            Reply = launch_st_tmux(Name),
            {reply, Reply, S}
    end;
handle_call({window_exists, Name}, _From, S = #state{clients = Clients}) ->
    {reply, client_exists(Name, Clients), S};
handle_call(refresh_clients, _From, S) ->
    Clients = refresh_clients(),
    {reply, {ok, Clients}, S#state{clients = Clients}};
handle_call({add_hook, Id, Fun}, _From, S = #state{hooks = H}) when is_function(Fun, 1) ->
    {reply, ok, S#state{hooks = maps:put(Id, Fun, H)}};
handle_call({get, events}, _From, S = #state{events = E}) ->
    {reply, E, S};
handle_call({query, focused_title}, _From, S) ->
    Title = string:trim(os:cmd("herbstclient attr clients.focus.title")),
    {reply, {ok, Title}, S};
handle_call(_Any, _From, S) ->
    {reply, ok, S}.

handle_cast(_Msg, S) -> {noreply, S}.
handle_info({Port, {data, {eol, Line}}}, S0 = #state{port = Port}) ->
    case parse_event(Line) of
        {ok, Evt} ->
            S1 = update_client_cache(Evt, S0),
            S2 = maybe_start_pending_windows(S1),
            S3 = push_event(Evt, S2),
            broadcast(Evt, S3),
            {noreply, S3};
        _ ->
            {noreply, S0}
    end;
handle_info({Port, {data, {eol, Line}}}, S = #state{port = Port}) ->
    case parse_event(Line) of
        {ok, Evt} ->
            S1 = push_event(Evt, S),
            broadcast(Evt, S1),
            {noreply, S1};
        _ ->
            {noreply, S}
    end;
handle_info({'EXIT', Port, _Status}, _State = #state{port = Port}) ->
    ?LOG_WARNING("hlwm port exited; restarting", []),
    {ok, S1} = init([#{}]),
    {noreply, S1};
handle_info(_Info, S) ->
    {noreply, S}.

terminate(Reason, _S) ->
    ?LOG_INFO("hlwm_events terminating ~p", [Reason]),
    ok.
code_change(_V, S, _E) -> {ok, S}.

push_event(E, S = #state{events = Evts, max_events = Max}) ->
    Evts1 =
        case length(Evts) < Max of
            true -> [E | Evts];
            false -> [E | lists:sublist(Evts, Max - 1)]
        end,
    S#state{events = Evts1}.

broadcast(Evt, #state{hooks = Hooks}) ->
    maps:map(fun(_K, Fun) -> catch Fun(Evt) end, Hooks),
    ok.

%%
%% Example lines (from `herbstclient --idle`):
%%  focus_changed 0x58026c6 1
%%  window_title_changed 0x58026c6 "ChatGPT - DamageBDD – Ablaze Floorp"
%%  tag_changed 4 staging
%%
parse_event(Line) ->
    Tokens = string:tokens(Line, " \t"),
    case Tokens of
        ["focus_changed", WinIdStr, _Idx] ->
            {ok, #{type => "focus_changed", win_id => WinIdStr}};
        ["window_title_changed", WinIdStr | Rest] ->
            Title = string:trim(string:join(Rest, " "), both, "\""),
            {ok, #{type => "window_title_changed", win_id => WinIdStr, title => Title}};
        ["tag_changed", Index, Name] ->
            {ok, #{type => "tag_changed", index => Index, name => Name}};
        [Other | _] ->
            {ok, #{type => Other, raw => Line}};
        _ ->
            {error, nomatch}
    end.
update_client_cache(
    #{type := "window_title_changed", win_id := WinId, title := Title},
    S = #state{clients = Clients}
) ->
    Client0 = maps:get(WinId, Clients, #{}),
    Client1 = maps:put(title, Title, Client0),
    S#state{clients = maps:put(WinId, Client1, Clients)};
update_client_cache(
    #{type := "focus_changed", win_id := WinId},
    S = #state{clients = Clients}
) ->
    %% Focus event proves client exists; fill metadata lazily if missing.
    case maps:is_key(WinId, Clients) of
        true ->
            S;
        false ->
            Client =
                case read_client_safe(WinId) of
                    {ok, C} -> C;
                    error -> #{title => "", class => "", instance => ""}
                end,
            S#state{clients = maps:put(WinId, Client, Clients)}
    end;
update_client_cache(_, S) ->
    S.

client_exists(Name, Clients) ->
    Needle = string:lowercase(to_list(Name)),
    lists:any(
        fun({_WinId, Client}) ->
            Haystack =
                string:lowercase(
                    string:join(
                        [
                            maps:get(title, Client, ""),
                            maps:get(class, Client, ""),
                            maps:get(instance, Client, "")
                        ],
                        " "
                    )
                ),
            string:find(Haystack, Needle) =/= nomatch
        end,
        maps:to_list(Clients)
    ).
refresh_clients() ->
    Ids0 = string:tokens(os:cmd("herbstclient list_clients 2>/dev/null"), "\n\r"),
    lists:foldl(
        fun(WinId, Acc) ->
            case read_client_safe(WinId) of
                {ok, Client} ->
                    maps:put(WinId, Client, Acc);
                error ->
                    Acc
            end
        end,
        #{},
        Ids0
    ).

read_client_safe(WinId) ->
    try
        {ok, read_client(WinId)}
    catch
        Class:Reason:Stack ->
            ?LOG_WARNING(
                "failed to read hlwm client winid=~p class=~p reason=~p stack=~p",
                [WinId, Class, Reason, Stack]
            ),
            error
    end.

read_client(WinId) ->
    #{
        title => hc_attr(["clients.", WinId, ".title"]),
        class => hc_attr(["clients.", WinId, ".class"]),
        instance => hc_attr(["clients.", WinId, ".instance"])
    }.

hc_attr(PathIo) ->
    Cmd = lists:flatten(["herbstclient attr ", PathIo, " 2>/dev/null"]),
    string:trim(os:cmd(Cmd)).
maybe_start_pending_windows(S = #state{pending_windows = []}) ->
    S;
maybe_start_pending_windows(S = #state{pending_windows = Names, clients = Clients}) ->
    lists:foreach(
        fun(Name) ->
            case client_exists(Name, Clients) of
                true -> ok;
                false -> launch_st_tmux(Name)
            end
        end,
        Names
    ),
    S#state{pending_windows = []}.
launch_st_tmux(Name0) ->
    Name = to_list(Name0),
    Cmd = [
        "st",
        " -f ",
        shell("Hack:size=12"),
        " -T ",
        shell(Name),
        " -t ",
        shell(Name),
        " -c ",
        shell(Name),
        " -e tmux",
        " -f ",
        shell(expand("~/.tmux/outer.conf")),
        " -L outer",
        " new-session -A -t ",
        shell(Name)
    ],
    case exec:run(iolist_to_binary(Cmd), [{shell, "/bin/sh"}]) of
        {ok, _Pid, _OsPid} -> ok;
        Error -> Error
    end.
to_list(B) when is_binary(B) -> binary_to_list(B);
to_list(A) when is_atom(A) -> atom_to_list(A);
to_list(L) when is_list(L) -> L.

expand([$~, $/ | Rest]) ->
    filename:join(os:getenv("HOME"), Rest);
expand(Path) when is_binary(Path) ->
    expand(binary_to_list(Path));
expand(Path) ->
    Path.

shell(S) when is_binary(S) ->
    shell(binary_to_list(S));
shell(S) ->
    "'" ++ string:replace(S, "'", "'\"'\"'", all) ++ "'".
test() ->
    notify_dunst("test erm notification").
