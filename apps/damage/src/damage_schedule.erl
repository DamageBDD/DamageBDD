-module(damage_schedule).

-vsn("0.1.0").

-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/logger.hrl").
-include_lib("damage.hrl").

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-export([init/2]).
-export([content_types_accepted/2]).
-export([content_types_provided/2]).
-export([to_json/2]).
-export([from_json/2, allowed_methods/2, from_html/2]).
-export([trails/0]).
-export([is_authorized/2]).
-export([execute_bdd/1]).
-export([schedule_job/1]).
-export([list_schedules/1]).
-export([list_all_schedules/0]).
-export([load_all_schedules/0]).
-export([test_schedule/0]).
-export([test_list_schedule/0]).
-export([delete_resource/2]).
-export([delete_schedule/2]).
-export([cancel_all_schedules/0]).
-export([get_schedules/1]).
-export([deploy_schedules_contract/0]).
-export(
    [
        restart_schedules_proc/1,
        get_schedules_proc/1
    ]
).

-behaviour(gen_server).

-export(
    [
        init/1,
        start_link/1,
        handle_call/3,
        handle_cast/2,
        handle_info/2,
        terminate/2,
        code_change/3
    ]
).

-define(TRAILS_TAG, ["Scheduling Tests"]).
-define(SCHEDULES_CONTRACT,
    "ct_hCcHw4hNAkvbadmVrkCRQJxEqvx825hA4gL3gbf4Kh9hpRrwS"
).

%% Short TTL because schedules can change, but they are still read-heavy.
-define(SCHEDULE_CACHE_TTL_SECONDS, 15).

%% Cache keys
-define(CK_GET_SCHEDULES(AeAccount), {get_schedules, AeAccount}).
-define(CK_LIST_SCHEDULES(AeAccount), {list_schedules, AeAccount}).
-define(CK_LIST_ALL_SCHEDULES, list_all_schedules).

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

start_link(AeAccount) -> gen_server:start_link(?MODULE, [AeAccount], []).

