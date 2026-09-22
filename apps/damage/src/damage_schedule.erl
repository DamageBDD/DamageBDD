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
    load_all_schedules/0,
    %% shared canonicalization boundary used by damage_schedule_index
    normalize_cron_spec/1
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
    case node_secrets_ready() of
        false ->
            schedule_service_unavailable_reply(Req, State, node_locked);
        true ->
            delete_resource_ready(Req, State, AeAccount)
    end.

delete_resource_ready(Req, State, AeAccount) ->
    case delete_schedule_ids(AeAccount, maps:get(path_info, Req)) of
        {ok, Deleted} ->
            ?LOG_INFO("deleted ~p schedules", [Deleted]),
            {true, Req, State};
        {error, Reason} ->
            schedule_service_unavailable_reply(Req, State, Reason)
    end.

delete_schedule_ids(AeAccount, DeleteIds) ->
    lists:foldl(
        fun
            (_DeleteId, {error, _} = Error) ->
                Error;
            (DeleteId, {ok, Acc}) ->
                ?LOG_DEBUG("deleting schedule path=~p id=~p", [
                    DeleteIds, DeleteId
                ]),
                case delete_schedule(AeAccount, DeleteId) of
                    ok -> {ok, Acc + 1};
                    {ok, _} -> {ok, Acc + 1};
                    {error, _} = Error -> Error;
                    Other -> {error, {unexpected_delete_result, Other}}
                end
        end,
        {ok, 0},
        DeleteIds
    ).

from_text(Req, #{public_key := AeAccount} = State) ->
    case node_secrets_ready() of
        false ->
            schedule_service_unavailable_reply(Req, State, node_locked);
        true ->
            from_text_ready(Req, State, AeAccount)
    end.

from_text_ready(Req, State, AeAccount) ->
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
            case lock_related_reason(Reason) of
                true ->
                    schedule_service_unavailable_reply(Req, State, Reason);
                false ->
                    Body = jsx:encode(#{
                        status => <<"error">>,
                        error => <<"SCHEDULE_WRITE_FAILED">>,
                        reason => iolist_to_binary(io_lib:format("~p", [Reason]))
                    }),
                    Req2 = cowboy_req:reply(
                        500,
                        #{
                            <<"content-type">> => <<"application/json">>,
                            <<"cache-control">> => <<"no-store">>
                        },
                        Body,
                        Req
                    ),
                    {stop, Req2, State}
            end
    end.

from_json(Req, State) -> from_text(Req, State).
from_html(Req, State) -> from_text(Req, State).

