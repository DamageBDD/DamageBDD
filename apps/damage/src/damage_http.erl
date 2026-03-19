-module(damage_http).

-vsn("0.1.0").

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").
-include_lib("damage.hrl").
-export([init/2]).
-export([content_types_accepted/2]).
-export([content_types_provided/2]).
-export([to_html/2]).
-export([to_json/2]).
-export([to_text/2]).
-export([from_json/2, allowed_methods/2, from_html/2, is_authorized/2]).
-export([trails/0]).
-import(damage_utils, [float_to_full_integer/1, to_bin/1]).

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
        ),
        trails:trail(
            "/execute_feature_from_ipfs/",
            damage_http,
            #{action => execute_feature_from_ipfs},
            #{
                get =>
                    #{
                        tags => ?TRAILS_TAG,
                        description =>
                            "Form to execute an IPFS-hosted feature on this DamageBDD server.",
                        produces => ["text/html"]
                    },
                put =>
                    #{
                        tags => ?TRAILS_TAG,
                        description => "Execute a feature fetched from IPFS (feature CID).",
                        produces => ["application/json"],
                        parameters =>
                            [
                                #{
                                    name => <<"feature_cid">>,
                                    description => <<"IPFS CID of the feature file (gherkin).">>,
                                    in => <<"body">>,
                                    required => true,
                                    type => <<"string">>
                                },
                                #{
                                    name => <<"vars">>,
                                    description => <<"Variables to merge into execution context.">>,
                                    in => <<"body">>,
                                    required => false,
                                    type => <<"object">>
                                }
                            ]
                    }
            }
        )
    ].
init(Req, Opts) -> {cowboy_rest, Req, Opts}.

is_authorized(Req, #{action := version} = State) ->
    {true, Req, State};
is_authorized(Req, #{action := tx} = State) ->
    {true, Req, State};
is_authorized(Req, State0) ->
    damage_auth:require_auth(
        Req,
        State0,
        fun generate_l402_invoice/2,
        fun(Req1, _Reason, State1) -> generate_l402_invoice(Req1, State1) end
    ).

generate_l402_invoice(Req0, State) ->
    Action = maps:get(action, State, unknown),
    Scope = iolist_to_binary(["/", atom_to_list(Action)]),

    case Action of
        execute_feature ->
            maybe_dynamic_price(Req0, State, Scope);
        execute_feature_from_ipfs ->
            maybe_dynamic_price(Req0, State, Scope);
        _ ->
            static_l402(Req0, State, Scope)
    end.

maybe_dynamic_price(Req0, State, Scope) ->
    case cowboy_req:has_body(Req0) of
        true ->
            {ok, FeatureBin, Req1} = cowboy_req:read_body(Req0),
            case dry_run_cost_msat(FeatureBin, State, Req1) of
                {ok, AmountMsat, DryRec} ->
                    Body = jsx:encode(#{
                        status => <<"payment_required">>,
                        scope => Scope,
                        amount_msat => AmountMsat,
                        dry_run => DryRec
                    }),
                    {Req2, _} =
                        damage_l402:challenge_with_body(Req1, Scope, AmountMsat, Body),
                    {stop, Req2, State};
                {error, _Why} ->
                    static_l402(Req1, State, Scope)
            end;
        false ->
            static_l402(Req0, State, Scope)
    end.

static_l402(Req, State, Scope) ->
    PriceMsat = application:get_env(damage, l402_price_msat, 1000),
    {Req1, _} = damage_l402:challenge(Req, Scope, PriceMsat),
    {stop, Req1, State}.

dry_run_cost_msat(FeatureBin, State, Req) ->
    #{public_key := NodePublicKey, private_key := _PrivateKey} = secrets:node_keypair(),
    Context0 = #{
        feature => FeatureBin,
        stream => nostream,
        concurrency => 1,
        color_formatter => false,
        public_key => to_bin(NodePublicKey)
    },
    case execute_bdd(Context0, State, Req, [{dry_run, true}]) of
        {200, #{status := <<"ok">>, cost := Cost, feature_hash := FeatureHash} = DryRec} ->
            %% Convert DAMAGE cost -> sats -> msat
            ?LOG_DEBUG("cost ~p", [Cost / ?DAMAGE_DECIMALS]),
            Sats = price_feed:damage_to_sats(damage:hits_to_damage(Cost)),
            MinSats = application:get_env(damage, l402_min_sats, 1),
            Sats1 = max(MinSats, Sats),
            AmountMsat = Sats1,

            %% Return dry-run + explicit keys client wants
            DryOut =
                DryRec#{
                    cost_damage => Cost,
                    feature_hash => FeatureHash,
                    sats => Sats1,
                    amount_msat => AmountMsat
                },

            {ok, AmountMsat, DryOut};
        {200, Other} ->
            {error, {dry_run_not_ok, Other}};
        {Code, Err} ->
            {error, {dry_run_failed, Code, Err}}
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
get_stream_config(Config, Context, Req) ->
    %% stream logs via text formatter to cowboy stream
    %Req = cowboy_req:stream_reply(
    %    200, #{<<"content-type">> => <<"text/plain">>}, Req0
    %),
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
    Config0.
