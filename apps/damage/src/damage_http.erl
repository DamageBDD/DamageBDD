-module(damage_http).

-vsn("0.1.0").

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-export([init/2]).
-export([content_types_accepted/2]).
-export([content_types_provided/2]).
-export([to_html/2]).
-export([to_json/2]).
-export([to_text/2]).
-export([from_json/2, allowed_methods/2, from_html/2, is_authorized/2]).
-export([trails/0]).

-include_lib("kernel/include/logger.hrl").
-include_lib("damage.hrl").

-define(TRAILS_TAG, ["Executing Tests"]).

trails() ->
    [
        trails:trail(
            "/version/",
            damage_http,
            #{action => version},
            #{
                get =>
                    #{
                        tags => ?TRAILS_TAG,
                        description => "Form to execute a test on this DamageBDD server.",
                        produces => ["text/html"]
                    }
            }
        ),
        trails:trail(
            "/tx/",
            damage_http,
            #{action => tx},
            #{
                get =>
                    #{
                        tags => ?TRAILS_TAG,
                        description => "Form to execute a test on this DamageBDD server.",
                        produces => ["text/html"]
                    },
                put =>
                    #{
                        tags => ?TRAILS_TAG,
                        description => "Get an lightning invoice from signed message",
                        produces => ["application/json"],
                        parameters =>
                            [
                                #{
                                    name => <<"message">>,
                                    description => <<"Test feature data.">>,
                                    in => <<"body">>,
                                    required => true,
                                    type => <<"string">>
                                },
                                #{
                                    name => <<"account">>,
                                    description => <<"account.">>,
                                    in => <<"body">>,
                                    required => true,
                                    type => <<"string">>
                                },
                                #{
                                    name => <<"signature">>,
                                    description => <<"signature of message.">>,
                                    in => <<"body">>,
                                    required => true,
                                    type => <<"string">>
                                }
                            ]
                    }
            }
        ),
        trails:trail(
            "/execute_feature/",
            damage_http,
            #{action => execute_feature},
            #{
                get =>
                    #{
                        tags => ?TRAILS_TAG,
                        description => "Form to execute a test on this DamageBDD server.",
                        produces => ["text/html"]
                    },
                put =>
                    #{
                        tags => ?TRAILS_TAG,
                        description => "Execute a test on post",
                        produces => ["application/json"],
                        parameters =>
                            [
                                #{
                                    name => <<"feature">>,
                                    description => <<"Test feature data.">>,
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

get_access_token(Req) ->
    case cowboy_req:header(<<"authorization">>, Req) of
        <<"Nostr ", Token/binary>> ->
            {nostr, Token};
        <<"Bearer null">> ->
            {error, missing};
        <<"Bearer ", Token/binary>> ->
            {oauth, Token};
        _ ->
            case catch cowboy_req:match_qs([access_token], Req) of
                #{access_token := null} ->
                    {error, missing};
                #{access_token := Token} ->
                    {oauth, Token};
                _ ->
                    Cookies = cowboy_req:parse_cookies(Req),
                    case lists:keyfind(<<"sessionid">>, 1, Cookies) of
                        {<<"sessionid">>, Token} -> {oauth, Token};
                        _ -> {error, missing}
                    end
            end
    end.

is_authorized(Req, #{action := tx} = State) ->
    {true, Req, State};
is_authorized(Req, #{action := version} = State) ->
    {true, Req, State};
is_authorized(Req, State0) ->
    State =
        maps:put(
            ip,
            damage_utils:get_ip(Req),
            maps:put(useragent, cowboy_req:header(<<"user-agent">>, Req, ""), State0)
        ),
    case get_access_token(Req) of
        {nostr, Token} ->
            #{pubkey := Npub} =
                NostrEvent =
                jsx:decode(base64:decode(Token), [{labels, atom}, return_maps]),
            ?LOG_INFO("Got Nostr auth ~p", [NostrEvent]),
            case nostrlib:verify(NostrEvent) of
                true -> damage_ae:contract_call_admin_account("resolve_npub", [Npub]);
                _ -> {false, Req, State}
            end;
        {oauth, Token} ->
            case damage_accounts:validate_access_token(Token) of
                {error, _E} ->
                    {false, Req, State};
                {AeAccount, <<"wallet">>} ->
                    {
                        true,
                        Req,
                        maps:merge(
                            State,
                            #{
                                public_key => AeAccount,
                                access_token => Token
                            }
                        )
                    };
                {AeAccount, Username} ->
                    case identity_server:get_account_by_email(Username) of
                        {AeAccount, _, _PrivateKey} ->
                            {
                                true,
                                Req,
                                maps:merge(
                                    State,
                                    #{
                                        public_key => AeAccount,
                                        username => Username,
                                        access_token => Token
                                    }
                                )
                            };
                        _ ->
                            {false, Req, State}
                    end;
                Other ->
                    ?LOG_ERROR("Unexpected auth ~p", [Other]),
                    {false, Req, State}
            end;
        {error, _} ->
            {false, Req, State}
    end.

content_types_provided(Req, State) ->
    {
        [
            {{<<"text">>, <<"html">>, '*'}, to_html},
            {{<<"application">>, <<"json">>, []}, to_json},
            {{<<"text">>, <<"plain">>, '*'}, to_text}
        ],
        Req,
        State
    }.

content_types_accepted(Req, State) ->
    {
        [
            {{<<"text">>, <<"plain">>, '*'}, from_html},
            {{<<"application">>, <<"x-www-form-urlencoded">>, '*'}, from_html},
            {{<<"application">>, <<"json">>, '*'}, from_json}
        ],
        Req,
        State
    }.

allowed_methods(Req, State) -> {[<<"GET">>, <<"POST">>], Req, State}.

get_config(
    #{public_key := AeAccount, concurrency := Concurrency0} = Context,
    Req0
) ->
    Concurrency = damage_utils:get_concurrency_level(Concurrency0),
    Formatters =
        case Concurrency of
            1 ->
                case maps:get(stream, Context, maybe_stream) of
                    nostream ->
                        [];
                    _ ->
                        Req =
                            cowboy_req:stream_reply(
                                200,
                                #{<<"content-type">> => <<"text/plain">>},
                                Req0
                            ),
                        ?LOG_INFO("get_config req ~p", [Req]),
                        [
                            {
                                text,
                                #{
                                    output => Req,
                                    color => maps:get(color_formatter, Context, false)
                                }
                            }
                        ]
                end;
            _ ->
                ?LOG_DEBUG("get_config concurrenc ~p", [Concurrency]),
                []
        end,
    damage:get_default_config(AeAccount, Concurrency, Formatters).

