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
    case cowboy_req:header(?AUTH_HEADER, Req) of
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

is_authorized(Req, #{action := version} = State) ->
    {true, Req, State};
is_authorized(Req, #{action := tx} = State) ->
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
                _ -> {{false, ?AUTH_HEADER}, Req, State}
            end;
        {oauth, Token} ->
            case damage_accounts:validate_access_token(Token) of
                {error, _E} ->
                    {{false, ?AUTH_HEADER}, Req, State};
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
                        {AeAccount, _, PrivateKey} ->
                            damage_ae:set_private_key(AeAccount, PrivateKey),
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
                            {{false, ?AUTH_HEADER}, Req, State}
                    end;
                Other ->
                    ?LOG_ERROR("Unexpected auth ~p", [Other]),
                    {{false, ?AUTH_HEADER}, Req, State}
            end;
        {error, _} ->
            {{false, ?AUTH_HEADER}, Req, State}
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

allowed_methods(Req, State) -> {[<<"GET">>, <<"POST">>, <<"PUT">>], Req, State}.

stream_mode(Req, Concurrency0) ->
    Concurrency =
        case Concurrency0 of
            undefined ->
                %% allow override from header too
                binary_to_integer(
                    cowboy_req:header(<<"x-damage-concurrency">>, Req, <<"1">>)
                );
            C ->
                C
        end,
    case Concurrency of
        1 -> maybe_stream;
        _ -> nostream
    end.

get_config(Config, Context, Req0) ->
    Concurrency = maps:get(concurrency, Context, 1),
    StreamFlag = maps:get(stream, Context, nostream),
    case {Concurrency, StreamFlag} of
        {1, maybe_stream} ->
            %% stream logs via text formatter to cowboy stream
            Req = cowboy_req:stream_reply(
                200, #{<<"content-type">> => <<"text/plain">>}, Req0
            ),
            Formatters = [
                {text, #{
                    output => Req,
                    color => maps:get(color_formatter, Context, false)
                }}
            ],
            AeAccount = maps:get(public_key, Context, undefined),
            Config0 = damage_config:get_default_config(
                [{public_key, AeAccount}, {concurrency, 1}, {formatters, Formatters} | Config]
            ),
            Config0;
        _ ->
            %% non-stream path; keep formatters as supplied (or none)
            AeAccount = maps:get(public_key, Context, undefined),
            Concurrency1 = damage_utils:get_concurrency_level(Concurrency),
            damage_config:get_default_config(
                [{public_key, AeAccount}, {concurrency, Concurrency1} | Config]
            )
    end.

%%--------------------------------------------------------------------
%% Execute a feature: normalized result
%%  - Always returns {StatusCode, Map}.
%%  - Map always carries 'status' => <<"ok">> | <<"notok">>.
%%--------------------------------------------------------------------
-spec execute_bdd(proplists:proplist(), map(), binary()) ->
    {200 | 400 | 500, map()}.
execute_bdd(Config, Context, FeatureData) ->
    case damage:execute_data(Config, Context, FeatureData) of
        %% Failing step (runner-level assertion failure)
        [
            #{
                fail := FailReason,
                failing_step := {_KeyWord, Line, Step, _Args}
            }
            | _
        ] ->
            {400, #{
                status => <<"notok">>,
                line => Line,
                failing_step => list_to_binary(damage_utils:lists_concat(Step, " ")),
                reason => FailReason
            }};
        %% Parser/lexer error with pretty message
        {parse_error, LineNo, MessagePretty} ->
            ?LOG_DEBUG("execute_bdd parse_error ~p.", [MessagePretty]),
            formatter:format(Config, error, {LineNo, MessagePretty}),
            {400, #{
                status => <<"notok">>,
                message => MessagePretty,
                line => LineNo
            }};
        %% Dry run success (explicit match on dry_run := true)
        #{dry_run := true, report_hash := _, cost := Cost} = Result ->
            {200, maps:merge(Result, #{status => <<"ok">>, cost => Cost})};
        %% Successful run (non-dry). We don't guard; the dry-run clause above
        %% already caught the dry-run case.
        #{report_hash := _} = Result ->
            {200, maps:merge(Result, #{status => <<"ok">>})};
        %% Anything unexpected
        Error ->
            ?LOG_ERROR("execute_bdd unexpected failure ~p.", [Error]),
            {500, #{
                status => <<"notok">>,
                message => Error,
                hint =>
                    <<"Make sure POST data is binary, e.g.: ",
                        "curl --data-binary @features/test.feature ...">>
            }}
    end.

%%--------------------------------------------------------------------
%% Public orchestration: dry-run, then (optionally) paid run
%% - check_execute_bdd(Context, State, Req0) -> … uses [] as Config overrides
%% - check_execute_bdd(Context, State, Req0, ConfigOverrides) -> …
%%   If ConfigOverrides includes {dry_run,true}, returns dry-run result only.
%%--------------------------------------------------------------------
%% API: default (no overrides)
-spec check_execute_bdd(map(), map(), cowboy_req:req()) ->
    {integer(), map()} | {error, map()}.
check_execute_bdd(Context, State, Req0) ->
    check_execute_bdd(Context, State, Req0, []).

%% API: with overrides (e.g., [{dry_run,true}])
-spec check_execute_bdd(map(), map(), cowboy_req:req(), proplists:proplist()) ->
    {integer(), map()} | {error, map()}.
check_execute_bdd(Context0, State, Req0, ConfigOverrides) ->
    %% Build effective context once (no guards used here)
    ContextIn = effective_context(Context0, State),
    FeatureData = maps:get(feature, Context0),

    %% --- 1) DRY RUN (force nostream) ----------------------------------------
    DryOverrides = [{dry_run, true} | ConfigOverrides],
    DryContext = maps:put(stream, nostream, ContextIn),
    {DryCode, DryRes} =
        execute_bdd(get_config(DryOverrides, DryContext, Req0), DryContext, FeatureData),

    %% If caller wanted only dry-run, return immediately on success/failure
    case dry_run_only(ConfigOverrides) of
        true ->
            {DryCode, DryRes};
        false ->
            case DryCode of
                200 ->
                    %% Must have a cost in dry-run success
                    Cost = maps:get(cost, DryRes, 0),
                    %% Find account id (support public_key or address)
                    AeAccount =
                        case ContextIn of
                            #{public_key := PK} -> PK;
                            #{address := PK} -> PK;
                            _ -> undefined
                        end,
                    Balance = damage_ae:balance(AeAccount),
                    %% Guard-safe comparison (>= is allowed in guards; or do it here plainly)
                    case Balance >= Cost of
                        true ->
                            %% --- 2) COSTED RUN --------------------------------
                            RunConfig = get_config(ConfigOverrides, ContextIn, Req0),
                            execute_bdd(RunConfig, ContextIn, FeatureData);
                        false ->
                            {400, #{
                                status => <<"notok">>,
                                message =>
                                    <<"Insufficient balance, please top up at `/api/accounts/topup`">>,
                                balance => Balance
                            }}
                    end;
                _Other ->
                    %% Dry run failed; bubble it up
                    {DryCode, DryRes}
            end
    end.

