-module(lightning_auth).
-vsn("0.1.0").
-author("Steven Joseph <steven@damagebdd.com>").
-copyright("Steven Joseph <steven@damagebdd.com>").
-license("Apache-2.0").
-include_lib("kernel/include/logger.hrl").

-include_lib("damage.hrl").

%% API Exports
-export([init/2, trails/0]).

%% JWT Secret Key (Change in production)
-define(JWT_SECRET, <<"super_secret_key">>).
-export([content_types_accepted/2]).
-export([content_types_provided/2]).
-export([to_json/2]).
-export([from_json/2, allowed_methods/2, is_authorized/2]).

%% Trails Route Definitions
-define(TRAILS_TAG, ["Lightning Authentication"]).

trails() ->
    [
        trails:trail(
            "/lnurl-auth",
            lightning_auth,
            #{action => lnurl_auth},
            #{
                get =>
                    #{
                        tags => ?TRAILS_TAG,
                        description => "LnUrl authentication.",
                        produces => ["application/json"],
                        parameters => [
                            #{
                                name => "tag",
                                in => path,
                                required => true,
                                type => string,
                                description => "Lightning address of the user"
                            },
                            #{
                                name => "action",
                                in => path,
                                required => true,
                                type => string,
                                description => "Lightning auth action."
                            },
                            #{
                                name => "k1",
                                in => path,
                                required => true,
                                type => string,
                                description => "Lightning challenge."
                            }
                        ],
                        responses => #{
                            200 => #{
                                description => "Authenticated successfully",
                                schema => #{invoice => string}
                            },
                            400 => #{
                                description => "Error authenticating",
                                schema => #{error => string}
                            }
                        }
                    }
            }
        ),
        trails:trail(
            "/auth/lninvoice/:lnaddress",
            lightning_auth,
            #{action => generate_ln_invoice},
            #{
                get =>
                    #{
                        tags => ?TRAILS_TAG,
                        description => "Generates a Lightning invoice for authentication.",
                        produces => ["application/json"],
                        parameters => [
                            #{
                                name => "lnaddress",
                                in => path,
                                required => true,
                                type => string,
                                description => "Lightning address of the user"
                            }
                        ],
                        responses => #{
                            200 => #{
                                description => "Invoice generated successfully",
                                schema => #{invoice => string}
                            },
                            400 => #{
                                description => "Error generating invoice",
                                schema => #{error => string}
                            }
                        }
                    }
            }
        ),
        trails:trail(
            "/auth/lninvoice/:lnaddress",
            lightning_auth,
            #{action => generate_ln_invoice},
            #{
                get =>
                    #{
                        tags => ?TRAILS_TAG,
                        description => "Generates a Lightning invoice for authentication.",
                        produces => ["application/json"],
                        parameters => [
                            #{
                                name => "lnaddress",
                                in => path,
                                required => true,
                                type => string,
                                description => "Lightning address of the user"
                            }
                        ],
                        responses => #{
                            200 => #{
                                description => "Invoice generated successfully",
                                schema => #{invoice => string}
                            },
                            400 => #{
                                description => "Error generating invoice",
                                schema => #{error => string}
                            }
                        }
                    }
            }
        ),
        trails:trail(
            "/auth/lnverify/:lnaddress",
            lightning_auth,
            #{action => verify_ln_payment},
            #{
                get =>
                    #{
                        tags => ?TRAILS_TAG,
                        description => "Verifies if the Lightning invoice has been paid.",
                        produces => ["application/json"],
                        parameters => [
                            #{
                                name => "lnaddress",
                                in => path,
                                required => true,
                                type => string,
                                description => "Lightning address of the user"
                            }
                        ],
                        responses => #{
                            200 => #{
                                description => "Payment verified",
                                schema => #{status => string, session => string}
                            },
                            400 => #{
                                description => "Payment not found or not verified",
                                schema => #{error => string}
                            }
                        }
                    }
            }
        ),
        trails:trail(
            "/auth/link_nostr/:lnaddress/:npub",
            lightning_auth,
            #{action => link_nostr},
            #{
                get =>
                    #{
                        tags => ?TRAILS_TAG,
                        description => "Links a Nostr public key (`npub`) to a Lightning address.",
                        produces => ["application/json"],
                        parameters => [
                            #{
                                name => "lnaddress",
                                in => path,
                                required => true,
                                type => string,
                                description => "Lightning address of the user"
                            },
                            #{
                                name => "npub",
                                in => path,
                                required => true,
                                type => string,
                                description => "Nostr public key to be linked"
                            }
                        ],
                        responses => #{
                            200 => #{
                                description => "Nostr public key linked successfully",
                                schema => #{status => string, npub => string}
                            },
                            400 => #{
                                description => "Error linking Nostr key",
                                schema => #{error => string}
                            }
                        }
                    }
            }
        ),
        trails:trail(
            "/auth/jwt/validate",
            lightning_auth,
            #{action => validate_jwt},
            #{
                get =>
                    #{
                        tags => ?TRAILS_TAG,
                        description => "Validates a JWT token and returns user claims.",
                        produces => ["application/json"],
                        parameters => [
                            #{
                                name => "Authorization",
                                in => header,
                                required => true,
                                type => string,
                                description => "Bearer JWT token"
                            }
                        ],
                        responses => #{
                            200 => #{
                                description => "JWT is valid",
                                schema => #{status => string, claims => map}
                            },
                            401 => #{
                                description => "Invalid or expired token",
                                schema => #{error => string}
                            }
                        }
                    }
            }
        )
    ].