execute_bdd(Config, Context, FeatureData) ->
    case damage:execute_data(Config, Context, FeatureData) of
        [#{fail := _FailReason, failing_step := {_KeyWord, Line, Step, _Args}} | _] ->
            Response =
                #{
                    status => <<"notok">>,
                    failing_step => list_to_binary(damage_utils:lists_concat(Step, " ")),
                    line => Line
                },
            {400, Response};
        {parse_error, LineNo, Message} ->
            ?LOG_DEBUG("execute_bdd failure parse_error ~p.", [Message]),
            {
                400,
                jsx:encode(
                    #{
                        status => <<"notok">>,
                        message => list_to_binary(Message),
                        line => LineNo,
                        hint =>
                            <<
                                "Make sure post data is in binary eg: curl --data-binary @features/test.feature ..."
                            >>
                    }
                )
            };
        #{report_hash := _} = Result ->
            {200, maps:merge(Result, #{status => <<"ok">>})};
        Error ->
            ?LOG_DEBUG("execute_bdd failure ~p.", [Error]),
            {
                400,
                jsx:encode(
                    #{
                        status => <<"notok">>,
                        message => Error,
                        hint =>
                            <<
                                "Make sure post data is in binary eg: curl --data-binary @features/test.feature ..."
                            >>
                    }
                )
            }
    end.

check_execute_bdd(
    #{concurrency := Concurrency0, feature := FeatureData} = Context0,
    #{public_key := AeAccount} = State,
    Req0
) ->
    Context = maps:merge(Context0, State),
    Concurrency = damage_utils:get_concurrency_level(Concurrency0),
    IP = damage_utils:get_ip(Req0),
    case throttle:check(damage_api_rate, IP) of
        {limit_exceeded, _, _} ->
            ?LOG_WARNING("IP ~p exceeded api limit", [IP]),
            {429, <<"throttled">>};
        _ ->
            case damage_ae:balance(AeAccount) of
                Balance when Balance >= Concurrency ->
                    Config = get_config(Context, Req0),
                    ?LOG_DEBUG(
                        "check_execute_bdd balance ~p context ~p",
                        [Balance, Context]
                    ),
                    GlobalContext = damage_context:get_global_template_context(Context),
                    AccountContext = damage_context:get_context(AeAccount),
                    execute_bdd(
                        Config,
                        maps:put(account_context, AccountContext, GlobalContext),
                        FeatureData
                    );
                Other ->
                    {
                        400,
                        #{
                            message =>
                                <<"Insufficient balance, please top up balance at `/api/accounts/topup`">>,
                            balance => Other
                        }
                    }
            end
    end.
