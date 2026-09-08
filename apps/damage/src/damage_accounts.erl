-module(damage_accounts).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-export([init/2]).
-export([content_types_provided/2]).
-export([to_html/2]).
-export([to_json/2]).
-export([is_authorized/2]).

%-export([to_text/2]).
-export([from_json/2, allowed_methods/2, from_html/2, from_yaml/2]).
-export([content_types_accepted/2]).
-export([trails/0]).
-export([delete_account/1]).
-export([delete_resource/2]).
-export([notify_user/2]).
-export([validate_password/1]).
-export([authenticate_user/2]).
-export([wallet_snapshot/1]).

-include_lib("kernel/include/logger.hrl").
-include_lib("damage.hrl").

-define(TRAILS_TAG, ["Account Management"]).
-define(TOKEN_TIMEOUT, 86400).
-define(RESET_PASSWORD_LINK_EXPIRY, 86400).

trails() ->
    [
        trails:trail(
            "/accounts/create",
            damage_accounts,
            #{action => create},
            #{
                get =>
                    #{
                        tags => ?TRAILS_TAG,
                        description => "Form to create an account on this DamageBDD server.",
                        produces => ["text/html", "application/json", "application/x-yaml"]
                    },
                put =>
                    #{
                        tags => ?TRAILS_TAG,
                        description => "Create account using form ",
                        produces => ["text/html", "application/json", "application/x-yaml"],
                        parameters =>
                            [
                                #{
                                    name => <<"email">>,
                                    description =>
                                        <<"A valid email address for user account recovery.">>,
                                    in => <<"body">>,
                                    required => true,
                                    type => <<"string">>
                                },
                                #{
                                    name => <<"full_name">>,
                                    description =>
                                        <<"A name to reffer to user in communications.">>,
                                    in => <<"body">>,
                                    required => false,
                                    type => <<"string">>
                                }
                            ]
                    }
            }
        ),
        trails:trail(
            "/accounts/balance",
            damage_accounts,
            #{action => balance},
            #{
                get =>
                    #{
                        tags => ?TRAILS_TAG,
                        description => "do some action ",
                        produces => ["text/html", "application/json", "application/x-yaml"]
                    }
            }
        ),
        trails:trail(
            "/accounts/wallet",
            damage_accounts,
            #{action => wallet},
            #{
                get =>
                    #{
                        tags => ?TRAILS_TAG,
                        description =>
                            "Return Lightning, AE, and DAMAGE balances for the authenticated account.",
                        produces => ["application/json"]
                    }
            }
        ),
        trails:trail(
            "/rate",
            damage_accounts,
            #{action => rate},
            #{
                get =>
                    #{
                        tags => ?TRAILS_TAG,
                        description => "do some action ",
                        produces => ["text/html", "application/json", "application/x-yaml"]
                    }
            }
        ),
        trails:trail(
            "/accounts/confirm",
            damage_accounts,
            #{action => confirm},
            #{
                get =>
                    #{
                        tags => ?TRAILS_TAG,
                        description => "Confirm account.",
                        produces => ["text/html", "application/json", "application/x-yaml"],
                        parameters =>
                            [
                                #{
                                    name => <<"token">>,
                                    description =>
                                        <<"A valid confirmation token sent to account email.">>,
                                    in => <<"query">>,
                                    required => true,
                                    type => <<"string">>
                                }
                            ]
                    },
                put =>
                    #{
                        tags => ?TRAILS_TAG,
                        description => "Confirm account and set password form.",
                        produces => ["text/html", "application/json"],
                        parameters =>
                            [
                                #{
                                    name => <<"confirm_token">>,
                                    description => <<"Confirm Token">>,
                                    in => <<"body">>,
                                    required => true,
                                    type => <<"string">>
                                },
                                #{
                                    name => <<"new_password">>,
                                    description => <<"New password">>,
                                    in => <<"body">>,
                                    required => true,
                                    type => <<"string">>
                                },
                                #{
                                    name => <<"new_password_confirm">>,
                                    description => <<"New password confirmation">>,
                                    in => <<"body">>,
                                    required => true,
                                    type => <<"string">>
                                }
                            ]
                    }
            }
        ),
        trails:trail(
            "/accounts/reset_password",
            damage_accounts,
            #{action => reset_password},
            #{
                get =>
                    #{
                        tags => ?TRAILS_TAG,
                        description => "Reset password using reset token sent to email.",
                        produces => ["text/plain"],
                        parameters =>
                            [
                                #{
                                    name => <<"token">>,
                                    description =>
                                        <<"A valid reset password token sent to account email.">>,
                                    in => <<"query">>,
                                    required => true,
                                    type => <<"string">>
                                }
                            ]
                    },
                put =>
                    #{
                        tags => ?TRAILS_TAG,
                        description => "Submit reset password form.",
                        produces => ["text/html", "application/json"],
                        parameters =>
                            [
                                #{
                                    name => <<"current_password">>,
                                    description => <<"Current password">>,
                                    in => <<"body">>,
                                    required => true,
                                    type => <<"string">>
                                },
                                #{
                                    name => <<"new_password">>,
                                    description => <<"New password">>,
                                    in => <<"body">>,
                                    required => true,
                                    type => <<"string">>
                                },
                                #{
                                    name => <<"new_password_confirm">>,
                                    description => <<"New password confirmation">>,
                                    in => <<"body">>,
                                    required => true,
                                    type => <<"string">>
                                }
                            ]
                    }
            }
        ),
        trails:trail(
            "/accounts/logout",
            damage_accounts,
            #{action => logout},
            #{
                post =>
                    #{
                        tags => ?TRAILS_TAG,
                        description =>
                            "Clear the authenticated browser session and return an idempotent logout response.",
                        produces => ["text/html", "application/json"]
                    },
                delete =>
                    #{
                        tags => ?TRAILS_TAG,
                        description =>
                            "Clear the authenticated browser session and return an idempotent logout response.",
                        produces => ["text/html", "application/json"]
                    }
            }
        ),
        trails:trail(
            "/accounts/auth/",
            damage_accounts,
            #{action => authenticate},
            #{
                post =>
                    #{
                        tags => ?TRAILS_TAG,
                        description => "Get auth token.",
                        produces => ["text/html", "application/json"],
                        parameters =>
                            [
                                #{
                                    username => <<"username">>,
                                    description => <<"Username for account.">>,
                                    in => <<"body">>,
                                    required => true,
                                    type => <<"string">>
                                },
                                #{
                                    password => <<"password">>,
                                    description => <<"Account password.">>,
                                    in => <<"body">>,
                                    required => true,
                                    type => <<"string">>
                                }
                            ]
                    }
            }
        )
    ].

