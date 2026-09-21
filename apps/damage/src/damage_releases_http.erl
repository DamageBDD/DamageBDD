%%% Public release discovery plus authenticated NFT transfer preparation/execution.
-module(damage_releases_http).
-license("Apache-2.0").
-include_lib("kernel/include/logger.hrl").
-export([trails/0, init/2]).
-ifdef(TEST).
-export([query_params/1, response/2, parse_token/1, transfer_body/1, discovery_response/4,
         authorize_transfer/3, transfer_content_type/1, read_transfer_body/3,
         custodial_transfer/5, executed_transfer_response/5]).
-endif.

-define(MAX_TRANSFER_BODY_BYTES, 4096).
-define(TRANSFER_BODY_TIMEOUT_MS, 5000).

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
                "Transfer a release NFT with Bearer header authentication. Custodial transfers return a tracked outcome; wallet accounts receive a preflight-checked unsigned transaction.",
            consumes => ["application/json"],
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

%% This mutation accepts an explicit Bearer header only. Never allow the
%% shared authenticator's cookie/query-token fallback to authorize a transfer.
%% GET/HEAD discovery continues through serve/2 without authentication.
serve_transfer(Req0, Opts) ->
    case authorize_transfer(Req0, Opts, fun damage_http:is_authorized/2) of
        {ok, Req1, #{public_key := From} = AuthState} ->
            case transfer_content_type(Req1) of
                ok -> serve_transfer_body(Req1, AuthState, From);
                {error, _} ->
                    transfer_error(415, <<"application_json_required">>, Req1)
            end;
        {error, unauthorized, Req1} ->
            {Status, Headers, Body, Req2} = transfer_error(401, <<"unauthorized">>, Req1),
            {Status, Headers#{<<"www-authenticate">> => <<"Bearer">>}, Body, Req2};
        {error, invalid_request, Req1} ->
            transfer_error(400, <<"invalid_transfer_request">>, Req1);
        {error, auth_unavailable, Req1} ->
            transfer_error(503, <<"authentication_unavailable">>, Req1)
    end.

authorize_transfer(Req0, _Opts, Authenticate) ->
    case bearer_header(cowboy_req:header(<<"authorization">>, Req0)) of
        false ->
            {error, unauthorized, Req0};
        true ->
            %% This route has no query parameters. In particular, credentials
            %% must not be accepted in URLs, even alongside a Bearer header.
            case cowboy_req:qs(Req0) of
                <<>> ->
                    try Authenticate(Req0, #{action => transfer}) of
                        {true, Req1, #{public_key := From} = State}
                                when is_binary(From) ->
                            {ok, Req1, State};
                        {_Failure, Req1, _State} ->
                            {error, unauthorized, Req1};
                        _ ->
                            {error, unauthorized, Req0}
                    catch
                        %% Never log auth state, credentials or exception terms.
                        _:_ -> {error, auth_unavailable, Req0}
                    end;
                _ ->
                    {error, invalid_request, Req0}
            end
    end.

bearer_header(<<"Bearer ", Token/binary>>) when
        byte_size(Token) > 0, byte_size(Token) =< 8192, Token =/= <<"null">> ->
    %% Match the scheme understood by damage_http, and reject whitespace and
    %% combined Authorization values instead of falling back to another source.
    re:run(Token, <<"\\A[A-Za-z0-9._~+/-]+=*\\z">>, [{capture, none}]) =:= match;
bearer_header(_) ->
    false.

transfer_content_type(Req) ->
    try {cowboy_req:parse_header(<<"content-type">>, Req),
         cowboy_req:header(<<"content-encoding">>, Req)} of
        {{<<"application">>, <<"json">>, _Params}, Encoding}
                when Encoding =:= undefined; Encoding =:= <<"identity">> ->
            ok;
        _ -> {error, unsupported_media_type}
    catch
        _:_ -> {error, unsupported_media_type}
    end.

serve_transfer_body(Req0, AuthState, From) ->
    case read_transfer_body(Req0) of
        {ok, Json, Req1} ->
            case {parse_token(cowboy_req:binding(token, Req1)), transfer_body(Json)} of
                {{ok, Token}, {ok, To}} ->
                    transfer_for_authenticated_user(AuthState, From, Token, To, Req1);
                _ -> transfer_error(400, <<"invalid_transfer_request">>, Req1)
            end;
        {error, payload_too_large, Req1} ->
            transfer_error(413, <<"transfer_request_too_large">>, Req1);
        {error, body_timeout, Req1} ->
            transfer_error(408, <<"transfer_request_timeout">>, Req1);
        {error, _, Req1} ->
            transfer_error(400, <<"invalid_transfer_request">>, Req1)
    end.

transfer_for_authenticated_user(AuthState, From, Token, To, Req) ->
    case maps:get(username, AuthState, <<"wallet">>) of
        <<"wallet">> ->
            %% Preparation has no signing key and never broadcasts. The exact
            %% returned bytes, not a separately built transaction, pass preflight.
            case damage_release_nft:prepare_transfer(From, Token, To) of
                {ok, Intent} ->
                    Body = Intent#{ok => true, status => <<"signature_required">>,
                                   signing => <<"wallet">>},
                    {202, json_headers(), jsx:encode(Body), Req};
                Error -> transfer_result_error(Error, Req)
            end;
        Username ->
            Result = custodial_transfer(From, Username, {Token, To},
                fun identity_server:get_account_by_email/1,
                fun damage_release_nft:transfer/3),
            executed_transfer_response(Result, From, Token, To, Req)
    end.

custodial_transfer(From, Username, {Token, To}, Lookup, Transfer) ->
    %% Catch only the key lookup here. Do not turn an exception AFTER a write
    %% into a false claim that signing was unavailable.
    Account = try Lookup(Username) catch _:_ -> unavailable end,
    case Account of
        {From, _Password, Private} when is_binary(Private), byte_size(Private) =:= 64 ->
            try Transfer(#{public_key => From, private_key => Private}, Token, To)
            catch _:_ -> {error, transfer_outcome_unknown}
            end;
        _ -> {error, transfer_signing_unavailable}
    end.

executed_transfer_response({ok, #{status := State, tx_hash := Hash}}, From, Token, To, Req)
        when is_binary(Hash),
             (State =:= confirmed orelse State =:= submitted orelse State =:= submission_unknown) ->
    Status = case State of confirmed -> 200; _ -> 202 end,
    Body = #{ok => true, status => atom_to_binary(State, utf8),
             token_id => Token, from => From, to => To, tx_hash => Hash},
    {Status, json_headers(), jsx:encode(Body), Req};
executed_transfer_response(Error, _From, _Token, _To, Req) ->
    transfer_result_error(Error, Req).

transfer_result_error({error, Invalid}, Req) when
    Invalid =:= invalid_release_token;
    Invalid =:= invalid_release_identifier
->
    transfer_error(400, <<"invalid_transfer_request">>, Req);
transfer_result_error({error, {release_transfer_rejected, Rejection}}, Req) ->
    %% Include only safe, explicitly selected fields. Never return raw VM data.
    Body0 = #{ok => false, status => <<"rejected">>, error => <<"transfer_rejected">>},
    Body = case maps:find(tx_hash, Rejection) of
        {ok, Hash} when is_binary(Hash) -> Body0#{tx_hash => Hash};
        _ -> Body0
    end,
    {409, json_headers(), jsx:encode(Body), Req};
transfer_result_error({error, {release_transfer_failed, {revert, _}}}, Req) ->
    transfer_error(409, <<"transfer_rejected">>, Req);
transfer_result_error({error, {release_transfer_failed, transfer_outcome_unknown}}, Req) ->
    transfer_result_error({error, transfer_outcome_unknown}, Req);
transfer_result_error({error, transfer_outcome_unknown}, Req) ->
    %% A process failure can lose the reply, even after submission. This
    %% is deliberately NOT 'rejected' or 'not submitted'; reconcile before retry.
    {503, json_headers(), jsx:encode(#{ok => false, status => <<"outcome_unknown">>,
                                     error => <<"transfer_outcome_unknown">>}), Req};
transfer_result_error({error, transfer_signing_unavailable}, Req) ->
    transfer_error(403, <<"transfer_signing_unavailable">>, Req);
transfer_result_error({error, invalid_release_signing_keypair}, Req) ->
    transfer_error(503, <<"transfer_signing_unavailable">>, Req);
transfer_result_error({error, {release_transfer_failed, _}}, Req) ->
    transfer_error(503, <<"transfer_unavailable">>, Req);
transfer_result_error(_, Req) ->
    transfer_error(503, <<"transfer_unavailable">>, Req).

transfer_error(Status, Code, Req) ->
    {Status, json_headers(), jsx:encode(#{ok => false, error => Code}), Req}.

read_transfer_body(Req) ->
    read_transfer_body(Req, fun cowboy_req:read_body/2,
                       fun() -> erlang:monotonic_time(millisecond) end).

%% Callbacks are private implementation seams, exported only for unit tests.
%% The request, context and application configuration cannot override them.
read_transfer_body(Req, Read, Now) ->
    Deadline = Now() + ?TRANSFER_BODY_TIMEOUT_MS,
    read_transfer_chunks(Req, Read, Now, Deadline, 0, []).

read_transfer_chunks(Req0, Read, Now, Deadline, Size, Acc) ->
    Remaining = Deadline - Now(),
    case Remaining > 0 of
        false -> {error, body_timeout, Req0};
        true ->
            %% Cowboy's length is a chunk request, NOT a hard body-size limit.
            %% Request one extra byte so an exactly-full body can be distinguished
            %% from a too-large body. Keep timeout > period and within our budget.
            Opts = #{length => ?MAX_TRANSFER_BODY_BYTES - Size + 1,
                     period => erlang:min(1000, Remaining div 2),
                     timeout => Remaining},
            ReadResult = try Read(Req0, Opts)
                         catch
                             exit:timeout -> {error, body_timeout};
                             exit:{timeout, _} -> {error, body_timeout};
                             exit:{request_error, timeout, _} -> {error, body_timeout};
                             exit:{request_error, {timeout, _}, _} -> {error, body_timeout};
                             error:timeout -> {error, body_timeout};
                             _:_ -> {error, body_read_failed}
                         end,
            case ReadResult of
                {Tag, Chunk, Req1} when
                        (Tag =:= ok orelse Tag =:= more), is_binary(Chunk) ->
                    NextSize = Size + byte_size(Chunk),
                    case {NextSize > ?MAX_TRANSFER_BODY_BYTES, Now() >= Deadline} of
                        {true, _} -> {error, payload_too_large, Req1};
                        {false, true} -> {error, body_timeout, Req1};
                        {false, false} when Tag =:= ok ->
                            decode_transfer_body(iolist_to_binary(lists:reverse([Chunk | Acc])), Req1);
                        {false, false} ->
                            read_transfer_chunks(Req1, Read, Now, Deadline,
                                                 NextSize, body_chunk(Chunk, Acc))
                    end;
                {error, body_timeout} -> {error, body_timeout, Req0};
                _ -> {error, body_read_failed, Req0}
            end
    end.

%% Empty partial reads must not grow the accumulator.
body_chunk(<<>>, Acc) -> Acc;
body_chunk(Chunk, Acc) -> [Chunk | Acc].

decode_transfer_body(Body, Req) ->
    try jsx:decode(Body, [return_maps]) of
        Json when is_map(Json) -> {ok, Json, Req};
        _ -> {error, invalid_json, Req}
    catch
        _:_ -> {error, invalid_json, Req}
    end.

transfer_body(Json) when is_map(Json), map_size(Json) =:= 1 ->
    case maps:find(<<"to">>, Json) of
        {ok, To} when is_binary(To), byte_size(To) > 0, byte_size(To) =< 64 -> {ok, To};
        _ -> {error, invalid_transfer_body}
    end;
transfer_body(_) ->
    {error, invalid_transfer_body}.

parse_token(Token) when is_binary(Token), byte_size(Token) > 0, byte_size(Token) =< 39 ->
    %% Keep the canonical positive-decimal form used by the release parser.
    case re:run(Token, <<"\\A[1-9][0-9]{0,38}\\z">>, [{capture, none}]) of
        match -> {ok, binary_to_integer(Token)};
        nomatch -> {error, invalid_release_token}
    end;
parse_token(_) ->
    {error, invalid_release_token}.

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