get_config(Config, Context, Req0) ->
    Concurrency = maps:get(concurrency, Context, 1),
    StreamFlag = maps:get(stream, Context, true),
    case {Concurrency, StreamFlag} of
        {1, maybe_stream} ->
            get_stream_config(Config, Context, Req0);
        {1, true} ->
            get_stream_config(Config, Context, Req0);
        _ ->
            %% non-stream path; keep formatters as supplied (or none)
            AeAccount = maps:get(public_key, Context, maps:get(address, Context, undefined)),
            Concurrency1 = damage_utils:get_concurrency_level(Concurrency),
            damage_config:get_default_config(
                [{public_key, AeAccount}, {concurrency, Concurrency1} | Config]
            )
    end.

%%--------------------------------------------------------------------
%% Low-level: execute a single feature run against Config/Context.
%%  - Always returns {StatusCode, Map}.
%%  - Map always carries 'status' => <<"ok">> | <<"notok">>.
%%--------------------------------------------------------------------
-spec execute_bdd_once(proplists:proplist(), map(), binary()) ->
    {200 | 400 | 500, map()}.
execute_bdd_once(Config, Context, FeatureData) ->
    case damage:execute_data(Config, Context, FeatureData) of
        %% Failing step (runner-level assertion failure)
        [
            #{
                fail := FailReason,
                failing_step := {_KeyWord, Line, Step, _Args}
            }
            | _
        ] ->
            {200, #{
                status => <<"notok">>,
                line => Line,
                failing_step =>
                    list_to_binary(damage_utils:lists_concat(Step, " ")),
                reason => FailReason
            }};
        %% Parser/lexer error with pretty message
        {parse_error, LineNo, MessagePretty} ->
            formatter:format(Config, error, {LineNo, MessagePretty}),
            {200, #{
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
%%
%%  - execute_bdd(Context, State, Req0) -> … uses [] as Config overrides
%%  - execute_bdd(Context, State, Req0, ConfigOverrides) -> …
%%
%%  If ConfigOverrides includes {dry_run,true}, returns dry-run result only.
%%--------------------------------------------------------------------

-spec execute_bdd(map(), map(), cowboy_req:req()) ->
    {integer(), map()} | {error, map()}.
execute_bdd(Context, State, Req0) ->
    execute_bdd(Context, State, Req0, []).

%% API: with overrides (e.g., [{dry_run,true}])
-spec execute_bdd(map(), map(), cowboy_req:req(), proplists:proplist()) ->
    {integer(), map()} | {error, map()}.
execute_bdd(Context0, State, Req0, ConfigOverrides) ->
    %% Build effective context once (no guards used here)
    ContextIn = effective_context(Context0, State),
    FeatureData = maps:get(feature, Context0),

    %% --- 1) DRY RUN (force nostream) ----------------------------------------
    DryOverrides = [{dry_run, true} | ConfigOverrides],
    DryContext = maps:put(stream, nostream, ContextIn),

    case
        execute_bdd_once(
            get_config(DryOverrides, DryContext, Req0),
            DryContext,
            FeatureData
        )
    of
        %% Dry run OK
        {200, DryRes} ->
            %% If caller wanted only dry-run, return immediately
            case dry_run_only(ConfigOverrides) of
                true ->
                    {200, DryRes};
                false ->
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

                    case Balance >= Cost of
                        true ->
                            %% --- 2) COSTED RUN --------------------------------
                            RunConfig = get_config(ConfigOverrides, ContextIn, Req0),
                            {_, Result} = execute_bdd_once(RunConfig, ContextIn, FeatureData),
                            {ok, Spend, TxHash} = damage_ae:confirm_spend(
                                RunConfig,
                                Result
                            ),
                            ?LOG_INFO("Result ~p", [Spend]),
                            formatter:format(
                                RunConfig,
                                summary,
                                maps:put(
                                    tx_hash,
                                    TxHash,
                                    maps:put(spend, Spend, Result)
                                )
                            ),
                            {200, Result};
                        false ->
                            {200, #{
                                status => <<"notok">>,
                                message =>
                                    <<"Insufficient balance, please top up at `/api/accounts/topup`">>,
                                balance => Balance
                            }}
                    end
            end;
        %% Dry run failed; bubble it up as-is
        {DryCode, DryRes} ->
            {DryCode, DryRes}
    end.

