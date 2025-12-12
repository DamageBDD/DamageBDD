%% steps_cdp.erl
%% BDD steps that use cdp_client to talk to the browser.
%% Resolves the current account's CDP server from the Context.

-module(steps_cdp).
-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("browser_mgr.hrl").

-export([step/6, test/0]).

%% ───────── Steps ─────────

%% Attach to the current account's CDP (discover ws and start client)
step(_Cfg, Context, <<"Given">>, _N, ["I attach to account CDP"], _) ->
    case ensure_client(Context) of
        {ok, C1} ->
            C1;
        {error, Why} ->
            maps:put(fail, to_bin(io_lib:format("cdp attach failed: ~p", [Why])), Context)
    end;
%% Call a CDP method (no body)
step(_Cfg, Context, <<"When">>, _N, ["I call CDP", Method], <<>>) ->
    {ok, C1, _Resp} = do_call(Context, iolist_to_binary(Method), #{}),
    C1;
%% Call a CDP method with JSON/k:v body
step(_Cfg, Context, <<"When">>, _N, ["I call CDP", Method, "with"], Body) ->
    Params = parse_body_to_map(Body),
    {ok, C1, _Resp} = do_call(Context, iolist_to_binary(Method), Params),
    C1;
%% Assert JSONPath-like value equals
step(_Cfg, Context, <<"Then">>, _N, ["the CDP result at", Path, "must be", Expected0], _) ->
    Expected = to_bin(Expected0),
    case maps:get(cdp_last, Context, undefined) of
        undefined ->
            maps:put(fail, <<"No CDP result">>, Context);
        Res when is_map(Res) ->
            case json_path_simple(Res, Path) of
                {ok, V} ->
                    VB = to_bin(V),
                    if
                        VB =:= Expected ->
                            Context;
                        true ->
                            maps:put(
                                fail,
                                to_bin(io_lib:format("Expected ~s got ~p", [Path, V])),
                                Context
                            )
                    end;
                {error, Why} ->
                    maps:put(fail, to_bin(io_lib:format("Path ~s error ~p", [Path, Why])), Context)
            end
    end.

%% ───────── Internals ─────────

%% ── replace in steps_cdp.erl ────────────────────────────────────────────────
ensure_client(Context0) ->
    Pid0 = maps:get(cdp_pid, Context0, undefined),
    case is_pid(Pid0) andalso erlang:is_process_alive(Pid0) of
        true ->
            {ok, Context0};
        false ->
            case browser_mgr:ensure_session(Context0) of
                {ok, Rec} ->
                    %% or maps:get(host, Rec) if you prefer maps
                    Host = Rec#rec.host,
                    Port = Rec#rec.port,
                    case
                        cdp_client:discover_ws(#{host => Host, port => Port, type => <<"page">>})
                    of
                        {ok, WS} ->
                            case
                                cdp_client:start_link(#{ws_url => WS, host => Host, port => Port})
                            of
                                {ok, Pid} ->
                                    ok = cdp_client:enable_console(Pid),
                                    {ok, Context0#{
                                        cdp_pid => Pid,
                                        cdp_endpoint => #{host => Host, port => Port},
                                        chrome_user_data_dir => Rec#rec.user_data_dir,
                                        chrome_log => Rec#rec.log_file
                                    }};
                                Error ->
                                    {error, Error}
                            end;
                        Error ->
                            {error, Error}
                    end;
                {error, Why} ->
                    {error, Why}
            end
    end.

do_call(Context0, Method, Params) ->
    case ensure_client(Context0) of
        {ok, Ctx1} ->
            Pid = maps:get(cdp_pid, Ctx1),
            Reply = cdp_client:call(Pid, Method, Params),
            {ok, maps:put(cdp_last, Reply, Ctx1), Reply};
        Error ->
            Error
    end.

%% Minimal JSONPath: "$.a.b.c" (keys only)
json_path_simple(Map, Path) when is_map(Map) ->
    PathBin =
        case Path of
            P when is_binary(P) -> P;
            P when is_list(P) -> list_to_binary(P)
        end,
    Clean = strip_prefix(PathBin),
    Keys = [K || K <- binary:split(Clean, <<".">>, [global]), K =/= <<>>],
    walk_keys(Map, Keys).

strip_prefix(<<$$, $., Rest/binary>>) -> Rest;
strip_prefix(<<$$, Rest/binary>>) -> Rest;
strip_prefix(Other) -> Other.

walk_keys(Val, []) ->
    {ok, Val};
walk_keys(M, [K | Ks]) when is_map(M) ->
    case maps:is_key(K, M) of
        true -> walk_keys(maps:get(K, M), Ks);
        false -> {error, {missing_key, K}}
    end;
walk_keys(Other, _Ks) ->
    {error, {not_a_map, Other}}.

%% Accepts body as JSON (preferred) or a simple k:v YAML-ish list.
parse_body_to_map(Bin) when is_binary(Bin) ->
    Str = unicode:characters_to_list(Bin),
    T = string:trim(Str),
    case T of
        [$\{ | _] ->
            case catch jiffy:decode(list_to_binary(T), [return_maps]) of
                M when is_map(M) -> M;
                _ -> #{}
            end;
        _ ->
            Lines = [L || L <- string:split(T, "\n", all), string:trim(L) =/= ""],
            Pairs = [parse_kv(L) || L <- Lines],
            maps:from_list([P || {ok, P} <- Pairs])
    end.

parse_kv(Line) ->
    case string:split(Line, ":", leading) of
        [K, V] -> {ok, {list_to_binary(string:trim(K)), parse_scalar(string:trim(V))}};
        _ -> error
    end.

parse_scalar("true") ->
    true;
parse_scalar("false") ->
    false;
parse_scalar(V) ->
    case catch list_to_integer(V) of
        I when is_integer(I) -> I;
        _ -> list_to_binary(V)
    end.

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> iolist_to_binary(L);
to_bin(I) when is_integer(I) -> integer_to_binary(I);
to_bin(F) when is_float(F) -> list_to_binary(io_lib:format("~p", [F]));
to_bin(true) -> <<"true">>;
to_bin(false) -> <<"false">>;
to_bin(Other) -> iolist_to_binary(io_lib:format("~p", [Other])).

%% ───────── Smoke test (optional): requires a browser on 127.0.0.1:9222 ─────────
test() ->
    %% no endpoint in Context -> defaults to 127.0.0.1:9222
    C0 = #{},
    case ensure_client(C0) of
        {ok, C1} ->
            {ok, _C2, R} = do_call(C1, <<"Runtime.evaluate">>, #{
                <<"expression">> => <<"1+2">>, <<"returnByValue">> => true
            }),
            case json_path_simple(R, "$.result.value") of
                {ok, 3} -> ok;
                Other -> {error, Other}
            end;
        {error, Why} ->
            {skipped, Why}
    end.
