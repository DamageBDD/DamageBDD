-module(damage_schedule).

-vsn("0.1.0").

-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/logger.hrl").
-include_lib("damage.hrl").

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-export([content_types_accepted/2]).
-export([content_types_provided/2]).
-export([to_json/2]).
-export([from_json/2, allowed_methods/2, from_html/2]).
-export([trails/0]).
-export([is_authorized/2]).
-export([execute_bdd/1]).
-export([schedule_job/1]).
-export([test_schedule/0]).
-export([test_list_schedule/0]).
-export([delete_resource/2]).

-behaviour(gen_server).

%% public API
-export([
    init/1,
    init/2,
    start_link/0,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3,

    set_contract/1,
    get_contract/0,
    clear_cache/0,
    clear_cache/1,

    %% user/account-level
    add_schedule/5,
    delete_schedule/2,
    delete_schedule_by_hash/2,
    get_schedules/1,
    list_schedules/1,

    %% node/admin-level
    get_schedules_for/1,
    list_schedules_for/1,
    list_all_schedules/0,
    mark_schedule_executed/3,
    load_all_schedules/0

    %% deployment / boot
]).
-import(damage_utils, [to_bin/1]).

-define(TRAILS_TAG, ["Scheduling Tests"]).
-define(SCHEDULES_CONTRACT,
    "ct_hCcHw4hNAkvbadmVrkCRQJxEqvx825hA4gL3gbf4Kh9hpRrwS"
).

%% Cache keys
-define(CK_GET_SCHEDULES(AeAccount), {get_schedules, AeAccount}).
-define(CK_LIST_SCHEDULES(AeAccount), {list_schedules, AeAccount}).
-define(CK_LIST_ALL_SCHEDULES, list_all_schedules).

-record(state, {
    ets_table,
    contract_id = undefined,
    contract_path = "contracts/schedules.aes",
    ttl_ms = 15000
}).

trails() ->
    [
        trails:trail(
            "/schedules/[...]",
            damage_schedule,
            #{},
            #{
                get =>
                    #{
                        tags => ?TRAILS_TAG,
                        description => "Form to schedule a test execution.",
                        produces => ["text/html"]
                    },
                put =>
                    #{
                        tags => ?TRAILS_TAG,
                        description => "Schedule a test on post",
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
                    },
                delete =>
                    #{
                        tags => ?TRAILS_TAG,
                        description => "Delete a scheduled job",
                        produces => ["application/json"],
                        parameters => []
                    }
            }
        )
    ].

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    process_flag(trap_exit, true),
    Tab = ets:new(?MODULE, [set, private]),
    {ok, #state{
        ets_table = Tab,
        contract_id = to_bin(get_schedules_contract())
    }}.
init(Req, Opts) -> {cowboy_rest, Req, Opts}.

is_authorized(Req, State) -> damage_http:is_authorized(Req, State).

content_types_provided(Req, State) ->
    {[{{<<"application">>, <<"json">>, []}, to_json}], Req, State}.

content_types_accepted(Req, State) ->
    {
        [
            {{<<"application">>, <<"x-www-form-urlencoded">>, '*'}, from_html},
            {{<<"application">>, <<"json">>, '*'}, from_json}
        ],
        Req,
        State
    }.

allowed_methods(Req, State) ->
    {[<<"GET">>, <<"POST">>, <<"DELETE">>], Req, State}.