to_json(Req, #{public_key := AeAccount} = State) ->
    case list_schedules(AeAccount) of
        Schedules when is_list(Schedules) ->
            Body =
                jsx:encode(
                    #{status => <<"ok">>, results => Schedules, length => length(Schedules)}
                ),
            ?LOG_INFO("Loading schedules for account=~p count=~p", [
                AeAccount, length(Schedules)
            ]),
            {Body, Req, State};
        {error, Reason} ->
            schedule_service_unavailable_reply(Req, State, Reason);
        Other ->
            schedule_service_unavailable_reply(
                Req, State, {unexpected_schedule_result, Other}
            )
    end.

execute_bdd(
    #{public_key := AeAccount, feature_hash := Hash, concurrency := Concurrency, id_hash := IdHash} =
        Schedule
) ->
    case node_secrets_ready() of
        false ->
            ?LOG_WARNING(
                "Deferring scheduled execution while node secrets are locked account=~p id_hash=~p",
                [AeAccount, IdHash]
            ),
            [];
        true ->
            execute_bdd_ready(Schedule, AeAccount, Hash, Concurrency, IdHash)
    end.

execute_bdd_ready(Schedule, AeAccount, Hash, Concurrency, IdHash) ->
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
            damage_metrics:update(schedule_execution, {AeAccount, Hash}),
            case mark_schedule_executed(AeAccount, IdHash, erlang:system_time(millisecond)) of
                ok ->
                    Result;
                {ok, _} ->
                    Result;
                Error ->
                    error({mark_schedule_executed_failed, AeAccount, IdHash, Error})
            end;
        {error, Reason} when Reason =:= node_locked; Reason =:= secrets_not_ready ->
            ?LOG_WARNING(
                "Deferring scheduled execution because node secrets became unavailable "
                "account=~p reason=~p",
                [AeAccount, Reason]
            ),
            [];
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
schedule_job(#{cron := [once | _], execution_counter := Count}) when is_integer(Count), Count > 0 ->
    ok;
schedule_job(#{public_key := Account, id := Id} = Schedule) ->
    damage_schedule_index:upsert_schedule(Account, Id, Schedule).

binary_spec_to_term_spec([], Acc) ->
    Acc;
binary_spec_to_term_spec([Spec | Rest], Acc) ->
    binary_spec_to_term_spec(Rest, Acc ++ [cron_token(Spec)]).

validate(Gherkin) ->
    try egherkin:parse(Gherkin) of
        {failed, LineNo, Message} ->
            ?LOG_ERROR("Parsing Failed LineNo +~p ~n     ~p.", [LineNo, Message]),
            {parse_error, LineNo, Message};
        {_LineNo, _Tags, _Feature, _Description, _BackGround, _Scenarios} ->
            ok;
        Other ->
            {parse_error, unexpected_result, Other}
    catch
        Class:Reason:Stacktrace ->
            ?LOG_ERROR("Schedule Gherkin parse crashed class=~p reason=~p stack=~p", [
                Class, Reason, Stacktrace
            ]),
            {parse_error, Class, Reason}
    end.

%% ------------------------------------------------------------------
%% Cached public readers
%% ------------------------------------------------------------------

list_schedules(AeAccount) ->
    gen_server:call(?MODULE, {list_schedules, AeAccount}, ?AE_TIMEOUT).

load_all_schedules() ->
    ?LOG_INFO("Loading all schedules into index ..."),
    case list_all_schedules() of
        AccountScheduleLists when is_list(AccountScheduleLists) ->
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
                AccountScheduleLists
            );
        {error, Reason} ->
            ?LOG_WARNING("Schedule index load deferred reason=~p", [Reason]),
            {error, Reason}
    end.

is_valid_schedule(#{error := Reason} = S) ->
    ?LOG_ERROR("Skipping invalid schedule ~p reason ~p", [S, Reason]),
    false;
is_valid_schedule(#{cron := [once | _], execution_counter := Count}) when is_integer(Count), Count > 0 ->
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
        {error, _} = Error ->
            ?LOG_WARNING("Schedules unavailable account=~p reason=~p", [AeAccount, Error]),
            Error;
        Error ->
            ?LOG_ERROR("Failed to load schedules ~p ~p", [AeAccount, Error]),
            {error, {unexpected_contract_result, Error}}
    end.

list_all_schedules_uncached() ->
    case node_secrets_ready() of
        false ->
            {error, node_locked};
        true ->
            case
                damage_ae:contract_call(
                    get_schedules_contract(),
                    damage_ae:contract_path(damage, "contracts/schedules.aes"),
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
                {error, _} = Error ->
                    Error;
                Error ->
                    ?LOG_ERROR("schedules loading failed ~p", [Error]),
                    {error, {unexpected_contract_result, Error}}
            end
    end.

%%--------------------------------------------------------------------
%% Decrypt schedules returned by the schedules contract.
%%--------------------------------------------------------------------
decrypt_schedules(undefined) ->
    [];
decrypt_schedules(none) ->
    [];
decrypt_schedules(null) ->
    [];
decrypt_schedules({option, none}) ->
    [];
decrypt_schedules({option, {some, Schedules}}) ->
    decrypt_schedules(Schedules);
decrypt_schedules({variant, [0, 1], 0, {}}) ->
    [];
decrypt_schedules({variant, [0, 1], 1, {Schedules}}) ->
    decrypt_schedules(Schedules);
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
    case
        contract_call(
            AeAccount,
            "delete_schedule",
            [binary_to_list(ScheduleId)]
        )
    of
        #{
            "gas_price" := GasPrice,
            "gas_used" := GasUsed,
            "height" := Height,
            "return_type" := "ok",
            "return_value" := Deleted
        } ->
            damage_schedule_index:delete_schedule(AeAccount, ScheduleId),
            invalidate_schedule_cache(AeAccount),
            ?LOG_DEBUG(
                "call AE contract ~p deleted ~p gasprice ~p gasused ~p, height ~p",
                [AeAccount, Deleted, GasPrice, GasUsed, Height]
            ),
            {ok, Deleted};
        {error, _} = Error ->
            Error;
        Other ->
            {error, {unexpected_contract_result, Other}}
    end.

add_schedule(AeAccount, Name, Cron0, FeatureHash, Concurrency) when is_binary(AeAccount) ->
    case node_secrets_ready() of
        false ->
            {error, node_locked};
        true ->
            case normalize_cron_spec(Cron0) of
                {ok, Cron} ->
                    add_schedule_canonical(AeAccount, Name, Cron, FeatureHash, Concurrency);
                {error, Reason} ->
                    {error, {invalid_cron_spec, Reason}}
            end
    end.

add_schedule_canonical(AeAccount, Name, Cron, FeatureHash, Concurrency) ->
    %% Bind encrypted fields to the textual stable id passed to the contract.
    %% The contract indexes that value by a derived 32-byte map key, so the map
    %% key itself is not the encryption context. New writes always persist the
    %% canonical cron shape.
    IdHash = secrets:salted_hash(Name),
    Result =
        contract_call(
            AeAccount,
            "add_schedule",
            [
                binary_to_list(IdHash),
                binary_to_list(
                    secrets:encrypt_bound(
                        schedule_crypto_context(AeAccount, IdHash, cron),
                        jsx:encode(Cron)
                    )
                ),
                binary_to_list(
                    secrets:encrypt_bound(
                        schedule_crypto_context(AeAccount, IdHash, feature_hash),
                        FeatureHash
                    )
                ),
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
                try
                    {true, parse_schedule_entry(Account, Entry)}
                catch
                    Class:Reason:Stacktrace ->
                        ?LOG_ERROR(
                            "Skipping schedule row for ~p: entry=~p class=~p reason=~p stack=~p",
                            [Account, Entry, Class, Reason, Stacktrace]
                        ),
                        false
                end
        end,
        Schedules
    ).

%% Contract reads may legitimately return an empty/none value when the account
%% has no schedules. Treat that as an empty list instead of crashing Cowboy.
normalize_schedules(undefined) ->
    [];
normalize_schedules(none) ->
    [];
normalize_schedules(null) ->
    [];
normalize_schedules({option, none}) ->
    [];
normalize_schedules({option, {some, Schedules}}) ->
    normalize_schedules(Schedules);
normalize_schedules({variant, [0, 1], 0, {}}) ->
    [];
normalize_schedules({variant, [0, 1], 1, {Schedules}}) ->
    normalize_schedules(Schedules);
normalize_schedules(Schedules) when is_list(Schedules) ->
    Schedules;
normalize_schedules(Schedules) when is_map(Schedules) ->
    lists:map(fun normalize_schedule_kv/1, maps:to_list(Schedules));
normalize_schedules(Bad) ->
    ?LOG_ERROR("Invalid schedules collection shape: ~p", [Bad]),
    [#{error => {invalid_schedules_collection_shape, Bad}}].

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
    #{error => {invalid_schedule_kv_shape, Bad}}.

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
    ?LOG_DEBUG("parse_schedule_entry account=~p id_hash=~p", [Account, IdHash]),
    {CronRaw, CronCryptoFormat} =
        decrypt_schedule_field(Account, IdHash, IdPlain, cron, CronEnc),
    {FeatureHash, FeatureCryptoFormat} =
        decrypt_schedule_field(Account, IdHash, IdPlain, feature_hash, FeatureHashEnc),
    case decode_cron_spec(CronRaw) of
        {ok, CronSpec} ->
            Schedule = #{
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
            },
            maybe_queue_schedule_migration(
                Account,
                IdHash,
                IdPlain,
                CronRaw,
                CronSpec,
                FeatureHash,
                Concurrency,
                Created,
                LastExecutionTs,
                ExecutionCounter,
                {CronCryptoFormat, FeatureCryptoFormat}
            ),
            Schedule;
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
schedule_crypto_context(Account0, ScheduleId0, Field) ->
    {schedule, to_bin(Account0), to_bin(ScheduleId0), Field}.

decrypt_schedule_field(Account, IdHash, IdPlain, Field, CipherText) ->
    %% Current writes bind to the textual stable schedule id supplied to the
    %% contract. The contract may additionally return a derived 32-byte map key
    %% as IdHash; that key is used for mark/delete operations, not for AAD.
    StableId = schedule_bind_id(IdHash, IdPlain),
    StableContext = schedule_crypto_context(Account, StableId, Field),
    case secrets:decrypt_bound(StableContext, CipherText) of
        error ->
            %% Compatibility for the short-lived map-key-bound format, then the
            %% original unbound format used before bound envelopes existed.
            decrypt_schedule_field_compat(Account, IdHash, StableId, Field, CipherText);
        Value ->
            {Value, current}
    end.

schedule_bind_id(IdHash, IdPlain) ->
    case usable_schedule_id(IdPlain) of
        {ok, StableId} -> StableId;
        error -> to_bin(IdHash)
    end.

usable_schedule_id(undefined) -> error;
usable_schedule_id(none) -> error;
usable_schedule_id(null) -> error;
usable_schedule_id(<<>>) -> error;
usable_schedule_id(Id) when is_binary(Id) -> {ok, Id};
usable_schedule_id(Id) when is_list(Id) -> {ok, to_bin(Id)};
usable_schedule_id(_) -> error.

decrypt_schedule_field_compat(Account, IdHash, StableId, Field, CipherText) ->
    IdHashBin = to_bin(IdHash),
    case IdHashBin =:= StableId of
        true ->
            decrypt_legacy_schedule_field(Account, IdHash, Field, CipherText);
        false ->
            MapKeyContext = schedule_crypto_context(Account, IdHashBin, Field),
            case secrets:decrypt_bound(MapKeyContext, CipherText) of
                error ->
                    decrypt_legacy_schedule_field(Account, IdHash, Field, CipherText);
                Value ->
                    ?LOG_WARNING(
                        "Using transitional map-key-bound schedule ciphertext account=~p id_hash=~p field=~p; queued for migration",
                        [to_bin(Account), IdHashBin, Field]
                    ),
                    {Value, transitional}
            end
    end.


decrypt_legacy_schedule_field(Account, IdHash, Field, CipherText) ->
    ?LOG_WARNING(
        "Using legacy unbound schedule ciphertext account=~p id_hash=~p field=~p; queued for migration",
        [to_bin(Account), to_bin(IdHash), Field]
    ),
    {secrets:decrypt(CipherText), legacy}.

maybe_queue_schedule_migration(
    Account,
    IdHash,
    IdPlain,
    CronRaw,
    CronSpec,
    FeatureHash,
    Concurrency,
    Created,
    LastExecutionTs,
    ExecutionCounter,
    CryptoFormats
) ->
    AutoMigrate = application:get_env(damage, schedule_auto_migrate, true),
    NeedsMigration =
        CryptoFormats =/= {current, current} orelse cron_storage_needs_migration(CronRaw, CronSpec),
    SafeToRewrite = legacy_metadata_shape(Created, LastExecutionTs, ExecutionCounter),
    case {AutoMigrate, NeedsMigration, SafeToRewrite, migration_schedule_id(IdHash, IdPlain)} of
        {true, true, true, {ok, StableId}} ->
            gen_server:cast(
                ?MODULE,
                {migrate_schedule, #{
                    account => to_bin(Account),
                    stable_id => StableId,
                    crypto_id => migration_crypto_id(IdHash, StableId),
                    cron => CronSpec,
                    feature_hash => to_bin(FeatureHash),
                    concurrency => normalize_concurrency(Concurrency),
                    crypto_formats => CryptoFormats
                }}
            ),
            ok;
        _ ->
            ok
    end.

legacy_metadata_shape(Created, LastExecutionTs, ExecutionCounter) ->
    decode_optional_int(Created) =:= undefined andalso
        decode_optional_int(LastExecutionTs) =:= undefined andalso
        (ExecutionCounter =:= 0 orelse ExecutionCounter =:= undefined).

cron_storage_needs_migration(CronRaw, CronSpec) when is_binary(CronRaw) ->
    CronRaw =/= iolist_to_binary(jsx:encode(CronSpec));
cron_storage_needs_migration(_CronRaw, _CronSpec) ->
    true.

migration_schedule_id(_IdHash, IdPlain) ->
    %% Never invent a textual id from the contract's derived 32-byte map key:
    %% those are different identifiers. Legacy rows that can be safely rewritten
    %% carry the original textual id alongside the map key.
    usable_schedule_id(IdPlain).

migration_crypto_id(_IdHash, StableId) ->
    StableId.

normalize_concurrency(I) when is_integer(I), I > 0 -> I;
normalize_concurrency(B) when is_binary(B) ->
    try binary_to_integer(B) of
        I when I > 0 -> I;
        _ -> 1
    catch
        _:_ -> 1
    end;
normalize_concurrency(L) when is_list(L) ->
    try list_to_integer(L) of
        I when I > 0 -> I;
        _ -> 1
    catch
        _:_ -> 1
    end;
normalize_concurrency(_) -> 1.

migrate_schedule_record(#{
    account := Account,
    stable_id := StableId,
    crypto_id := CryptoId,
    cron := Cron,
    feature_hash := FeatureHash,
    concurrency := Concurrency
}) ->
    CronEnc = secrets:encrypt_bound(
        schedule_crypto_context(Account, CryptoId, cron),
        iolist_to_binary(jsx:encode(Cron))
    ),
    FeatureHashEnc = secrets:encrypt_bound(
        schedule_crypto_context(Account, CryptoId, feature_hash),
        FeatureHash
    ),
    Result = contract_call(
        Account,
        "add_schedule",
        [
            binary_to_list(StableId),
            binary_to_list(CronEnc),
            binary_to_list(FeatureHashEnc),
            Concurrency
        ]
    ),
    migration_write_result(Result).

migration_write_result(#{"return_type" := "ok"}) -> ok;
migration_write_result(#{<<"return_type">> := <<"ok">>}) -> ok;
migration_write_result(#{"return_type" := "revert", "return_value" := Reason}) ->
    {error, Reason};
migration_write_result(#{<<"return_type">> := <<"revert">>, <<"return_value">> := Reason}) ->
    {error, Reason};
migration_write_result({error, Reason}) -> {error, Reason};
migration_write_result(Other) -> {error, {unexpected_contract_response, Other}}.

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
            case normalize_cron_spec(JsonTerms) of
                {ok, CronSpec} ->
                    {ok, CronSpec};
                {error, Reason} ->
                    ?LOG_ERROR("failed to decode json cron ~p reason=~p", [Bin, Reason]),
                    {error, {invalid_json_cron, Bin, Reason}}
            end;
        error ->
            parse_plain_cron(Bin)
    end;
decode_cron_spec(List) when is_list(List) ->
    case normalize_cron_spec(List) of
        {ok, CronSpec} ->
            {ok, CronSpec};
        {error, Reason} ->
            ?LOG_ERROR("failed to decode list cron ~p reason=~p", [List, Reason]),
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
    Tokens0 = binary:split(Bin, <<" ">>, [global, trim_all]),
    Tokens = [T || T <- Tokens0, T =/= <<>>],
    case normalize_cron_spec(Tokens) of
        {ok, CronSpec} ->
            {ok, CronSpec};
        {error, Reason} ->
            ?LOG_ERROR("failed to parse plain cron ~p reason=~p", [Bin, Reason]),
            {error, {invalid_plain_cron, Bin, Reason}}
    end.

%% Normalize every accepted historical representation into the small canonical
%% representation consumed by damage_schedule_index. This is the migration
%% boundary: old persisted JSON/plain forms continue to load, while all new
%% writes are encoded from the canonical form.
-spec normalize_cron_spec(term()) -> {ok, list()} | {error, term()}.
normalize_cron_spec(Spec0) when is_list(Spec0) ->
    try
        Terms = binary_spec_to_term_spec(Spec0, []),
        Canonical = canonical_cron_spec(Terms),
        case Canonical =:= Terms of
            true -> ok;
            false -> ?LOG_INFO("Migrated legacy cron spec ~p -> ~p", [Terms, Canonical])
        end,
        {ok, Canonical}
    catch
        Class:Reason:Stacktrace ->
            ?LOG_ERROR(
                "invalid cron spec ~p class=~p reason=~p stack=~p",
                [Spec0, Class, Reason, Stacktrace]
            ),
            {error, Reason}
    end;
normalize_cron_spec(Other) ->
    {error, {invalid_cron_spec, Other}}.

canonical_cron_spec([once, Delay, Unit]) when is_integer(Delay), Delay >= 0 ->
    case canonical_unit(Unit) of
        sec -> [once, Delay];
        minute -> [once, Delay * 60];
        hour -> [once, Delay * 60 * 60];
        day -> [once, Delay * 24 * 60 * 60];
        week -> [once, Delay * 7 * 24 * 60 * 60];
        CanonicalUnit -> [once, Delay, CanonicalUnit]
    end;
canonical_cron_spec([daily, every, Amount, Unit]) when is_integer(Amount), Amount > 0 ->
    [daily, every, Amount, canonical_unit(Unit)];
canonical_cron_spec([daily, every, Hour, Minute, AMPM]) when
    is_integer(Hour), is_integer(Minute), (AMPM =:= am orelse AMPM =:= pm)
->
    validate_clock(Hour, Minute, AMPM),
    [daily, every, Hour, Minute, AMPM];
canonical_cron_spec([daily, at, Hour, Minute, AMPM]) when
    is_integer(Hour), is_integer(Minute), (AMPM =:= am orelse AMPM =:= pm)
->
    validate_clock(Hour, Minute, AMPM),
    [daily, every, Hour, Minute, AMPM];
canonical_cron_spec([once, Hour, Minute, Second]) when
    is_integer(Hour), is_integer(Minute), is_integer(Second)
->
    validate_hms(Hour, Minute, Second),
    [once, Hour, Minute, Second];
canonical_cron_spec(Spec) ->
    Spec.

canonical_unit(sec) -> sec;
canonical_unit(second) -> sec;
canonical_unit(seconds) -> sec;
canonical_unit(secs) -> sec;
canonical_unit(min) -> minute;
canonical_unit(mins) -> minute;
canonical_unit(minute) -> minute;
canonical_unit(minutes) -> minute;
canonical_unit(hr) -> hour;
canonical_unit(hrs) -> hour;
canonical_unit(hour) -> hour;
canonical_unit(hours) -> hour;
canonical_unit(day) -> day;
canonical_unit(days) -> day;
canonical_unit(week) -> week;
canonical_unit(weeks) -> week;
canonical_unit(month) -> month;
canonical_unit(months) -> month;
canonical_unit(year) -> year;
canonical_unit(years) -> year;
canonical_unit(Unit) -> Unit.

validate_clock(Hour, Minute, AMPM) when
    Hour >= 1, Hour =< 12, Minute >= 0, Minute =< 59, (AMPM =:= am orelse AMPM =:= pm)
->
    ok;
validate_clock(Hour, Minute, AMPM) ->
    error({invalid_clock_time, Hour, Minute, AMPM}).

validate_hms(Hour, Minute, Second) when
    Hour >= 0, Hour =< 23, Minute >= 0, Minute =< 59, Second >= 0, Second =< 59
->
    ok;
validate_hms(Hour, Minute, Second) ->
    error({invalid_time, Hour, Minute, Second}).

cron_token(I) when is_integer(I) ->
    I;
cron_token(A) when is_atom(A) ->
    case cron_keyword(atom_to_binary(A, utf8)) of
        {ok, Keyword} -> Keyword;
        error -> erlang:error({invalid_cron_token, A})
    end;
cron_token(List) when is_list(List) ->
    cron_token(unicode:characters_to_binary(List));
cron_token(Bin) when is_binary(Bin) ->
    try binary_to_integer(Bin) of
        I -> I
    catch
        error:badarg ->
            case cron_keyword(Bin) of
                {ok, Keyword} -> Keyword;
                error -> erlang:error({invalid_cron_token, Bin})
            end
    end.

%% Never create atoms from schedule input. erlcron expressions use a small
%% vocabulary, so map accepted textual tokens to compile-time atoms explicitly.
cron_keyword(Bin0) ->
    Bin = list_to_binary(string:lowercase(binary_to_list(Bin0))),
    case Bin of
        <<"*">> -> {ok, '*'};
        <<"every">> -> {ok, every};
        <<"at">> -> {ok, at};
        <<"on">> -> {ok, on};
        <<"once">> -> {ok, once};
        <<"daily">> -> {ok, daily};
        <<"weekly">> -> {ok, weekly};
        <<"monthly">> -> {ok, monthly};
        <<"yearly">> -> {ok, yearly};
        <<"am">> -> {ok, am};
        <<"pm">> -> {ok, pm};
        <<"sec">> -> {ok, sec};
        <<"secs">> -> {ok, secs};
        <<"second">> -> {ok, second};
        <<"seconds">> -> {ok, seconds};
        <<"minute">> -> {ok, minute};
        <<"minutes">> -> {ok, minutes};
        <<"min">> -> {ok, min};
        <<"mins">> -> {ok, mins};
        <<"hour">> -> {ok, hour};
        <<"hours">> -> {ok, hours};
        <<"hr">> -> {ok, hr};
        <<"hrs">> -> {ok, hrs};
        <<"day">> -> {ok, day};
        <<"days">> -> {ok, days};
        <<"week">> -> {ok, week};
        <<"weeks">> -> {ok, weeks};
        <<"month">> -> {ok, month};
        <<"months">> -> {ok, months};
        <<"year">> -> {ok, year};
        <<"years">> -> {ok, years};
        <<"monday">> -> {ok, monday};
        <<"tuesday">> -> {ok, tuesday};
        <<"wednesday">> -> {ok, wednesday};
        <<"thursday">> -> {ok, thursday};
        <<"friday">> -> {ok, friday};
        <<"saturday">> -> {ok, saturday};
        <<"sunday">> -> {ok, sunday};
        _ -> error
    end.

%% Parser/migration regression tests.
legacy_pm_cron_migration_test() ->
    ?assertEqual(
        {ok, [daily, every, 3, 0, pm]},
        decode_cron_spec(<<"[\"daily\",\"every\",3,0,\"pm\"]">>)
    ).

legacy_once_secs_migration_test() ->
    ?assertEqual(
        {ok, [once, 60]},
        decode_cron_spec(<<"[\"once\",60,\"secs\"]">>)
    ),
    ?assertEqual({ok, [once, 60]}, decode_cron_spec(<<"once 60 secs">>)).

legacy_seconds_unit_migration_test() ->
    ?assertEqual(
        {ok, [daily, every, 60, sec]},
        decode_cron_spec(<<"[\"daily\",\"every\",60,\"seconds\"]">>)
    ).

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
            Schedules = list_schedules_uncached(AeAccount),
            ok = maybe_cache_schedule_result(Key, Schedules, State),
            {reply, Schedules, State}
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
            ok = maybe_cache_schedule_result(Key, Resp, State),
            {reply, Resp, State}
    end;
handle_call({list_schedules_for, AeAccount}, _From, State) ->
    Key = {list_schedules_for, AeAccount},
    case cache_get(Key, State) of
        {hit, Val} ->
            {reply, Val, State};
        miss ->
            Raw = contract_call_admin(State, "get_schedules_for", [AeAccount]),
            case Raw of
                {error, _} = Error ->
                    {reply, Error, State};
                _ ->
                    Schedules = load_account_schedules(AeAccount, decode_result_map(Raw)),
                    ok = maybe_cache_schedule_result(Key, Schedules, State),
                    {reply, Schedules, State}
            end
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
            ok = maybe_cache_schedule_result(Key, Schedules, State),
            {reply, Schedules, State}
    end;
handle_call(list_all_schedules, _From, State) ->
    Key = ?CK_LIST_ALL_SCHEDULES,
    case cache_get(Key, State) of
        {hit, Schedules} ->
            {reply, Schedules, State};
        miss ->
            Schedules = list_all_schedules_uncached(),
            ok = maybe_cache_schedule_result(Key, Schedules, State),
            {reply, Schedules, State}
    end.

handle_cast({migrate_schedule, Migration}, State = #state{ets_table = Tab}) ->
    Account = maps:get(account, Migration),
    StableId = maps:get(stable_id, Migration),
    MigrationKey = {schedule_migration, Account, StableId},
    case ets:lookup(Tab, MigrationKey) of
        [] ->
            ets:insert(Tab, {MigrationKey, in_progress}),
            Parent = self(),
            spawn(fun() ->
                Result =
                    try migrate_schedule_record(Migration) of
                        R -> R
                    catch
                        Class:Reason:Stack -> {error, {Class, Reason, Stack}}
                    end,
                gen_server:cast(Parent, {schedule_migration_result, MigrationKey, Migration, Result})
            end),
            {noreply, State};
        _ ->
            {noreply, State}
    end;
handle_cast({schedule_migration_result, MigrationKey, Migration, ok}, State = #state{ets_table = Tab}) ->
    Account = maps:get(account, Migration),
    StableId = maps:get(stable_id, Migration),
    ?LOG_INFO(
        "Migrated schedule storage account=~p id=~p crypto=~p cron=~p",
        [Account, StableId, maps:get(crypto_formats, Migration, undefined), maps:get(cron, Migration)]
    ),
    ets:insert(Tab, {MigrationKey, done}),
    invalidate_schedule_keys(State, Account, StableId),
    {noreply, State};
handle_cast(
    {schedule_migration_result, MigrationKey, Migration, {error, Reason}},
    State = #state{ets_table = Tab}
) ->
    ?LOG_WARNING(
        "Schedule migration failed account=~p id=~p reason=~p; legacy row remains usable",
        [maps:get(account, Migration), maps:get(stable_id, Migration), Reason]
    ),
    ets:insert(Tab, {MigrationKey, {failed, Reason}}),
    {noreply, State};
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
    case node_keypair() of
        {ok, KeyPair} ->
            ContractId = require_contract(State),
            damage_ae:contract_call(
                KeyPair,
                ContractId,
                damage_ae:contract_path(damage, State#state.contract_path),
                Func,
                Args
            );
        {error, _} = Error ->
            Error
    end.

contract_call_for_user(State, AeAccount, Func, Args) ->
    case account_private_key(AeAccount) of
        {ok, PrivateKey} ->
            ContractId = require_contract(State),
            damage_ae:set_private_key(AeAccount, PrivateKey),
            damage_ae:contract_call_payfor_user(
                AeAccount,
                ContractId,
                damage_ae:contract_path(damage, State#state.contract_path),
                Func,
                Args
            );
        {error, _} = Error ->
            Error
    end.
invalidate_schedule_keys(State, AeAccount, _ScheduleHash) ->
    Tab = State#state.ets_table,
    ets:delete(Tab, ?CK_GET_SCHEDULES(AeAccount)),
    ets:delete(Tab, ?CK_LIST_SCHEDULES(AeAccount)),
    ets:delete(Tab, {get_schedules_for, AeAccount}),
    ets:delete(Tab, {list_schedules_for, AeAccount}),
    ets:delete(Tab, ?CK_LIST_ALL_SCHEDULES),
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
    case account_private_key(AeAccount) of
        {ok, PrivateKey} ->
            damage_ae:set_private_key(AeAccount, PrivateKey),
            damage_ae:contract_call_payfor_user(
                AeAccount,
                get_schedules_contract(),
                damage_ae:contract_path(damage, "contracts/schedules.aes"),
                Func,
                Args
            );
        {error, _} = Error ->
            Error
    end.

maybe_cache_schedule_result(Key, Value, State) when is_list(Value); is_map(Value) ->
    cache_put(Key, Value, State);
maybe_cache_schedule_result(_Key, _Value, _State) ->
    ok.

node_secrets_ready() ->
    try secrets:node_keypair() of
        #{public_key := _Pub, private_key := PrivateKey} when is_binary(PrivateKey) ->
            true;
        _ ->
            false
    catch
        _:_ ->
            false
    end.

node_keypair() ->
    case node_secrets_ready() of
        false ->
            {error, node_locked};
        true ->
            try secrets:node_keypair() of
                #{public_key := _Pub, private_key := _Priv} = KeyPair ->
                    {ok, KeyPair};
                {error, _} = Error ->
                    Error;
                Other ->
                    {error, {invalid_node_keypair_result, Other}}
            catch
                Class:Reason ->
                    {error, {node_keypair_lookup_failed, Class, Reason}}
            end
    end.

account_private_key(AeAccount) ->
    case node_secrets_ready() of
        false ->
            {error, node_locked};
        true ->
            try identity_server:get_account(AeAccount) of
                #{public_key := _Pub, private_key := PrivateKey} ->
                    {ok, PrivateKey};
                notfound ->
                    {error, account_not_found};
                {error, _} = Error ->
                    Error;
                Other ->
                    {error, {unexpected_identity_result, Other}}
            catch
                Class:Reason ->
                    {error, {identity_lookup_failed, Class, Reason}}
            end
    end.

lock_related_reason(node_locked) -> true;
lock_related_reason(secrets_not_ready) -> true;
lock_related_reason({error, Reason}) -> lock_related_reason(Reason);
lock_related_reason(Tuple) when is_tuple(Tuple) ->
    lists:any(fun lock_related_reason/1, tuple_to_list(Tuple));
lock_related_reason(List) when is_list(List) ->
    lists:any(fun lock_related_reason/1, List);
lock_related_reason(_) -> false.

schedule_service_unavailable_reply(Req0, State, Reason) ->
    {ErrorCode, Message} =
        case lock_related_reason(Reason) of
            true ->
                {
                    <<"NODE_SECRETS_LOCKED">>,
                    <<"Node secrets are locked. Unlock the node and retry the request.">>
                };
            false ->
                {
                    <<"SCHEDULE_SERVICE_UNAVAILABLE">>,
                    <<"Schedule service is temporarily unavailable.">>
                }
        end,
    Body = jsx:encode(#{
        status => <<"notok">>,
        error => ErrorCode,
        message => Message,
        reason => to_bin(io_lib:format("~p", [Reason])),
        retryable => true
    }),
    Req = cowboy_req:reply(
        503,
        #{
            <<"content-type">> => <<"application/json">>,
            <<"cache-control">> => <<"no-store">>,
            <<"retry-after">> => <<"5">>
        },
        Body,
        Req0
    ),
    {stop, Req, State}.

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
decode_result_map(none) ->
    [];
decode_result_map(undefined) ->
    [];
decode_result_map(null) ->
    [];
decode_result_map({option, none}) ->
    [];
decode_result_map({option, {some, Results}}) ->
    Results;
decode_result_map({variant, [0, 1], 0, {}}) ->
    [];
decode_result_map({variant, [0, 1], 1, {Results}}) ->
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
