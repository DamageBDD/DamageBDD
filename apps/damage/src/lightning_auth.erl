-module(lightning_auth).
-behaviour(cowboy_handler).
-vsn("0.1.0").

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

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
-define(TRAILS_TAG, <<"Lightning Authentication">>).

trails() ->
    [
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
reply_json(Req, Status, Body) ->
    cowboy_req:reply(
        Status, #{<<"content-type">> => <<"application/json">>}, jsx:encode(Body), Req
    ).

to_json(
    Req,
    #{action := generate_ln_invoice} = _State
) ->
    case cowboy_req:binding(lnaddress, Req) of
        undefined ->
            reply_json(Req, 400, #{error => <<"lnaddress required">>});
        LnAddress ->
            case lightning_auth_logic:generate_ln_invoice(LnAddress) of
                {ok, Invoice} -> reply_json(Req, 200, #{invoice => Invoice});
                {error, Reason} -> reply_json(Req, 400, #{error => Reason})
            end
    end;
to_json(
    Req,
    #{action := verify_ln_payment} = _State
) ->
    case cowboy_req:binding(lnaddress, Req) of
        undefined ->
            reply_json(Req, 400, #{error => <<"lnaddress required">>});
        LnAddress ->
            case lightning_auth_logic:verify_ln_payment(LnAddress) of
                {ok, verified} ->
                    Token = generate_jwt(LnAddress),
                    reply_json(Req, 200, #{status => <<"verified">>, token => Token});
                {error, Reason} ->
                    reply_json(Req, 400, #{error => Reason})
            end
    end;
to_json(
    Req,
    #{action := generate_lnurl_auth_challenge} = _State
) ->
    case cowboy_req:binding(lnaddress, Req) of
        undefined ->
            reply_json(Req, 400, #{error => <<"lnaddress required">>});
        LnAddress ->
            case lightning_auth_logic:generate_lnurl_auth_challenge(LnAddress) of
                {ok, Challenge} -> reply_json(Req, 200, #{challenge => Challenge});
                {error, Reason} -> reply_json(Req, 400, #{error => Reason})
            end
    end;
%        {<<"GET">>, {, [{lnaddress, LnAddress}]}} ->
%
to_json(
    Req,
    #{action := verify_lnurl_auth} = _State
) ->
    case cowboy_req:binding(lnaddress, Req) of
        undefined ->
            reply_json(Req, 400, #{error => <<"lnaddress required">>});
        LnAddress ->
            case cowboy_req:binding(signature, Req) of
                undefined ->
                    reply_json(Req, 400, #{error => <<"signature required">>});
                Signature ->
                    case lightning_auth_logic:verify_lnurl_auth(LnAddress, Signature) of
                        {ok, verified} ->
                            Token = generate_jwt(LnAddress),
                            reply_json(Req, 200, #{status => <<"verified">>, token => Token});
                        {error, Reason} ->
                            reply_json(Req, 400, #{error => Reason})
                    end
            end
    end;
to_json(
    Req,
    #{action := validate_jwt} = _State
) ->
    case cowboy_req:parse_header(<<"authorization">>, Req) of
        {ok, <<"Bearer ", Token/binary>>} ->
            case validate_jwt(Token) of
                {ok, Claims} -> reply_json(Req, 200, #{status => <<"valid">>, claims => Claims});
                {error, Reason} -> reply_json(Req, 401, #{error => Reason})
            end;
        _ ->
            reply_json(Req, 401, #{error => <<"Missing or invalid token">>})
    end;
%
%        %% Validate JWT Token
%        {<<"GET">>, {validate_jwt, []}} ->
%
%        %% Default Case: Not Found
to_json(Req, _State) ->
    reply_json(Req, 404, #{error => <<"Not Found">>}).
from_json(Req, State) ->
    {ok, Data, _Req2} = cowboy_req:read_body(Req),
    {Status, Resp0} =
        case catch jsx:decode(Data, [{labels, atom}, return_maps]) of
            {'EXIT', {badarg, Trace}} ->
                logger:error("json decoding failed ~p err: ~p.", [Data, Trace]),
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