delete_resource(Req, #{public_key := AeAccount} = State) ->
    Deleted =
        lists:foldl(
            fun(DeleteId, Acc) ->
                ?LOG_DEBUG("deleted ~p ~p", [maps:get(path_info, Req), DeleteId]),
                ok = delete_schedule(AeAccount, DeleteId),
                Acc + 1
            end,
            0,
            maps:get(path_info, Req)
        ),
    ?LOG_INFO("deleted ~p schedules", [Deleted]),
    {true, Req, State}.

from_text(Req, #{public_key := AeAccount} = State) ->
    ?LOG_DEBUG("From text ~p", [Req]),
    {ok, Body, _} = cowboy_req:read_body(Req),
    ok = validate(Body),
    CronSpec = binary_spec_to_term_spec(cowboy_req:path_info(Req), []),
    Concurrency = cowboy_req:header(<<"x-damage-concurrency">>, Req, 1),
    ?LOG_DEBUG("Cron Spec: ~p", [CronSpec]),
    {ok, [#{<<"Hash">> := Hash}]} =
        damage_ipfs:add({data, Body, <<"Scheduledjob">>}),
    Name = list_to_binary(uuid:to_string(uuid:uuid4())),
    Schedule =
        #{
            id => Name,
            public_key => AeAccount,
            feature_hash => Hash,
            concurrency => Concurrency,
            cron => CronSpec
        },
    case add_schedule(AeAccount, Name, CronSpec, Hash, Concurrency) of
        ok ->
            CronJob = schedule_job(Schedule),
            ?LOG_INFO("Cron Job: ~p", [CronJob]),
            Resp = cowboy_req:set_resp_body(jsx:encode(#{status => <<"ok">>}), Req),
            {stop, cowboy_req:reply(201, Resp), State};
        {error, Reason} ->
            Body = jsx:encode(#{
                status => <<"error">>,
                reason => iolist_to_binary(io_lib:format("~p", [Reason]))
            }),
            Req2 = cowboy_req:reply(
                500, #{<<"content-type">> => <<"application/json">>}, Body, Req
            ),
            {stop, Req2, State}
    end.

from_json(Req, State) -> from_text(Req, State).
from_html(Req, State) -> from_text(Req, State).

to_json(Req, #{public_key := AeAccount} = State) ->
    Schedules = list_schedules(AeAccount),
    Body =
        jsx:encode(
            #{status => <<"ok">>, results => Schedules, length => length(Schedules)}
        ),
    ?LOG_INFO("Loading scheduled for  ~p", [Body]),
    {Body, Req, State}.

execute_bdd(
    #{public_key := AeAccount, feature_hash := Hash, concurrency := Concurrency, id_hash := IdHash} =
        Schedule
) ->
    MinBalance = Concurrency * math:pow(10, ?DAMAGE_DECIMALS),
    case damage_ae:balance(AeAccount) of
        Balance when Balance >= MinBalance ->
            Config = damage_config:get_default_config([
                {public_key, AeAccount}, {concurrency, Concurrency}
            ]),
            Context = damage_context:get_context(Schedule),
            {run_dir, RunDir} = lists:keyfind(run_dir, 1, Config),
            {run_id, RunId} = lists:keyfind(run_id, 1, Config),
            BddFileName = filename:join(RunDir, string:join([RunId, ".feature"], "")),
            ok = damage_ipfs:get(Hash, BddFileName),
            ?LOG_DEBUG(
                "scheduled job execution ~p AeAccount ~p, Hash ~p Concurrency ~p Balance ~p.",
                [Schedule, AeAccount, Hash, Concurrency, Balance]
            ),
            Result = damage:execute_file(Config, Context, BddFileName),
            metrics:update(schedule_execution, {AeAccount, Hash}),
            case mark_schedule_executed(AeAccount, IdHash, erlang:system_time(millisecond)) of
                ok ->
                    Result;
                {ok, _} ->
                    Result;
                Error ->
                    error({mark_schedule_executed_failed, AeAccount, IdHash, Error})
            end;
        Other ->
            Msg =
                lists:flatten(
                    io_lib:format(
                        <<"Insufficient balance acc: ~p balance:~p">>,
                        [binary_to_list(AeAccount), Other]
                    )
                ),
            damage_accounts:notify_user(AeAccount, Msg),
            ?LOG_INFO(Msg),
            []
    end.

schedule_job(#{error := Reason} = Schedule) ->
    ?LOG_ERROR("Ignoring schedule with error ~p ~p", [Reason, Schedule]),
    ok;
schedule_job(#{public_key := Account, id := Id} = Schedule) ->
    damage_schedule_index:upsert_schedule(Account, Id, Schedule).

binary_spec_to_term_spec([], Acc) ->
    Acc;
binary_spec_to_term_spec([Spec | Rest], Acc) when is_integer(Spec) ->
    binary_spec_to_term_spec(Rest, Acc ++ [Spec]);
binary_spec_to_term_spec([Spec | Rest], Acc) ->
    Term =
        case catch binary_to_integer(Spec) of
            {'EXIT', _} -> binary_to_atom(Spec);
            Other -> Other
        end,
    binary_spec_to_term_spec(Rest, Acc ++ [Term]).

validate(Gherkin) ->
    case catch egherkin:parse(Gherkin) of
        {failed, LineNo, Message} ->
            ?LOG_ERROR("Parsing Failed LineNo +~p ~n     ~p.", [LineNo, Message]),
            {parse_error, LineNo, Message};
        {_LineNo, _Tags, _Feature, _Description, _BackGround, _Scenarios} ->
            ok
    end.

%% ------------------------------------------------------------------
%% Cached public readers
%% ------------------------------------------------------------------

list_schedules(AeAccount) ->
    gen_server:call(?MODULE, {list_schedules, AeAccount}, ?AE_TIMEOUT).

load_all_schedules() ->
    ?LOG_INFO("Loading all schedules into index ..."),
    lists:foreach(
        fun(AccountSchedules) ->
            lists:foreach(
                fun(S) ->
                    case is_valid_schedule(S) of
                        true ->
                            #{public_key := Account, id := Id} = S,
                            damage_schedule_index:upsert_schedule(Account, Id, S);
                        false ->
                            ok
                    end
                end,
                AccountSchedules
            )
        end,
        list_all_schedules()
    ).

is_valid_schedule(#{error := Reason} = S) ->
    ?LOG_ERROR("Skipping invalid schedule ~p reason ~p", [S, Reason]),
    false;
is_valid_schedule(#{cron := Cron}) when is_list(Cron) ->
    true;
is_valid_schedule(S) ->
    ?LOG_ERROR("Skipping malformed schedule ~p", [S]),
    false.

%% ------------------------------------------------------------------
%% Raw uncached fetchers
%% ------------------------------------------------------------------

list_schedules_uncached(AeAccount) ->
    case
        contract_call(
            AeAccount,
            "get_schedules",
            []
        )
    of
        #{decodedResult := Results} ->
            ?LOG_INFO("loaded schedules ~p", [Results]),
            load_account_schedules(AeAccount, Results);
        #{"return_value" := Results} ->
            ?LOG_INFO("loaded schedules raw ~p", [Results]),
            load_account_schedules(AeAccount, Results);
        Error ->
            ?LOG_ERROR("Failed to load schedules ~p ~p", [AeAccount, Error]),
            []
    end.

list_all_schedules_uncached() ->
    case
        damage_ae:contract_call(
            get_schedules_contract(),
            "contracts/schedules.aes",
            "get_all_schedules",
            []
        )
    of
        #{decoded_result := Results} ->
            decrypt_schedules(Results);
        #{<<"return_value">> := Results} ->
            decrypt_schedules(Results);
        #{"return_value" := Results} ->
            decrypt_schedules(Results);
        Error ->
            ?LOG_ERROR("schedules loading failed ~p", [Error]),
            []
    end.

%%--------------------------------------------------------------------
%% Decrypt schedules returned by the schedules contract.
%%--------------------------------------------------------------------
decrypt_schedules(EncryptedSchedules) when is_map(EncryptedSchedules) ->
    maps:fold(
        fun(AccountKey, SchedulesMap, Acc) ->
            Account = account_key_to_ak(AccountKey),
            [load_account_schedules(Account, SchedulesMap) | Acc]
        end,
        [],
        EncryptedSchedules
    );
decrypt_schedules(EncryptedSchedules) when is_list(EncryptedSchedules) ->
    lists:map(
        fun
            ([Account, Schedules]) ->
                ?LOG_DEBUG("Account ~p", [Account]),
                load_account_schedules(Account, Schedules);
            (Other) ->
                error({invalid_all_schedules_shape, Other})
        end,
        EncryptedSchedules
    ).

account_key_to_ak({address, PubKeyBin}) when is_binary(PubKeyBin) ->
    aeser_api_encoder:encode(account_pubkey, PubKeyBin);
account_key_to_ak(<<"ak_", _/binary>> = Ak) ->
    Ak;
account_key_to_ak(Other) ->
    Other.

delete_schedule(AeAccount, ScheduleId) ->
    #{
        "gas_price" := GasPrice,
        "gas_used" := GasUsed,
        "height" := Height,
        "return_type" := "ok",
        "return_value" := Deleted
    } =
        contract_call(
            AeAccount,
            "delete_schedule",
            [binary_to_list(ScheduleId)]
        ),
    damage_schedule_index:delete_schedule(AeAccount, ScheduleId),
    invalidate_schedule_cache(AeAccount),
    ?LOG_DEBUG(
        "call AE contract ~p deleted ~p gasprice ~p gasused ~p, height ~p",
        [AeAccount, Deleted, GasPrice, GasUsed, Height]
    ),
    {ok, Deleted}.

add_schedule(AeAccount, Name, Cron, FeatureHash, Concurrency) when is_binary(AeAccount) ->
    Result =
        contract_call(
            AeAccount,
            "add_schedule",
            [
                binary_to_list(secrets:salted_hash(Name)),
                binary_to_list(secrets:encrypt(jsx:encode(Cron))),
                binary_to_list(secrets:encrypt(FeatureHash)),
                Concurrency
            ]
        ),
    case Result of
        #{
            "caller_id" := CallerId,
            "gas_price" := GasPrice,
            "gas_used" := GasUsed,
            "return_type" := "ok"
        } ->
            invalidate_schedule_cache(AeAccount),
            damage_schedule_index:upsert_schedule(
                AeAccount,
                Name,
                #{
                    id => Name,
                    public_key => AeAccount,
                    feature_hash => FeatureHash,
                    concurrency => Concurrency,
                    cron => Cron
                }
            ),
            ?LOG_DEBUG(
                "call AE contract ~p caller ~p gasprice ~p gasused ~p",
                [AeAccount, CallerId, GasPrice, GasUsed]
            ),
            ok;
        #{"return_type" := ReturnType} ->
            ?LOG_ERROR("add_schedule failed ~p", [Result]),
            {error, {unexpected_return_type, ReturnType, Result}};
        {error, Reason} ->
            ?LOG_ERROR("add_schedule contract call error ~p", [Reason]),
            {error, Reason};
        Other ->
            ?LOG_ERROR("add_schedule unexpected result ~p", [Other]),
            {error, {unexpected_contract_result, Other}}
    end.

load_account_schedules(Account, Schedules0) ->
    Schedules = normalize_schedules(Schedules0),
    ?LOG_DEBUG("Account ~p Schedules ~p", [Account, Schedules]),
    lists:filtermap(
        fun
            (#{error := _} = Bad) ->
                ?LOG_ERROR("Skipping invalid schedule row for ~p: ~p", [Account, Bad]),
                false;
            (Entry) ->
                {true, parse_schedule_entry(Account, Entry)}
        end,
        Schedules
    ).

normalize_schedules(Schedules) when is_list(Schedules) ->
    Schedules;
normalize_schedules(Schedules) when is_map(Schedules) ->
    lists:map(fun normalize_schedule_kv/1, maps:to_list(Schedules)).

%% New contract shape with wrapped id hash
normalize_schedule_kv(
    {_Key,
        {tuple, {
            {bytes, IdHash},
            IdPlain,
            CronEnc,
            FeatureHashEnc,
            Concurrency,
            Created,
            LastExecutionTs,
            ExecutionCounter
        }}}
) ->
    {IdHash, IdPlain, CronEnc, FeatureHashEnc, Concurrency, Created, LastExecutionTs,
        ExecutionCounter};
%% New contract shape with plain id hash
normalize_schedule_kv(
    {_Key,
        {tuple, {
            IdHash,
            IdPlain,
            CronEnc,
            FeatureHashEnc,
            Concurrency,
            Created,
            LastExecutionTs,
            ExecutionCounter
        }}}
) ->
    {
        normalize_id(IdHash),
        IdPlain,
        CronEnc,
        FeatureHashEnc,
        Concurrency,
        Created,
        LastExecutionTs,
        ExecutionCounter
    };
%% Legacy shape: key is schedule hash, value stores only id/hash/plain cron/feature
normalize_schedule_kv(
    {Key,
        {tuple, {
            {bytes, IdHash},
            IdPlain,
            CronEnc,
            FeatureHashEnc
        }}}
) ->
    {
        normalize_legacy_id(Key, IdHash),
        IdPlain,
        CronEnc,
        FeatureHashEnc,
        1,
        undefined,
        undefined,
        0
    };
%% Legacy shape: plain id hash inside tuple
normalize_schedule_kv(
    {Key,
        {tuple, {
            IdHash,
            IdPlain,
            CronEnc,
            FeatureHashEnc
        }}}
) ->
    {
        normalize_legacy_id(Key, normalize_id(IdHash)),
        IdPlain,
        CronEnc,
        FeatureHashEnc,
        1,
        undefined,
        undefined,
        0
    };
normalize_schedule_kv(Bad) ->
    error({invalid_schedule_kv_shape, Bad}).

normalize_id({bytes, Bin}) -> Bin;
normalize_id(Bin) when is_binary(Bin) -> Bin;
normalize_id(Other) -> Other.

normalize_legacy_id({bytes, KeyBin}, _TupleId) when is_binary(KeyBin) ->
    KeyBin;
normalize_legacy_id(KeyBin, _TupleId) when is_binary(KeyBin) ->
    KeyBin;
normalize_legacy_id(_Key, TupleId) ->
    TupleId.
parse_schedule_entry(
    Account,
    {IdHash, IdPlain, CronEnc, FeatureHashEnc, Concurrency, Created, LastExecutionTs,
        ExecutionCounter} = Entry
) ->
    ?LOG_DEBUG("parse_schedule_entry ~p ~p", [Account, Entry]),
    CronRaw = secrets:decrypt(CronEnc),
    FeatureHash = secrets:decrypt(FeatureHashEnc),
    case decode_cron_spec(CronRaw) of
        {ok, CronSpec} ->
            #{
                id =>
                    case IdPlain of
                        undefined -> IdHash;
                        _ -> IdPlain
                    end,
                id_hash => IdHash,
                public_key => Account,
                concurrency => Concurrency,
                cron => CronSpec,
                feature_hash => FeatureHash,
                created => Created,
                last_execution_timestamp => decode_optional_int(LastExecutionTs),
                execution_counter => ExecutionCounter,
                contract_address => get_schedules_contract()
            };
        {error, Reason} ->
            ?LOG_ERROR("invalid cron for account ~p schedule ~p reason ~p", [
                Account, Entry, Reason
            ]),
            #{
                id =>
                    case IdPlain of
                        undefined -> IdHash;
                        _ -> IdPlain
                    end,
                id_hash => IdHash,
                public_key => Account,
                concurrency => Concurrency,
                feature_hash => FeatureHash,
                created => Created,
                last_execution_timestamp => decode_optional_int(LastExecutionTs),
                execution_counter => ExecutionCounter,
                contract_address => get_schedules_contract(),
                error => Reason
            }
    end.
decode_optional_int({variant, [0, 1], 0, {}}) -> undefined;
decode_optional_int({variant, [0, 1], 1, {V}}) -> V;
decode_optional_int({option, none}) -> undefined;
decode_optional_int({option, {some, V}}) -> V;
decode_optional_int(undefined) -> undefined;
decode_optional_int(V) -> V.

decode_cron_spec({bytes, Bin}) when is_binary(Bin) ->
    decode_cron_spec(Bin);
decode_cron_spec(Bin) when is_binary(Bin) ->
    case try_decode_json(Bin) of
        {ok, JsonTerms} ->
            try
                {ok, binary_spec_to_term_spec(JsonTerms, [])}
            catch
                Class:Reason:Stacktrace ->
                    ?LOG_ERROR(
                        "failed to decode json cron ~p class=~p reason=~p stack=~p",
                        [Bin, Class, Reason, Stacktrace]
                    ),
                    {error, {invalid_json_cron, Bin, Reason}}
            end;
        error ->
            parse_plain_cron(Bin)
    end;
decode_cron_spec(List) when is_list(List) ->
    try
        {ok, binary_spec_to_term_spec(List, [])}
    catch
        Class:Reason:Stacktrace ->
            ?LOG_ERROR(
                "failed to decode list cron ~p class=~p reason=~p stack=~p",
                [List, Class, Reason, Stacktrace]
            ),
            {error, {invalid_list_cron, List, Reason}}
    end;
decode_cron_spec(Other) ->
    {error, {invalid_cron_value, Other}}.

try_decode_json(Bin) ->
    try jsx:decode(Bin) of
        Json -> {ok, Json}
    catch
        _:_ -> error
    end.

parse_plain_cron(Bin) when is_binary(Bin) ->
    try
        Tokens0 = binary:split(Bin, <<" ">>, [global, trim_all]),
        Tokens = [cron_token(T) || T <- Tokens0, T =/= <<>>],
        {ok, binary_spec_to_term_spec(Tokens, [])}
    catch
        Class:Reason:Stacktrace ->
            ?LOG_ERROR(
                "failed to parse plain cron ~p class=~p reason=~p stack=~p",
                [Bin, Class, Reason, Stacktrace]
            ),
            {error, {invalid_plain_cron, Bin, Reason}}
    end.

cron_token(Bin) when is_binary(Bin) ->
    case catch binary_to_integer(Bin) of
        I when is_integer(I) ->
            I;
        _ ->
            binary_to_atom(string:lowercase(binary_to_list(Bin)))
    end.

%% ------------------------------------------------------------------
%% Cache helpers
%% ------------------------------------------------------------------

cache_get(Key, #state{ets_table = Tab, ttl_ms = TtlMs}) ->
    Now = erlang:monotonic_time(millisecond),
    case ets:lookup(Tab, Key) of
        [{Key, Ts, Val}] when (Now - Ts) =< TtlMs ->
            {hit, Val};
        [{Key, _Ts, _Val}] ->
            ets:delete(Tab, Key),
            miss;
        [] ->
            miss
    end.

cache_put(Key, Val, #state{ets_table = Tab}) ->
    Ts = erlang:monotonic_time(millisecond),
    ets:insert(Tab, {Key, Ts, Val}),
    ok.

cache_invalidate(Keys, #state{ets_table = Tab}) ->
    lists:foreach(fun(Key) -> ets:delete(Tab, Key) end, Keys),
    ok.

invalidate_schedule_cache(AeAccount) ->
    gen_server:cast(
        ?MODULE,
        {invalidate_cache_keys, [
            ?CK_GET_SCHEDULES(AeAccount),
            ?CK_LIST_SCHEDULES(AeAccount)
        ]}
    ),
    gen_server:cast(
        ?MODULE,
        {invalidate_cache_keys, [?CK_LIST_ALL_SCHEDULES]}
    ),
    ok.

handle_call({get_schedules, AeAccount}, _From, State) ->
    Key = ?CK_GET_SCHEDULES(AeAccount),
    case cache_get(Key, State) of
        {hit, Schedules} ->
            {reply, Schedules, State};
        miss ->
            #{decodedResult := Results} =
                damage_ae:contract_call_user_account(AeAccount, "get_schedules", []),
            Schedules =
                case Results of
                    M when is_map(M) ->
                        maps:from_list(
                            [
                                begin
                                    {tuple, {_Id, CronEnc, FeatureHashEnc}} = V,
                                    {
                                        secrets:decrypt(FeatureHashEnc),
                                        secrets:decrypt(CronEnc)
                                    }
                                end
                             || {_K, V} <- maps:to_list(M)
                            ]
                        );
                    L when is_list(L) ->
                        maps:from_list(
                            [
                                {
                                    secrets:decrypt(FeatureHashEncrypted),
                                    secrets:decrypt(CronEncrypted)
                                }
                             || [FeatureHashEncrypted, CronEncrypted] <- L
                            ]
                        )
                end,
            {reply, Schedules, cache_put(Key, Schedules, State)}
    end;
handle_call({set_contract, ContractId0}, _From, State) ->
    ContractId = to_bin(ContractId0),
    ets:delete_all_objects(State#state.ets_table),
    {reply, ok, State#state{contract_id = ContractId}};
handle_call(get_contract, _From, State) ->
    {reply, State#state.contract_id, State};
handle_call(clear_cache, _From, State) ->
    ets:delete_all_objects(State#state.ets_table),
    {reply, ok, State};
handle_call({clear_cache, Key}, _From, State) ->
    ets:delete(State#state.ets_table, Key),
    {reply, ok, State};
handle_call({get_schedules_for, AeAccount}, _From, State) ->
    Key = {get_schedules_for, AeAccount},
    case cache_get(Key, State) of
        {hit, Val} ->
            {reply, Val, State};
        miss ->
            Resp = contract_call_admin(State, "get_schedules_for", [AeAccount]),
            ok = cache_put(Key, Resp, State),
            {reply, Resp, State}
    end;
handle_call({list_schedules_for, AeAccount}, _From, State) ->
    Key = {list_schedules_for, AeAccount},
    case cache_get(Key, State) of
        {hit, Val} ->
            {reply, Val, State};
        miss ->
            Raw = contract_call_admin(State, "get_schedules_for", [AeAccount]),
            Schedules = load_account_schedules(AeAccount, decode_result_map(Raw)),
            ok = cache_put(Key, Schedules, State),
            {reply, Schedules, State}
    end;
handle_call({delete_schedule_by_hash, AeAccount, ScheduleHash}, _From, State) ->
    Resp = contract_call_for_user(State, AeAccount, "delete_schedule_by_hash", [ScheduleHash]),
    damage_schedule_index:delete_schedule(AeAccount, ScheduleHash),
    invalidate_schedule_keys(State, AeAccount, ScheduleHash),
    {reply, normalize_write_response(Resp), State};
handle_call({mark_schedule_executed, AeAccount, ScheduleHash, Timestamp}, _From, State) ->
    Resp = contract_call_for_user(
        State,
        AeAccount,
        "mark_executed",
        [ScheduleHash, integer_to_list(Timestamp)]
    ),
    invalidate_schedule_keys(State, AeAccount, ScheduleHash),
    {reply, normalize_write_response(Resp), State};
handle_call({list_schedules, AeAccount}, _From, State) ->
    Key = ?CK_LIST_SCHEDULES(AeAccount),
    case cache_get(Key, State) of
        {hit, Schedules} ->
            {reply, Schedules, State};
        miss ->
            Schedules = list_schedules_uncached(AeAccount),
            ok = cache_put(Key, Schedules, State),
            {reply, Schedules, State}
    end;
handle_call(list_all_schedules, _From, State) ->
    Key = ?CK_LIST_ALL_SCHEDULES,
    case cache_get(Key, State) of
        {hit, Schedules} ->
            {reply, Schedules, State};
        miss ->
            Schedules = list_all_schedules_uncached(),
            ok = cache_put(Key, Schedules, State),
            {reply, Schedules, State}
    end.

handle_cast({invalidate_cache_keys, Keys}, State) ->
    ok = cache_invalidate(Keys, State),
    {noreply, State};
handle_cast(Event, State) ->
    ?LOG_DEBUG("unhandled cast : ~p", [Event]),
    {noreply, State}.

handle_info(_Info, State) -> {noreply, State}.

terminate(Reason, _State) ->
    ?LOG_INFO("Server ~p terminating with reason ~p~n", [self(), Reason]),
    ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

get_schedules(AeAccount) ->
    gen_server:call(?MODULE, {get_schedules, AeAccount}, ?AE_TIMEOUT).

set_contract(ContractId) ->
    gen_server:call(?MODULE, {set_contract, ContractId}).

get_contract() ->
    gen_server:call(?MODULE, get_contract).

clear_cache() ->
    gen_server:call(?MODULE, clear_cache).

clear_cache(Key) ->
    gen_server:call(?MODULE, {clear_cache, Key}).
-spec get_schedules_for(binary() | list()) -> map() | list().
get_schedules_for(AeAccount) ->
    gen_server:call(?MODULE, {get_schedules_for, to_bin(AeAccount)}, ?AE_TIMEOUT).

-spec list_schedules_for(binary() | list()) -> list().
list_schedules_for(AeAccount) ->
    gen_server:call(?MODULE, {list_schedules_for, to_bin(AeAccount)}, ?AE_TIMEOUT).

-spec list_all_schedules() -> list().
list_all_schedules() ->
    gen_server:call(?MODULE, list_all_schedules, ?AE_TIMEOUT).

-spec delete_schedule_by_hash(binary() | list(), binary() | list()) ->
    {ok, term()} | {error, term()}.
delete_schedule_by_hash(AeAccount, ScheduleHash) ->
    gen_server:call(
        ?MODULE,
        {delete_schedule_by_hash, to_bin(AeAccount), to_bin(ScheduleHash)},
        ?AE_TIMEOUT
    ).

-spec mark_schedule_executed(binary() | list(), binary() | list(), integer()) ->
    {ok, term()} | {error, term()}.
mark_schedule_executed(AeAccount, ScheduleHash, Timestamp) ->
    gen_server:call(
        ?MODULE,
        {mark_schedule_executed, to_bin(AeAccount), to_bin(ScheduleHash), Timestamp},
        ?AE_TIMEOUT
    ).
contract_call_admin(State, Func, Args) ->
    ContractId = require_contract(State),
    damage_ae:contract_call(
        secrets:node_keypair(),
        ContractId,
        State#state.contract_path,
        Func,
        Args
    ).

contract_call_for_user(State, AeAccount, Func, Args) ->
    ContractId = require_contract(State),
    #{public_key := _Pub, private_key := PrivateKey, password := _} =
        identity_server:get_account(AeAccount),
    damage_ae:set_private_key(AeAccount, PrivateKey),
    damage_ae:contract_call_payfor_user(
        AeAccount,
        ContractId,
        State#state.contract_path,
        Func,
        Args
    ).
invalidate_schedule_keys(State, AeAccount, _ScheduleHash) ->
    ets:delete(State#state.ets_table, {get_schedules_for, AeAccount}),
    ets:delete(State#state.ets_table, {list_schedules_for, AeAccount}),
    ets:delete(State#state.ets_table, list_all_schedules),
    ok.

test_schedule() ->
    {ok, TestUserEmail} = application:get_env(damage, test_user),
    {PubKey, _Password, _PrivateKey} = identity_server:get_account_by_email(
        list_to_binary(TestUserEmail)
    ),
    Name = <<"test schedule">>,
    ok =
        add_schedule(
            PubKey,
            Name,
            [<<"daily">>, <<"every">>, <<"60">>, <<"seconds">>],
            <<"QmVHFpuoHCiTHYcLYgkhdXqQ94EoBT6VdWtocVgurXVnRU">>,
            1
        ),
    Schedules = list_all_schedules(),
    ?LOG_INFO("Schedule tests ok ~p", [Schedules]).

test_list_schedule() ->
    Results =
        [
            [
                "RDQSRp27KiwaIQk/+klzE6YnKkpHlqp83F59tge9gEdm6hXh0Jx30QM7YGSEE+TGkeKsHg==",
                [
                    ["cron", "KKuPJcbNhrP8srtYZhabn80yL0oazuo63Uor9gbizVFy5Qj0wolznxAF"],
                    [
                        "feature_hash",
                        "wfycG1gdgf4ifKiCIQWFBcd9Kk0D8f5ZsjIIsjne0zYPm0Lg2IpTlkQ3FmzwbcaIl4Ksf+fxRY3TX96zTgc="
                    ]
                ]
            ]
        ],
    Decrypted = load_account_schedules("Acc", Results),
    ?LOG_DEBUG("schedules ~p", [Decrypted]),
    Decrypted.

get_schedules_contract() ->
    application:get_env(damage, schedules_ct, ?SCHEDULES_CONTRACT).

contract_call(AeAccount, Func, Args) when is_binary(AeAccount) ->
    #{public_key := _PubKey, private_key := PrivateKey, password := _} =
        identity_server:get_account(AeAccount),
    damage_ae:set_private_key(AeAccount, PrivateKey),
    damage_ae:contract_call_payfor_user(
        AeAccount,
        get_schedules_contract(),
        "contracts/schedules.aes",
        Func,
        Args
    ).

require_contract(#state{contract_id = undefined}) ->
    to_bin(get_schedules_contract());
require_contract(#state{contract_id = ContractId}) ->
    ContractId.

decode_result_map(#{decodedResult := Results}) ->
    Results;
decode_result_map(#{decoded_result := Results}) ->
    Results;
decode_result_map(#{<<"return_value">> := Results}) ->
    Results;
decode_result_map(#{"return_value" := Results}) ->
    Results;
decode_result_map(Other) ->
    error({invalid_contract_result, Other}).

normalize_write_response(#{
    "return_type" := "ok",
    "return_value" := Value
}) ->
    {ok, Value};
normalize_write_response(#{
    <<"return_type">> := <<"ok">>,
    <<"return_value">> := Value
}) ->
    {ok, Value};
normalize_write_response(#{
    "return_type" := "revert",
    "return_value" := Reason
}) ->
    {error, Reason};
normalize_write_response(#{
    <<"return_type">> := <<"revert">>,
    <<"return_value">> := Reason
}) ->
    {error, Reason};
normalize_write_response({error, Reason}) ->
    {error, Reason};
normalize_write_response(Other) ->
    {error, {unexpected_contract_response, Other}}.
