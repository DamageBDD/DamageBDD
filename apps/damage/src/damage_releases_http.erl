%%% Public, read-only release discovery. No mint/deploy/publish HTTP routes.
-module(damage_releases_http).
-license("Apache-2.0").
-export([trails/0, init/2]).
-ifdef(TEST).
-export([query_params/1, response/2]).
-endif.

trails() ->
    Meta = #{
        get => #{
            tags => ["Build releases"],
            description => "Read an NFT-backed published installation manifest.",
            produces => ["application/json", "text/plain"]
        }
    },
    [
        trails:trail("/api/releases/latest", ?MODULE, #{action => latest}, Meta),
        trails:trail("/api/releases/:release", ?MODULE, #{action => versioned}, Meta)
    ].

init(Req0, Opts) ->
    Method = cowboy_req:method(Req0),
    {Status, Headers, Body} =
        case Method of
            Allowed when Allowed =:= <<"GET">>; Allowed =:= <<"HEAD">> ->
                serve(Req0, Opts);
            _ ->
                {405, (json_headers())#{<<"allow">> => <<"GET, HEAD">>},
                    jsx:encode(#{ok => false, error => <<"method_not_allowed">>})}
        end,
    Req = cowboy_req:reply(Status, Headers, Body, Req0),
    {ok, Req, Opts}.

serve(Req, Opts) ->
    try query_params(cowboy_req:parse_qs(Req)) of
        {ok, Platform, Format} ->
            Result =
                case maps:get(action, Opts) of
                    latest ->
                        damage_release_nft:latest(Platform);
                    versioned ->
                        %% Domain validation is owned by damage_release_nft.
                        damage_release_nft:release(cowboy_req:binding(release, Req), Platform)
                end,
            response(Result, Format);
        {error, _} ->
            response({error, invalid_request}, json)
    catch
        _:_ -> response({error, invalid_request}, json)
    end.

query_params(Pairs) when is_list(Pairs) ->
    try
        true = lists:all(
            fun({K, _}) ->
                K =:= <<"platform">> orelse K =:= <<"format">>
            end,
            Pairs
        ),
        Platform = one_param(<<"platform">>, Pairs, <<>>),
        Format =
            case one_param(<<"format">>, Pairs, <<"json">>) of
                <<"json">> -> json;
                <<"install">> -> install
            end,
        true = Platform =:= <<>> orelse damage_release_nft:valid_platform(Platform),
        true = Format =/= install orelse Platform =/= <<>>,
        {ok, Platform, Format}
    catch
        _:_ -> {error, invalid_request}
    end;
query_params(_) ->
    {error, invalid_request}.

one_param(Key, Pairs, Default) ->
    case [V || {K, V} <- Pairs, K =:= Key] of
        [] -> Default;
        [Value] when is_binary(Value) -> Value;
        _ -> error(invalid_query_parameter)
    end.

response({ok, Release}, install) ->
    {200, (json_headers())#{<<"content-type">> => <<"text/plain; charset=utf-8">>},
        damage_release_nft:install_manifest(Release)};
response({ok, Release}, json) ->
    {200, json_headers(), jsx:encode(Release#{ok => true})};
response({error, installation_manifest_missing}, _) ->
    error_response(422, <<"installation_manifest_missing">>);
response({error, not_found}, _) ->
    error_response(404, <<"release_not_found">>);
response({error, Invalid}, _) when
    Invalid =:= invalid_request; Invalid =:= invalid_platform; Invalid =:= invalid_release
->
    error_response(400, <<"invalid_release_request">>);
response({error, _}, _) ->
    {Status, Headers, Body} = error_response(503, <<"release_unavailable">>),
    {Status, Headers#{<<"retry-after">> => <<"30">>}, Body}.

error_response(Status, Code) ->
    {Status, json_headers(), jsx:encode(#{ok => false, error => Code})}.
json_headers() ->
    #{
        <<"content-type">> => <<"application/json">>,
        <<"cache-control">> => <<"no-store">>,
        <<"x-content-type-options">> => <<"nosniff">>
    }.
