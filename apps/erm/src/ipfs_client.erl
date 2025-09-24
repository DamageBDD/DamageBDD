%%%-------------------------------------------------------------------
%%% ipfs_client.erl — talks to local IPFS HTTP API
%%%-------------------------------------------------------------------
-module(ipfs_client).
-export([ensure_started/1, add_and_pin/1, pin_add/1, gateway_url/1]).

-define(DEFAULT_API, "http://127.0.0.1:5001").
-define(HDRS, [{"Content-Type", "application/octet-stream"}]).

-define(API(Path), lists:concat([get_api(), "/api/v0", Path])).

ensure_started(Api) ->
    application:ensure_all_started(inets),
    put(ipfs_api, Api),
    ok.
get_api() ->
    case get(ipfs_api) of
        undefined -> ?DEFAULT_API;
        A -> A
    end.

gateway_url(Cid) -> lists:concat(["https://ipfs.io/ipfs/", Cid]).

add_and_pin(FilePath) ->
    {ok, Cid} = add(FilePath),
    _ = pin_add(Cid),
    {ok, Cid}.

add(FilePath) ->
    {ok, Bin} = file:read_file(FilePath),
    Url = ?API("/add?pin=false&wrap-with-directory=false"),
    case httpc:request(post, {Url, ?HDRS, "application/octet-stream", Bin}, [], []) of
        {ok, {{_, 200, _}, _RespHdrs, Body}} ->
            Map = jsx:decode(Body, [return_maps]),
            {ok, maps:get(<<"Hash">>, Map)};
        Err ->
            Err
    end.

pin_add(Cid) ->
    Url = ?API("/pin/add?arg=" ++ binary_to_list(Cid)),
    httpc:request(get, {Url, []}, [], []).
