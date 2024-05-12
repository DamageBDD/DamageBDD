-module(damage_schedule).

-vsn("0.1.0").

-include_lib("eunit/include/eunit.hrl").

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
-export([run_schedule_job/3]).
-export([run_schedule_job/5]).
-export([run_schedule_job/6]).
-export([load_all_schedules/0]).
-export([list_schedules/1]).
-export([list_all_schedules/0]).
-export([test_conflict_resolution/0]).
-export([clean_schedules/0]).
-export([delete_resource/2]).
-export([get_schedule/1]).

-include_lib("kernel/include/logger.hrl").

-define(SCHEDULES_BUCKET, {<<"Default">>, <<"Schedules">>}).
-define(SCHEDULE_EXECUTION_COUNTER, {<<"counters">>, <<"ScheduleExecution">>}).
-define(TRAILS_TAG, ["Scheduling Tests"]).

trails() ->
  [
    trails:trail(
      "/schedule/[...]",
      damage_schedule,
      #{},
      #{
        get
        =>
        #{
          tags => ?TRAILS_TAG,
          description => "Form to schedule a test execution.",
          produces => ["text/html"]
        },
        put
        =>
        #{
          tags => ?TRAILS_TAG,
          description => "Schedule a test on post",
          produces => ["application/json"],
          parameters
          =>
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
        delete
        =>
        #{
          tags => ?TRAILS_TAG,
          description => "Schedule a test on post",
          produces => ["application/json"],
          parameters => []
        }
      }
    )
  ].

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

delete_resource(Req, State) ->
  Deleted =
    lists:foldl(
      fun
        (DeleteId, Acc) ->
          ?LOG_DEBUG("deleted ~p ~p", [maps:get(path_info, Req), DeleteId]),
          ok = damage_riak:delete(?SCHEDULES_BUCKET, DeleteId),
          Acc + 1
      end,
      0,
      maps:get(path_info, Req)
    ),
  ?LOG_INFO("deleted ~p schedules", [Deleted]),
  {true, Req, State}.