%% Helper: merge global+account into caller context (no guards)
-spec effective_context(map(), map()) -> map().
effective_context(Context0, State) ->
    Ctx1 = maps:merge(Context0, State),
    AeAccount =
        case Ctx1 of
            #{public_key := PK} -> PK;
            #{address := PK} -> PK;
            _ -> undefined
        end,
    GlobalCtx = damage_context:get_global_template_context(Ctx1),
    AccountCtx = damage_context:get_context(AeAccount),
    maps:put(public_key, AeAccount, maps:put(account_context, AccountCtx, maps:merge(GlobalCtx, Ctx1))).

%% Helper: true iff overrides explicitly request dry-run only
-spec dry_run_only(proplists:proplist()) -> boolean().
dry_run_only(Overrides) ->
    proplists:get_value(dry_run, Overrides, false) =:= true.

do_action_tx_throttled(Json, State, Req) ->
    IP = damage_utils:get_ip(Req),
    case throttle:check(damage_api_rate, IP) of
        {limit_exceeded, _, _} ->
            ?LOG_WARNING("IP ~p exceeded api limit", [IP]),
            {429, <<"throttled">>};
        _ ->
            do_action_tx(Json, State, Req)
    end.
do_action_tx(
    #{
        feature := FeatureData,
        signed_tx := SignedTx,
        concurrency := Concurrency,
        address := AeAccount
    } = _Json,
    State,
    Req
) ->
    ?LOG_DEBUG("signed tx received ~p", [SignedTx]),
    {ok, #{"tx_hash" := ContractCallTxHash}} = vanillae:post_tx(SignedTx),
    #{
        "caller_id" := _,
        "caller_nonce" := _,
        "contract_id" := _,
        "gas_price" := _GasPrice,
        "gas_used" := _GasUsed,
        "height" := _Height,
        "log" := _Log,
        "return_type" := "ok",
        "return_value" := {}
    } = damage_ae:wait_tx(ContractCallTxHash),
    case
        check_execute_bdd(
            #{
                feature => FeatureData,
                color_formatter => false,
                concurrency => Concurrency,
                stream => maybe_stream
            },
            maps:put(public_key, AeAccount, State),
            Req
        )
    of
        {200, Response} ->
            ?LOG_INFO(
                "ok execute_feature from_json tx ~p concurrency ~p",
                [Response, Concurrency]
            ),
            {
                stop,
                case Concurrency of
                    1 ->
                        Req;
                    C when is_integer(C) ->
                        cowboy_req:reply(200, Req),
                        cowboy_req:set_resp_body(jsx:encode(Response), Req)
                end,
                State
            };
        {Status, Response} ->
            ?LOG_INFO("~p execute_feature from_json tx ~p", [Status, Response]),
            {
                stop,
                cowboy_req:reply(
                    Status,
                    cowboy_req:set_resp_body(jsx:encode(Response), Req)
                ),
                State
            }
    end;