content_types_accepted(Req, State) ->
    {
        [
            {{<<"application">>, <<"json">>, '*'}, from_json}
        ],
        Req,
        State
    }.

content_types_provided(Req, State) ->
    {
        [
            {{<<"application">>, <<"json">>, []}, to_json}
        ],
        Req,
        State
    }.
allowed_methods(Req, State) -> {[<<"GET">>, <<"POST">>], Req, State}.
is_authorized(Req, #{action := _} = State) ->
    {true, Req, State};
is_authorized(Req, State) ->
    case cowboy_req:parse_header(<<"authorization">>, Req) of
        {ok, <<"Bearer ", Token/binary>>} ->
            case validate_jwt(Token) of
                {ok, _Claims} ->
                    {true, Req, State};
                {error, _Reason} ->
                    {false, Req, State}
            end;
        _ ->
            {false, Req, State}
    end.

%% HTTP Handler
init(Req, Opts) -> {cowboy_rest, Req, Opts}.
%init(Req, State) ->
%    Path = cowboy_req:path(Req),
%    Method = cowboy_req:method(Req),
%    Params = trails:match(trails(), Path),
%
%    Response = case {Method, Params} of
%        %% Generate Lightning Invoice for Payment Authentication
%        {<<"GET">>, {generate_ln_invoice, [{lnaddress, LnAddress}]}} ->
%            case lightning_auth_logic:generate_ln_invoice(LnAddress) of
%                {ok, Invoice} -> reply_json(Req, 200, #{invoice => Invoice});
%                {error, Reason} -> reply_json(Req, 400, #{error => Reason})
%            end;
%
%        %% Verify if a Lightning Payment has been Made
%        {<<"GET">>, {verify_ln_payment, [{lnaddress, LnAddress}]}} ->
%            case lightning_auth_logic:verify_ln_payment(LnAddress) of
%                {ok, verified} ->
%                    Token = generate_jwt(LnAddress),
%                    reply_json(Req, 200, #{status => <<"verified">>, token => Token});
%                {error, Reason} -> reply_json(Req, 400, #{error => Reason})
%            end;
%
%        %% Generate LNURL-Auth Challenge
%        {<<"GET">>, {generate_lnurl_auth_challenge, [{lnaddress, LnAddress}]}} ->
%            case lightning_auth_logic:generate_lnurl_auth_challenge(LnAddress) of
%                {ok, Challenge} -> reply_json(Req, 200, #{challenge => Challenge});
%                {error, Reason} -> reply_json(Req, 400, #{error => Reason})
%            end;
%
%        %% Verify LNURL-Auth Signature
%        {<<"GET">>, {verify_lnurl_auth, [{lnaddress, LnAddress}, {signature, Signature}]}} ->
%            case lightning_auth_logic:verify_lnurl_auth(LnAddress, Signature) of
%                {ok, verified} ->
%                    Token = generate_jwt(LnAddress),
%                    reply_json(Req, 200, #{status => <<"verified">>, token => Token});
%                {error, Reason} -> reply_json(Req, 400, #{error => Reason})
%            end;
%
%        %% Validate JWT Token
%        {<<"GET">>, {validate_jwt, []}} ->
%            case cowboy_req:parse_header(<<"authorization">>, Req) of
%                {ok, <<"Bearer ", Token/binary>>} ->
%                    case validate_jwt(Token) of
%                        {ok, Claims} -> reply_json(Req, 200, #{status => <<"valid">>, claims => Claims});
%                        {error, Reason} -> reply_json(Req, 401, #{error => Reason})
%                    end;
%                _ -> reply_json(Req, 401, #{error => <<"Missing or invalid token">>})
%            end;
%
%        %% Default Case: Not Found
%        _ -> reply_json(Req, 404, #{error => <<"Not Found">>})
%    end,
%
%    {ok, Response, State}.

%% Helper: Respond with JSON

to_json(
    Req,
    #{action := lnurl_auth} = State
) ->
    Qs = cowboy_req:match_qs([tag, sig, k1, action, key], Req),
    ?LOG_DEBUG("lnurl_auth ~p", [Qs]),
    case Qs of
        #{tag := _Tag, sig := Sig, action := _Action, k1 := K1, key := Key} ->
            case lightning_auth_logic:verify_lnurl_auth(K1, Sig, Key) of
                {ok, verified, _PubKey} ->
                    lightning_auth_ws:authenticate_socket(K1, Key),
                    ?LOG_DEBUG("lnurl_auth Success ~p", [Key]),
                    {jsx:encode(#{status => <<"OK">>}), Req, State};
                {error, Reason} ->
                    ?LOG_ERROR("lnurl_auth verify Fail ~p", [Reason]),
                    {jsx:encode(#{status => "ERROR", reason => Reason}), Req, State}
            end;
        Reason ->
            ?LOG_ERROR("lnurl_auth Fail ~p", [Reason]),
            {jsx:encode(#{status => "ERROR", reason => <<"k1,action,tag required">>}), Req, State}
    end;
to_json(
    Req,
    #{action := generate_ln_invoice} = State
) ->
    case cowboy_req:binding(lnaddress, Req) of
        undefined ->
            {jsx:encode(#{status => "ERROR", reason => <<"lnaddress required">>}), Req, State};
        LnAddress ->
            case lightning_auth_logic:generate_ln_invoice(LnAddress) of
                {ok, Invoice} ->
                    {jsx:encode(#{invoice => Invoice}), Req, State};
                {error, Reason} ->
                    {jsx:encode(#{status => "ERROR", reason => Reason}), Req, State}
            end
    end;
to_json(
    Req,
    #{action := verify_ln_payment} = State
) ->
    case cowboy_req:binding(lnaddress, Req) of
        undefined ->
            {jsx:encode(#{error => <<"lnaddress required">>}), Req, State};
        LnAddress ->
            case lightning_auth_logic:verify_ln_payment(LnAddress) of
                {ok, verified} ->
                    Token = generate_jwt(LnAddress),
                    {jsx:encode(#{status => <<"verified">>, token => Token}), Req, State};
                {error, Reason} ->
                    {jsx:encode(#{error => Reason}), Req, State}
            end
    end;
to_json(
    Req,
    #{action := generate_lnurl_auth_challenge} = State
) ->
    case cowboy_req:binding(lnaddress, Req) of
        undefined ->
            {jsx:encode(#{error => <<"lnaddress required">>}), Req, State};
        LnAddress ->
            case lightning_auth_logic:generate_lnurl_auth_challenge(LnAddress) of
                {ok, Challenge} ->
                    {jsx:encode(#{challenge => Challenge}), Req, State};
                {error, Reason} ->
                    {jsx:encode(#{error => Reason}), Req, State}
            end
    end;
%        {<<"GET">>, {, [{lnaddress, LnAddress}]}} ->
%
to_json(
    Req,
    #{action := validate_jwt} = State
) ->
    case cowboy_req:parse_header(<<"authorization">>, Req) of
        {ok, <<"Bearer ", Token/binary>>} ->
            case validate_jwt(Token) of
                {ok, Claims} ->
                    {jsx:encode(#{status => <<"valid">>, claims => Claims}), Req, State};
                {error, Reason} ->
                    {jsx:encode(#{error => Reason}), Req, State}
            end;
        _ ->
            {jsx:encode(#{error => <<"Missing or invalid token">>}), Req, State}
    end;
%
%        %% Validate JWT Token
%        {<<"GET">>, {validate_jwt, []}} ->
%
%        %% Default Case: Not Found
to_json(Req, State) ->
    {jsx:encode(#{error => <<"Not Found">>}), Req, State}.

from_json(Req, State) ->
    {ok, Data, _Req2} = cowboy_req:read_body(Req),
    {Status, Resp0} =
        case catch jsx:decode(Data, [{labels, atom}, return_maps]) of
            {'EXIT', {badarg, Trace}} ->
                ?LOG_ERROR("json decoding failed ~p err: ~p.", [Data, Trace]),
                {400, <<"Json decoding failed.">>};
            #{feature := _FeatureData} = FeatureJson ->
                check_execute_bdd(FeatureJson, State, Req)
        end,
    Resp = cowboy_req:set_resp_body(jsx:encode(Resp0), Req),
    cowboy_req:reply(Status, Resp),
    {stop, Resp, State}.
check_execute_bdd(_FeatureJson, _State, _Req) ->
    ok.
%%% --- JWT Functions ---

%% Generate JWT Token
generate_jwt(LnAddress) ->
    % 24 hours validity
    Expiration = calendar:system_time(seconds) + 86400,
    Claims = #{<<"lnaddress">> => LnAddress, <<"exp">> => Expiration},
    jose_jwt:encode({<<"HS256">>, <<>>, ?JWT_SECRET}, Claims).

%% Validate JWT Token
validate_jwt(Token) ->
    case jose_jwt:decode(Token, ?JWT_SECRET) of
        {ok, Claims} when is_map(Claims) ->
            case maps:get(<<"exp">>, Claims, 0) > calendar:system_time(seconds) of
                true -> {ok, Claims};
                false -> {error, <<"invalid_token_or_expired">>}
            end;
        _ ->
            {error, <<"invalid_token">>}
    end.
