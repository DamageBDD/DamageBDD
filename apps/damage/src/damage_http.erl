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

%% Focused test visibility. Production builds keep these helpers private.
-ifdef(TEST).
-export([
    normalize_execution_json_context/1,
    execution_context_from_request/2,
    stream_final_body/2
]).
-endif.

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
                        description =>
                            "Return DamageBDD application, build, Git and Erlang runtime version information.",
                        produces => ["application/json"]
                    }
            }
        ),
        trails:trail(
            "/api/version",
            damage_http,
            #{action => version},
            #{
                get =>
                    #{
                        tags => ?TRAILS_TAG,
                        description =>
                            "Return DamageBDD application, build, Git and Erlang runtime version information.",
                        produces => ["application/json"]
                    }
            }
        ),
        trails:trail(
            "/api/node/balances",
            damage_http,
            #{action => node_balances},
            #{
                get =>
                    #{
                        tags => ?TRAILS_TAG,
                        description =>
                            "Return DamageBDD node wallet balances.",
                        produces => ["application/json"]
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
is_authorized(Req, #{action := node_balances} = State) ->
    {true, Req, State};
is_authorized(Req, #{action := tx} = State) ->
    {true, Req, State};
is_authorized(Req, State0) ->
    damage_auth:require_auth(
        Req,
        State0,
        fun generate_l402_invoice/2,
        fun(Req1, _Reason, State1) ->
            generate_l402_invoice(Req1, State1)
        end
    ).

generate_l402_invoice(Req0, State) ->
    Action = maps:get(action, State, unknown),
    Scope = iolist_to_binary(["/", atom_to_list(Action)]),

    case Action of
        %% Context administration/proof routes require normal authenticated
        %% access. Never turn missing/invalid auth into a payable L402 challenge.
        node_context ->
            {{false, ?AUTH_HEADER}, Req0, State};
        account_proof ->
            {{false, ?AUTH_HEADER}, Req0, State};
        node_anchor ->
            {{false, ?AUTH_HEADER}, Req0, State};
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
    case l402_execution_account() of
        {ok, L402Account} ->
            %% Price the protected execution using the same account that will
            %% execute after payment: the node's configured l402_account.
            Context0 = #{
                feature => FeatureBin,
                stream => nostream,
                concurrency => 1,
                color_formatter => false,
                public_key => L402Account
            },
            dry_run_cost_msat_for_context(Context0, State, Req);
        {error, _Why} = Error ->
            Error
    end.

dry_run_cost_msat_for_context(Context0, State, Req) ->
    case execute_bdd(Context0, State, Req, [{dry_run, true}]) of
        {200, #{status := <<"ok">>, cost := Cost, feature_hash := FeatureHash} = DryRec} ->
            %% Convert DAMAGE cost hits -> whole DAMAGE -> sats -> msat.
            CostDamage = ceil_damage(cost_hits_to_damage(Cost)),
            ?LOG_DEBUG("cost_hits=~p cost_damage=~p", [Cost, CostDamage]),
            Sats = price_feed:damage_to_sats(CostDamage),
            MinSats = application:get_env(damage, l402_min_sats, 1),
            Sats1 = max(MinSats, Sats),
            AmountMsat = Sats1 * 1000,

            %% Return dry-run + explicit keys client wants
            DryOut =
                DryRec#{
                    cost_hits => Cost,
                    cost_damage => CostDamage,
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

l402_execution_account() ->
    case application:get_env(damage, l402_account) of
        {ok, AeAccount0} ->
            {ok, to_bin(AeAccount0)};
        Other ->
            ?LOG_INFO("L402 not enabled ~p", [Other]),
            {error, l402_not_enabled}
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
    ContinueOnFail =
        maps:get(
            continue_on_fail,
            Context,
            proplists:get_value(continue_on_fail, Config, false)
        ),
    RunnerOpts = [{continue_on_fail, ContinueOnFail}],
    Config0 = damage_config:get_default_config(
        RunnerOpts ++
            [{public_key, AeAccount}, {concurrency, 1}, {formatters, Formatters} | Config]
    ),
    Config0.
get_config(Config, Context, Req0) ->
    Concurrency = maps:get(concurrency, Context, 1),
    StreamFlag = maps:get(stream, Context, true),
    ContinueOnFail =
        maps:get(
            continue_on_fail,
            Context,
            proplists:get_value(continue_on_fail, Config, false)
        ),
    RunnerOpts = [{continue_on_fail, ContinueOnFail}],
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
                RunnerOpts ++
                    [{public_key, AeAccount}, {concurrency, Concurrency1} | Config]
            )
    end.

%%--------------------------------------------------------------------
%% Low-level: execute a single feature run against Config/Context.
%%  - Always returns {StatusCode, Map}.
%%  - Map always carries 'status' => <<"ok">> | <<"notok">>.
%%--------------------------------------------------------------------
-spec execute_bdd_once(proplists:proplist(), map(), binary()) ->
    {200 | 400 | 500 | 503, map()}.
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
            ?LOG_ERROR("Fail ~p", [FailReason]),
            {200, #{
                status => <<"notok">>,
                line => Line,
                failing_step =>
                    list_to_binary(damage_utils:lists_concat(Step, " ")),
                reason => FailReason
            }};
        %% Failed run map. This must come before report_hash success,
        %% because damage:execute_data/3 may still return hashes for failed runs.
        #{fail := FailReason, failing_step := {_KeyWord, Line, Step, _Args}} ->
            {400, #{
                status => <<"notok">>,
                line => Line,
                failing_step =>
                    list_to_binary(damage_utils:lists_concat(Step, " ")),
                reason => FailReason
            }};
        #{fail := FailReason} = Result ->
            {400,
                maps:merge(Result, #{
                    status => <<"notok">>,
                    reason => FailReason
                })};
        %% Current RunRecord may carry result instead of fail.
        #{result := Result0} = Result when
            Result0 =/= <<"success">>,
            Result0 =/= "success",
            Result0 =/= success
        ->
            {400,
                maps:merge(Result, #{
                    status => <<"notok">>,
                    reason => Result0
                })};
        %% Parser/lexer error with pretty message
        {parse_error, LineNo, MessagePretty} ->
            formatter:format(Config, error, {LineNo, MessagePretty}),
            ?LOG_ERROR("Fail parse_error ~p ~p", [LineNo, MessagePretty]),
            {400, #{
                status => <<"notok">>,
                message => MessagePretty,
                line => LineNo
            }};
        %% Dry run success (explicit match on dry_run := true)
        #{dry_run := true, report_hash := _, cost := Cost} = Result ->
            {200, add_cost_units(maps:merge(Result, #{status => <<"ok">>, cost => Cost}))};
        %% Successful run (non-dry). We don't guard; the dry-run clause above
        %% already caught the dry-run case.
        #{report_hash := _} = Result ->
            {200, maps:merge(Result, #{status => <<"ok">>})};
        {error, {context_scope_unavailable, Scope, Reason}} ->
            {503, #{
                status => <<"notok">>,
                error => <<"CONTEXT_SCOPE_UNAVAILABLE">>,
                message => <<"Required context scope is unavailable.">>,
                scope => to_bin(io_lib:format("~p", [Scope])),
                reason => to_bin(io_lib:format("~p", [Reason]))
            }};
        {error, {context_ipfs_publish_failed, Reason}} ->
            {500, #{
                status => <<"notok">>,
                error => <<"CONTEXT_IPFS_PUBLISH_FAILED">>,
                message =>
                    <<"Context proof could not be published to IPFS; report was not published.">>,
                reason => to_bin(io_lib:format("~p", [Reason]))
            }};
        {error, {context_proof_write_failed, Reason}} ->
            {500, #{
                status => <<"notok">>,
                error => <<"CONTEXT_PROOF_WRITE_FAILED">>,
                message => <<"Context proof could not be written; report was not published.">>,
                reason => to_bin(io_lib:format("~p", [Reason]))
            }};
        %% Anything unexpected
        Error ->
            ?LOG_ERROR("execute_bdd unexpected failure ~p.", [Error]),
            {500, #{
                status => <<"notok">>,
                message => to_bin(io_lib:format("~p", [Error])),
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
    try
        %% Build and freeze effective context once for both dry and paid runs.
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
                        {200, add_cost_units(DryRes)};
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

                        Charge = charge_hits(Cost),

                        ?LOG_INFO("has_enough_damage ~p ~p", [AeAccount, Charge]),
                        case damage_balance_cache:has_enough_damage(AeAccount, Charge) of
                            {ok, _Balance, _BalanceSnapshot} ->
                                %% Original execution path for both normal auth and
                                %% L402 auth. L402 auth has already mapped State to
                                %% the configured l402_account in damage_auth.
                                RunConfig0 = get_config(ConfigOverrides, ContextIn, Req0),
                                RunConfig = [{defer_summary, true} | RunConfig0],
                                case execute_bdd_once(RunConfig, ContextIn, FeatureData) of
                                    {RunStatus, #{report_hash := _} = Result0} when
                                        RunStatus =:= 200; RunStatus =:= 400
                                    ->
                                        %% Only published runs enter settlement. Feature
                                        %% assertion failures remain billable when the runner
                                        %% produced a committed report; infrastructure failures
                                        %% and non-publishable errors return immediately.
                                        case safe_confirm_spend(RunConfig, Result0) of
                                            {ok, Spend, TxHash} ->
                                                ?LOG_INFO("Result ~p", [Spend]),
                                                Result1 =
                                                    maps:put(
                                                        tx_hash,
                                                        to_bin(TxHash),
                                                        maps:put(spend, Spend, Result0)
                                                    ),
                                                Result2 = maps:put(cost, Cost, Result1),
                                                Summary0 = add_cost_units(
                                                    maybe_l402_result_meta(ContextIn, Result2)
                                                ),
                                                Summary = Summary0#{
                                                    status => maps:get(status, Summary0, <<"ok">>),
                                                    result => maps:get(
                                                        result, Summary0, <<"success">>
                                                    ),
                                                    public_key => AeAccount
                                                },
                                                formatter:format(
                                                    RunConfig,
                                                    summary,
                                                    Summary
                                                ),
                                                {RunStatus, Summary};
                                            {pending, TxHash, ChainError} ->
                                                ?LOG_WARNING(
                                                    "confirm spend pending account=~p tx_hash=~p error=~p",
                                                    [AeAccount, TxHash, ChainError]
                                                ),
                                                Pending0 =
                                                    add_cost_units(
                                                        maybe_l402_result_meta(
                                                            ContextIn,
                                                            maps:put(cost, Cost, Result0)
                                                        )
                                                    ),
                                                Pending = Pending0#{
                                                    status => <<"pending">>,
                                                    result => maps:get(
                                                        result, Pending0, <<"success">>
                                                    ),
                                                    settlement_status => <<"pending">>,
                                                    error => <<"CONFIRM_SPEND_PENDING">>,
                                                    message =>
                                                        <<
                                                            "Execution completed and the spend transaction was submitted, "
                                                            "but it was not mined before the confirmation timeout. "
                                                            "Do not rerun the feature; verify tx_hash before retrying settlement."
                                                        >>,
                                                    tx_hash => to_bin(TxHash),
                                                    public_key => AeAccount,
                                                    retry_feature => false,
                                                    chain_reason => confirm_spend_reason(ChainError)
                                                },
                                                formatter:format(RunConfig, summary, Pending),
                                                {202, Pending};
                                            {error, insufficient_balance, Spend, ChainError} ->
                                                ?LOG_WARNING(
                                                    "confirm spend insufficient balance account=~p spend=~p error=~p",
                                                    [AeAccount, Spend, ChainError]
                                                ),
                                                {402, #{
                                                    status => <<"notok">>,
                                                    error => <<"ACCOUNT_INSUFFICIENT_BALANCE">>,
                                                    message => insufficient_balance_message(
                                                        ContextIn
                                                    ),
                                                    balance => damage_balance_cache:execution_damage_balance(
                                                        AeAccount
                                                    ),
                                                    required => Spend,
                                                    required_damage => cost_hits_to_damage(Spend),
                                                    required_sats => cost_hits_to_sats(Spend),
                                                    chain_reason => confirm_spend_reason(ChainError)
                                                }};
                                            {error, Reason, Spend, ChainError} ->
                                                ?LOG_ERROR(
                                                    "confirm spend failed account=~p spend=~p reason=~p error=~p",
                                                    [AeAccount, Spend, Reason, ChainError]
                                                ),
                                                {500, #{
                                                    status => <<"notok">>,
                                                    error => <<"CONFIRM_SPEND_FAILED">>,
                                                    reason => confirm_spend_reason(Reason),
                                                    required => Spend,
                                                    required_damage => cost_hits_to_damage(Spend),
                                                    required_sats => cost_hits_to_sats(Spend),
                                                    chain_reason => confirm_spend_reason(ChainError)
                                                }};
                                            {exception, Class, Reason, Stack} ->
                                                ?LOG_ERROR(
                                                    "confirm spend crashed account=~p error=~p:~p stack=~p",
                                                    [AeAccount, Class, Reason, Stack]
                                                ),
                                                {500, #{
                                                    status => <<"notok">>,
                                                    error => <<"CONFIRM_SPEND_CRASH">>,
                                                    class => to_bin(Class),
                                                    reason => confirm_spend_reason(Reason)
                                                }};
                                            Other ->
                                                ?LOG_ERROR(
                                                    "confirm spend unexpected result account=~p result=~p",
                                                    [AeAccount, Other]
                                                ),
                                                {500, #{
                                                    status => <<"notok">>,
                                                    error => <<"CONFIRM_SPEND_UNEXPECTED_RESULT">>,
                                                    reason => confirm_spend_reason(Other)
                                                }}
                                        end;
                                    {RunStatus, RunError} ->
                                        {RunStatus, RunError}
                                end;
                            {error, insufficient_damage, Balance, _BalanceSnapshot} ->
                                {402, #{
                                    status => <<"notok">>,
                                    message => insufficient_balance_message(ContextIn),
                                    balance => Balance,
                                    required => Charge,
                                    required_damage => cost_hits_to_damage(Charge),
                                    required_sats => cost_hits_to_sats(Charge)
                                }}
                        end
                end;
            %% Dry run failed; bubble it up as-is
            {DryCode, DryRes} ->
                {DryCode, DryRes}
        end
    catch
        error:{context_scope_unavailable, Scope, Reason0}:Stacktrace ->
            ?LOG_ERROR(
                "Context preparation failed scope=~p reason=~p stack=~p",
                [Scope, Reason0, Stacktrace]
            ),
            {503, #{
                status => <<"notok">>,
                error => <<"CONTEXT_SCOPE_UNAVAILABLE">>,
                message => <<"Required context scope is unavailable.">>,
                scope => to_bin(io_lib:format("~p", [Scope])),
                reason => to_bin(io_lib:format("~p", [Reason0]))
            }}
    end.

