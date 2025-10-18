%% steps_cdp.erl
%% BDD steps that use cdp_client to talk to the browser.
%% Resolves the current account's CDP server from the Context.

-module(steps_cdp).
-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").
-include_lib("eunit/include/eunit.hrl").

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
            case resolve_account_cdp(Context0) of
                {ws, WSUrl} ->
                    case cdp_client:start_link(#{ws_url => WSUrl}) of
                        {ok, Pid} ->
                            ok = cdp_client:enable_console(Pid),
                            {ok, maps:put(cdp_pid, Pid, Context0)};
                        Error ->
                            {error, Error}
                    end;
                {hostport, Host, Port} ->
                    case cdp_client:start_link(#{host => Host, port => Port, type => <<"page">>}) of
                        {ok, Pid} ->
                            ok = cdp_client:enable_console(Pid),
                            {ok, maps:put(cdp_pid, Pid, Context0)};
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

%% Best-effort resolver of current account's CDP endpoint.
%% Supported shapes in Context:
%%   - cdp_ws_url :: binary()
%%   - cdp_endpoint :: #{host => "127.0.0.1", port => 9222}
%%   - account / current_account / accounts_current :: #{cdp => #{ws_url|host|port|debug_port}}
resolve_account_cdp(Context) ->
    case maps:get(cdp_ws_url, Context, undefined) of
        B when is_binary(B) -> {ws, B};
        _ ->
            case maps:get(cdp_endpoint, Context, undefined) of
                #{host := Host, port := Port} -> {hostport, Host, Port};
                _ -> from_account_maps(Context)
            end
    end.

from_account_maps(Context) ->
    Candidates = [
        maps:get(account, Context, undefined),
        maps:get(current_account, Context, undefined),
        maps:get(accounts_current, Context, undefined)
    ],
    Acct = lists:keyfind(true, 1, [{is_map(C), C} || C <- Candidates]),
    case Acct of
        false -> default_local();
        {true, A} -> from_account(A)
    end.

from_account(A) when is_map(A) ->
    CDP =
        case maps:get(cdp, A, undefined) of
            M when is_map(M) -> M;
            _ -> A
        end,
    case maps:get(ws_url, CDP, undefined) of
        B when is_binary(B) -> {ws, B};
        _ ->
            Host = pick_host(CDP),
            Port = pick_port(CDP),
            case {Host, Port} of
                {undefined, _} -> default_local();
                {_, undefined} -> default_local();
                {H, P} -> {hostport, H, P}
            end
    end.

pick_host(M) ->
    case {maps:get(host, M, undefined), maps:get(<<"host">>, M, undefined)} of
        {H, _} when is_list(H) -> H;
        {undefined, HB} when is_binary(HB) -> binary_to_list(HB);
        _ -> "127.0.0.1"
    end.
pick_port(M) ->
    case
        {
            maps:get(port, M, undefined),
            maps:get(debug_port, M, undefined),
            maps:get(<<"port">>, M, undefined),
            maps:get(<<"debug_port">>, M, undefined)
        }
    of
        {P, _, _, _} when is_integer(P) -> P;
        {_, P, _, _} when is_integer(P) -> P;
        {_, _, PB, _} when is_integer(PB) -> PB;
        {_, _, _, PB} when is_integer(PB) -> PB;
        _ -> 9222
    end.

default_local() -> {hostport, "127.0.0.1", 9222}.

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
