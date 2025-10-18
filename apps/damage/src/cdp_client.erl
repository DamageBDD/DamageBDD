%% cdp_client.erl
%% GenServer for Chrome DevTools Protocol (CDP) over WebSocket.
%% Trace-friendly: all calls go through gen_server:call/2.
%% Dependencies: gun (HTTP/WS), jsx (JSON)

-module(cdp_client).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("damage.hrl").
-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-export([start_link/1, stop/1, call/3, enable_console/1, ws_url/1, discover_ws/1, proto_index/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

    %% shell helpers
-export([sh_smoke/0,
         sh_attach/0, sh_attach/2,
         sh_go_click/2, sh_go_click/3]).

-define(DEFAULT_WS_TIMEOUT, 30000).

-record(state, {
    %% gun connection pid
    conn,
    %% ws stream ref
    ref,
    %% message id counter
    next_id = 1,
    %% #{Id => From}
    pending = #{},
    %% binary ws URL
    ws_url,
    %% host for discovery (string())
    host,
    %% integer
    port,
    %% protocol index cache
    index = #{}
}).

%%% ───────── Public API ─────────

%% Options:
%%   #{ws_url => <<"ws://...">>} OR
%%   #{host => "127.0.0.1", port => 9222, type => <<"page">> | <<"node">> | <<"background_page">>}
start_link(Opts) ->
    gen_server:start_link(?MODULE, Opts, []).

stop(Pid) ->
    gen_server:call(Pid, stop, 5000).

%% call(Pid, <<"Domain.Method">>, #{...Params...}) -> ResultMap | {error, term()}
call(Pid, Method, Params) when is_pid(Pid), is_binary(Method), is_map(Params) ->
    ?LOG_INFO("Call Pid ~p ~p", [Pid, erlang:is_process_alive(Pid)]),
    gen_server:call(Pid, {cdp, Method, Params}, infinity).

enable_console(Pid) ->
    #{<<"id">> := _, <<"result">> := _} = gen_server:call(
        Pid, {cdp, <<"Runtime.enable">>, #{}}, 5000
    ),
    #{<<"id">> := _, <<"result">> := _} = gen_server:call(Pid, {cdp, <<"Log.enable">>, #{}}, 5000),
    #{<<"id">> := _, <<"result">> := _} = gen_server:call(
        Pid, {cdp, <<"Console.enable">>, #{}}, 5000
    ),
    ok.

ws_url(Pid) ->
    gen_server:call(Pid, get_ws_url, 1000).

%% discover_ws(#{host := "127.0.0.1", port := 9222, type := <<"page">>})
discover_ws(Opts = #{host := Host, port := Port}) ->
    Type = maps:get(type, Opts, <<"page">>),
    case cdp_http_get(Host, Port, "/json") of
        {200, Body} ->
            case catch jsx:decode(Body, [return_maps]) of
                List when is_list(List) ->
                    pick_ws(List, Type);
                _ ->
                    {error, bad_json}
            end;
        Other ->
            {error, Other}
    end.

proto_index() -> load_protocol().

%%% ───────── gen_server ─────────

init(Opts) ->
    ?LOG_INFO("Cdp client init ~p", [Opts]),
    S0 = #state{},
    case init_connect(S0, Opts) of
        {ok, S1} ->
            Idx = load_protocol_dynamic(S1),
            {ok, S1#state{index = Idx}};
        {error, Why} ->
            {stop, Why}
    end.
load_protocol_dynamic(#state{host=Host, port=Port}) when Host =/= undefined, Port =/= undefined ->
    case cdp_http_get(Host, Port, "/json/protocol") of
        {200, Bin} ->
            case catch jiffy:decode(Bin, [return_maps]) of
                #{<<"domains">> := Domains} ->
                    Idx = build_command_index(Domains),
                    ?LOG_INFO("Loaded CDP protocol from DevTools (~p domains)", [maps:size(Idx)]),
                    Idx;
                _ ->
                    ?LOG_WARNING("Bad /json/protocol JSON; falling back to priv files", []),
                    load_protocol_from_files()
            end;
        Other ->
            ?LOG_WARNING("Fetch /json/protocol failed: ~p; falling back to priv files", [Other]),
            load_protocol_from_files()
    end;
load_protocol_dynamic(_) ->
    load_protocol_from_files().


load_protocol_from_files() ->
    Files = app_priv_protocol_files() ++ dev_fallback_files(),
    Domains = lists:flatten([read_domains(F) || F <- Files]),
    build_command_index(Domains).

app_priv_protocol_files() ->
    App =
        case application:get_application(?MODULE) of
            {ok, A} -> A;
            _ -> undefined
        end,
    case (App =/= undefined) andalso code:priv_dir(App) of
        Dir when is_list(Dir); is_binary(Dir) ->
            D =
                case Dir of
                    B when is_binary(B) -> binary_to_list(B);
                    L -> L
                end,
            [
                filename:join(D, "browser_protocol.json"),
                filename:join(D, "js_protocol.json")
            ];
        _ ->
            []
    end.

%% Only for your dev box; safe to leave in or remove in prod
dev_fallback_files() ->
    ["/mnt/data/browser_protocol.json", "/mnt/data/js_protocol.json"].

handle_call(get_ws_url, _From, S = #state{ws_url = WS}) ->
    {reply, WS, S};
handle_call(stop, _From, S) ->
    {stop, normal, ok, S};
handle_call(
    {cdp, Method, Params},
    From,
    S = #state{index = Idx, conn = Conn, ref = Ref, next_id = Id, pending = P0}
) ->
    case validate_method(Method, Params, Idx) of
        {error, Reason} ->
            {reply, {error, Reason}, S};
        {ok, Valid} ->
            Payload = jsx:encode(#{<<"id">> => Id, <<"method">> => Method, <<"params">> => Valid}),
            ok = gun:ws_send(Conn, Ref, {text, Payload}),
            P1 = P0#{Id => From},
            {noreply, S#state{next_id = Id + 1, pending = P1}}
    end.

handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info({gun_ws, _Conn, _Ref, {text, Data}}, S = #state{pending = P0}) ->
    case catch jsx:decode(Data, [return_maps]) of
        #{<<"id">> := Id} = R ->
            case maps:take(Id, P0) of
                {From, P1} ->
                    gen_server:reply(From, R),
                    {noreply, S#state{pending = P1}};
                error ->
                    {noreply, S}
            end;
        #{<<"method">> := <<"Runtime.consoleAPICalled">>} ->
            ?LOG_INFO("consoleAPICalled ~p", [Data]),
            {noreply, S};
        #{<<"method">> := _Any} ->
            {noreply, S};
        _ ->
            {noreply, S}
    end;
handle_info({gun_down, _Conn, _Proto, Reason, _Killed, _Unproc}, S) ->
    ?LOG_INFO("Terminating cdp client ~p.", [gun_down]),
    {stop, {ws_down, Reason}, S};
handle_info(_Other, S) ->
    {noreply, S}.

terminate(Reason, _S = #state{conn = Conn}) ->
    ?LOG_INFO("Terminating cdp client ~p.", [Reason]),
    maybe_close_gun(Conn),
    ok.
maybe_close_gun(Conn) when is_pid(Conn) ->
    catch gun:close(Conn),
    ok;
maybe_close_gun(_) ->
    ok.

code_change(_Old, S, _Extra) -> {ok, S}.

%%% ───────── Internal ─────────

%% in init_connect/2 (the ws_url branch)
init_connect(S, #{ws_url := WS0}) ->
    WS = to_bin(WS0),
    %% derive host/port for dynamic protocol loading
    U = uri_string:parse(WS),
    Host = case maps:get(host, U) of
              H when is_binary(H) -> binary_to_list(H);
              H when is_list(H)   -> H
           end,
    Port = maps:get(port, U),
    connect_ws(S#state{ws_url=WS, host=Host, port=Port});
init_connect(S, #{host := Host, port := Port} = Opts) ->
    Type = maps:get(type, Opts, <<"page">>),
    case discover_ws(#{host => Host, port => Port, type => Type}) of
        {ok, WS} -> connect_ws(S#state{ws_url = WS, host = Host, port = Port});
        {error, Why} -> {error, Why}
    end;
init_connect(_S, _Bad) ->
    {error, bad_opts}.

connect_ws(S = #state{ws_url = WS}) ->
    U = uri_string:parse(WS),

    %% Scheme -> transport (fix: correct case clauses)
    Scheme0 = maps:get(scheme, U, <<"ws">>),
    Transport =
        case Scheme0 of
            <<"wss">> -> tls;
            wss -> tls;
            _ -> tcp
        end,

    %% Host must be a *string* (or IP tuple). uri_string gives binaries.
    Host0 = maps:get(host, U),
    Host =
        case Host0 of
            H when is_list(H) -> H;
            H when is_binary(H) -> binary_to_list(H);
            {_, _, _, _} = Ip -> inet_parse:ntoa(Ip)
        end,

    Port = maps:get(port, U),
    Path0 = maps:get(path, U, <<"/">>),
    Path =
        case maps:get(query, U, <<>>) of
            <<>> -> Path0;
            Q -> <<Path0/binary, "?", Q/binary>>
        end,

    Opts =
        case Transport of
            tls ->
                #{
                    transport => tls,
                    tls_opts => [{verify, verify_none}],
                    connect_timeout => ?DEFAULT_HTTP_TIMEOUT
                };
            tcp ->
                #{
                    transport => tcp,
                    connect_timeout => ?DEFAULT_HTTP_TIMEOUT
                }
        end,

    {ok, Conn} = gun:open(Host, Port, Opts),
    {ok, _} = gun:await_up(Conn),

    Ref = gun:ws_upgrade(Conn, Path, []),
    receive
        {gun_upgrade, Conn, Ref, [<<"websocket">>], _Hdrs} ->
            {ok, S#state{conn = Conn, ref = Ref}};
        {gun_ws_upgrade, Conn, Ref, _Hdrs} ->
            {ok, S#state{conn = Conn, ref = Ref}};
        {gun_response, Conn, Ref, IsFin, Status, Hdrs} ->
            {error, {bad_upgrade, {IsFin, Status, Hdrs}}}
    after ?DEFAULT_WS_TIMEOUT ->
        {error, timeout}
    end.

pick_ws(List, Type) ->
    case List of
        [] ->
            {error, no_targets};
        _ ->
            case lists:keyfind(Type, 2, [{maps:get(<<"type">>, T, <<>>), T} || T <- List]) of
                false ->
                    case
                        [
                            maps:get(<<"webSocketDebuggerUrl">>, T)
                         || T <- List,
                            maps:is_key(<<"webSocketDebuggerUrl">>, T)
                        ]
                    of
                        [WS | _] -> {ok, WS};
                        [] -> {error, no_ws_url}
                    end;
                {_Type, T} ->
                    case maps:get(<<"webSocketDebuggerUrl">>, T, undefined) of
                        undefined -> {error, no_ws_url};
                        WS -> {ok, WS}
                    end
            end
    end.

%% Simple, robust GET for DevTools JSON endpoints.
%% Retries a few times to ride out "closed, normal" while Chrome warms up.
cdp_http_get(Host, Port, Path) ->
    ok = ensure_inets(),
    Url = lists:flatten(io_lib:format("http://~s:~p~s", [host_to_list(Host), Port, Path])),
    http_get_retry(Url, 5).

http_get_retry(_Url, 0) ->
    {error, timeout};
http_get_retry(Url, N) ->
    case httpc:request(get, {Url, []}, [{timeout, 3000}], []) of
        {ok, {{_Vsn, Status, _Reason}, _Hdrs, Body}} ->
            {Status, iolist_to_binary(Body)};
        {error, socket_closed_remotely} ->
            timer:sleep(150), http_get_retry(Url, N-1);
        {error, {failed_connect, _}} ->
            timer:sleep(150), http_get_retry(Url, N-1);
        {error, _}  ->
            timer:sleep(150), http_get_retry(Url, N-1);
        Other ->
            {error, Other}
    end.

ensure_inets() ->
    case application:ensure_all_started(inets) of
        {ok, _} -> ok;
        {error, {already_started, _}} -> ok
    end.

host_to_list(H) when is_list(H)   -> H;
host_to_list(H) when is_binary(H) -> binary_to_list(H);
host_to_list({_,_,_,_}=IP)        -> inet_parse:ntoa(IP).


%%% ───────── Protocol index + validation ─────────
load_protocol() ->
    Files = ["/mnt/data/browser_protocol.json", "/mnt/data/js_protocol.json"],
    Domains = lists:flatten([read_domains(F) || F <- Files]),
    build_command_index(Domains).

read_domains(Path) ->
    case file:read_file(Path) of
        {ok, Bin} ->
            case catch jsx:decode(Bin, [return_maps]) of
                #{<<"domains">> := DomainList} -> DomainList;
                _ -> []
            end;
        _Err ->
            []
    end.

build_command_index(DomainList) ->
    lists:foldl(
        fun(#{<<"domain">> := Domain} = Dom, Acc) ->
            Cmds = maps:get(<<"commands">>, Dom, []),
            lists:foldl(
                fun(Cmd, A1) ->
                    Name = maps:get(<<"name">>, Cmd),
                    Key = <<Domain/binary, ".", Name/binary>>,
                    Params = maps:get(<<"parameters">>, Cmd, []),
                    Returns = maps:get(<<"returns">>, Cmd, []),
                    maps:put(
                        Key,
                        #{
                            params => Params,
                            returns => Returns,
                            domain => Domain,
                            name => Name
                        },
                        A1
                    )
                end,
                Acc,
                Cmds
            )
        end,
        #{},
        DomainList
    ).

validate_method(Method, Params, Index) when is_map(Index) ->
    case maps:size(Index) of
        0 ->
            ?LOG_WARNING("CDP protocol index empty; allowing ~p with params ~p", [Method, Params]),
            {ok, Params};
        _ ->
            case maps:get(Method, Index, undefined) of
                undefined ->
                    ?LOG_WARNING("CDP method ~p not in index; allowing", [Method]),
                    {ok, Params};
                #{params := ParamSpecs} ->
                    Required = [maps:get(<<"name">>, P) || P <- ParamSpecs,
                                                  not maps:get(<<"optional">>, P, false)],
                    Provided = maps:keys(Params),
                    Missing  = [R || R <- Required, not lists:member(R, Provided)],
                    case Missing of
                        [] ->
                            Allowed = [maps:get(<<"name">>, P) || P <- ParamSpecs],
                            {ok, maps:with(Allowed, Params)};
                        _  ->
                            {error, {missing_required, Missing}}
                    end
            end
    end.


%%% ───────── Utils ─────────
to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> iolist_to_binary(L);
to_bin(Other) -> iolist_to_binary(io_lib:format("~p", [Other])).
%% ---------- Shell helpers (no CT needed) -----------------------------------

%% Discover local Chrome (CDP_HOST/CDP_PORT respected), connect, enable console,
%% eval 40+2, and return the value.
sh_smoke() ->
    {Host, Port} = sh_hostport(),
    case discover_ws(#{host => Host, port => Port, type => <<"page">>}) of
        {ok, WS} ->
            case start_link(#{ws_url => WS, host => Host, port => Port}) of
                {ok, Pid} ->
                    ok = enable_console(Pid),
                    Res = call(Pid, <<"Runtime.evaluate">>,
                               #{<<"expression">> => <<"40+2">>,
                                 <<"returnByValue">> => true}),
                    _ = stop(Pid),
                    Val = case Res of
                              #{<<"result">> := #{<<"result">> := #{<<"value">> := V}}} -> V;
                              #{<<"result">> := #{<<"value">> := V}} -> V;
                              _ -> undefined
                          end,
                    {ok, Val, Res};
                Error -> Error
            end;
        Error ->
            %% don’t crash the shell on discovery errors
            {error, {discover_failed, Host, Port, Error}}
    end.


%% Attach to a running browser and return the client pid (so you can poke it).
sh_attach() ->
    {Host, Port} = sh_hostport(),
    sh_attach(Host, Port).

sh_attach(Host, Port) when is_list(Host), is_integer(Port) ->
    case discover_ws(#{host => Host, port => Port, type => <<"page">>}) of
        {ok, WS} ->
            start_link(#{ws_url => WS, host => Host, port => Port});
        Err -> Err
    end.

%% Navigate to URL and click a button whose visible text/value equals Text.
%% Uses Page/Runtime only.
sh_go_click(URL, Text) -> sh_go_click(URL, Text, "127.0.0.1").
sh_go_click(URL, Text, Host) ->
    {_, Port} = sh_hostport(),
    {ok, Pid} = sh_attach(Host, Port),
    ok = enable_console(Pid),
    _  = call(Pid, <<"Page.enable">>, #{}),
    _  = call(Pid, <<"Runtime.enable">>, #{}),

    %% navigate
    _Nav = call(Pid, <<"Page.navigate">>, #{<<"url">> => to_bin(URL)}),

    %% wait for load (or readyState 'complete')
    _ = call(Pid, <<"Runtime.evaluate">>,
             #{<<"expression">> => <<
                 "new Promise(r=>{if(document.readyState==='complete')r(1);"
                 "else addEventListener('load',()=>r(1),{once:true});})">>,
               <<"awaitPromise">> => true}),

    %% click the first button/input whose visible text/value === Text
    Expr = iolist_to_binary([
        "(function(){const t=",
        jsx:encode(to_bin(Text)),
        ";const els=[...document.querySelectorAll('button, input[type=button], input[type=submit]')];",
        "const btn=els.find(el=>((el.textContent||'').trim()===t)||((el.value||'').trim()===t));",
        "if(!btn) return {ok:false, msg:'button not found: '+t};",
        "btn.click(); return {ok:true};})()"
    ]),
    Res = call(Pid, <<"Runtime.evaluate">>,
               #{<<"expression">>  => Expr,
                 <<"returnByValue">> => true,
                 <<"userGesture">>   => true}),
    %% Return simplified result
    case Res of
        #{<<"result">> := #{<<"result">> := #{<<"value">> := #{<<"ok">> := true}}}} -> ok;
        #{<<"result">> := #{<<"value">> := #{<<"ok">> := true}}} -> ok;
        _ -> {error, Res}
    end.

%% --- small helper for host/port from env or default
sh_hostport() ->
    Host = case os:getenv("CDP_HOST") of false -> "127.0.0.1"; H -> H end,
    Port = case os:getenv("CDP_PORT") of false -> 9223; P -> list_to_integer(P) end,
    {Host, Port}.