from_text(Req, #{contract_address := ContractAddress} = State) ->
  ?LOG_DEBUG("From text ~p", [Req]),
  {ok, Body, _} = cowboy_req:read_body(Req),
  ok = validate(Body),
  CronSpec = binary_spec_to_term_spec(cowboy_req:path_info(Req), []),
  Concurrency = cowboy_req:header(<<"x-damage-concurrency">>, Req, 1),
  FeatureTitle = lists:nth(1, binary:split(Body, <<"\n">>, [global])),
  ?LOG_DEBUG("Cron Spec: ~p", [CronSpec]),
  {ok, [#{<<"Hash">> := Hash}]} =
    damage_ipfs:add({data, Body, <<"Scheduledjob">>}),
  ScheduleId = damage_utils:idhash_keys([ContractAddress, Hash]),
  Args = [ScheduleId] ++ CronSpec,
  logger:info("run_schedule_job: ~p", [Args]),
  CronJob = apply(?MODULE, run_schedule_job, Args),
  Created = date_util:now_to_seconds_hires(os:timestamp()),
  logger:info("Cron Job: ~p", [CronJob]),
  {ok, true} =
    save_schedule(
      #{
        created => Created,
        modified => Created,
        contract_address => ContractAddress,
        hash => Hash,
        concurrency => Concurrency,
        feature_title => FeatureTitle,
        cronspec => CronSpec
      }
    ),
  %damage_accounts:update_schedules(ContractAddress, Hash, CronJob),
  Resp = cowboy_req:set_resp_body(jsx:encode(#{status => <<"ok">>}), Req),
  {stop, cowboy_req:reply(201, Resp), State}.


from_json(Req, State) -> from_text(Req, State).

from_html(Req, State) -> from_text(Req, State).


to_json(Req, #{contract_address := ContractAddress} = State) ->
  Body = jsx:encode(list_schedules(ContractAddress)),
  logger:info("Loading scheduled for ~p ~p", [ContractAddress, Body]),
  {Body, Req, State}.


save_schedule(
  #{contract_address := ContractAddress, hash := Hash, cronspec := _CronSpec} =
    Schedule
) ->
  ScheduleId = damage_utils:idhash_keys([ContractAddress, Hash]),
  Schedule0 =
    case damage_riak:get(?SCHEDULES_BUCKET, ScheduleId) of
      notfound ->
        logger:error("failed to load  schedule ~p", [ScheduleId]),
        Schedule;

      {ok, ScheduleObj} ->
        ?LOG_DEBUG("loaded  schedule ~p", [ScheduleObj]),
        maps:merge(ScheduleObj, Schedule)
    end,
  ?LOG_DEBUG("saving  schedule ~p", [Schedule0]),
  {ok, true} =
    damage_riak:put(
      ?SCHEDULES_BUCKET,
      ScheduleId,
      Schedule0,
      [{{binary_index, "contract_address"}, [ContractAddress]}]
    ).


execute_bdd(ScheduleId) ->
  %% Add the filter to allow PidToLog to send debug events
  case get_schedule(ScheduleId) of
    none -> ?LOG_ERROR("scheduledid  not found ~p.", [ScheduleId]);

    #{
      contract_address := ContractAddress,
      hash := Hash,
      concurrency := Concurrency,
      id := ScheduleId0
    } = Schedule ->
      logger:info(
        "scheduled job execution ~p ContractAddress ~p, Hash ~p.",
        [Schedule, ContractAddress, Hash]
      ),
      Config =
        [
          {schedule_id, ScheduleId}
          | damage:get_default_config(ContractAddress, Concurrency, [])
        ],
      Context =
        damage_context:get_account_context(
          maps:put(
            contract_address,
            ContractAddress,
            damage_context:get_global_template_context(
              #{schedule_id => ScheduleId}
            )
          )
        ),
      {run_dir, RunDir} = lists:keyfind(run_dir, 1, Config),
      {run_id, RunId} = lists:keyfind(run_id, 1, Config),
      BddFileName = filename:join(RunDir, string:join([RunId, ".feature"], "")),
      ok = damage_ipfs:get(Hash, BddFileName),
      ?LOG_DEBUG(
        "scheduled job execution config ~p feature ~p scheduleid ~p.",
        [Config, BddFileName, Hash]
      ),
      Result = damage:execute_file(Config, Context, BddFileName),
      true =
        damage_riak:update_counter(
          ?SCHEDULE_EXECUTION_COUNTER,
          ScheduleId,
          {increment, 1}
        ),
      {ok, true} =
        damage_riak:put(
          ?SCHEDULES_BUCKET,
          ScheduleId0,
          maps:put(last_excution_timestamp, list_to_binary(RunId), Schedule),
          [{{binary_index, "contract_address"}, [ContractAddress]}]
        ),
      Result
  end.


run_schedule_job(ScheduleId, daily, every, Hour, Minute, AMPM) ->
  Job =
    {{once, {Hour, Minute, AMPM}}, {damage_schedule, execute_bdd, [ScheduleId]}},
  erlcron:cron(ScheduleId, Job).


run_schedule_job(ScheduleId, daily, every, Second, sec) ->
  Job =
    {
      {daily, {every, {Second, sec}}},
      {damage_schedule, execute_bdd, [ScheduleId]}
    },
  erlcron:cron(ScheduleId, Job);

run_schedule_job(ScheduleId, once, Hour, Minute, Second) when is_integer(Second) ->
  Job =
    {
      {once, {Hour, Minute, Second}},
      {damage_schedule, execute_bdd, [ScheduleId]}
    },
  erlcron:cron(ScheduleId, Job);

run_schedule_job(ScheduleId, once, Hour, Minute, AMPM) when is_atom(AMPM) ->
  Job =
    {{once, {Hour, Minute, AMPM}}, {damage_schedule, execute_bdd, [ScheduleId]}},
  erlcron:cron(ScheduleId, Job).


run_schedule_job(ScheduleId, once, Seconds) when is_integer(Seconds) ->
  Job = {{once, Seconds}, {damage_schedule, execute_bdd, [ScheduleId]}},
  erlcron:cron(ScheduleId, Job).


binary_spec_to_term_spec([], Acc) -> Acc;

binary_spec_to_term_spec([Spec | Rest], Acc) ->
  Term =
    case catch binary_to_integer(Spec) of
      {'EXIT', _} -> binary_to_atom(Spec);
      Int -> Int
    end,
  binary_spec_to_term_spec(Rest, Acc ++ [Term]).


validate(Gherkin) ->
  case catch egherkin:parse(Gherkin) of
    {failed, LineNo, Message} ->
      logger:error("Parsing Failed LineNo +~p ~n     ~p.", [LineNo, Message]),
      {parse_error, LineNo, Message};

    {_LineNo, _Tags, _Feature, _Description, _BackGround, _Scenarios} -> ok
  end.


get_schedule_unencrypted(ScheduleId) ->
  case damage_riak:get(?SCHEDULES_BUCKET, ScheduleId) of
    {ok, Schedule} ->
      ?LOG_DEBUG("Loaded Schedulid ~p", [ScheduleId]),
      maps:put(id, ScheduleId, Schedule);

    _ -> none
  end.


get_schedule(ScheduleId) when is_binary(ScheduleId) ->
  case catch damage_utils:decrypt(ScheduleId) of
    error ->
      ?LOG_DEBUG("ScheduleId Decryption error ~p ", [ScheduleId]),
      get_schedule_unencrypted(ScheduleId);

    {'EXIT', _Error} ->
      ?LOG_DEBUG("ScheduleId Decryption error ~p ", [ScheduleId]),
      get_schedule_unencrypted(ScheduleId);

    ScheduleIdDecrypted -> get_schedule_unencrypted(ScheduleIdDecrypted)
  end;

get_schedule(_) -> none.


list_get_schedule(ScheduleId) ->
  #{id := ScheduleId0} = Schedule = get_schedule(ScheduleId),
  maps:put(
    execution_counter,
    damage_riak:counter_value(?SCHEDULE_EXECUTION_COUNTER, ScheduleId0),
    Schedule
  ).


list_schedules(ContractAddress) ->
  ?LOG_DEBUG("Contract ~p", [ContractAddress]),
  lists:filter(
    fun (none) -> false; (_Other) -> true end,
    [
      list_get_schedule(ScheduleId)
      ||
      ScheduleId
      <-
      damage_riak:get_index(
        ?SCHEDULES_BUCKET,
        {binary_index, "contract_address"},
        ContractAddress
      )
    ]
  ).


load_schedule(Schedule) ->
  #{cronspec := Args, id:=Id} = Schedule,
    Args0 = lists:map(fun(A) when is_binary(A) -> binary_to_atom(A);(A)->A end, Args),
  logger:info("run_schedule_job: ~p", [Args0]),
  CronJob = apply(?MODULE, run_schedule_job, [Id] ++ Args0),
  logger:info("load_schedule: ~p", [CronJob]).


load_all_schedules() ->
  [load_schedule(Schedule) || Schedule <- list_all_schedules()].

list_all_schedules() ->
  lists:filter(
    fun (none) -> false; (_Other) -> true end,
    [
      get_schedule(ScheduleId)
      || ScheduleId <- damage_riak:list_keys(?SCHEDULES_BUCKET)
    ]
  ).

test_conflict_resolution() -> list_all_schedules().

clean_schedule(ScheduleId) ->
  case catch damage_utils:decrypt(ScheduleId) of
    error ->
      ?LOG_DEBUG("ScheduleId Decryption error ~p ", [ScheduleId]),
      ok = damage_riak:delete(?SCHEDULES_BUCKET, ScheduleId),
      none;

    {'EXIT', _Error} ->
      ?LOG_DEBUG("ScheduleId Decryption error ~p ", [ScheduleId]),
      ok = damage_riak:delete(?SCHEDULES_BUCKET, ScheduleId),
      none;

    ScheduleIdDecrypted ->
      case damage_riak:get(?SCHEDULES_BUCKET, ScheduleIdDecrypted) of
        {ok, Schedule} ->
          ?LOG_DEBUG("Loaded Schedulid ~p", [ScheduleIdDecrypted]),
          Schedule;

        Unexpected ->
          ?LOG_DEBUG("ScheduleId Decryption error ~p ", [Unexpected]),
          none
      end
  end.


clean_schedules() ->
  [
    clean_schedule(Schedule)
    || Schedule <- damage_riak:list_keys(?SCHEDULES_BUCKET)
  ].

%update_schedules(ContractAddress, JobId, _Cron) ->
%  ContractCall =
%    damage_ae:aecli(
%      contract,
%      call,
%      binary_to_list(ContractAddress),
%      "contracts/account.aes",
%      "update_schedules",
%      [JobId]
%    ),
%  ?LOG_DEBUG("call AE contract ~p", [ContractCall]),
%  #{
%    decodedResult
%    :=
%    #{
%      btc_address := _BtcAddress,
%      btc_balance := _BtcBalance,
%      deso_address := _DesoAddress,
%      deso_balance := _DesoBalance,
%      usage := _Usage,
%      deployer := _Deployer
%    } = Results
%  } = ContractCall,
%  ?LOG_DEBUG("State ~p ", [Results]).
