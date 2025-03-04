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
        ),
        trails:trail(
            "/ecai/",
            damage_http,
            #{action => ecai_train},
            #{
                get =>
                    #{
                        tags => ?TRAILS_TAG,
                        description => "list models.",
                        produces => ["text/html"]
                    },
                put =>
                    #{
                        tags => ?TRAILS_TAG,
                        description => "create new model from data",
                        produces => ["application/json"],
                        parameters =>
                            [
                                #{
                                    name => <<"data">>,
                                    description => <<"training data.">>,
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
        <<"Bearer ", Token/binary>> ->
            {oauth, Token};
        _ ->
            case catch cowboy_req:match_qs([access_token], Req) of
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
                _ -> {{false, <<"Bearer">>}, Req, State}
            end;
        {oauth, Token} ->
            case oauth2:verify_access_token(Token, []) of
                {ok, {[], Auth}} ->
                    #{
                        <<"client">> := _Client,
                        <<"resource_owner">> := ResourceOwner,
                        <<"expiry_time">> := _Expiry,
                        <<"scope">> := _Scope
                    } = maps:from_list(Auth),
                    case damage_ae:get_meta(ResourceOwner) of
                        notfound ->
                            {{false, <<"Bearer">>}, Req, State};
                        User ->
                            {
                                true,
                                Req,
                                maps:merge(
                                    State,
                                    #{
                                        ae_account => maps:get(ae_account, User),
                                        user => User,
                                        username => ResourceOwner,
                                        access_token => Token
                                    }
                                )
                            }
                    end;
                {error, access_denied} ->
                    {{false, <<"Bearer">>}, Req, State};
                Other ->
                    ?LOG_ERROR("Unexpected auth ~p", [Other]),
                    {{false, <<"Bearer">>}, Req, State}
            end;
        {error, _} ->
            {{false, <<"Bearer">>}, Req, State}
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
            {{<<"application">>, <<"x-www-form-urlencoded">>, '*'}, from_html},
            {{<<"application">>, <<"json">>, '*'}, from_json}
        ],
        Req,
        State
    }.

allowed_methods(Req, State) -> {[<<"GET">>, <<"POST">>], Req, State}.

get_config(
    #{ae_account := AeAccount, concurrency := Concurrency0} = Context,
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
                        logger:info("get_config req ~p", [Req]),
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

execute_bdd(Config, Context, #{feature := FeatureData}) ->
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
    #{concurrency := Concurrency0} = Context0,
    #{ae_account := AeAccount} = State,
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
                    execute_bdd(
                        Config,
                        damage_context:get_account_context(
                            damage_context:get_global_template_context(Context)
                        ),
                        Context
                    );
                Other ->
                    {
                        400,
                        io_lib:format(
                            <<
                                "Insufficient balance, please top up balance at `/api/accounts/topup` balance: ~p"
                            >>,
                            [Other]
                        )
                    }
            end
    end.
read_stream(ConnPid, StreamRef) ->
    case gun:await(ConnPid, StreamRef, 600000) of
        {response, nofin, Status, _Headers0} ->
            {ok, Body} = gun:await_body(ConnPid, StreamRef),
            ?LOG_DEBUG("read_stream Status ~p Response: ~p", [Status, Body]),
            jsx:decode(Body, [{labels, atom}, return_maps]);
        Default ->
            ?LOG_DEBUG("Got unexpected response ~p.", [Default]),
            Default
    end.

get_knowledge(KnowledgeTxHash) ->
    {ok, KnowledgeNftContract} = application:get_env(damage, knowledge_contract),
    case damage_ae:get_ae_mdw_node() of
        {ok, ConnPid, PathPrefix} ->
            Path =
                PathPrefix ++ "v3/aex141/" ++ KnowledgeNftContract ++ "/tokens/" ++ KnowledgeTxHash,
            StreamRef = gun:get(ConnPid, Path),
            MetaData =
                case catch read_stream(ConnPid, StreamRef) of
                    #{amount := null} ->
                        0;
                    {error, Error} ->
                        ?LOG_ERROR("Error getting balance ~p", [Error]),
                        0;
                    #{error := Error} ->
                        ?LOG_ERROR("Error getting balance ~p", [Error]),
                        0;
                    #{amount := Balance0} ->
                        Balance0
                end,
            {reply, MetaData};
        Err ->
            ?LOG_DEBUG("Finding ae node failed ~p", [Err]),
            {reply, {error, not_found}}
    end.

do_action(train, Data, #{ae_account := AeAccount} = _State) ->
    {ok, KnowledgeNftContract} = application:get_env(damage, knowledge_contract),
    Knowledge = ecai:train(Data),
    MetaData = #{},
    MintResult = damage_ae:contract_call(
        damage_ae:account_keypair(AeAccount),
        KnowledgeNftContract,
        "contracts/knowledge_nft.aes",
        "mint",
        [AeAccount, MetaData, Knowledge]
    ),
    {200, jsx:encode(MintResult)};
do_action(think, KnowledgeTxHash, _State) ->
    Knowledge = get_knowledge(KnowledgeTxHash),
    ThinkResult = ecai:think(Knowledge),
    {200, jsx:encode(ThinkResult)}.

from_json(Req, #{action := Action} = State) ->
    {ok, Data, _Req2} = cowboy_req:read_body(Req),
    {Status, Resp0} =
        case jsx:decode(Data, [{labels, atom}, return_maps]) of
            #{feature := _FeatureData, concurrency := _Concurrency} = FeatureJson ->
                do_action(Action, FeatureJson, State);
            Err ->
                logger:error("json decoding failed ~p.", [Data]),
                {400, jsx:encode(#{status => <<"notok">>, result => [Err]})}
        end,
    Resp = cowboy_req:set_resp_body(Resp0, Req),
    cowboy_req:reply(Status, Resp),
    {stop, Resp, State}.

from_html(Req0, State) ->
    {ok, Body, Req} = cowboy_req:read_body(Req0),
    ?LOG_DEBUG("Req ~p.", [Req]),
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
            ?LOG_DEBUG(
                "ok execute_feature from_html ~p concurrency ~p",
                [Response, Concurrency]
            ),
            {
                stop,
                case Concurrency of
                    1 ->
                        Req0;
                    _ ->
                        cowboy_req:reply(200, Req0),
                        cowboy_req:set_resp_body(jsx:encode(Response), Req0)
                end,
                State
            };
        {Status, Response} ->
            ?LOG_DEBUG("~p execute_feature from_html ~p", [Status, Response]),
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
    {jsx:encode(#{commit_hash => CommitHash}), Req, State};
to_json(Req0, State) ->
    Body = <<"{\"rest\": \"Hello World!\", \"status\": \"ok\"}">>,
    %Req1 = cowboy_req:set_resp_header(<<"X-CSRFToken">>, <<"testtoken">>, Req0),
    %Req =
    %  cowboy_req:set_resp_header(<<"X-SessionID">>, <<"testsessionid">>, Req1),
    {Body, Req0, State}.

to_text(Req, State) -> {<<"REST Hello World as text!">>, Req, State}.