init([AeAccount]) ->
    process_flag(trap_exit, true),
    {ok, #{public_key => AeAccount, cache => #{}}}.

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
                erlcron:cancel(DeleteId),
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
    ?LOG_INFO("schedule_job: ~p", [Schedule]),
    CronJob = apply(?MODULE, schedule_job, [Schedule]),
    ?LOG_INFO("Cron Job: ~p", [CronJob]),
    ok = add_schedule(AeAccount, Name, Hash, CronSpec),
    Resp = cowboy_req:set_resp_body(jsx:encode(#{status => <<"ok">>}), Req),
    {stop, cowboy_req:reply(201, Resp), State}.

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
    #{public_key := AeAccount, feature_hash := Hash, concurrency := Concurrency} = Schedule
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
            Result;
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

erlcron_cron(ScheduleId, Job) ->
    ?LOG_INFO("Scheduling job ~p ~p", [ScheduleId, Job]),
    erlcron:cron(ScheduleId, Job).

schedule_job(
    #{id := ScheduleId, cron := [daily, every, Hour, Minute, AMPM]} = Schedule
) ->
    Job =
        {{once, {Hour, Minute, AMPM}}, {damage_schedule, execute_bdd, [Schedule]}},
    erlcron_cron(ScheduleId, Job);
schedule_job(
    #{id := _ScheduleId, cron := [daily, every, Second, seconds]} = Schedule
) ->
    schedule_job(maps:put(cron, [daily, every, Second, sec], Schedule));
schedule_job(
    #{id := ScheduleId, cron := [daily, every, Second, sec]} = Schedule
) ->
    Job =
        {
            {daily, {every, {Second, sec}}},
            {damage_schedule, execute_bdd, [Schedule]}
        },
    erlcron_cron(ScheduleId, Job);
schedule_job(
    #{id := ScheduleId, cron := [once, Hour, Minute, Second]} = Schedule
) when is_integer(Second) ->
    Job =
        {{once, {Hour, Minute, Second}}, {damage_schedule, execute_bdd, [Schedule]}},
    erlcron_cron(ScheduleId, Job);
schedule_job(#{id := ScheduleId, cron := [once, Hour, Minute, AMPM]} = Schedule) when
    is_atom(AMPM) ->
    Job =
        {{once, {Hour, Minute, AMPM}}, {damage_schedule, execute_bdd, [Schedule]}},
    erlcron_cron(ScheduleId, Job);
schedule_job(#{id := ScheduleId, cron := [once, Seconds]} = Schedule) when
    is_integer(Seconds) ->
    Job = {{once, Seconds}, {damage_schedule, execute_bdd, [Schedule]}},
    erlcron_cron(ScheduleId, Job).

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
    SchedulesPid = get_schedules_proc(AeAccount),
    gen_server:call(SchedulesPid, {list_schedules, AeAccount}, ?AE_TIMEOUT).

load_all_schedules() ->
    ?LOG_INFO("Loading all schedules ..."),
    [
        [schedule_job(Schedule) || Schedule <- AccountSchedule]
     || AccountSchedule <- list_all_schedules()
    ].

list_all_schedules() ->
    SchedulesPid = get_schedules_proc(admin),
    gen_server:call(SchedulesPid, list_all_schedules, ?AE_TIMEOUT).

%% ------------------------------------------------------------------
%% Raw uncached fetchers
%% ------------------------------------------------------------------

list_schedules_uncached(AeAccount) ->
    case contract_call(AeAccount, "get_schedules", []) of
        {error, Error} ->
            ?LOG_ERROR("Failed to load schedules ~p ~p", [AeAccount, Error]),
            [];
        #{"return_value" := Results} ->
            ?LOG_INFO("loaded schedules ~p ", [Results]),
            load_account_schedules(AeAccount, Results)
    end.

list_all_schedules_uncached() ->
    case
        catch damage_ae:contract_call(
            get_schedules_contract(),
            "contracts/schedules.aes",
            "get_all_schedules",
            []
        )
    of
        #{"return_type" := "ok", "return_value" := Results} ->
            ?LOG_DEBUG("all schedules encrypted ~p", [Results]),
            Decrypted = decrypt_schedules(Results),
            ?LOG_DEBUG("all schedules ~p", [Decrypted]),
            Decrypted;
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
        "caller_id" := _AeAccountList,
        "caller_nonce" := _Nonce,
        "contract_id" := ?SCHEDULES_CONTRACT,
        "gas_price" := GasPrice,
        "gas_used" := GasUsed,
        "height" := Height,
        "log" := [],
        "return_type" := "ok",
        "return_value" := {}
    } =
        contract_call(
            AeAccount,
            "delete_schedule",
            [binary_to_list(ScheduleId)]
        ),
    Cancelled = erlcron:cancel(ScheduleId),
    invalidate_schedule_cache(AeAccount),
    ?LOG_DEBUG(
        "call AE contract ~p gasprice ~p gasused ~p, height ~p, cancelled ~p",
        [AeAccount, GasPrice, GasUsed, Height, Cancelled]
    ),
    ok.

add_schedule(AeAccount, Name, FeatureHash, Cron) when is_binary(AeAccount) ->
    #{
        log := [],
        gasPrice := GasPrice,
        callerId := AeAccount,
        gasUsed := GasUsed,
        returnType := <<"ok">>
    } =
        contract_call(
            AeAccount,
            "add_schedule",
            [
                binary_to_list(secrets:salted_hash(Name)),
                binary_to_list(secrets:encrypt(FeatureHash)),
                binary_to_list(secrets:encrypt(jsx:encode(Cron)))
            ]
        ),
    invalidate_schedule_cache(AeAccount),
    ?LOG_DEBUG(
        "call AE contract ~p gasprice ~p gasused ~p",
        [AeAccount, GasPrice, GasUsed]
    ),
    ok.

cancel_all_schedules() -> [erlcron:cancel(X) || X <- erlcron:get_all_jobs()].

load_account_schedules(Account, Schedules0) ->
    ?LOG_DEBUG("Account ~p", [Account]),
    Schedules = normalize_schedules(Schedules0),
    lists:map(fun(Entry) -> parse_schedule_entry(Account, Entry) end, Schedules).

normalize_schedules(Schedules) when is_list(Schedules) ->
    Schedules;
normalize_schedules(Schedules) when is_map(Schedules) ->
    lists:map(fun normalize_schedule_kv/1, maps:to_list(Schedules)).

normalize_schedule_kv({_Key, {tuple, {Id, CronEnc, FeatureHashEnc}}}) ->
    {Id, CronEnc, FeatureHashEnc};
normalize_schedule_kv({_Key, {tuple, {Id, CronEnc}}}) ->
    {Id, CronEnc, undefined};
normalize_schedule_kv({Key, Other}) ->
    {Key, Other}.

parse_schedule_entry(Account, [ScheduleId, EncryptedScheduleKVs]) ->
    Schedule0 = kvs_to_schedule_map(EncryptedScheduleKVs),
    maps:merge(#{id => ScheduleId, public_key => Account, concurrency => 1}, Schedule0);
parse_schedule_entry(Account, {ScheduleId, CronEnc, FeatureHashEnc}) ->
    CronJson = decrypt_b64_blob(CronEnc),
    CronSpec = binary_spec_to_term_spec(jsx:decode(CronJson), []),
    FeatureHash = decrypt_b64_blob(FeatureHashEnc),
    Schedule0 = #{cron => CronSpec, feature_hash => FeatureHash},
    maps:merge(#{id => ScheduleId, public_key => Account, concurrency => 1}, Schedule0);
parse_schedule_entry(_Account, Bad) ->
    error({invalid_schedule_shape, Bad}).

kvs_to_schedule_map(EncryptedScheduleKVs) ->
    maps:from_list(
        lists:map(
            fun
                ([<<"cron">>, Value]) ->
                    {
                        cron,
                        binary_spec_to_term_spec(
                            jsx:decode(decrypt_b64_blob(Value)),
                            []
                        )
                    };
                ([Key, Value]) when is_binary(Key) ->
                    {binary_to_atom(Key), decrypt_b64_blob(Value)};
                ([Key, Value]) when is_list(Key) ->
                    {list_to_atom(Key), decrypt_b64_blob(Value)}
            end,
            EncryptedScheduleKVs
        )
    ).

decrypt_b64_blob(B64Bin) when is_binary(B64Bin) ->
    secrets:decrypt(B64Bin).

%% ------------------------------------------------------------------
%% Cache helpers
%% ------------------------------------------------------------------

cache_now() ->
    erlang:monotonic_time(second).

cache_get(Key, #{cache := Cache}) ->
    Now = cache_now(),
    case maps:get(Key, Cache, undefined) of
        {Value, Expiry} when Now < Expiry ->
            {hit, Value};
        _ ->
            miss
    end.

cache_put(Key, Value, #{cache := Cache} = State) ->
    Expiry = cache_now() + ?SCHEDULE_CACHE_TTL_SECONDS,
    State#{cache := maps:put(Key, {Value, Expiry}, Cache)}.

cache_invalidate(Keys, #{cache := Cache} = State) ->
    State#{cache := maps:without(Keys, Cache)}.

invalidate_schedule_cache(AeAccount) ->
    AccountPid = get_schedules_proc(AeAccount),
    gen_server:cast(
        AccountPid,
        {invalidate_cache_keys, [
            ?CK_GET_SCHEDULES(AeAccount),
            ?CK_LIST_SCHEDULES(AeAccount)
        ]}
    ),
    GlobalPid = get_schedules_proc(admin),
    gen_server:cast(
        GlobalPid,
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

handle_call({list_schedules, AeAccount}, _From, State) ->
    Key = ?CK_LIST_SCHEDULES(AeAccount),
    case cache_get(Key, State) of
        {hit, Schedules} ->
            {reply, Schedules, State};
        miss ->
            Schedules = list_schedules_uncached(AeAccount),
            {reply, Schedules, cache_put(Key, Schedules, State)}
    end;

handle_call(list_all_schedules, _From, State) ->
    Key = ?CK_LIST_ALL_SCHEDULES,
    case cache_get(Key, State) of
        {hit, Schedules} ->
            {reply, Schedules, State};
        miss ->
            Schedules = list_all_schedules_uncached(),
            {reply, Schedules, cache_put(Key, Schedules, State)}
    end.

handle_cast({invalidate_cache_keys, Keys}, State) ->
    {noreply, cache_invalidate(Keys, State)};
handle_cast(Event, State) ->
    ?LOG_DEBUG("unhandled cast : ~p", [Event]),
    {noreply, State}.

handle_info(_Info, State) -> {noreply, State}.

terminate(Reason, _State) ->
    ?LOG_INFO("Server ~p terminating with reason ~p~n", [self(), Reason]),
    ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

get_schedules(AeAccount) ->
    DamageAEPid = get_schedules_proc(AeAccount),
    gen_server:call(DamageAEPid, {get_schedules, AeAccount}, ?AE_TIMEOUT).

get_schedules_proc(admin) ->
    case gproc:lookup_local_name({?MODULE, admin}) of
        undefined ->
            case
                supervisor:start_child(
                    damage_sup,
                    #{
                        id => {?MODULE, admin},
                        start => {?MODULE, start_link, [admin]},
                        restart => permanent,
                        shutdown => 60,
                        type => worker,
                        modules => [damage_schedule]
                    }
                )
            of
                {ok, Pid} ->
                    gproc:reg_other({n, l, {?MODULE, admin}}, Pid),
                    Pid;
                {error, {already_started, Pid}} ->
                    gproc:reg_other({n, l, {?MODULE, admin}}, Pid),
                    Pid
            end;
        Pid ->
            Pid
    end;
get_schedules_proc(<<"ak_", _/binary>> = AeAccount) ->
    case gproc:lookup_local_name({?MODULE, AeAccount}) of
        undefined ->
            case
                supervisor:start_child(
                    damage_sup,
                    #{
                        id => {?MODULE, AeAccount},
                        start => {?MODULE, start_link, [AeAccount]},
                        restart => permanent,
                        shutdown => 60,
                        type => worker,
                        modules => [damage_schedule]
                    }
                )
            of
                {ok, AePid} ->
                    gproc:reg_other({n, l, {?MODULE, AeAccount}}, AePid),
                    AePid;
                {error, {already_started, AePid}} ->
                    gproc:reg_other({n, l, {?MODULE, AeAccount}}, AePid),
                    AePid
            end;
        Pid ->
            Pid
    end.

restart_schedules_proc(AeAccount) ->
    case gproc:lookup_local_name({?MODULE, AeAccount}) of
        undefined ->
            get_schedules_proc(AeAccount);
        Pid ->
            supervisor:terminate_child(damage_sup, Pid),
            get_schedules_proc(AeAccount)
    end.

test_schedule() ->
    {ok, TestUserEmail} = application:get_env(damage, test_user),
    {PubKey, _Password, PrivateKey} = identity_server:get_account_by_email(
        list_to_binary(TestUserEmail)
    ),
    Name = <<"test schedule">>,
    ok =
        add_schedule(
            #{public_key => PubKey, private_key => PrivateKey},
            Name,
            <<"QmVHFpuoHCiTHYcLYgkhdXqQ94EoBT6VdWtocVgurXVnRU">>,
            [<<"daily">>, <<"every">>, <<"60">>, <<"seconds">>]
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
    #{public_key := _PubKey, private_key := PrivateKey} =
        identity_server:get_account(AeAccount),
    damage_ae:set_private_key(AeAccount, PrivateKey),
    damage_ae:contract_call_payfor_user(
        AeAccount,
        get_schedules_contract(),
        "contracts/schedules.aes",
        Func,
        Args
    ).

deploy_schedules_contract() ->
    damage_ae:contract_deploy(
        damage_ae:contract_path("contracts/schedules.aes"), []
    ).