do_action_tx(Json, _State, Req) ->
    IP = damage_utils:get_ip(Req),
    case throttle:check(damage_api_rate, IP) of
        {limit_exceeded, _, _} ->
            ?LOG_WARNING("IP ~p exceeded api limit", [IP]),
            {429, <<"throttled">>};
        _ ->
            case Json of
                #{signature := Sig, message := Message, pubkey := PubKey} ->
                    case vanillae:verify_signature(Sig, Message, PubKey) of
                        {ok, _Result} ->
                            case catch jsx:decode(Message, [{labels, atom}, return_maps]) of
                                #{amount := Amount} ->
                                    Description = <<"Pay amount for amount of DAMAGE">>,
                                    {ok, Timestamp} = datestring:format(
                                        "YmdHMS", erlang:localtime()
                                    ),
                                    Label0 = list_to_binary("buy:" ++ Timestamp ++ ":"),
                                    Label = <<Label0/binary, PubKey/binary>>,

                                    #{
                                        payment_hash := _PaymentHash,
                                        expires_at := _Expiry,
                                        bolt11 := Bolt11,
                                        payment_secret := _PaymentSecret,
                                        created_index := _CreatedIndex
                                    } =
                                        Invoice = cln:create_invoice(
                                            Amount * 1000, Description, 3600, Label
                                        ),
                                    ?LOG_INFO("invoice ~p", [Invoice]),
                                    {
                                        200,
                                        #{payment_request => Bolt11}
                                    };
                                Reason ->
                                    {
                                        400,
                                        #{
                                            message =>
                                                Reason
                                        }
                                    }
                            end;
                        {error, Reason} ->
                            {
                                400,
                                #{
                                    message =>
                                        Reason
                                }
                            }
                    end
            end
    end.
from_json(Req, State) ->
    {ok, Data, _Req2} = cowboy_req:read_body(Req),
    ?LOG_DEBUG("from_json ~p.", [Req]),
    case catch jsx:decode(Data, [{labels, atom}, return_maps]) of
        {'EXIT', {badarg, Trace}} ->
            ?LOG_ERROR("Json decoding failed ~p", [Trace]),
            {
                cowboy_req:reply(
                    400,
                    cowboy_req:set_resp_body(<<"Json decoding failed.">>, Req)
                ),
                Req,
                State
            };
        #{message := _Message, signature := _Sig} = Json ->
            {Status0, Response0} = do_action_tx(Json, State, Req),
            {
                stop,
                cowboy_req:reply(
                    Status0,
                    cowboy_req:set_resp_body(fast_yaml:encode(Response0), Req)
                ),
                State
            };
        #{feature := _FeatureData, stream := true} = Json ->
            {_Status, Response} = check_execute_bdd(Json, State, Req),
            {stop, Response, State};
        #{feature := _FeatureData, concurrency := Concurrency} = Json when Concurrency > 1 ->
            {Status, Response} = check_execute_bdd(Json, State, Req),
            {stop, cowboy_req:reply(Status, cowboy_req:set_resp_body(jsx:encode(Response))), State}
    end.

from_html(Req0, State) ->
    {ok, Body, _Req} = cowboy_req:read_body(Req0),
    _UserAgent = cowboy_req:header(<<"user-agent">>, Req0, ""),
    Concurrency =
        binary_to_integer(
            cowboy_req:header(<<"x-damage-concurrency">>, Req0, <<"1">>)
        ),
    ColorFormatter =
        case cowboy_req:match_qs([{color, [], <<"true">>}], Req0) of
            #{color := <<"true">>} -> true;
            _Other -> false
        end,
    case
        check_execute_bdd(
            #{
                feature => Body,
                color_formatter => ColorFormatter,
                concurrency => Concurrency,
                stream => maybe_stream
            },
            State,
            Req0
        )
    of
        {200, Response} ->
            ?LOG_INFO(
                "ok execute_feature from_html ~p concurrency ~p",
                [Response, Concurrency]
            ),
            {
                stop,
                case Concurrency of
                    1 ->
                        Req0;
                    C ->
                        ?LOG_DEBUG("got concurrency of ~p", [C]),
                        cowboy_req:reply(200, Req0),
                        cowboy_req:set_resp_body(jsx:encode(Response), Req0)
                end,
                State
            };
        {Status, Response} ->
            ?LOG_INFO("~p execute_feature from_html ~p", [Status, Response]),
            {
                stop,
                cowboy_req:reply(
                    Status,
                    cowboy_req:set_resp_body(jsx:encode(Response), Req0)
                ),
                State
            };
        Error ->
            ?LOG_ERROR("execute_feature from_html error ~p", [Error]),
            {
                stop,
                cowboy_req:reply(400, cowboy_req:set_resp_body(jsx:encode(Error), Req0)),
                State
            }
    end.

to_html(Req, #{action := version} = State) ->
    to_json(Req, State);
to_html(Req, State) ->
    Body = damage_utils:load_template("api.mustache", #{body => <<"Test">>}),
    {Body, Req, State}.

to_json(Req, #{action := version} = State) ->
    {ok, CommitHash} = file:read_file("commit_hash.txt"),
    {ok, Version} = file:read_file("VERSION"),
    #{public_key := PubKey, private_key := _NodePrivateKey} = secrets:node_keypair(),
    {
        jsx:encode(#{
            commit_hash => CommitHash, version => Version, public_key => list_to_binary(PubKey)
        }),
        Req,
        State
    };
to_json(Req0, State) ->
    Body = <<"{\"rest\": \"Hello World!\", \"status\": \"ok\"}">>,
    %Req1 = cowboy_req:set_resp_header(<<"X-CSRFToken">>, <<"testtoken">>, Req0),
    %Req =
    %  cowboy_req:set_resp_header(<<"X-SessionID">>, <<"testsessionid">>, Req1),
    {Body, Req0, State}.

to_text(Req, State) -> {<<"REST Hello World as text!">>, Req, State}.
