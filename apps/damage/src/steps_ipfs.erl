%% steps_ipfs.erl
%% IPFS verification steps for DamageBDD
%% Template adapted from steps_http.erl

-module(steps_ipfs).

-author("Steven Joseph <steven@stevenjoseph.in>").
-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([step/6]).

-define(DEFAULT_HTTP_TIMEOUT, 30000).
-define(DEFAULT_HEADERS, [
    {<<"accept">>, "application/json,text/plain,*/*"},
    {<<"user-agent">>, "damagebdd/1.0"},
    {<<"content-type">>, "application/json"}
]).

%%% ---------------------- helpers (kept similar to steps_http) -----------------

get_headers(Context, DefaultHeaders) ->
    maps:to_list(
        maps:merge(
            maps:from_list(DefaultHeaders),
            maps:from_list(maps:get(headers, Context, []))
        )
    ).

%% keep the same response tuple format as steps_http
response_to_list({StatusCode, Headers, Body}) ->
    [{status_code, StatusCode}, {headers, Headers}, {body, Body}].

get_conn(Config0, #{public_key := Ae} = Context) ->
    Host = damage_utils:get_context_value(host, Context, Config0),
    Port = damage_utils:get_context_value(port, Context, Config0),
    Opts =
        case Port of
            443 -> #{transport => tls, tls_opts => [{verify, verify_none}]};
            _ -> #{transport => tcp}
        end,
    case lists:keyfind(concurrency, 1, Config0) of
        {concurrency, 1} ->
            gun:open(Host, Port, Opts#{connect_timeout => ?DEFAULT_HTTP_TIMEOUT});
        {concurrency, _} ->
            case damage_domains:is_allowed_domain(Host, Ae) of
                true -> gun:open(Host, Port, Opts#{connect_timeout => ?DEFAULT_HTTP_TIMEOUT});
                false -> throw(<<"Host not allowed for concurrent tests. See docs.">>)
            end;
        false ->
            gun:open(Host, Port, Opts#{connect_timeout => ?DEFAULT_HTTP_TIMEOUT})
    end.

await(ConnPid, StreamRef, Context) ->
    case gun:await(ConnPid, StreamRef, ?DEFAULT_HTTP_TIMEOUT) of
        {response, fin, Status, Headers} ->
            maps:put(response, response_to_list({Status, Headers, <<"">>}), Context);
        {response, nofin, Status, Headers} ->
            {ok, Body} = gun:await_body(ConnPid, StreamRef),
            maps:put(response, response_to_list({Status, Headers, Body}), Context);
        Other ->
            maps:put(fail, damage_utils:strf("Gun request failed: ~p", [Other]), Context)
    end.

%% Build full URL if caller passes a relative path
build_url(PathOrUrl, Base) ->
    case lists:prefix("http", PathOrUrl) of
        true -> PathOrUrl;
        false -> Base ++ "/" ++ string:trim(PathOrUrl, both, "/")
    end.

%% Simple JSONPath matcher like steps_http
ejsonpath_match(Path, Data, Expected, Context) ->
    Expected1 =
        case Expected of
            <<"false">> ->
                false;
            <<"true">> ->
                true;
            Bin when is_binary(Bin) ->
                case re:run(Bin, "^[0-9]+$") of
                    nomatch -> Bin;
                    _ -> binary_to_integer(Bin)
                end;
            L when is_list(L) ->
                case re:run(L, "^[0-9]+$") of
                    nomatch -> list_to_binary(L);
                    _ -> list_to_integer(L)
                end;
            Other ->
                Other
        end,
    case catch ejsonpath:q(Path, Data) of
        {[Expected1 | _], _} ->
            Context;
        UnExp ->
            Msg = "the object at path ~p is not ~p, it is ~p",
            maps:put(fail, damage_utils:strf(Msg, [Path, Expected1, UnExp]), Context)
    end.

%%% --------------------------- IPFS conveniences ------------------------------

%% Given "http://127.0.0.1:5001" -> base_url="http://...:5001", host/port parsed
set_server(Context0, Url) ->
    Context = maps:put(base_url, Url, Context0),
    case uri_string:parse(Url) of
        #{scheme := "https", host := Host} ->
            maps:put(port, 443, maps:put(host, Host, Context));
        #{scheme := "http", host := Host, port := Port} ->
            maps:put(port, Port, maps:put(host, Host, Context));
        #{scheme := "http", host := Host} ->
            maps:put(port, 80, maps:put(host, Host, Context));
        #{host := Host, port := Port} ->
            maps:put(port, Port, maps:put(host, Host, Context))
    end.

%% Compose /api/v0/<cmd>?arg=<cid>&<k>=<v>...
ipfs_api_url(Context, Cmd, Params0) ->
    Base = maps:get(base_url, Context, ""),
    Q = uri_string:compose_query(Params0),
    build_url("/api/v0/" ++ Cmd ++ "?" ++ Q, Base).

%% Uniform POST to IPFS API (some endpoints expect POST)
ipfs_post(Config, Context, Url, Headers) ->
    {ok, ConnPid} = get_conn(Config, Context),
    await(ConnPid, gun:post(ConnPid, Url, Headers, <<>>), Context).

%% Uniform GET (for gateways or API GET-compatible calls)
ipfs_get(Config, Context, Url, Headers) ->
    {ok, ConnPid} = get_conn(Config, Context),
    await(ConnPid, gun:get(ConnPid, Url, Headers), Context).

%%% ------------------------------- Steps --------------------------------------

step(_Cfg, Context, <<"Given">>, _N, ["I am using IPFS API at", Url], _) ->
    set_server(Context, Url);
step(_Cfg, Context, <<"Given">>, _N, ["I am using IPFS gateway", Url], _) ->
    maps:put(ipfs_gateway, Url, Context);
step(_Cfg, Context, <<"Given">>, _N, ["a CID", CID], _) ->
    maps:put(cid, CID, Context);
%% When I call IPFS "block/stat" for the CID
step(Cfg, Context0, <<"When">>, _N, ["I call IPFS", Cmd, "for the CID"], _Body) ->
    CID = maps:get(cid, Context0, undefined),
    case CID of
        undefined ->
            maps:put(fail, <<"CID not set">>, Context0);
        _ ->
            Url = ipfs_api_url(Context0, Cmd, [{"arg", CID}]),
            Headers = get_headers(Context0, ?DEFAULT_HEADERS),
            ipfs_post(Cfg, Context0, Url, Headers)
    end;
%% When I call IPFS "pin/ls" for the CID with type "all"
step(
    Cfg,
    Context0,
    <<"When">>,
    _N,
    ["I call IPFS", Cmd, "for the CID with type", Type],
    _Body
) ->
    CID = maps:get(cid, Context0, undefined),
    case CID of
        undefined ->
            maps:put(fail, <<"CID not set">>, Context0);
        _ ->
            Url = ipfs_api_url(Context0, Cmd, [{"arg", CID}, {"type", Type}]),
            Headers = get_headers(Context0, ?DEFAULT_HEADERS),
            ipfs_post(Cfg, Context0, Url, Headers)
    end;
%% When I GET "/ipfs/<cid>" from the gateway with Range "bytes=0-63"
step(
    Cfg,
    Context0,
    <<"When">>,
    _N,
    ["I GET", Path0, "from the gateway with Range", Range],
    _B
) ->
    Gw = maps:get(ipfs_gateway, Context0, undefined),
    CID = maps:get(cid, Context0, undefined),
    case {Gw, CID} of
        {undefined, _} ->
            maps:put(fail, <<"IPFS gateway not set">>, Context0);
        {_, undefined} ->
            maps:put(fail, <<"CID not set">>, Context0);
        {Gateway, _} ->
            Path = binary_to_list(
                binary:replace(list_to_binary(Path0), <<"<cid>">>, list_to_binary(CID), [global])
            ),
            Url = build_url(Path, Gateway),
            Headers = [{<<"range">>, Range} | get_headers(Context0, ?DEFAULT_HEADERS)],
            ipfs_get(Cfg, Context0, Url, Headers)
    end;
%% ----- Assertions (reuse steps_http semantics) --------------------------------

%% Then the response status must be N
step(_Cfg, Context, <<"Then">>, _N, ["the response status must be", NStr], _) ->
    Want = list_to_integer(NStr),
    case maps:get(response, Context) of
        [{status_code, Want} | _] ->
            Context;
        [{status_code, Got} | _] ->
            maps:put(fail, damage_utils:strf("Response status ~p /= ~p", [Got, Want]), Context);
        Unexpected ->
            maps:put(fail, damage_utils:strf("Unexpected response ~p", [Unexpected]), Context)
    end;
%% Then the response status must be 200 or 206
step(_Cfg, Context, <<"Then">>, _N, ["the response status must be 200 or 206"], _) ->
    case maps:get(response, Context) of
        [{status_code, 200} | _] ->
            Context;
        [{status_code, 206} | _] ->
            Context;
        [{status_code, Got} | _] ->
            maps:put(fail, damage_utils:strf("Response not 200/206: ~p", [Got]), Context);
        Unexpected ->
            maps:put(fail, damage_utils:strf("Unexpected response ~p", [Unexpected]), Context)
    end;
%% Then the json at path $.Key must be "<cid>"
step(_Cfg, Context, <<"Then">>, _N, ["the json at path", Path, "must be", Expect], _) ->
    case maps:get(response, Context) of
        [{status_code, _}, _Hdrs, {body, Body}] ->
            case catch jsx:decode(Body, [return_maps]) of
                {'EXIT', _} ->
                    maps:put(fail, <<"invalid json in response">>, Context);
                Json ->
                    ejsonpath_match(Path, Json, list_to_binary(Expect), Context)
            end;
        Unexpected ->
            maps:put(fail, damage_utils:strf("Unexpected response ~p", [Unexpected]), Context)
    end;
%% Then the JSON integer field at $.Size must be >= N
step(_Cfg, Context, <<"Then">>, _N, ["the json int at path", Path, "must be >=", MinStr], _) ->
    case maps:get(response, Context) of
        [{status_code, _}, _Hdrs, {body, Body}] ->
            case catch jsx:decode(Body, [return_maps]) of
                {'EXIT', _} ->
                    maps:put(fail, <<"invalid json in response">>, Context);
                Json ->
                    case ejsonpath:q(Path, Json) of
                        {[Val | _], _} ->
                            V =
                                case Val of
                                    I when is_integer(I) -> I;
                                    B when is_binary(B) -> binary_to_integer(B);
                                    L when is_list(L) -> list_to_integer(L);
                                    _ -> -1
                                end,
                            Min = list_to_integer(MinStr),
                            if
                                V >= Min ->
                                    Context;
                                true ->
                                    maps:put(
                                        fail, damage_utils:strf("Value ~p < ~p", [V, Min]), Context
                                    )
                            end;
                        Other ->
                            maps:put(
                                fail,
                                damage_utils:strf("Path ~p not found (~p)", [Path, Other]),
                                Context
                            )
                    end
            end;
        Unexpected ->
            maps:put(fail, damage_utils:strf("Unexpected response ~p", [Unexpected]), Context)
    end;
%% Then the JSON at path "Keys.<cid>.Type" must be one of "recursive,direct,indirect"
step(
    _Cfg,
    Context0,
    <<"Then">>,
    _N,
    ["the json at path", Path0, "must be one of", Csv],
    _
) ->
    [{status_code, _}, _Hdrs, {body, Body}] = maps:get(response, Context0),
    case catch jsx:decode(Body, [return_maps]) of
        {'EXIT', _} ->
            maps:put(fail, <<"invalid json in response">>, Context0);
        Json ->
            case ejsonpath:q(Path0, Json) of
                {[Val | _], _} ->
                    ValB =
                        case Val of
                            B when is_binary(B) -> B;
                            L when is_list(L) -> list_to_binary(L);
                            Other -> list_to_binary(io_lib:format("~p", [Other]))
                        end,
                    Allowed = [
                        list_to_binary(string:trim(S))
                     || S <- string:split(Csv, ",", all)
                    ],
                    case lists:member(ValB, Allowed) of
                        true ->
                            Context0;
                        false ->
                            maps:put(
                                fail, damage_utils:strf("~p not in ~p", [ValB, Allowed]), Context0
                            )
                    end;
                Other ->
                    maps:put(
                        fail, damage_utils:strf("Path ~p not found (~p)", [Path0, Other]), Context0
                    )
            end
    end;
%% Print helpers (optional)
step(Cfg, Context, <<"Then">>, N, ["I print the response"], _) ->
    Resp = maps:get(response, Context, <<"">>),
    formatter:format(
        Cfg, print, {<<"Then">>, N, ["Response:"], jsx:encode(Resp), Context, success}
    ),
    Context.
