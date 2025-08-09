-module(damage_accounts).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-export([init/2]).
-export([content_types_provided/2]).
-export([to_html/2]).
-export([to_json/2]).

%-export([to_text/2]).
-export([from_json/2, allowed_methods/2, from_html/2, from_yaml/2]).
-export([content_types_accepted/2]).
-export([trails/0]).
-export([delete_account/1]).
-export([delete_resource/2]).
-export([notify_user/2]).
-export([validate_access_token/1]).
-export([validate_password/1]).
-export([authenticate_user/2]).

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

to_json(Req, #{action := confirm} = State) ->
    % for some browsers who send in applicaion/json contenttype
    to_html(Req, State);
to_json(Req, #{action := rate} = State) ->
    {jsx:encode(#{price => ?DAMAGE_PRICE}), Req, State};
to_json(Req, #{action := balance} = State) ->
    case damage_http:is_authorized(Req, State) of
        {true, _Req0, #{public_key := AeAccount} = _State0} ->
            {jsx:encode(balance(AeAccount)), Req, State};
        {false, _, _} ->
            {{false, ?AUTH_HEADER}, Req, State}
    end;
to_json(Req, State) ->
    {stop, cowboy_req:reply(401, cowboy_req:set_resp_body(<<"Unauthorized.">>, Req)), State}.

to_html(Req, #{action := reset_password} = State) ->
    case cowboy_req:match_qs([token], Req) of
        #{token := Token} ->
            Now = date_util:now_to_seconds(os:timestamp()),
            case catch binary_to_term(secrets:decrypt(Token)) of
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
    case catch binary_to_term(secrets:decrypt(Token)) of
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

authenticate_user(Email, Password) ->
    case identity_server:get_account_by_email(Email) of
        {Account, Password, _PrivateKey} ->
            Expiry = date_util:now_to_seconds(os:timestamp()) + ?TOKEN_TIMEOUT,
            Token = secrets:encrypt(term_to_binary({Account, Email, Expiry})),
            {ok, Account, Token};
        Error = {error, notfound} ->
            ?LOG_ERROR("authenticate_user error ~p ", [Error]),
            Error;
        notfound ->
            ?LOG_ERROR("authenticate_user error ~p ", [notfound]),
            {error, notfound};
        _ ->
            {error, notauthorized}
    end.
validate_access_token(Token) ->
    Now = date_util:now_to_seconds(os:timestamp()),
    case catch binary_to_term(secrets:decrypt(Token)) of
        {AeAccount, Email, Expiry} when Expiry > Now ->
            {AeAccount, Email};
        {_AeAccount, _Username, Expiry} when Expiry < Now ->
            {error, exprired};
        _ ->
            {error, badrequest}
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
    ?LOG_DEBUG("AuthToken sent ~p", [Query]),
    Ctxt =
        maps:put(
            <<"password_reset_url">>,
            <<ApiUrl0/binary, "/accounts/confirm?", Query/binary>>,
            Data
        ),
    Result = damage_utils:send_email(
        {maps:get(full_name, Meta, <<"">>), Email},
        <<"DamageBDD Account SignUp">>,
        damage_utils:load_template("signup_email.txt.mustache", Ctxt),
        damage_utils:load_template("signup_email.html.mustache", Ctxt)
    ),
    ?LOG_DEBUG("Email sent ~p", [Result]),
    {
        ok,
        <<
            "Please check email for confirmation link. Don't forget to check spam folder too."
        >>
    }.

-spec do_post_action(atom(), map()) ->
    {integer(), map()}.
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
                    case catch binary_to_term(secrets:decrypt(Token)) of
                        #{email := _Email, expiry := Expiry} when Expiry < Now ->
                            Message = <<"Reset password token expired.">>,
                            {400, #{status => <<"failed">>, message => Message}};
                        #{email := Email, expiry := Expiry} when Expiry > Now ->
                            case identity_server:set_email_password(Email, NewPassword) of
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
                    Message = <<"Password does match.">>,
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
    ?LOG_DEBUG("AuthToken sent ~p", [Query]),
    Ctxt =
        maps:put(
            <<"password_reset_url">>,
            <<ApiUrl0/binary, "/accounts/reset_password?", Query/binary>>,
            Data
        ),
    Result = damage_utils:send_email(
        {maps:get(full_name, Data, <<"">>), Email},
        <<"DamageBDD Account Reset Password">>,
        damage_utils:load_template("reset_password_email.txt.mustache", Ctxt),
        damage_utils:load_template("reset_password_email.html.mustache", Ctxt)
    ),
    ?LOG_DEBUG("Email sent ~p", [Result]),
    {200, #{
        status => <<"ok">>,
        message =>
            <<"Account password reset. Please check email for confirmation link. Don't forget to check spam folder too.">>
    }};
do_post_action(
    confirm,
    #{token := Token, new_password := NewPassword, new_password_confirm := NewPasswordConfirm}
) ->
    Now = date_util:now_to_seconds(os:timestamp()),
    case validate_password(NewPassword) of
        true ->
            case NewPassword of
                NewPasswordConfirm ->
                    case catch binary_to_term(secrets:decrypt(Token)) of
                        #{email := _Email, expiry := Expiry} when Expiry < Now ->
                            Message = <<"Confirm Token Expired.">>,
                            {400, #{status => <<"failed">>, message => Message}};
                        #{email := Email, expiry := Expiry} when Expiry > Now ->
                            ok = identity_server:register_email(Email, NewPassword),
                            {200, #{
                                status => <<"ok">>,
                                message => <<"Email confirmed and password set.">>
                            }}
                    end;
                _ ->
                    {400, <<"Password does not match.">>}
            end;
        false ->
            Message =
                <<"Password does not meet complexity requirement: minimum 8 characters with at least one uppercase letter, one lowercase letter, one digit, and one special character.">>,
            {400, #{status => <<"failed">>, message => Message}}
    end;
do_post_action(create, #{email := Email} = Data) when is_atom(Email) ->
    do_post_action(create, maps:put(email, atom_to_binary(Email), Data));
do_post_action(create, #{email := Email} = Data) ->
    case damage_utils:is_valid_email(Email) of
        true ->
            ?LOG_DEBUG("account  ~p", [Data]),
            case send_account_confirm_email(#{email => Email}) of
                {ok, Message} -> {201, #{status => <<"ok">>, message => Message}};
                {error, Message} -> {400, #{status => <<"failed">>, message => Message}};
                Error -> {400, #{status => <<"failed">>, message => Error}}
            end;
        false ->
            {400, #{status => <<"failed">>, message => <<"Invalid email">>}}
    end.

from_html(Req, #{action := authenticate} = State) ->
    {ok, Params, Req0} = cowboy_req:read_urlencoded_body(Req),
    ?LOG_DEBUG(" form data: ~p ", [Params]),
    Username = proplists:get_value(<<"username">>, Params),
    Password = proplists:get_value(<<"password">>, Params),
    case authenticate_user(Username, Password) of
        {ok, Account, Token} ->
            {stop,
                cowboy_req:reply(
                    200,
                    cowboy_req:set_resp_body(
                        jsx:encode(#{status => <<"ok">>, access_token => Token, address => Account}),
                        Req0
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
    ?LOG_DEBUG(" form data: ~p ", [Params]),
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

from_json(Req, #{action := Action} = State) ->
    {ok, Data, Req0} = cowboy_req:read_body(Req),
    ?LOG_DEBUG("post action ~p ", [Data]),
    case catch jsx:decode(Data, [return_maps, {labels, atom}]) of
        badarg ->
            Response =
                cowboy_req:set_resp_body(
                    jsx:encode(
                        #{status => <<"failed">>, message => <<"Json decode error.">>}
                    ),
                    Req0
                ),
            cowboy_req:reply(400, Response),
            ?LOG_DEBUG("post response 400 ~p ", [Response]),
            {stop, Response, State};
        {'EXIT', {badarg, _}} ->
            Response =
                cowboy_req:set_resp_body(
                    jsx:encode(
                        #{status => <<"failed">>, message => <<"Json decode error.">>}
                    ),
                    Req0
                ),
            cowboy_req:reply(400, Response),
            ?LOG_DEBUG("post response 400 ~p ", [Response]),
            {stop, Response, State};
        Data0 ->
            case do_post_action(Action, Data0) of
                {204, <<"">>} ->
                    {stop, cowboy_req:reply(204, Req0), State};
                {Status0, Response0} ->
                    Response = cowboy_req:set_resp_body(
                        jsx:encode(Response0),
                        Req0
                    ),
                    cowboy_req:reply(Status0, Response),
                    {stop, Response, State}
            end
    end.

from_yaml(Req, #{action := reset_password} = State) ->
    {ok, Data, _Req2} = cowboy_req:read_body(Req),
    {Status0, Response0} =
        case fast_yaml:decode(Data, [maps, {plain_as_atom, true}]) of
            {ok, [Data0]} ->
                case damage_oauth:reset_password(Data0) of
                    {ok, Message} -> {200, #{status => <<"ok">>, message => Message}};
                    {error, Message} -> {400, #{status => <<"failed">>, message => Message}}
                end;
            {error, Message} ->
                {400, #{status => <<"failed">>, message => Message}}
        end,
    ?LOG_DEBUG("post action ~p resp ~p", [Data, Response0]),
    {
        stop,
        cowboy_req:reply(
            Status0,
            cowboy_req:set_resp_body(fast_yaml:encode(Response0), Req)
        ),
        State
    };
from_yaml(Req, #{action := Action} = State) ->
    {ok, Data, _Req2} = cowboy_req:read_body(Req),
    {Status0, Response0} =
        case fast_yaml:decode(Data, [maps, {plain_as_atom, true}]) of
            {ok, [Data0]} -> do_post_action(Action, Data0);
            {error, Message} -> {400, #{status => <<"failed">>, message => Message}}
        end,
    ?LOG_DEBUG("post action ~p resp ~p", [Data, Response0]),
    {
        stop,
        cowboy_req:reply(
            Status0,
            cowboy_req:set_resp_body(fast_yaml:encode(Response0), Req)
        ),
        State
    }.

delete_resource(Req, #{action := invoices} = State) ->
    case damage_http:is_authorized(Req, State) of
        {true, _Req0, #{username := _Username} = _State0} ->
            Deleted =
                lists:foldl(
                    fun(RHash, Acc) ->
                        ?LOG_DEBUG(
                            "cancelling invoice ~p ~p",
                            [maps:get(path_info, Req), RHash]
                        ),
                        case cln:cancel_invoice(RHash) of
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
                    400,
                    cowboy_req:set_resp_body(<<"Unauthorized.">>, Req)
                ),
                Req,
                State
            }
    end.

balance(AeAccount) -> #{amount => damage_ae:balance(AeAccount)}.

delete_account(Email) ->
    case damage_ae:delete_account(Email) of
        ok -> ok;
        _ -> fail
    end.

notify_user(Username, Message) ->
    ?LOG_DEBUG("NotifyUser ~p, Message: ~p", [Username, Message]).
