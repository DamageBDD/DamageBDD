%%% Public release discovery plus authenticated NFT transfer preparation/execution.
-module(damage_releases_http).
-license("Apache-2.0").
-include_lib("kernel/include/logger.hrl").
-export([trails/0, init/2]).
-ifdef(TEST).
-export([query_params/1, response/2, parse_token/1, transfer_body/1, discovery_response/4]).
-endif.

-define(MAX_TRANSFER_BODY_BYTES, 4096).

trails() ->
    Meta = #{
        get => #{
            tags => ["Build releases"],
            description => "Read an NFT-backed published installation manifest.",
            produces => ["application/json", "text/plain"]
        }
    },
    CurrentMeta = #{
        get => #{
            tags => ["Build releases"],
            description => "Read provenance for the release running on this node.",
            produces => ["application/json"]
        }
    },
    TransferMeta = #{
        post => #{
            tags => ["Build releases"],
            description =>
                "Transfer a release NFT as the authenticated account. Custodial accounts execute immediately; wallet accounts receive an unsigned transaction to sign.",
            produces => ["application/json"],
            parameters => [
                #{
                    name => <<"to">>,
                    description => <<"Aeternity recipient account (ak_...).">>,
                    in => <<"body">>,
                    required => true,
                    type => <<"string">>
                }
            ]
        }
    },
    [
        trails:trail("/api/releases/current", ?MODULE, #{action => current}, CurrentMeta),
        trails:trail("/api/releases/latest", ?MODULE, #{action => latest}, Meta),
        trails:trail("/api/releases/nfts/:token/transfer", ?MODULE, #{action => transfer}, TransferMeta),
        trails:trail("/api/releases/:release", ?MODULE, #{action => versioned}, Meta)
    ].

init(Req0, Opts) ->
    Method = cowboy_req:method(Req0),
    Action = maps:get(action, Opts),
    {Status, Headers, Body, Req1} =
        case {Action, Method} of
            {transfer, <<"POST">>} ->
                serve_transfer(Req0, Opts);
            {transfer, _} ->
                method_not_allowed(<<"POST">>, Req0);
            {_, Allowed} when Allowed =:= <<"GET">>; Allowed =:= <<"HEAD">> ->
                {S, H, B} = serve(Req0, Opts),
                {S, H, B, Req0};
            _ ->
                method_not_allowed(<<"GET, HEAD">>, Req0)
        end,
    Req = cowboy_req:reply(Status, Headers, Body, Req1),
    {ok, Req, Opts}.

method_not_allowed(Allow, Req) ->
    {405, (json_headers())#{<<"allow">> => Allow},
        jsx:encode(#{ok => false, error => <<"method_not_allowed">>}), Req}.

serve(_Req, #{action := current}) ->
    {200, json_headers(), jsx:encode((damage_release:info())#{ok => true})};
serve(Req, Opts) ->
    %% Only malformed query parsing is a client error. Exceptions in discovery
    %% or rendering are backend failures, never an "invalid request" response.
    Parsed = try {ok, cowboy_req:parse_qs(Req)} catch _:_ -> error end,
    case Parsed of
        {ok, Pairs} ->
            Lookup = fun
                (latest, Platform) -> damage_release_nft:latest(Platform);
                ({release, Version}, Platform) -> damage_release_nft:release(Version, Platform)
            end,
            Action = maps:get(action, Opts),
            Version = case Action of
                versioned -> cowboy_req:binding(release, Req);
                latest -> undefined
            end,
            discovery_response(Action, Version, Pairs, Lookup);
        error -> response({error, invalid_request}, json)
    end.

discovery_response(Action, Version, Pairs, Lookup) ->
    case query_params(Pairs) of
        {ok, Platform, Format} ->
            try
                Selector = case Action of
                    latest -> latest;
                    versioned -> {release, Version}
                end,
                response(Lookup(Selector, Platform), Format)
            catch
                Class:_ ->
                    ?LOG_WARNING("Release HTTP discovery failed class=~p", [Class]),
                    response({error, release_backend_failed}, Format)
            end;
        {error, _} -> response({error, invalid_request}, json)
    end.

%% Auth is deliberately delegated to the same Bearer/cookie authentication path
%% used by the rest of DamageBDD. The transfer handler never accepts a caller
%% address in the request body: the sender always comes from authenticated state.
serve_transfer(Req0, Opts) ->
    case damage_http:is_authorized(Req0, Opts) of
        {true, Req1, #{public_key := From} = AuthState} ->
            case read_transfer_body(Req1) of
                {ok, Json, Req2} ->
                    case {parse_token(cowboy_req:binding(token, Req2)), transfer_body(Json)} of
                        {{ok, Token}, {ok, To}} ->
                            transfer_for_authenticated_user(AuthState, From, Token, To, Req2);
                        _ ->
                            transfer_error(400, <<"invalid_transfer_request">>, Req2)
                    end;
                {error, payload_too_large, Req2} ->
                    transfer_error(413, <<"transfer_request_too_large">>, Req2);
                {error, _, Req2} ->
                    transfer_error(400, <<"invalid_transfer_request">>, Req2)
            end;
        {_AuthFailure, Req1, _State} ->
            transfer_error(401, <<"unauthorized">>, Req1);
        _ ->
            transfer_error(401, <<"unauthorized">>, Req0)
    end.

transfer_for_authenticated_user(AuthState, From, Token, To, Req) ->
    case maps:find(username, AuthState) of
        {ok, Username} ->
            %% Password/custodial login. Re-read the keypair instead of trusting
            %% any key material from the request or HTTP state.
            case identity_server:get_account_by_email(Username) of
                {From, _Password, PrivateKey} when is_binary(PrivateKey), byte_size(PrivateKey) > 0 ->
                    Result = damage_release_nft:transfer(
                        #{public_key => From, private_key => PrivateKey}, Token, To
                    ),
                    executed_transfer_response(Result, From, Token, To, Req);
                _ ->
                    transfer_error(403, <<"transfer_signing_unavailable">>, Req)
            end;
        error ->
            %% Wallet login: never ask for or reconstruct the private key. Return
            %% only the exact AEX-141 transaction after a dry-run authorization
            %% check. The wallet signs it client-side.
            case damage_release_nft:prepare_transfer(From, Token, To) of
                {ok, Intent} ->
                    Body = Intent#{
                        ok => true,
                        status => <<"signature_required">>,
                        signing => <<"wallet">>
                    },
                    {202, json_headers(), jsx:encode(Body), Req};
                Error ->
                    transfer_result_error(Error, Req)
            end
    end.

executed_transfer_response({ok, Call}, From, Token, To, Req) ->
    Base = #{
        ok => true,
        status => <<"transferred">>,
        token_id => Token,
        from => From,
        to => To
    },
    Body =
        case transfer_tx_hash(Call) of
            undefined -> Base;
            TxHash -> Base#{tx_hash => TxHash}
        end,
    {200, json_headers(), jsx:encode(Body), Req};
executed_transfer_response(Error, _From, _Token, _To, Req) ->
    transfer_result_error(Error, Req).

transfer_result_error({error, Invalid}, Req) when
    Invalid =:= invalid_release_token;
    Invalid =:= invalid_release_identifier
->
    transfer_error(400, <<"invalid_transfer_request">>, Req);
transfer_result_error({error, {release_transfer_failed, {revert, _Reason}}}, Req) ->
    %% The NFT contract remains authoritative for owner/operator permission and
    %% token existence. Keep the public response stable instead of leaking raw
    %% VM/contract payloads.
    transfer_error(409, <<"transfer_rejected">>, Req);
transfer_result_error({error, {release_transfer_failed, _Reason}}, Req) ->
    transfer_error(502, <<"transfer_failed">>, Req);
transfer_result_error({error, invalid_release_signing_keypair}, Req) ->
    transfer_error(503, <<"transfer_signing_unavailable">>, Req);
transfer_result_error({error, _}, Req) ->
    transfer_error(503, <<"transfer_unavailable">>, Req).

transfer_error(Status, Code, Req) ->
    {Status, json_headers(), jsx:encode(#{ok => false, error => Code}), Req}.

read_transfer_body(Req0) ->
    case cowboy_req:read_body(Req0, #{length => ?MAX_TRANSFER_BODY_BYTES, period => 5000}) of
        {ok, Body, Req1} when byte_size(Body) =< ?MAX_TRANSFER_BODY_BYTES ->
            try jsx:decode(Body, [return_maps]) of
                Json when is_map(Json) -> {ok, Json, Req1};
                _ -> {error, invalid_json, Req1}
            catch
                _:_ -> {error, invalid_json, Req1}
            end;
        {more, _Chunk, Req1} ->
            {error, payload_too_large, Req1};
        {error, _Reason} ->
            {error, body_read_failed, Req0}
    end.

transfer_body(Json) when is_map(Json), map_size(Json) =:= 1 ->
    case maps:find(<<"to">>, Json) of
        {ok, To} when is_binary(To), byte_size(To) > 0 -> {ok, To};
        _ -> {error, invalid_transfer_body}
    end;
transfer_body(_) ->
    {error, invalid_transfer_body}.

parse_token(Token) when is_binary(Token), byte_size(Token) > 0, byte_size(Token) =< 39 ->
    try binary_to_integer(Token) of
        I when I > 0 -> {ok, I};
        _ -> {error, invalid_release_token}
    catch
        _:_ -> {error, invalid_release_token}
    end;
parse_token(_) ->
    {error, invalid_release_token}.

transfer_tx_hash(Call) when is_map(Call) ->
    maps:get("tx_hash", Call,
        maps:get(<<"tx_hash">>, Call,
            maps:get(tx_hash, Call, undefined)));
transfer_tx_hash(_) ->
    undefined.

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