do_action_tx(
    #{feature := _FeatureData, concurrency := _Concurrency, address := AeAccount} = Json, State, Req
) ->
    #{public_key := NodeAeAccount} = secrets:node_keypair(),

    case
        check_execute_bdd(
            maps:put(stream, nostream, Json), State, Req, [{dry_run, true}]
        )
    of
        {200, DryRunRecord} ->
            #{cost := Cost, feature_hash := FeatureHash, report_hash := ReportHash} =
                DryRunRecord,
            Args = [
                NodeAeAccount,
                integer_to_list(round(Cost)),
                binary_to_list(FeatureHash),
                binary_to_list(ReportHash)
            ],
            ?LOG_DEBUG("creating execute tx ~p", [Args]),
            Tx = damage_ae:contract_call_prepare_tx(
                #{public_key => AeAccount},
                ?DAMAGE_TOKEN_CONTRACT,
                "contracts/token.aes",
                "spend",
                Args
            ),
            {200, maps:put(tx, Tx, maps:put(cost, Cost, DryRunRecord))};
        {Status, Response} ->
            {Status, Response}
    end;
do_action_tx(#{signature := Sig, message := Message, pubkey := PubKey} = _Json, _State, _Req) ->
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
    end.
from_json(Req, #{action := tx} = State) ->
    {ok, Data, _Req2} = cowboy_req:read_body(Req),
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
        Json when is_map(Json) ->
            {Status0, Response0} = do_action_tx_throttled(Json, State, Req),
            {
                stop,
                cowboy_req:reply(
                    Status0,
                    cowboy_req:set_resp_body(jsx:encode(Response0), Req)
                ),
                State
            }
    end;
from_json(Req0, State) ->
    {ok, Data, Req1} = cowboy_req:read_body(Req0),
    case catch jsx:decode(Data, [{labels, atom}, return_maps]) of
        {'EXIT', {badarg, Trace}} ->
            ?LOG_ERROR("JSON decoding failed ~p", [Trace]),
            Req2 = cowboy_req:reply(
                400,
                #{<<"content-type">> => <<"text/plain">>},
                <<"Json decoding failed.">>,
                Req1
            ),
            {stop, Req2, State};
        Json when is_map(Json) ->
            %% choose streaming or not without guard functions
            Stream = stream_mode(Req1, maps:get(concurrency, Json, 1)),
            case check_execute_bdd(maps:put(stream, Stream, Json), State, Req1) of
                {_Status, _Response} when Stream =:= maybe_stream ->
                    {stop, Req1, State};
                {Status, Response} ->
                    %% normal JSON reply
                    Req2 = cowboy_req:reply(
                        Status,
                        #{<<"content-type">> => <<"application/json">>},
                        jsx:encode(Response),
                        Req1
                    ),
                    {stop, Req2, State}
            end;
        _Other ->
            %% not a map / missing 'feature' etc.
            Req2 = cowboy_req:reply(
                400,
                #{<<"content-type">> => <<"text/plain">>},
                <<"Missing or invalid 'feature' payload.">>,
                Req1
            ),
            {stop, Req2, State}
    end.

from_html(Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    _UserAgent = cowboy_req:header(<<"user-agent">>, Req1, ""),
    Concurrency =
        binary_to_integer(
            cowboy_req:header(<<"x-damage-concurrency">>, Req1, <<"1">>)
        ),
    ColorFormatter =
        case cowboy_req:match_qs([{color, [], <<"true">>}], Req1) of
            #{color := <<"true">>} -> true;
            _ -> false
        end,
    MaybeStream = stream_mode(Req1, Concurrency),

    case
        check_execute_bdd(
            #{
                feature => Body,
                color_formatter => ColorFormatter,
                concurrency => Concurrency,
                stream => MaybeStream
            },
            State,
            Req1
        )
    of
        %% -------------------- OK (send JSON) --------------------
        {200, Response} ->
            ?LOG_INFO(
                "ok execute_feature from_html ~p concurrency ~p",
                [Response, Concurrency]
            ),
            case MaybeStream of
                false ->
                    Req2 = cowboy_req:reply(
                        200,
                        #{<<"content-type">> => <<"application/json">>},
                        jsx:encode(Response),
                        Req1
                    ),
                    {stop, Req2, State};
                _ ->
                    %% If you really want to stream success, do it here:
                    Req2 = cowboy_req:stream_reply(
                        200,
                        #{<<"content-type">> => <<"application/json">>},
                        Req1
                    ),
                    Req3 = cowboy_req:stream_body(jsx:encode(Response), fin, Req2),
                    {stop, Req3, State}
            end;
        %% -------------------- Error (stream the dry-run error) --------------------
        {Status, Response} ->
            ?LOG_INFO("~p execute_feature from_html ~p", [Status, Response]),
            case MaybeStream of
                false ->
                    %% Non-streaming error JSON
                    Req2 = cowboy_req:reply(
                        Status,
                        #{<<"content-type">> => <<"application/json">>},
                        jsx:encode(Response),
                        Req1
                    ),
                    {stop, Req2, State};
                _ ->
                    %% Streaming error text (or JSON – your call)
                    Req2 = cowboy_req:stream_reply(
                        Status,
                        #{<<"content-type">> => <<"text/plain">>},
                        Req1
                    ),
                    %% send a header line and then details
                    Req3 = cowboy_req:stream_body(maps:get(message, Response), nofin, Req2),
                    %% stream the pretty message or entire map
                    Chunk =
                        case Response of
                            #{message := Msg} when is_binary(Msg) -> Msg;
                            _ -> list_to_binary(io_lib:format("~p~n", [Response]))
                        end,
                    Req4 = cowboy_req:stream_body(Chunk, fin, Req3),
                    {stop, Req4, State}
            end
    end.

to_html(Req, #{action := version} = State) ->
    to_json(Req, State);
to_html(Req, State) ->
    Body = damage_utils:load_template("api.mustache", #{body => <<"Test">>}),
    {Body, Req, State}.

to_json(Req, #{action := version} = State) ->
    {ok, CommitHash} = file:read_file("commit_hash.txt"),
    {ok, Version} = application:get_key(damage, vsn),
    Resp = #{
        ok => true,
        commit_hash => CommitHash,
        version => list_to_binary(Version)
    },
    NodeDamageBalance = damage_ae:node_damage_balance(),
    NodeAeBalance = damage_ae:node_ae_balance(),
    #{public_key := PubKey, private_key := _NodePrivateKey} = secrets:node_keypair(),
    Resp0 =
        #{
            public_key => list_to_binary(PubKey),
            damage_balance => NodeDamageBalance,
            ae_balance => NodeAeBalance
        },
    {
        jsx:encode(
            maps:merge(
                Resp,
                Resp0
            )
        ),
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