%% Helper: merge global+account into caller context (no guards)
-spec effective_context(map(), map()) -> map().
effective_context(Context0, State) ->
    Ctx1 = maps:merge(Context0, State),
    damage_context:get_context(Ctx1).

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
get_bin(Key, M) ->
    V = maps:get(Key, M),
    case V of
        B when is_binary(B) -> B;
        L when is_list(L) -> list_to_binary(L)
    end.

get_int(Key, M) ->
    V = maps:get(Key, M),
    case V of
        I when is_integer(I) -> I;
        B when is_binary(B) -> list_to_integer(binary_to_list(B));
        L when is_list(L) -> list_to_integer(L)
    end.

%% action = "prepare_create_channel"
%% ------------------------------------------------------------
%% PREPARE: build final unsigned channel_create_tx (node = responder)
%% ------------------------------------------------------------
do_action_tx(#{action := <<"prepare_create_channel">>} = J, State, Req) ->
    Ini = get_bin(initiator_id, J),
    IniAmt = get_int(initiator_amount, J),
    ResAmt = get_int(responder_amount, J),
    Reserve = get_int(channel_reserve, J),
    Lock = get_int(lock_period, J),
    TTL = get_int(ttl, J),
    Fee = get_int(fee, J),

    #{public_key := NodePub} = secrets:node_keypair(),
    Responder = list_to_binary(NodePub),

    case
        damage_channels:build_channel_create_tx(
            Ini, Responder, IniAmt, ResAmt, Reserve, Lock, TTL, Fee
        )
    of
        {ok, #{tx := Unsigned, tx_hash := TxHash}} ->
            Reply = #{
                status => <<"ok">>, tx => Unsigned, tx_hash => TxHash, responder => Responder
            },
            {stop, cowboy_req:reply(200, cowboy_req:set_resp_body(jsx:encode(Reply), Req)), State};
        {error, Reason} ->
            Reply = #{status => <<"notok">>, error => Reason},
            {stop, cowboy_req:reply(400, cowboy_req:set_resp_body(jsx:encode(Reply), Req)), State}
    end;
%% ------------------------------------------------------------
%% FINALIZE: verify initiator signer; optionally wrap in paying_for; post
%% ------------------------------------------------------------
do_action_tx(
    #{
        action := <<"finalize_create_channel">>,
        unsigned_tx := Unsigned,
        signed_tx := Signed
    } = J,
    State,
    Req
) ->
    PayFor = maps:get(payfor, J, true),
    case damage_channels:finalize_channel_create(Unsigned, Signed, PayFor) of
        {ok, #{<<"tx_hash">> := _TxHash} = R} ->
            Reply = R#{status => <<"ok">>},
            {stop, cowboy_req:reply(200, cowboy_req:set_resp_body(jsx:encode(Reply), Req)), State};
        {error, Reason} ->
            Reply = #{status => <<"notok">>, error => list_to_binary(Reason)},
            {stop, cowboy_req:reply(400, cowboy_req:set_resp_body(jsx:encode(Reply), Req)), State}
    end;
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
        execute_bdd(
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
        {_Status, Response} ->
            {
                200, Response
            }
    end;
%do_action_tx(
%    #{feature := _FeatureData, concurrency := _Concurrency, address := AeAccount} = Json, State, Req
%) ->
%    #{public_key := NodeAeAccount} = secrets:node_keypair(),
%
%    case
%        execute_bdd(
%            maps:put(stream, nostream, Json), State, Req, [{dry_run, true}]
%        )
%    of
%        {200, DryRunRecord} ->
%            #{cost := Cost, feature_hash := FeatureHash, report_hash := ReportHash} =
%                DryRunRecord,
%            Args = [
%                NodeAeAccount,
%                integer_to_list(round(Cost)),
%                binary_to_list(FeatureHash),
%                binary_to_list(ReportHash)
%            ],
%            ?LOG_DEBUG("creating execute tx ~p", [Args]),
%            Tx = damage_ae:contract_call_prepare_tx(
%                #{public_key => AeAccount},
%                ?DAMAGE_TOKEN_CONTRACT,
%                "contracts/token.aes",
%                "spend",
%                Args
%            ),
%            {200, maps:put(tx, Tx, maps:put(cost, Cost, DryRunRecord))};
%        {Status, Response} ->
%            {Status, Response}
%    end;
%% Initialise a job in the channel and snapshot after execution
do_action_tx(
    #{
        feature := _FeatureData,
        concurrency := _Concurrency,
        address := AeAccount,
        channel_id := ChannelId
    } = ContextIn0,
    State,
    Req
) ->
    %% Node’s AE account (responder in the channel)
    %#{public_key := NodeAeAccount} = secrets:node_keypair(),

    %% 1) Dry-run to get cost + hashes (no side effects)
    ContextIn = effective_context(ContextIn0, State),
    DryOverrides = [{dry_run, true}],
    DryContext = maps:put(stream, nostream, ContextIn),
    FeatureData = maps:get(feature, ContextIn),

    case
        execute_bdd_once(
            get_config(DryOverrides, DryContext, Req),
            DryContext,
            FeatureData
        )
    of
        {200, DryRunRecord} ->
            #{
                cost := Cost,
                feature_hash := FeatureHash,
                report_hash := ReportHash
            } = DryRunRecord,

            %% 2) Initialise the job inside the channel (JobRegistry via channel contract call)
            %%    damage_channels:init_job/3 should:
            %%      - ensure/reuse an AE state-channel between AeAccount and NodeAeAccount
            %%      - call JobRegistry (off-chain) to register the job
            %%      - return job_id and the channel pid/info
            case
                damage_channels:init_job(
                    ChannelId,
                    #{
                        cost => Cost,
                        feature_hash => FeatureHash,
                        report_hash_dry_run => ReportHash
                    }
                )
            of
                {ok, #{job_id := JobId, channel_pid := ChanPid} = InitInfo} ->
                    %% 3) Execute the BDD for real, charging via the channel
                    %%    execute_bdd/5 can use job_id + channel_pid to:
                    %%      - call damage_jobs:record_step/6 via the channel
                    %%      - update JobRegistry off-chain per step
                    ExecOpts = [
                        {dry_run, false},
                        {job_id, JobId},
                        {channel_pid, ChanPid}
                    ],
                    {200, ExecResult} =
                        execute_bdd_once(
                            get_stream_config(ExecOpts, ContextIn, Req), ContextIn, FeatureData
                        ),
                    %#{
                    %%  public_key := AeAccount,
                    %%  feature_hash := FeatureHash,
                    %%  report_hash := ReportHash,
                    %  node_public_key := NodePublicKey
                    % } = ExecResult,
                    %Spend = maps:get(step_spend, ExecResult, 1 * math:pow(10, ?DAMAGE_DECIMALS)),
                    %ok = damage_channels:channel_contract_call(
                    %?DAMAGE_TOKEN_CONTRACT,
                    %"contracts/token.aes",
                    %"spend",
                    %[
                    %    binary_to_list(NodePublicKey),
                    %    integer_to_list(float_to_full_integer(Spend)),
                    %    FeatureHash,
                    %    ReportHash
                    %]),

                    %% 4) Finalise by snapshotting latest channel state on-chain
                    %%    damage_channels:finalize_snapshot/2 should:
                    %%      - fetch {channel_id, round, state_hash} from ChanPid
                    %%      - build & post channel_snapshot_solo_tx (or force_progress if needed)
                    ?LOG_INFO("Execition compl;ete finalizing ~p", [ExecResult]),
                    SnapRes = damage_channels:finalize_snapshot(
                        ChanPid,
                        #{from_id => AeAccount}
                    ),
                    ?LOG_INFO("Execution compl;ete finalized ~p", [SnapRes]),

                    Reply = #{
                        status => <<"ok">>,
                        job_id => JobId,
                        dry_run => DryRunRecord,
                        init => InitInfo,
                        exec => ExecResult,
                        snapshot => SnapRes
                    },
                    ?LOG_DEBUG("execute_bdd wallet channel success ~p", [Reply]),
                    {200, Reply};
                {error, Reason} ->
                    ?LOG_ERROR("execute_bdd wallet channel success ~p", [Reason]),
                    {500, #{status => <<"notok">>, error => Reason}}
            end;
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
        Json0 when is_map(Json0) ->
            %% Support IPFS-hosted feature execution
            Json =
                case maps:is_key(feature_cid, Json0) of
                    true ->
                        case damage_ipfs:hydrate_feature_from_ipfs(Json0) of
                            {ok, J} ->
                                J;
                            {error, Why} ->
                                ErrBin = jsx:encode(#{status => <<"notok">>, error => to_bin(Why)}),
                                ReqE = cowboy_req:reply(
                                    400,
                                    #{<<"content-type">> => <<"application/json">>},
                                    ErrBin,
                                    Req1
                                ),
                                throw({stop, ReqE, State})
                        end;
                    false ->
                        Json0
                end,

            Stream = maps:get(stream, Json, false),
            case execute_bdd(Json, State, Req1) of
                {_Status, _Response} when Stream == true ->
                    {stop, Req1, State};
                {Status, Response} ->
                    %% normal JSON reply
                    JsonBin = jsx:encode(Response),
                    Req2 = cowboy_req:reply(
                        Status,
                        #{
                            <<"content-type">> => <<"application/json">>,
                            <<"cache-control">> => <<"no-cache">>
                        },
                        JsonBin,
                        Req1
                    ),
                    {stop, Req2, State}
            end
    end.

from_html(Req0, State) ->
    try
        {ok, Body, Req1} = cowboy_req:read_body(Req0),
        _UserAgent = cowboy_req:header(<<"user-agent">>, Req1, ""),
        Concurrency =
            binary_to_integer(cowboy_req:header(<<"x-damage-concurrency">>, Req1, <<"1">>)),
        ColorFormatter =
            case cowboy_req:match_qs([{color, [], <<"true">>}], Req1) of
                #{color := <<"true">>} -> true;
                _ -> false
            end,
        Stream = stream_mode(Req1, Concurrency),

        %% Own the stream lifecycle here (DON'T guess using resp_headers).
        {ReqRun, Context} =
            case Stream of
                maybe_stream ->
                    ReqS =
                        cowboy_req:stream_reply(
                            200,
                            #{<<"content-type">> => <<"text/plain">>},
                            Req1
                        ),
                    {ReqS, #{
                        feature => Body,
                        concurrency => Concurrency,
                        stream => maybe_stream,
                        color_formatter => ColorFormatter
                    }};
                _ ->
                    {Req1, #{
                        feature => Body,
                        concurrency => Concurrency,
                        stream => Stream,
                        color_formatter => ColorFormatter
                    }}
            end,

        case execute_bdd(Context, State, ReqRun) of
            %% STREAM MODE: always finish with a footer + fin
            {_Status, _Resp} when Stream =:= maybe_stream ->
                Footer = <<"">>,
                Req2 = cowboy_req:stream_body(Footer, fin, ReqRun),
                {stop, Req2, State};
            %% Non-stream OK (JSON)
            {200, Response} ->
                Req2 =
                    cowboy_req:reply(
                        200,
                        #{<<"content-type">> => <<"application/json">>},
                        jsx:encode(Response),
                        Req1
                    ),
                {stop, Req2, State};
            %% Non-stream error (JSON + real status)
            {Status, Response} ->
                Req2 =
                    cowboy_req:reply(
                        Status,
                        #{<<"content-type">> => <<"application/json">>},
                        jsx:encode(Response),
                        Req1
                    ),
                {stop, Req2, State}
        end
    catch
        Class:Reason:Stack ->
            ?LOG_ERROR("from_html crashed ~p:~p ~p", [Class, Reason, Stack]),
            %% Best effort: stream a 500 if we were streaming, else JSON 500
            Concurrency0 =
                catch binary_to_integer(
                    cowboy_req:header(<<"x-damage-concurrency">>, Req0, <<"1">>)
                ),
            Stream0 = stream_mode(Req0, Concurrency0),
            case Stream0 of
                maybe_stream ->
                    ReqS0 =
                        cowboy_req:stream_reply(
                            500,
                            #{<<"content-type">> => <<"text/plain">>},
                            Req0
                        ),
                    Footer0 =
                        iolist_to_binary([
                            "\n---\n",
                            "ERROR: 500 ",
                            io_lib:format("~p:~p", [Class, Reason]),
                            "\n"
                        ]),
                    Req3 = cowboy_req:stream_body(Footer0, fin, ReqS0),
                    {stop, Req3, State};
                _ ->
                    BodyBin =
                        jsx:encode(#{
                            error => <<"internal_error">>,
                            class => to_bin(Class),
                            reason => to_bin(Reason)
                        }),
                    Req4 =
                        cowboy_req:reply(
                            500,
                            #{<<"content-type">> => <<"application/json">>},
                            BodyBin,
                            Req0
                        ),
                    {stop, Req4, State}
            end
    end.