init(Req, Opts) -> {cowboy_rest, Req, Opts}.

content_types_provided(Req, State) ->
    {
        [
            {{<<"application">>, <<"json">>, []}, to_json},
            %{{<<"text">>, <<"plain">>, '*'}, to_text},
            {{<<"text">>, <<"html">>, '*'}, to_html}
        ],
        Req,
        State
    }.

content_types_accepted(Req, State) ->
    {
        [
            {{<<"application">>, <<"x-www-form-urlencoded">>, '*'}, from_html},
            {{<<"application">>, <<"x-yaml">>, '*'}, from_yaml},
            {{<<"application">>, <<"json">>, '*'}, from_json}
        ],
        Req,
        State
    }.

allowed_methods(Req, State) ->
    {[<<"GET">>, <<"POST">>, <<"DELETE">>], Req, State}.

is_authorized(Req, #{action := Action} = State)
        when Action =:= balance;
             Action =:= wallet;
             Action =:= invoices ->
    safe_account_authorized(Req, State);
is_authorized(Req, State) ->
    {true, Req, State}.

safe_account_authorized(Req, State) ->
    try damage_http:is_authorized(Req, State) of
        {true, Req1, State1} ->
            {true, Req1, State1};
        {false, Req1, State1} ->
            {{false, <<"Bearer realm=\"damage\"">>}, Req1, State1};
        {{false, _Realm} = False, Req1, State1} ->
            {False, Req1, State1};
        Other ->
            ?LOG_WARNING("Unexpected account authorization result: ~p", [Other]),
            {{false, <<"Bearer realm=\"damage\"">>}, Req, State}
    catch
        Class:Reason:Stacktrace ->
            ?LOG_WARNING("Account authorization crashed: ~p", [
                {Class, Reason, Stacktrace}
            ]),
            {{false, <<"Bearer realm=\"damage\"">>}, Req, State}
    end.
no_store_req(Req0) ->
    Req1 = cowboy_req:set_resp_header(<<"cache-control">>, <<"no-store">>, Req0),
    cowboy_req:set_resp_header(<<"pragma">>, <<"no-cache">>, Req1).
to_json(Req, #{action := logout} = State) ->
    logout_json_response(Req, State);
to_json(Req, #{action := confirm} = State) ->
    % for some browsers who send in applicaion/json contenttype
    to_html(Req, State);
to_json(Req, #{action := rate} = State) ->
    {jsx:encode(#{price => price_feed:get_prices()}), Req, State};
to_json(Req, #{action := balance, public_key := AeAccount} = State) ->
    Req1 = no_store_req(Req),
    {jsx:encode(balance(AeAccount)), Req1, State};

to_json(Req, #{action := wallet, public_key := AeAccount} = State) ->
    Req1 = no_store_req(Req),
    {jsx:encode(wallet_snapshot(AeAccount)), Req1, State};
to_json(Req, State) ->
    Body = #{
        status => <<"failed">>,
        message => <<"Unsupported account action.">>
    },
    {jsx:encode(Body), Req, State}.

to_html(Req, #{action := logout} = State) ->
    logout_html_response(Req, State);
to_html(Req, #{action := reset_password} = State) ->
    case cowboy_req:match_qs([token], Req) of
        #{token := Token} ->
            Now = date_util:now_to_seconds(os:timestamp()),
            case decrypt_token_term(Token) of
                #{email := _Email, expiry := Expiry} when Expiry < Now ->
                    Body = <<"Confirm Token Expired.">>,
                    {Body, Req, State};
                #{email := Email, expiry := Expiry} when Expiry > Now ->
                    Body =
                        damage_utils:load_template(
                            "reset_password.mustache",
                            #{
                                email => Email,
                                token => Token,
                                action => <<"reset_password">>,
                                action_label => <<"Reset">>
                            }
                        ),
                    {Body, Req, State};
                Error ->
                    ?LOG_DEBUG("Error validating ~p", [Error]),
                    {<<"Invalid reset password link. Please try again.">>, Req, State}
            end
    end;
to_html(Req, #{action := create} = State) ->
    Body =
        damage_utils:load_template("create_account.mustache", #{body => <<"Test">>}),
    {Body, Req, State};
to_html(Req, #{action := confirm} = State) ->
    #{token := Token} = cowboy_req:match_qs([token], Req),
    Now = date_util:now_to_seconds(os:timestamp()),
    case decrypt_token_term(Token) of
        #{email := _Email, expiry := Expiry} when Expiry < Now ->
            Body = <<"Confirm Token Expired.">>,
            {Body, Req, State};
        #{email := Email, expiry := Expiry} when Expiry > Now ->
            Body =
                damage_utils:load_template(
                    "reset_password.mustache",
                    #{
                        email => Email,
                        token => Token,
                        action => <<"confirm">>,
                        action_label => <<"Set">>
                    }
                ),
            {Body, Req, State};
        Error ->
            ?LOG_DEBUG("Error validating ~p", [Error]),
            {<<"Invalid confirmation link. Please try again.">>, Req, State}
    end.

authenticate_user(Email, Password0) ->
    Password = secrets:salted_hash(Password0),
    case identity_server:get_account_by_email(Email) of
        {Account, Password, PrivateKey} ->
            {ok, Token} = damage_access_token:generate_access_token(
                #{public_key => Account, private_key => PrivateKey}
            ),
            {ok, Account, Token};
        Error = {error, notfound} ->
            Error;
        notfound ->
            {error, notfound};
        _ ->
            {error, notauthorized}
    end.

validate_password(Password) ->
    %% For example, minimum 8 characters with at least one uppercase letter,
    %% one lowercase letter, one digit, and one special character
    Regex =
        "^(?=.*\\d)(?=.*[a-z])(?=.*[A-Z])(?=.*[!@#$%^&*()_+\\-=[\\]{};':\"\\\\|,.<>/?]).{8,}$",
    case re:run(Password, Regex) of
        {match, _} -> true;
        _ -> false
    end.
send_account_confirm_email(#{email := Email} = Meta) when is_binary(Email) ->
    {ok, ApiUrl} = application:get_env(damage, api_url),
    {ok, Allowance} = application:get_env(damage, allowance),
    ApiUrl0 = list_to_binary(ApiUrl),

    Expiry = date_util:now_to_seconds(os:timestamp()) + 86400,
    AuthTokenEncrypted = secrets:encrypt(term_to_binary(#{email => Email, expiry => Expiry})),

    Data = maps:put(allowance, Allowance, maps:put(password, AuthTokenEncrypted, Meta)),
    Query = list_to_binary(uri_string:compose_query([{"token", AuthTokenEncrypted}])),
    Ctxt =
        maps:put(
            <<"password_reset_url">>,
            <<ApiUrl0/binary, "/accounts/confirm?", Query/binary>>,
            Data
        ),
    Result = damage_utils:send_email(
        {maps:get(full_name, Meta, <<>>), Email},
        <<"DamageBDD Account SignUp">>,
        damage_utils:load_template("signup_email.txt.mustache", Ctxt),
        damage_utils:load_template("signup_email.html.mustache", Ctxt)
    ),
    account_email_result(
        Result,
        <<"Please check email for confirmation link. Don't forget to check spam folder too.">>,
        <<"Unable to send account confirmation email. Please try again later.">>
    ).

account_email_result({ok, _}, SuccessMessage, _FailureMessage) ->
    {ok, SuccessMessage};
account_email_result(ok, SuccessMessage, _FailureMessage) ->
    {ok, SuccessMessage};
account_email_result({error, Reason}, _SuccessMessage, FailureMessage) ->
    ?LOG_ERROR("Account email delivery failed: ~p", [Reason]),
    {error, FailureMessage};
account_email_result(Unexpected, _SuccessMessage, FailureMessage) ->
    ?LOG_ERROR("Unexpected account email delivery result: ~p", [Unexpected]),
    {error, FailureMessage}.

-spec do_post_action(atom(), map()) ->
    {integer(), map()}.
do_post_action(logout, _Data) ->
    {200, #{status => <<"ok">>, message => <<"Logged out.">>}};
do_post_action(
    authenticate,
    #{username := Email, password := Password}
) ->
    case authenticate_user(Email, Password) of
        {ok, Account, Token} ->
            {200, #{status => <<"ok">>, access_token => Token, address => Account}};
        {error, Message} ->
            {400, #{status => <<"failed">>, message => Message}}
    end;
do_post_action(
    authenticate,
    #{address := _Account, signature := false}
) ->
    {400, #{status => <<"failed">>, message => <<"Connect Failed">>}};
do_post_action(
    authenticate,
    #{address := Account, signature := Signature, meta := SessionMeta}
) ->
    case vanillae:verify_signature(Signature, SessionMeta, Account) of
        {ok, true} ->
            Expiry = date_util:now_to_seconds(os:timestamp()) + 86400,
            Token = secrets:encrypt(term_to_binary({Account, <<"wallet">>, Expiry})),
            {200, #{
                status => <<"ok">>, access_token => Token, address => Account, meta => SessionMeta
            }};
        {error, Message} ->
            {400, #{status => <<"failed">>, message => Message}}
    end;
do_post_action(
    reset_password,
    #{token := Token, new_password := NewPassword, new_password_confirm := NewPasswordConfirm}
) ->
    Now = date_util:now_to_seconds(os:timestamp()),
    case validate_password(NewPassword) of
        true ->
            case NewPassword of
                NewPasswordConfirm ->
                    case decrypt_token_term(Token) of
                        #{email := _Email, expiry := Expiry} when Expiry < Now ->
                            Message = <<"Reset password token expired.">>,
                            {400, #{status => <<"failed">>, message => Message}};
                        #{email := Email, expiry := Expiry} when Expiry > Now ->
                            case
                                identity_server:set_email_password(
                                    Email, secrets:salted_hash(NewPassword)
                                )
                            of
                                {ok, _Message} ->
                                    %mark_token_used(Token, Expiry),
                                    {200, #{
                                        status => <<"ok">>,
                                        message => <<"Password has been reset.">>
                                    }};
                                {error, Message} ->
                                    {400, #{status => <<"failed">>, message => Message}}
                            end
                    end;
                _ ->
                    Message = <<"Password does not match.">>,
                    {400, #{status => <<"failed">>, message => Message}}
            end;
        false ->
            Message =
                <<"Password does not meet complexity requirement: minimum 8 characters with at least one uppercase letter, one lowercase letter, one digit, and one special character.">>,
            {400, #{status => <<"failed">>, message => Message}}
    end;
do_post_action(
    reset_password,
    #{email := Email}
) ->
    {ok, ApiUrl} = application:get_env(damage, api_url),
    ApiUrl0 = list_to_binary(ApiUrl),

    Expiry = date_util:now_to_seconds(os:timestamp()) + 86400,
    AuthTokenEncrypted = secrets:encrypt(term_to_binary(#{email => Email, expiry => Expiry})),

    Data = maps:put(password, AuthTokenEncrypted, #{email => Email}),
    Query = list_to_binary(uri_string:compose_query([{"token", AuthTokenEncrypted}])),
    Ctxt =
        maps:put(
            <<"password_reset_url">>,
            <<ApiUrl0/binary, "/accounts/reset_password?", Query/binary>>,
            Data
        ),
    Result = damage_utils:send_email(
        {maps:get(full_name, Data, <<>>), Email},
        <<"DamageBDD Account Reset Password">>,
        damage_utils:load_template("reset_password_email.txt.mustache", Ctxt),
        damage_utils:load_template("reset_password_email.html.mustache", Ctxt)
    ),
    case
        account_email_result(
            Result,
            <<"Account password reset. Please check email for confirmation link. Don't forget to check spam folder too.">>,
            <<"Unable to send password reset email. Please try again later.">>
        )
    of
        {ok, Message} ->
            {200, #{status => <<"ok">>, message => Message}};
        {error, Message} ->
            {500, #{status => <<"failed">>, message => Message}}
    end;
do_post_action(
    confirm,
    #{token := Token, new_password := NewPassword, new_password_confirm := NewPasswordConfirm}
) ->
    Now = date_util:now_to_seconds(os:timestamp()),
    case validate_password(NewPassword) of
        true ->
            case NewPassword of
                NewPasswordConfirm ->
                    case decrypt_token_term(Token) of
                        #{email := _Email, expiry := Expiry} when Expiry < Now ->
                            Message = <<"Confirm Token Expired.">>,
                            {400, #{status => <<"failed">>, message => Message}};
                        #{email := Email, expiry := Expiry} when Expiry > Now ->
                            case identity_server:register_email(Email, NewPassword) of
                                {ok, Message, PubKey, _PrivKey} ->
                                    spawn_monitor(fun() ->
                                        try
                                            case
                                                damage_contract_bootstrap:bootstrap_user_account(
                                                    PubKey
                                                )
                                            of
                                                {ok, _} ->
                                                    ?LOG_INFO("user bootstrap success ~p", [PubKey]);
                                                {error, Why} ->
                                                    ?LOG_ERROR(
                                                        "user bootstrap failed ~p reason ~p", [
                                                            PubKey, Why
                                                        ]
                                                    )
                                            end
                                        catch
                                            Class:Reason:Stack ->
                                                ?LOG_ERROR("user bootstrap crash ~p ~p ~p ~p", [
                                                    PubKey, Class, Reason, Stack
                                                ])
                                        end
                                    end),
                                    {200, #{
                                        status => <<"ok">>,
                                        message => Message,
                                        public_key => PubKey
                                    }};
                                {error, Error} ->
                                    {400, #{
                                        status => <<"failed">>,
                                        message => Error
                                    }}
                            end
                    end;
                _ ->
                    {400, #{
                        status => <<"failed">>,
                        message => <<"Password does not match. Go back to try again.">>
                    }}
            end;
        false ->
            Message =
                <<"Password does not meet complexity requirement: minimum 8 characters with at least one uppercase letter, one lowercase letter, one digit, and one special character.">>,
            {400, #{status => <<"failed">>, message => Message}}
    end;
do_post_action(create, #{email := Email} = Data) when is_atom(Email) ->
    do_post_action(create, maps:put(email, atom_to_binary(Email), Data));
do_post_action(create, #{email := Email} = _Data) ->
    case damage_utils:is_valid_email(Email) of
        true ->
            case send_account_confirm_email(#{email => Email}) of
                {ok, Message} -> {201, #{status => <<"ok">>, message => Message}};
                {error, Message} -> {400, #{status => <<"failed">>, message => Message}};
                Error -> {400, #{status => <<"failed">>, message => Error}}
            end;
        false ->
            {400, #{status => <<"failed">>, message => <<"Invalid email">>}}
    end.

from_html(Req, #{action := logout} = State) ->
    logout_html_response(discard_request_body(Req), State);
from_html(Req, #{action := authenticate} = State) ->
    {ok, Params, Req0} = cowboy_req:read_urlencoded_body(Req),
    Username = proplists:get_value(<<"username">>, Params),
    Password = proplists:get_value(<<"password">>, Params),
    case authenticate_user(Username, Password) of
        {ok, Account, Token} ->
            Req1 = damage_access_token:set_access_cookie(Req0, Token),
            {stop,
                cowboy_req:reply(
                    200,
                    cowboy_req:set_resp_body(
                        jsx:encode(#{status => <<"ok">>, access_token => Token, address => Account}),
                        Req1
                    )
                ),
                State};
        {error, Message} ->
            ?LOG_DEBUG("Auth failed ~p", [Message]),
            {
                stop,
                cowboy_req:reply(
                    401, cowboy_req:set_resp_body(jsx:encode(#{status => <<"fail">>}), Req0)
                ),
                State
            }
    end;
from_html(Req, #{action := create} = State) ->
    {ok, Params, Req0} = cowboy_req:read_urlencoded_body(Req),
    case proplists:get_value(<<"email">>, Params) of
        undefined ->
            Response = cowboy_req:set_resp_body(
                jsx:encode(#{status => <<"failed">>, message => <<"email required">>}), Req0
            ),
            cowboy_req:reply(400, Response),
            {stop, Response, State};
        Email ->
            case do_post_action(create, #{email => Email}) of
                {204, <<"">>} ->
                    Response = cowboy_req:reply(204, Req0),
                    {stop, Response, State};
                {Status0, Response0} ->
                    Response = cowboy_req:set_resp_body(jsx:encode(Response0), Req0),
                    cowboy_req:reply(Status0, Response),
                    {stop, Response, State}
            end
    end;
from_html(Req, #{action := reset_password} = State) ->
    {ok, Data, _Req2} = cowboy_req:read_body(Req),
    Data0 = maps:from_list(cow_qs:parse_qs(Data)),
    {Status0, Response0} =
        case do_post_action(reset_password, damage_utils:binary_to_atom_keys(Data0)) of
            {200, #{message := Message}} ->
                {ok, ApiUrl} = application:get_env(damage, api_url),
                {
                    200,
                    damage_utils:load_template(
                        "reset_password_response.html.mustache",
                        #{status => <<"ok">>, message => Message, login_url => ApiUrl}
                    )
                };
            {_, #{message := Message, status := _}} ->
                {
                    400,
                    damage_utils:load_template(
                        "reset_password_response.html.mustache",
                        #{status => <<"failed">>, message => Message}
                    )
                }
        end,
    {
        stop,
        cowboy_req:reply(Status0, cowboy_req:set_resp_body(Response0, Req)),
        State
    };
from_html(Req, #{action := Action} = State) ->
    {ok, Data, _Req2} = cowboy_req:read_body(Req),
    Data0 = maps:from_list(cow_qs:parse_qs(Data)),
    {Status0, Response0} =
        case do_post_action(Action, damage_utils:binary_to_atom_keys(Data0)) of
            {200, #{message := Message}} ->
                {ok, ApiUrl} = application:get_env(damage, api_url),
                {
                    200,
                    damage_utils:load_template(
                        "reset_password_response.html.mustache",
                        #{status => <<"ok">>, message => Message, login_url => ApiUrl}
                    )
                };
            {_, #{message := Message, status := _}} ->
                {
                    400,
                    damage_utils:load_template(
                        "reset_password_response.html.mustache",
                        #{status => <<"failed">>, message => Message}
                    )
                }
        end,
    {
        stop,
        cowboy_req:reply(Status0, cowboy_req:set_resp_body(Response0, Req)),
        State
    }.

from_json(Req, #{action := logout} = State) ->
    logout_json_response(discard_request_body(Req), State);
from_json(Req, #{action := authenticate} = State) ->
    {ok, Data, Req0} = cowboy_req:read_body(Req),
    case decode_json_body(Data) of
        {ok, Data0} ->
            case do_post_action(authenticate, Data0) of
                {200, #{access_token := Token} = Response0} ->
                    Req1 = damage_access_token:set_access_cookie(Req0, Token),
                    Req2 =
                        cowboy_req:reply(
                            200,
                            #{<<"content-type">> => <<"application/json">>},
                            jsx:encode(Response0),
                            Req1
                        ),
                    {stop, Req2, State};
                {Status0, Response0} ->
                    Req1 =
                        cowboy_req:reply(
                            Status0,
                            #{<<"content-type">> => <<"application/json">>},
                            jsx:encode(Response0),
                            Req0
                        ),
                    {stop, Req1, State}
            end;
        {error, _Reason} ->
            json_decode_error_response(Req0, State)
    end;
from_json(Req, #{action := Action} = State) ->
    {ok, Data, Req0} = cowboy_req:read_body(Req),
    case decode_json_body(Data) of
        {ok, Data0} ->
            case do_post_action(Action, Data0) of
                {204, <<>>} ->
                    {stop, cowboy_req:reply(204, Req0), State};
                {Status0, Response0} ->
                    Req1 =
                        cowboy_req:reply(
                            Status0,
                            #{<<"content-type">> => <<"application/json">>},
                            jsx:encode(Response0),
                            Req0
                        ),
                    {stop, Req1, State}
            end;
        {error, _Reason} ->
            json_decode_error_response(Req0, State)
    end.

%% Decrypt account tokens without the deprecated `catch Expr` form and never
%% decode untrusted external terms without the safe option.
decrypt_token_term(Token) ->
    try secrets:decrypt(Token) of
        Plain when is_binary(Plain) ->
            try binary_to_term(Plain, [safe]) of
                Term -> Term
            catch
                _:_ -> invalid_token
            end;
        _ ->
            invalid_token
    catch
        _:_ -> invalid_token
    end.

decode_json_body(Data) ->
    %% Never let request-controlled JSON create VM atoms. Decode all object
    %% keys as binaries, then normalize only the small set of top-level fields
    %% consumed by do_post_action/2. Nested metadata remains binary-keyed.
    try jsx:decode(Data, [return_maps]) of
        Decoded when is_map(Decoded) ->
            {ok, normalize_account_json_fields(Decoded)};
        _ ->
            {error, json_object_required}
    catch
        error:badarg -> {error, badarg};
        Class:Reason -> {error, {Class, Reason}}
    end.

normalize_account_json_fields(Map) when is_map(Map) ->
    maps:from_list([
        {account_json_field(Key), Value}
     || {Key, Value} <- maps:to_list(Map)
    ]).

%% These atoms are compile-time constants already present in the VM. Unknown
%% request keys stay binary, so arbitrary client input cannot grow the atom
%% table while do_post_action/2 keeps its existing atom-key patterns.
account_json_field(<<"username">>) -> username;
account_json_field(<<"password">>) -> password;
account_json_field(<<"address">>) -> address;
account_json_field(<<"signature">>) -> signature;
account_json_field(<<"meta">>) -> meta;
account_json_field(<<"token">>) -> token;
account_json_field(<<"new_password">>) -> new_password;
account_json_field(<<"new_password_confirm">>) -> new_password_confirm;
account_json_field(<<"current_password">>) -> current_password;
account_json_field(<<"email">>) -> email;
account_json_field(Key) -> Key.

json_decode_error_response(Req0, State) ->
    Req1 = cowboy_req:reply(
        400,
        no_store_headers(<<"application/json">>),
        jsx:encode(#{status => <<"failed">>, message => <<"Json decode error.">>}),
        Req0
    ),
    {stop, Req1, State}.


from_yaml(Req, #{action := logout} = State) ->
    logout_json_response(discard_request_body(Req), State);
from_yaml(Req, #{action := reset_password} = State) ->
    {ok, Data, _Req2} = cowboy_req:read_body(Req),
    {Status0, Response0} =
        case damage_utils:yaml_decode(Data, [maps, {plain_as_atom, true}]) of
            {ok, [Data0]} ->
                case damage_oauth:reset_password(Data0) of
                    {ok, Message} -> {200, #{status => <<"ok">>, message => Message}};
                    {error, Message} -> {400, #{status => <<"failed">>, message => Message}}
                end;
            {error, Message} ->
                {400, #{status => <<"failed">>, message => Message}}
        end,
    {
        stop,
        cowboy_req:reply(
            Status0,
            cowboy_req:set_resp_body(damage_utils:yaml_encode(Response0), Req)
        ),
        State
    };
from_yaml(Req, #{action := Action} = State) ->
    {ok, Data, _Req2} = cowboy_req:read_body(Req),
    {Status0, Response0} =
        case damage_utils:yaml_decode(Data) of
            {ok, [Data0]} -> do_post_action(Action, Data0);
            {error, Message} -> {400, #{status => <<"failed">>, message => Message}}
        end,
    {
        stop,
        cowboy_req:reply(
            Status0,
            cowboy_req:set_resp_body(damage_utils:yaml_encode(Response0), Req)
        ),
        State
    }.

%% Logout is deliberately idempotent: an absent or expired session still
%% receives a successful response. The canonical token helper owns the cookie
%% attributes so login and logout cannot drift apart.
logout_json_response(Req0, State) ->
    Req1 = damage_access_token:clear_access_cookie(Req0),
    Body = jsx:encode(#{status => <<"ok">>, message => <<"Logged out.">>}),
    Req2 = cowboy_req:reply(
        200,
        no_store_headers(<<"application/json">>),
        Body,
        Req1
    ),
    {stop, Req2, State}.

logout_html_response(Req0, State) ->
    Req1 = damage_access_token:clear_access_cookie(Req0),
    {ok, ApiUrl} = application:get_env(damage, api_url),
    Body = damage_utils:load_template(
        "reset_password_response.html.mustache",
        200,
        #{
            status => <<"ok">>,
            message => <<"Logged out.">>,
            login_url => list_to_binary(ApiUrl)
        }
    ),
    Req2 = cowboy_req:reply(
        200,
        no_store_headers(<<"text/html">>),
        Body,
        Req1
    ),
    {stop, Req2, State}.

no_store_headers(ContentType) ->
    #{
        <<"content-type">> => ContentType,
        <<"cache-control">> => <<"no-store">>,
        <<"pragma">> => <<"no-cache">>
    }.

discard_request_body(Req) ->
    case cowboy_req:read_body(Req) of
        {ok, _Data, Req0} -> Req0;
        {more, _Data, Req0} -> discard_request_body(Req0)
    end.

delete_resource(Req, #{action := logout} = State) ->
    logout_json_response(Req, State);
delete_resource(Req, #{action := invoices} = State) ->
    case damage_http:is_authorized(Req, State) of
        {true, _Req0, #{username := _Username} = _State0} ->
            Deleted =
                lists:foldl(
                    fun(RHash, Acc) ->
                        ?LOG_INFO(
                            "cancelling invoice ~p ~p",
                            [maps:get(path_info, Req), RHash]
                        ),
                        case damage_cln:cancel_invoice(RHash) of
                            #{<<"code">> := 5} ->
                                ?LOG_INFO("Invoice not found ~p", [RHash]);
                            Other ->
                                ?LOG_INFO("Invoice found ~p", [Other]),
                                Acc + 1
                        end
                    end,
                    0,
                    maps:get(path_info, Req)
                ),
            ?LOG_INFO("deleted ~p schedules", [Deleted]),
            {true, Req, State};
        _Other ->
            {
                cowboy_req:reply(
                    401,
                    cowboy_req:set_resp_body(<<"Unauthorized.">>, Req)
                ),
                Req,
                State
            }
    end.

balance(AeAccount) ->
    damage_balance_cache:snapshot(AeAccount).

%% Return atomic values as decimal strings so mobile/web clients do not lose
%% precision when balances exceed JavaScript's safe integer range.
-spec wallet_snapshot(binary()) -> map().
wallet_snapshot(AeAccount) ->
    Balances = #{
        lightning => wallet_lightning_balance(AeAccount),
        ae => wallet_ae_balance(AeAccount),
        damage => wallet_damage_balance(AeAccount)
    },
    Status =
        case lists:all(fun wallet_balance_available/1, maps:values(Balances)) of
            true -> <<"ok">>;
            false -> <<"partial">>
        end,
    #{
        status => Status,
        address => AeAccount,
        updated_at => erlang:system_time(second),
        balances => Balances
    }.

wallet_balance_available(#{available := true}) -> true;
wallet_balance_available(_) -> false.

wallet_damage_balance(AeAccount) ->
    try damage_ae:balance(AeAccount) of
        Amount when is_integer(Amount), Amount >= 0 ->
            wallet_atomic_balance(Amount, ?DAMAGE_DECIMALS, <<"DAMAGE">>, <<"damage_token">>);
        {error, Reason} ->
            wallet_unavailable_balance(
                ?DAMAGE_DECIMALS, <<"DAMAGE">>, <<"damage_token">>, Reason
            );
        Other ->
            wallet_unavailable_balance(
                ?DAMAGE_DECIMALS,
                <<"DAMAGE">>,
                <<"damage_token">>,
                {unexpected_damage_balance, Other}
            )
    catch
        Class:Reason ->
            wallet_unavailable_balance(
                ?DAMAGE_DECIMALS, <<"DAMAGE">>, <<"damage_token">>, {Class, Reason}
            )
    end.

wallet_ae_balance(AeAccount) ->
    try damage_ae:get_ae_balance(AeAccount) of
        Account when is_map(Account) ->
            case wallet_map_get([balance, <<"balance">>], Account, undefined) of
                Amount when is_integer(Amount), Amount >= 0 ->
                    wallet_atomic_balance(Amount, ?AE_DECIMALS, <<"AE">>, <<"aeternity_node">>);
                Other ->
                    wallet_unavailable_balance(
                        ?AE_DECIMALS,
                        <<"AE">>,
                        <<"aeternity_node">>,
                        {unexpected_ae_balance, Other}
                    )
            end;
        {error, Reason} ->
            wallet_unavailable_balance(?AE_DECIMALS, <<"AE">>, <<"aeternity_node">>, Reason);
        Other ->
            wallet_unavailable_balance(
                ?AE_DECIMALS,
                <<"AE">>,
                <<"aeternity_node">>,
                {unexpected_ae_account, Other}
            )
    catch
        Class:Reason ->
            wallet_unavailable_balance(
                ?AE_DECIMALS, <<"AE">>, <<"aeternity_node">>, {Class, Reason}
            )
    end.

wallet_lightning_balance(AeAccount) ->
    try damage_nwc_http:resolve_user_ledger_ct(AeAccount) of
        {ok, LedgerCt0} ->
            LedgerCt = wallet_to_binary(LedgerCt0),
            case damage_nwc_ledger_events:sessions(LedgerCt, 200) of
                {ok, Sessions} when is_list(Sessions) ->
                    AmountMsat = lists:sum([wallet_session_balance_msat(S) || S <- Sessions]),
                    #{
                        available => true,
                        amount => integer_to_binary(AmountMsat),
                        amount_msat => integer_to_binary(AmountMsat),
                        amount_sat => integer_to_binary(AmountMsat div 1000),
                        decimals => 3,
                        symbol => <<"sat">>,
                        source => <<"nwc_ledger">>,
                        ledger_ct => LedgerCt,
                        session_count => length(Sessions)
                    };
                {error, Reason} ->
                    wallet_unavailable_balance(3, <<"sat">>, <<"nwc_ledger">>, Reason);
                Other ->
                    wallet_unavailable_balance(
                        3, <<"sat">>, <<"nwc_ledger">>, {unexpected_nwc_sessions, Other}
                    )
            end;
        {error, Reason} ->
            maps:merge(
                wallet_unavailable_balance(3, <<"sat">>, <<"nwc_ledger">>, Reason),
                #{configured => false, session_count => 0}
            );
        Other ->
            wallet_unavailable_balance(
                3, <<"sat">>, <<"nwc_ledger">>, {unexpected_nwc_ledger, Other}
            )
    catch
        Class:Reason ->
            wallet_unavailable_balance(3, <<"sat">>, <<"nwc_ledger">>, {Class, Reason})
    end.

wallet_atomic_balance(Amount, Decimals, Symbol, Source) ->
    #{
        available => true,
        amount => integer_to_binary(Amount),
        decimals => Decimals,
        symbol => Symbol,
        source => Source
    }.

wallet_unavailable_balance(Decimals, Symbol, Source, Reason) ->
    #{
        available => false,
        amount => <<"0">>,
        decimals => Decimals,
        symbol => Symbol,
        source => Source,
        reason => wallet_reason(Reason)
    }.

wallet_session_balance_msat(Session) when is_map(Session) ->
    wallet_to_non_neg_integer(
        wallet_map_get([balance_msat, <<"balance_msat">>], Session, 0)
    );
wallet_session_balance_msat(_) ->
    0.

wallet_map_get([Key | Rest], Map, Default) ->
    case maps:find(Key, Map) of
        {ok, Value} -> Value;
        error -> wallet_map_get(Rest, Map, Default)
    end;
wallet_map_get([], _Map, Default) ->
    Default.

wallet_to_non_neg_integer(Value) when is_integer(Value), Value >= 0 ->
    Value;
wallet_to_non_neg_integer(Value) when is_binary(Value) ->
    try binary_to_integer(Value) of
        Integer when Integer >= 0 -> Integer;
        _ -> 0
    catch
        _:_ -> 0
    end;
wallet_to_non_neg_integer(Value) when is_list(Value) ->
    try list_to_integer(Value) of
        Integer when Integer >= 0 -> Integer;
        _ -> 0
    catch
        _:_ -> 0
    end;
wallet_to_non_neg_integer(_) ->
    0.

wallet_to_binary(Value) when is_binary(Value) -> Value;
wallet_to_binary(Value) when is_list(Value) -> unicode:characters_to_binary(Value);
wallet_to_binary(Value) when is_atom(Value) -> atom_to_binary(Value, utf8);
wallet_to_binary(Value) -> iolist_to_binary(io_lib:format("~p", [Value])).

wallet_reason(Reason) when is_binary(Reason) -> Reason;
wallet_reason(Reason) when is_atom(Reason) -> atom_to_binary(Reason, utf8);
wallet_reason(Reason) -> iolist_to_binary(io_lib:format("~p", [Reason])).

delete_account(Email) ->
    case damage_ae:delete_account(Email) of
        ok -> ok;
        _ -> fail
    end.

notify_user(Username, Message) ->
    ?LOG_INFO("NotifyUser ~p, Message: ~p", [Username, Message]).