%% Build one immutable scoped execution context after authentication. Internal
%% preparation/proof fields are never accepted from the request body.
-spec effective_context(map(), map()) -> map().
effective_context(Context0, State) ->
    ClientContext = maps:without(internal_context_keys(), Context0),
    Ctx1 = maps:merge(ClientContext, State),
    damage_context:prepare_run_context(Ctx1).

internal_context_keys() ->
    Atoms = [
        damage_context_effective,
        context_proofs,
        context_ipfs_hash,
        context_ipfs_uri,
        context_ipfs_url,
        context_url,
        account_context,
        node_context
    ],
    Atoms ++ [atom_to_binary(Key, utf8) || Key <- Atoms].

%% Helper: true iff overrides explicitly request dry-run only
-spec dry_run_only(proplists:proplist()) -> boolean().
dry_run_only(Overrides) ->
    proplists:get_value(dry_run, Overrides, false) =:= true.

maybe_l402_result_meta(#{auth_type := l402} = Context, Result) ->
    maps:merge(
        Result,
        #{
            payment_type => <<"l402">>,
            l402_payment_hash_hex => maps:get(l402_payment_hash_hex, Context, <<>>)
        }
    );
maybe_l402_result_meta(_Context, Result) ->
    Result.

insufficient_balance_message(#{auth_type := l402}) ->
    <<"Configured l402_account has insufficient DAMAGE balance for execution">>;
insufficient_balance_message(_Context) ->
    <<"Insufficient balance, please top up at `/api/accounts/topup`">>.

charge_hits(Value) when is_integer(Value) ->
    Value;
charge_hits(Value) when is_float(Value) ->
    ceil_damage(Value);
charge_hits(Value) when is_binary(Value) ->
    binary_to_integer(Value);
charge_hits(Value) when is_list(Value) ->
    list_to_integer(Value);
charge_hits(_) ->
    0.

safe_confirm_spend(Config, Result) ->
    try damage_ae:confirm_spend(Config, Result) of
        Reply ->
            Reply
    catch
        exit:Reason:Stack ->
            case confirm_spend_pending(Reason) of
                {ok, TxHash, ChainError} ->
                    {pending, TxHash, ChainError};
                error ->
                    {exception, exit, Reason, Stack}
            end;
        Class:Reason:Stack ->
            {exception, Class, Reason, Stack}
    end.

confirm_spend_pending(
    {timeout_error, {polling_failed, ChainError, _PollFun, [TxHash]}}
) ->
    {ok, TxHash, ChainError};
confirm_spend_pending(
    {
        {timeout_error, {polling_failed, ChainError, _PollFun, [TxHash]}},
        {gen_server, call, _Call}
    }
) ->
    {ok, TxHash, ChainError};
confirm_spend_pending(_) ->
    error.

confirm_spend_reason({error, Reason}) ->
    confirm_spend_reason(Reason);
confirm_spend_reason(#{"return_value" := Reason}) ->
    confirm_spend_reason(Reason);
confirm_spend_reason(#{<<"return_value">> := Reason}) ->
    confirm_spend_reason(Reason);
confirm_spend_reason(Value) when is_binary(Value) ->
    Value;
confirm_spend_reason(Value) when is_atom(Value) ->
    atom_to_binary(Value, utf8);
confirm_spend_reason(Value) when is_integer(Value) ->
    integer_to_binary(Value);
confirm_spend_reason(Value) when is_list(Value) ->
    try unicode:characters_to_binary(Value) of
        Bin when is_binary(Bin) -> Bin
    catch
        _:_ -> iolist_to_binary(io_lib:format("~p", [Value]))
    end;
confirm_spend_reason(Value) ->
    iolist_to_binary(io_lib:format("~p", [Value])).
cost_hits_to_damage(CostHits) when is_integer(CostHits); is_float(CostHits) ->
    CostHits / math:pow(10, ?DAMAGE_DECIMALS);
cost_hits_to_damage(_) ->
    0.

cost_hits_to_sats(CostHits) ->
    Damage = cost_hits_to_damage(CostHits),
    try price_feed:damage_to_sats(Damage) of
        Sats -> Sats
    catch
        Class:Reason ->
            ?LOG_WARNING(
                "Failed to convert cost to sats cost_hits=~p damage=~p error=~p:~p",
                [CostHits, Damage, Class, Reason]
            ),
            undefined
    end.

add_cost_units(#{cost := Cost} = Result) ->
    CostDamage = cost_hits_to_damage(Cost),
    CostSats = cost_hits_to_sats(Cost),
    Result#{
        cost_hits => Cost,
        cost_damage => CostDamage,
        cost_sats => CostSats,
        cost_btc => sats_to_btc(CostSats),
        cost_ae => cost_to_ae(CostDamage, CostSats)
    };
add_cost_units(#{spend := Spend} = Result) ->
    add_cost_units(maps:put(cost, Spend, Result));
add_cost_units(Result) ->
    Result.

sats_to_btc(Sats) when is_integer(Sats); is_float(Sats) ->
    Sats / 100000000;
sats_to_btc(_) ->
    undefined.

cost_to_ae(Damage, Sats) when
    (is_integer(Damage) orelse is_float(Damage)),
    (is_integer(Sats) orelse is_float(Sats))
->
    case code:ensure_loaded(price_feed) of
        {module, price_feed} ->
            cost_to_ae_loaded(Damage, Sats);
        Error ->
            ?LOG_WARNING(
                "Cannot convert execution cost to AE: price_feed unavailable error=~p",
                [Error]
            ),
            undefined
    end;
cost_to_ae(_, _) ->
    undefined.

cost_to_ae_loaded(Damage, Sats) ->
    case erlang:function_exported(price_feed, damage_to_ae, 1) of
        true ->
            safe_ae_conversion(
                fun() -> price_feed:damage_to_ae(Damage) end,
                damage_to_ae
            );
        false ->
            cost_sats_to_ae(Sats)
    end.

cost_sats_to_ae(Sats) ->
    case erlang:function_exported(price_feed, sats_to_ae, 1) of
        true ->
            safe_ae_conversion(
                fun() -> price_feed:sats_to_ae(Sats) end,
                sats_to_ae
            );
        false ->
            cost_sats_to_ae_using_unit_price(Sats)
    end.

cost_sats_to_ae_using_unit_price(Sats) ->
    case erlang:function_exported(price_feed, ae_to_sats, 1) of
        true ->
            safe_ae_conversion(
                fun() ->
                    case price_feed:ae_to_sats(1) of
                        AeSats when is_integer(AeSats), AeSats > 0 ->
                            Sats / AeSats;
                        AeSats when is_float(AeSats), AeSats > 0 ->
                            Sats / AeSats;
                        Unexpected ->
                            {error, {invalid_ae_sats_price, Unexpected}}
                    end
                end,
                ae_to_sats
            );
        false ->
            ?LOG_WARNING(
                "Cannot convert execution cost to AE: price_feed exports none of "
                "damage_to_ae/1, sats_to_ae/1 or ae_to_sats/1",
                []
            ),
            undefined
    end.

safe_ae_conversion(Fun, Conversion) ->
    try Fun() of
        Ae when is_integer(Ae); is_float(Ae) ->
            Ae;
        {error, Reason} ->
            ?LOG_WARNING(
                "AE cost conversion failed conversion=~p reason=~p",
                [Conversion, Reason]
            ),
            undefined;
        Unexpected ->
            ?LOG_WARNING(
                "Unexpected AE cost conversion result conversion=~p result=~p",
                [Conversion, Unexpected]
            ),
            undefined
    catch
        Class:Reason:Stack ->
            ?LOG_WARNING(
                "AE cost conversion crashed conversion=~p error=~p:~p stack=~p",
                [Conversion, Class, Reason, Stack]
            ),
            undefined
    end.

ceil_damage(Value) when is_integer(Value) ->
    Value;
ceil_damage(Value) when is_float(Value) ->
    Trunc = trunc(Value),
    case Value > Trunc of
        true -> Trunc + 1;
        false -> Trunc
    end;
ceil_damage(_) ->
    0.

decode_json(Data) ->
    try
        {ok, jsx:decode(Data, [{labels, atom}, return_maps])}
    catch
        Class:Reason:Stack ->
            {error, {Class, Reason, Stack}}
    end.
%% Runtime context accepted by execution endpoints.
%%
%% JSON:
%%   {"feature":"...", "context":{"server":"https://example.com"}}
%%
%% text/plain / form POST:
%%   X-Damage-Context: {"server":"https://example.com"}
%%   X-Damage-Context-region: au
%%
%% Explicit request control fields win over nested/header context so context
%% cannot replace feature, concurrency, stream, channel_id, signed_tx, etc.
normalize_execution_json_context(Json0) when is_map(Json0) ->
    Runtime0 =
        case maps:find(context, Json0) of
            {ok, ContextValue} ->
                ContextValue;
            error ->
                case maps:find(<<"context">>, Json0) of
                    {ok, BinaryContextValue} ->
                        BinaryContextValue;
                    error ->
                        case maps:find(runtime_context, Json0) of
                            {ok, RuntimeValue} -> RuntimeValue;
                            error -> maps:get(<<"runtime_context">>, Json0, undefined)
                        end
                end
        end,
    Base = maps:without([context, <<"context">>, runtime_context, <<"runtime_context">>], Json0),
    case Runtime0 of
        undefined ->
            {ok, Base};
        Runtime when is_map(Runtime) ->
            case normalize_runtime_context_map(Runtime) of
                {ok, NormalizedRuntime0} ->
                    %% Outer request fields always win, including arbitrary
                    %% runtime fields whose atom/binary representations differ.
                    BaseKeys = [
                        normalize_runtime_context_key(Key)
                     || Key <- maps:keys(Base)
                    ],
                    NormalizedRuntime = maps:without(BaseKeys, NormalizedRuntime0),
                    {ok, maps:merge(NormalizedRuntime, Base)};
                {error, _} = Error ->
                    Error
            end;
        _ ->
            {error, <<"context must be a JSON object">>}
    end.

normalize_runtime_context_map(Map) when is_map(Map) ->
    maps:fold(fun normalize_runtime_context_entry/3, {ok, #{}}, Map).

normalize_runtime_context_entry(_Key0, _Value, {error, _} = Error) ->
    Error;
normalize_runtime_context_entry(Key0, Value, {ok, Acc}) ->
    Key = normalize_runtime_context_key(Key0),
    case runtime_context_key_allowed(Key) of
        false ->
            {error, <<"runtime context key is reserved: ", Key/binary>>};
        true ->
            case maps:is_key(Key, Acc) of
                true ->
                    {error, <<"duplicate runtime context key after normalization: ", Key/binary>>};
                false ->
                    {ok, maps:put(Key, Value, Acc)}
            end
    end.

normalize_runtime_context_key(Key) when is_binary(Key) -> Key;
normalize_runtime_context_key(Key) when is_atom(Key) -> atom_to_binary(Key, utf8);
normalize_runtime_context_key(Key) when is_list(Key) -> unicode:characters_to_binary(Key);
normalize_runtime_context_key(Key) -> to_bin(Key).

runtime_context_key_allowed(Key) ->
    Lower = list_to_binary(string:lowercase(binary_to_list(Key))),
    not lists:member(Lower, runtime_context_forbidden_keys()).

runtime_context_forbidden_keys() ->
    [
        <<"feature">>,
        <<"feature_cid">>,
        <<"vars">>,
        <<"stream">>,
        <<"dry_run">>,
        <<"concurrency">>,
        <<"continue_on_fail">>,
        <<"color_formatter">>,
        <<"channel_id">>,
        <<"signed_tx">>,
        <<"unsigned_tx">>,
        <<"tx">>,
        <<"action">>,
        <<"payfor">>,
        <<"signature">>,
        <<"message">>,
        <<"pubkey">>,
        <<"address">>,
        <<"public_key">>,
        <<"private_key">>,
        <<"access_token">>,
        <<"auth_type">>,
        <<"username">>,
        <<"node_public_key">>,
        <<"token_contract">>,
        <<"run_id">>,
        <<"run_dir">>,
        <<"report_hash">>,
        <<"report_dir">>,
        <<"feature_hash">>,
        <<"context">>,
        <<"runtime_context">>,
        <<"context_scopes">>,
        <<"context_proofs">>,
        <<"context_redactions">>,
        <<"context_redaction_ref">>,
        <<"damage_context_effective">>,
        <<"account_context">>,
        <<"node_context">>,
        <<"context_ipfs_hash">>,
        <<"context_ipfs_uri">>,
        <<"context_ipfs_url">>,
        <<"context_url">>,
        <<"l402">>,
        <<"l402_macaroon">>,
        <<"l402_payment_hash_hex">>
    ].

runtime_context_from_headers(Req) ->
    case runtime_context_json_header(Req) of
        {ok, Base} ->
            Headers = cowboy_req:headers(Req),
            Prefix = <<"x-damage-context-">>,
            PrefixSize = byte_size(Prefix),
            PerKey =
                maps:fold(
                    fun(Name, Value, Acc) ->
                        case Name of
                            <<Prefix:PrefixSize/binary, Key/binary>> when Key =/= <<>> ->
                                maps:put(Key, decode_header_context_value(Value), Acc);
                            _ ->
                                Acc
                        end
                    end,
                    #{},
                    Headers
                ),
            normalize_runtime_context_map(maps:merge(Base, PerKey));
        {error, _} = Error ->
            Error
    end.

runtime_context_json_header(Req) ->
    case cowboy_req:header(<<"x-damage-context">>, Req, undefined) of
        undefined ->
            {ok, #{}};
        <<>> ->
            {ok, #{}};
        Header ->
            try jsx:decode(Header, [return_maps]) of
                Map when is_map(Map) ->
                    {ok, Map};
                _ ->
                    {error, <<"x-damage-context must contain a JSON object">>}
            catch
                _:_ ->
                    {error, <<"x-damage-context contains invalid JSON">>}
            end
    end.

decode_header_context_value(Value) ->
    try jsx:decode(Value, [return_maps]) of
        Decoded -> Decoded
    catch
        _:_ -> Value
    end.

runtime_context_error_reply(Req, State, Reason) ->
    Body = jsx:encode(#{
        status => <<"notok">>,
        error => <<"INVALID_RUNTIME_CONTEXT">>,
        message => Reason
    }),
    Req1 = cowboy_req:reply(
        400,
        #{<<"content-type">> => <<"application/json">>},
        Body,
        Req
    ),
    {stop, Req1, State}.

json_decode_failed(Req, State, Prefix, {Class, Reason, Stack}) ->
    ?LOG_ERROR("~s ~p:~p ~p", [Prefix, Class, Reason, Stack]),
    Req1 = cowboy_req:reply(
        400,
        #{<<"content-type">> => <<"text/plain">>},
        <<"Json decoding failed.">>,
        Req
    ),
    {stop, Req1, State}.

%% Streaming responses already emit human-readable formatter output while the
%% run executes. Successful executions already end with the formatted summary,
%% so do not append the result map or another summary-like footer.
%%
%% Structured results are still returned by the non-streaming JSON response
%% path. Pending/error streamed executions retain a compact diagnostic footer.
stream_final_body(200, Resp) when is_map(Resp) ->
    <<>>;
stream_final_body(Status, Resp) when is_map(Resp) ->
    stream_map_footer(Status, Resp);
stream_final_body(Status, Resp) when is_binary(Resp) ->
    case stream_blank(Resp) of
        true ->
            case status_success(Status) of
                true -> <<>>;
                false -> stream_map_footer(Status, #{})
            end;
        false ->
            Resp
    end;
stream_final_body(Status, Resp) ->
    stream_map_footer(Status, #{response => Resp}).

stream_map_footer(Status, Resp) ->
    iolist_to_binary([
        "\n---\n",
        "status: ",
        printable_stream_value(stream_status_value(Status, Resp)),
        "\n",
        "http_status: ",
        status_to_iodata(Status),
        "\n",
        stream_line("message: ", stream_map_get([message, <<"message">>], Resp)),
        stream_line("reason: ", stream_map_get([reason, <<"reason">>], Resp)),
        stream_line("error: ", stream_map_get([error, <<"error">>], Resp)),
        stream_line("failing_step: ", stream_map_get([failing_step, <<"failing_step">>], Resp)),
        stream_line("line: ", stream_map_get([line, <<"line">>], Resp)),
        stream_line(
            "result: ",
            stream_map_get([result, <<"result">>, result_status, <<"result_status">>], Resp)
        ),
        stream_line("run_id: ", stream_map_get([run_id, <<"run_id">>], Resp)),
        stream_line("feature_hash: ", stream_map_get([feature_hash, <<"feature_hash">>], Resp)),
        stream_line("report_hash: ", stream_map_get([report_hash, <<"report_hash">>], Resp)),
        stream_line("report: ", stream_map_get([report_dir, <<"report_dir">>], Resp)),
        stream_line(
            "context: ",
            stream_map_get(
                [context_url, <<"context_url">>, context_ipfs_url, <<"context_ipfs_url">>],
                Resp
            )
        ),
        stream_line("tx_hash: ", stream_map_get([tx_hash, <<"tx_hash">>], Resp)),
        stream_line("balance: ", stream_map_get([balance, <<"balance">>], Resp)),
        stream_line("required: ", stream_map_get([required, <<"required">>], Resp)),
        stream_line(
            "required_damage: ", stream_map_get([required_damage, <<"required_damage">>], Resp)
        ),
        stream_line("required_sats: ", stream_map_get([required_sats, <<"required_sats">>], Resp)),
        stream_line("spend: ", stream_map_get([spend, <<"spend">>], Resp)),
        stream_line("response: ", stream_map_get([response, <<"response">>], Resp)),
        "\n"
    ]).

stream_status_value(Status, Resp) ->
    case stream_map_get([status, <<"status">>], Resp) of
        {ok, Value} ->
            Value;
        none ->
            case status_success(Status) of
                true -> <<"ok">>;
                false -> <<"notok">>
            end
    end.

stream_line(_Label, none) ->
    [];
stream_line(Label, {ok, Value}) ->
    [Label, printable_stream_value(Value), "\n"].

stream_map_get([], _Map) ->
    none;
stream_map_get([Key | Rest], Map) ->
    case maps:find(Key, Map) of
        {ok, Value} ->
            case stream_blank(Value) of
                true -> stream_map_get(Rest, Map);
                false -> {ok, Value}
            end;
        error ->
            stream_map_get(Rest, Map)
    end.

stream_blank(undefined) ->
    true;
stream_blank(null) ->
    true;
stream_blank(false) ->
    true;
stream_blank(<<>>) ->
    true;
stream_blank("") ->
    true;
stream_blank(_) ->
    false.

status_success(Status) when is_integer(Status), Status >= 200, Status < 300 ->
    true;
status_success(_Status) ->
    false.

status_to_iodata(Status) when is_integer(Status) ->
    integer_to_list(Status);
status_to_iodata(Status) ->
    io_lib:format("~p", [Status]).

printable_stream_value(Value) when is_binary(Value) ->
    Value;
printable_stream_value(Value) when is_integer(Value) ->
    integer_to_binary(Value);
printable_stream_value(Value) when is_float(Value) ->
    list_to_binary(io_lib:format("~p", [Value]));
printable_stream_value(Value) when is_list(Value) ->
    try unicode:characters_to_binary(Value) of
        Bin when is_binary(Bin) ->
            Bin
    catch
        _:_ ->
            iolist_to_binary(io_lib:format("~p", [Value]))
    end;
printable_stream_value(Value) when is_atom(Value) ->
    atom_to_binary(Value, utf8);
printable_stream_value(Value) ->
    iolist_to_binary(io_lib:format("~p", [Value])).

execution_context_from_request(Json, Overrides) ->
    Runtime = maps:without(execution_request_internal_keys(), Json),
    maps:merge(Runtime, Overrides).

execution_request_internal_keys() ->
    [
        feature,
        <<"feature">>,
        concurrency,
        <<"concurrency">>,
        stream,
        <<"stream">>,
        color_formatter,
        <<"color_formatter">>,
        signed_tx,
        <<"signed_tx">>,
        unsigned_tx,
        <<"unsigned_tx">>,
        address,
        <<"address">>,
        action,
        <<"action">>,
        payfor,
        <<"payfor">>,
        signature,
        <<"signature">>,
        message,
        <<"message">>,
        pubkey,
        <<"pubkey">>,
        tx,
        <<"tx">>
    ].

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
    Responder = NodePub,

    case
        damage_channels:build_channel_create_tx(
            Ini, Responder, IniAmt, ResAmt, Reserve, Lock, TTL, Fee
        )
    of
        {ok, #{tx := Unsigned, tx_hash := TxHash}} ->
            Reply = #{
                status => <<"ok">>,
                tx => Unsigned,
                tx_hash => to_bin(TxHash),
                responder => Responder
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
    } = Json,
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
        "return_type" := <<"ok">>,
        "return_value" := {}
    } = damage_ae:wait_tx(ContractCallTxHash),
    ExecutionContext = execution_context_from_request(
        Json,
        #{
            feature => FeatureData,
            color_formatter => maps:get(color_formatter, Json, false),
            concurrency => Concurrency,
            stream => maps:get(stream, Json, maybe_stream)
        }
    ),
    case
        execute_bdd(
            ExecutionContext,
            maps:put(public_key, AeAccount, State),
            Req
        )
    of
        {Status, Response} ->
            {Status, Response}
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
            case decode_json(Message) of
                {ok, #{amount := Amount}} ->
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
                        Invoice = damage_cln:create_invoice(
                            Amount * 1000, Description, 3600, Label
                        ),
                    ?LOG_INFO("invoice ~p", [Invoice]),
                    {
                        200,
                        #{payment_request => Bolt11}
                    };
                {ok, DecodeOther} ->
                    {
                        400,
                        #{message => DecodeOther}
                    };
                {error, {Class, DecodeReason, Stack}} ->
                    ?LOG_ERROR("Json decoding failed ~p:~p ~p", [Class, DecodeReason, Stack]),
                    {
                        400,
                        #{message => <<"Json decoding failed.">>}
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
from_json(Req0, #{action := tx} = State) ->
    {ok, Data, Req1} = cowboy_req:read_body(Req0),
    case decode_json(Data) of
        {error, DecodeError} ->
            json_decode_failed(Req1, State, "Json decoding failed", DecodeError);
        {ok, Json0} when is_map(Json0) ->
            case normalize_execution_json_context(Json0) of
                {ok, Json} ->
                    {Status0, Response0} = do_action_tx_throttled(Json, State, Req1),
                    {
                        stop,
                        cowboy_req:reply(
                            Status0,
                            cowboy_req:set_resp_body(jsx:encode(Response0), Req1)
                        ),
                        State
                    };
                {error, Reason} ->
                    runtime_context_error_reply(Req1, State, Reason)
            end;
        {ok, _Other} ->
            Req2 = cowboy_req:reply(
                400,
                #{<<"content-type">> => <<"text/plain">>},
                <<"Missing or invalid JSON payload.">>,
                Req1
            ),
            {stop, Req2, State}
    end;
from_json(Req0, State) ->
    {ok, Data, Req1} = cowboy_req:read_body(Req0),
    case decode_json(Data) of
        {error, DecodeError} ->
            json_decode_failed(Req1, State, "JSON decoding failed", DecodeError);
        {ok, Json0} when is_map(Json0) ->
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

            case normalize_execution_json_context(Json) of
                {ok, ExecutionJson} ->
                    Stream = maps:get(stream, ExecutionJson, false),
                    case execute_bdd(ExecutionJson, State, Req1) of
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
                    end;
                {error, Reason} ->
                    runtime_context_error_reply(Req1, State, Reason)
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
        ContinueOnFail =
            case cowboy_req:header(<<"x-damage-continue-on-fail">>, Req1, <<"false">>) of
                <<"true">> -> true;
                <<"1">> -> true;
                _ -> false
            end,
        Stream = stream_mode(Req1, Concurrency),
        RuntimeContext =
            case runtime_context_from_headers(Req1) of
                {ok, HeaderContext} -> HeaderContext;
                {error, ContextReason} -> throw({invalid_runtime_context, ContextReason})
            end,

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
                    BaseContext = #{
                        feature => Body,
                        concurrency => Concurrency,
                        stream => maybe_stream,
                        continue_on_fail => ContinueOnFail,
                        color_formatter => ColorFormatter
                    },
                    {ReqS, maps:merge(RuntimeContext, BaseContext)};
                _ ->
                    BaseContext = #{
                        feature => Body,
                        concurrency => Concurrency,
                        stream => Stream,
                        continue_on_fail => ContinueOnFail,
                        color_formatter => ColorFormatter
                    },
                    {Req1, maps:merge(RuntimeContext, BaseContext)}
            end,

        case execute_bdd(Context, State, ReqRun) of
            {Status, Resp} when Stream =:= maybe_stream ->
                Req2 = cowboy_req:stream_body(stream_final_body(Status, Resp), fin, ReqRun),
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
        throw:{invalid_runtime_context, ContextReason0} ->
            runtime_context_error_reply(Req0, State, ContextReason0);
        Class:Reason:Stack ->
            ?LOG_ERROR("from_html crashed ~p:~p ~p", [Class, Reason, Stack]),
            %% Best effort: stream a 500 if we were streaming, else JSON 500
            Concurrency0 =
                try
                    binary_to_integer(
                        cowboy_req:header(<<"x-damage-concurrency">>, Req0, <<"1">>)
                    )
                catch
                    _:_ -> 1
                end,
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
to_html(Req, #{action := node_balances} = State) ->
    to_json(Req, State);
to_html(Req, State) ->
    Body = damage_utils:load_template("api.mustache", #{body => <<"Test">>}),
    {Body, Req, State}.

to_json(Req, #{action := version} = State) ->
    {
        jsx:encode(#{
            ok => true,
            version => damage:version()
        }),
        Req,
        State
    };
to_json(Req, #{action := node_balances} = State) ->

    case secrets:node_keypair() of
        #{public_key := PubKey, private_key := _NodePrivateKey} ->
            NodeDamageBalance = damage_ae:node_damage_balance(),
            NodeAeBalance = damage_ae:node_ae_balance(),
            NodeBtcBalance = damage_cln:get_node_balance(),
            {
                jsx:encode(#{
                    ok => true,
                    public_key => to_bin(PubKey),
                    damage_balance => NodeDamageBalance,
                    ae_balance => NodeAeBalance,
                    btc_balance => NodeBtcBalance
                }),
                Req,
                State
            };
        {error, Error} ->
            {
                jsx:encode(#{
                    ok => false,
                    error => to_bin(Error)
                }),
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
