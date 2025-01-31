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
-export([list_schedules/2]).
-export([list_all_schedules/0]).
-export([load_all_schedules/0]).
-export([test_schedule/0]).
-export([test_list_schedule/0]).
-export([delete_resource/2]).
-export([cancel_all_schedules/0]).

-define(SCHEDULES_BUCKET, {<<"Default">>, <<"Schedules">>}).
-define(SCHEDULE_EXECUTION_COUNTER, {<<"counters">>, <<"ScheduleExecution">>}).
-define(TRAILS_TAG, ["Scheduling Tests"]).

trails() ->
  [
    trails:trail(
      "/schedules/[...]",
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
          description => "Delete a scheduled job",
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

delete_resource(Req, #{username := Username} = State) ->
  Deleted =
    lists:foldl(
      fun
        (DeleteId, Acc) ->
          ?LOG_DEBUG("deleted ~p ~p", [maps:get(path_info, Req), DeleteId]),
          ok = delete_schedule(Username, DeleteId),
          erlcron:cancel(DeleteId),
          Acc + 1
      end,
      0,
      maps:get(path_info, Req)
    ),
  ?LOG_INFO("deleted ~p schedules", [Deleted]),
  {true, Req, State}.


from_text(Req, #{ae_account := AeAccount, username := Username} = State) ->
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
      ae_account => AeAccount,
      feature_hash => Hash,
      concurrency => Concurrency,
      username => Username,
      cron => CronSpec
    },
  logger:info("schedule_job: ~p", [Schedule]),
  CronJob = apply(?MODULE, schedule_job, [Schedule]),
  logger:info("Cron Job: ~p", [CronJob]),
  ok = add_schedule(Username, Name, Hash, CronSpec),
  %damage_accounts:update_schedules(AeAccount, Hash, CronJob),
  Resp = cowboy_req:set_resp_body(jsx:encode(#{status => <<"ok">>}), Req),
  {stop, cowboy_req:reply(201, Resp), State}.


from_json(Req, State) -> from_text(Req, State).

from_html(Req, State) -> from_text(Req, State).

to_json(Req, #{username := Username, ae_account := AeAccount} = State) ->
  Schedules = list_schedules(Username, AeAccount),
  Body =
    jsx:encode(
      #{status => <<"ok">>, results => Schedules, length => length(Schedules)}
    ),
  logger:info("Loading scheduled for ~p ~p", [Username, Body]),
  {Body, Req, State}.


execute_bdd(
  %% Add the filter to allow PidToLog to send debug events
  #{ae_account := AeAccount, feature_hash := Hash, concurrency := Concurrency} =
    Schedule
) ->
  MinBalance = Concurrency * math:pow(10, ?DAMAGE_DECIMALS),
  case damage_ae:balance(AeAccount) of
    Balance when Balance >= MinBalance ->
      Config = damage:get_default_config(AeAccount, Concurrency, []),
      Context =
        damage_context:get_account_context(
          damage_context:get_global_template_context(Schedule)
        ),
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
)
when is_integer(Second) ->
  Job =
    {{once, {Hour, Minute, Second}}, {damage_schedule, execute_bdd, [Schedule]}},
  erlcron_cron(ScheduleId, Job);

schedule_job(#{id := ScheduleId, cron := [once, Hour, Minute, AMPM]} = Schedule)
when is_atom(AMPM) ->
  Job =
    {{once, {Hour, Minute, AMPM}}, {damage_schedule, execute_bdd, [Schedule]}},
  erlcron_cron(ScheduleId, Job);

schedule_job(#{id := ScheduleId, cron := [once, Seconds]} = Schedule)
when is_integer(Seconds) ->
  Job = {{once, Seconds}, {damage_schedule, execute_bdd, [Schedule]}},
  erlcron_cron(ScheduleId, Job).


binary_spec_to_term_spec([], Acc) -> Acc;

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

    {_LineNo, _Tags, _Feature, _Description, _BackGround, _Scenarios} -> ok
  end.


list_schedules(Username, AeAccount) ->
  {ok, AccountContract} = application:get_env(damage, account_contract),
  ?LOG_DEBUG("Contract ~p", [Username]),
  #{decodedResult := Results} =
    damage_ae:contract_call(
      Username,
      AccountContract,
      "contracts/account.aes",
      "get_schedules",
      []
    ),
  load_account_schedules(AeAccount, Results).


load_all_schedules() ->
  ?LOG_INFO("Loading all schedules ..."),
  [
    [schedule_job(Schedule) || Schedule <- AccountSchedule]
    || AccountSchedule <- list_all_schedules()
  ].


list_all_schedules() ->
  {ok, AccountContract} = application:get_env(damage, account_contract),
  {ok, AdminWallet} = application:get_env(damage, ae_wallet),
  AdminPassword = damage_utils:pass_get(ae_wallet_pass_path),
  case
  damage_ae:contract_call(
    AdminWallet,
    AdminPassword,
    AccountContract,
    "contracts/account.aes",
    "get_all_schedules",
    []
  ) of
    #{decodedResult := Results} ->
      Decrypted = decrypt_schedules(Results),
      ?LOG_DEBUG("schedules ~p", [Decrypted]),
      Decrypted;

    #{status := <<"fail">>} ->
      ?LOG_ERROR("schedules loading failed ~p", [AccountContract]),
      []
  end.


delete_schedule(Username, ScheduleId) ->
  {ok, AccountContract} = application:get_env(damage, account_contract),
  FeatureHashEncrypted = base64:encode(damage_utils:encrypt(ScheduleId)),
  #{
    decodedResult := [],
    result
    :=
    #{
      log := [],
      gasPrice := GasPrice,
      callerId := AeAccount,
      gasUsed := GasUsed,
      returnType := <<"ok">>
    }
  } =
    damage_ae:contract_call(
      Username,
      AccountContract,
      "contracts/account.aes",
      "delete_schedule",
      [FeatureHashEncrypted]
    ),
  ?LOG_DEBUG(
    "call AE contract ~p gasprice ~p gasused ~p",
    [AeAccount, GasPrice, GasUsed]
  ).


add_schedule(Username, Name, FeatureHash, Cron) ->
  {ok, AccountContract} = application:get_env(damage, account_contract),
  NameEncrypted = base64:encode(damage_utils:encrypt(Name)),
  FeatureHashEncrypted = base64:encode(damage_utils:encrypt(FeatureHash)),
  CronEncrypted = base64:encode(damage_utils:encrypt(jsx:encode(Cron))),
  #{
    decodedResult := [],
    result
    :=
    #{
      log := [],
      gasPrice := GasPrice,
      callerId := AeAccount,
      gasUsed := GasUsed,
      returnType := <<"ok">>
    }
  } =
    damage_ae:contract_call(
      Username,
      AccountContract,
      "contracts/account.aes",
      "add_schedule",
      [NameEncrypted, FeatureHashEncrypted, CronEncrypted]
    ),
  ?LOG_DEBUG(
    "call AE contract ~p gasprice ~p gasused ~p",
    [AeAccount, GasPrice, GasUsed]
  ).


cancel_all_schedules() -> [erlcron:cancel(X) || X <- erlcron:get_all_jobs()].

load_account_schedules(Account, Schedules) ->
  ?LOG_DEBUG("Accounts ~p", [Account]),
  lists:map(
    fun
      ([ScheduleId, EncryptedSchedule]) ->
        Schedule0 =
          maps:from_list(
            lists:map(
              fun
                ([<<"cron">>, Value]) ->
                  {
                    cron,
                    binary_spec_to_term_spec(
                      jsx:decode(damage_utils:decrypt(base64:decode(Value))),
                      []
                    )
                  };

                ([Key, Value]) when is_binary(Key) ->
                  {
                    binary_to_atom(Key),
                    damage_utils:decrypt(base64:decode(Value))
                  };

                ([Key, Value]) when is_list(Key) ->
                  {
                    list_to_atom(Key),
                    damage_utils:decrypt(base64:decode(Value))
                  }
              end,
              EncryptedSchedule
            )
          ),
        maps:merge(
          #{id => ScheduleId, ae_account => Account, concurrency => 1},
          Schedule0
        )
    end,
    Schedules
  ).


decrypt_schedules(EncryptedSchedules) ->
  lists:filtermap(
    fun
      ([Account, Schedules]) ->
        ?LOG_DEBUG("Account ~p", [Account]),
        load_account_schedules(Account, Schedules)
    end,
    EncryptedSchedules
  ).


test_schedule() ->
  Name = <<"test schedule">>,
  ok =
    add_schedule(
      <<"steven@stevenjoseph.in">>,
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