to_html(Req, #{action := version} = State) ->
    to_json(Req, State);
to_html(Req, State) ->
    Body = damage_utils:load_template("api.mustache", #{body => <<"Test">>}),
    {Body, Req, State}.

to_json(Req, #{action := version} = State) ->
    {ok, Version} = application:get_key(damage, vsn),
    Resp = #{
        version => list_to_binary(Version)
    },
    VersionInfo = #{
        git_sha => damage_build_info:git_sha(),
        git_sha_short => damage_build_info:git_sha_short(),
        build_time => damage_build_info:build_time(),
        build_env => damage_build_info:build_env()
    },

    case secrets:node_keypair() of
        #{public_key := PubKey, private_key := _NodePrivateKey} ->
            NodeDamageBalance = damage_ae:node_damage_balance(),
            NodeAeBalance = damage_ae:node_ae_balance(),
            NodeBtcBalance = cln:get_node_balance(),
            Resp0 =
                #{
                    ok => true,
                    public_key => list_to_binary(PubKey),
                    damage_balance => NodeDamageBalance,
                    ae_balance => NodeAeBalance,
                    btc_balance => NodeBtcBalance,
                    version => VersionInfo
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
        {error, Error} ->
            Resp0 =
                #{
                    ok => false,
                    error => atom_to_binary(Error)
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
            }
    end;
to_json(Req0, State) ->
    Body = <<"{\"rest\": \"Hello World!\", \"status\": \"ok\"}">>,
    %Req1 = cowboy_req:set_resp_header(<<"X-CSRFToken">>, <<"testtoken">>, Req0),
    %Req =
    %  cowboy_req:set_resp_header(<<"X-SessionID">>, <<"testsessionid">>, Req1),
    {Body, Req0, State}.

to_text(Req, State) -> {<<"REST Hello World as text!">>, Req, State}.
