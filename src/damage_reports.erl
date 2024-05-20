-module(damage_reports).

-vsn("0.1.0").

-include_lib("kernel/include/logger.hrl").

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-export([init/2]).
-export([content_types_provided/2]).
-export([to_json/2]).
-export([to_html/2]).
-export([from_json/2, allowed_methods/2, is_authorized/2]).
-export([clean_reports/0]).
-export([test/0]).
-export([ls/1]).
-export([content_types_accepted/2]).
-export([trails/0]).

-include_lib("kernel/include/logger.hrl").
-include_lib("damage.hrl").

-define(TRAILS_TAG, ["Test Reports"]).

trails() ->
  [
    trails:trail(
      "/features/:hash/",
      damage_reports,
      #{action => features},
      #{
        get
        =>
        #{
          tags => ?TRAILS_TAG,
          description => "Get the test feature data.",
          produces => ["text/plain", "application/json", "text/html"]
        }
      }
    ),
    trails:trail(
      "/reports/",
      damage_reports,
      #{}
      #{
        get
        =>
        #{
          tags => ?TRAILS_TAG,
          description => "List test execution report directory .",
          produces => ["text/html"]
        }
      }
    ),
    trails:trail(
      "/reports/:hash/[:path]",
      damage_reports,
      #{}
      #{
        get
        =>
        #{
          tags => ?TRAILS_TAG,
          description => "List test execution report directory .",
          produces => ["text/html", "application/json"]
        },
        put
        =>
        #{
          tags => ?TRAILS_TAG,
          description => "Query test reports",
          produces => ["application/json"],
          parameters
          =>
          [
            #{
              name => <<"start">>,
              description
              =>
              <<"Include Test execution reports from `start` date .">>,
              in => <<"body">>,
              required => false,
              type => <<"string">>
            },
            #{
              name => <<"end">>,
              description
              =>
              <<"Include test execution reports to `end` date .">>,
              in => <<"body">>,
              required => false,
              type => <<"string">>
            },
            #{
              name => <<"tags">>,
              description
              =>
              <<"Include Test execution reports with tags matching `tags`.">>,
              in => <<"body">>,
              required => false,
              type => <<"string">>
            }
          ]
        }
      }
    )
  ].

init(Req, Opts) -> {cowboy_rest, Req, Opts}.

is_authorized(Req, State) ->
  case cowboy_req:binding(hash, Req) of
    undefined -> damage_http:is_authorized(Req, State);
    Hash -> {true, Req, maps:put(hash, Hash, State)}
  end.


content_types_provided(Req, State) ->
  {
    [
      {{<<"application">>, <<"json">>, []}, to_json},
      {{<<"text">>, <<"html">>, []}, to_html},
      {{<<"text">>, <<"plain">>, []}, to_json}
    ],
    Req,
    State
  }.

content_types_accepted(Req, State) ->
  {[{{<<"application">>, <<"json">>, '*'}, from_json}], Req, State}.

allowed_methods(Req, State) -> {[<<"GET">>, <<"POST">>], Req, State}.

to_html(Req, #{action := features} = State) ->
  ?LOG_DEBUG("feature to ", []),
  case cowboy_req:binding(hash, Req) of
    undefined -> {<<"Hash required">>, Req, State};

    Hash0 ->
      Hash = binary_to_list(Hash0),
      FeatureData = cat(list_to_binary(Hash), <<"">>),
      FeatureTitle =
        lists:nth(1, binary:split(FeatureData, <<"\n">>, [global])),
      Body =
        damage_utils:load_template(
          "feature.mustache",
          #{body => FeatureData, feature_title => FeatureTitle}
        ),
      {Body, Req, State}
  end;

to_html(Req, #{hash := Hash} = State) ->
  case cowboy_req:binding(path, Req) of
    undefined ->
      {ok, DamageApi} = application:get_env(damage, api_url),
      Dir =
        ls(list_to_binary(string:join([binary_to_list(Hash), "reports"], "/"))),
      List =
        list_to_binary(
          string:join(
            [
              mustache:render(
                "<a href=\"{{api_url}}/reports/{{hash}}/{{file}}\">{{hash}}/{{file}}</a>",
                [
                  {api_url, DamageApi},
                  {hash, binary_to_list(Hash)},
                  {file, binary_to_list(X)}
                ]
              )
              || X <- Dir
            ],
            "<br>"
          )
        ),
      Data = <<"<html><body>", List/binary, "</body></html>">>,
      {Data, Req, State};

    Path ->
      Path0 = string:join(["reports", binary_to_list(Path)], "/"),
      ?LOG_DEBUG(" cat hash ~p", [Hash]),
      {cat(Hash, Path0), Req, State}
  end.


to_json(Req, #{action := features} = State) ->
  ?LOG_DEBUG("feature to ", []),
  case cowboy_req:binding(hash, Req) of
    undefined -> {<<"Path required">>, Req, State};

    Hash0 ->
      Hash = binary_to_list(Hash0),
      {cat(list_to_binary(Hash), <<"">>), Req, State}
  end;

to_json(Req, #{contract_address := ContractAddress} = State) ->
  Reports =
    case cowboy_req:match_qs([{schedule_id, [], none}], Req) of
      #{schedule_id := none} ->
        do_query(#{contract_address => ContractAddress});

      #{schedule_id := ScheduleId} ->
        do_query(
          #{contract_address => ContractAddress, schedule_id => ScheduleId}
        )
    end,
  {jsx:encode(Reports), Req, State};

to_json(Req, #{hash := Hash0} = State) ->
  {jsx:encode(get_reports(Req, Hash0)), Req, State}.


get_reports(Req, Hash) ->
  case cowboy_req:binding(path, Req) of
    undefined ->
      ls(list_to_binary(string:join([binary_to_list(Hash), "reports"], "/")));

    Path ->
      Path0 = string:join(["reports", binary_to_list(Path)], "/"),
      ?LOG_DEBUG(" cat hash ~p", [Hash]),
      cat(Hash, Path0)
  end.


get_record(Id) ->
  case damage_riak:get(?RUNRECORDS_BUCKET, damage_utils:decrypt(Id)) of
    {ok, Record} -> Record;
    notfound -> none
  end.


do_query_base(Fun, Index, Args, ContractAddress) ->
  Args0 = [?RUNRECORDS_BUCKET, Index] ++ Args ++ [[{max_results, 30}]],
  ?LOG_DEBUG("riak query index ~p", [Args0]),
  case apply(damage_riak, Fun, Args0) of
    [] ->
      logger:info("no reports for account ~p ~p", [Index, Args]),
      #{results => [], status => <<"ok">>, length => 0};

    Found ->
      Results =
        lists:filter(
          fun
            (none) -> false;

            (#{contract_address := ContractAddress0})
            when ContractAddress0 =:= ContractAddress ->
              true
          end,
          [get_record(X) || X <- Found]
        ),
      #{results => Results, status => <<"ok">>, length => length(Results)}
  end.


since_seconds(hours, Value) -> Value * 3600;
since_seconds(hour, Value) -> Value * 3600;
since_seconds(secs, Value) -> Value;
since_seconds(seconds, Value) -> Value;
since_seconds(day, Value) -> Value * 3600 * 24;
since_seconds(days, Value) -> Value * 3600 * 24;
since_seconds(week, Value) -> Value * 3600 * 24 * 7;
since_seconds(weeks, Value) -> Value * 3600 * 24 * 7.

range_query(StartDateTime0, EndDateTime0, Prefix, ContractAddress) ->
  StartDateTime = list_to_integer(Prefix ++ integer_to_list(StartDateTime0)),
  EndDateTime = list_to_integer(Prefix ++ integer_to_list(EndDateTime0)),
  ?LOG_DEBUG("Since ~p to ~p", [StartDateTime, EndDateTime]),
  do_query_base(
    get_index_range,
    {integer_index, "result_status"},
    [StartDateTime, EndDateTime],
    ContractAddress
  ).


do_query(
  #{contract_address := ContractAddress, since := Since0, status := Status}
) ->
  Since = binary_to_list(Since0),
  case
  re:run(
    Since,
    "([0-9]+)(hours|hour|secs|seconds|day|days|week|weeks)",
    [{capture, [1, 2]}]
  ) of
    {match, [{0, End}, {UnitStart, UnitEnd}]} ->
      StartDateTime0 =
        date_util:epoch()
        -
        since_seconds(
          list_to_atom(string:substr(Since, UnitStart + 1, UnitEnd)),
          list_to_integer(string:substr(Since, 1, End))
        ),
      EndDateTime0 = date_util:epoch(),
      case Status of
        <<"fail">> ->
          range_query(
            StartDateTime0,
            EndDateTime0,
            ?RESULT_STATUS_PREFIX_FAIL,
            ContractAddress
          );

        <<"success">> ->
          range_query(
            StartDateTime0,
            EndDateTime0,
            ?RESULT_STATUS_PREFIX_SUCCESS,
            ContractAddress
          )
      end;

    Other ->
      ?LOG_DEBUG("Invalid query ~p", [Other]),
      <<"Invalid query.">>
  end;

do_query(#{contract_address := ContractAddress, since := Since0}) ->
  Since = binary_to_list(Since0),
  case
  re:run(
    Since,
    "([0-9]+)(hours|hour|secs|seconds|day|days|week|weeks)",
    [{capture, [1, 2]}]
  ) of
    {match, [{0, End}, {UnitStart, UnitEnd}]} ->
      StartDateTime =
        date_util:epoch()
        -
        since_seconds(
          list_to_atom(string:substr(Since, UnitStart + 1, UnitEnd)),
          list_to_integer(string:substr(Since, 1, End))
        ),
      EndDateTime = date_util:epoch(),
      ?LOG_DEBUG("Since ~p", [StartDateTime]),
      do_query_base(
        get_index_range,
        {integer_index, "created"},
        [StartDateTime, EndDateTime],
        ContractAddress
      );

    Other ->
      ?LOG_DEBUG("Invalid query ~p", [Other]),
      <<"Invalid query.">>
  end;

do_query(#{contract_address := ContractAddress, schedule_id := ScheduleId}) ->
  do_query_base(
    get_index,
    {binary_index, "schedule_id"},
    [ScheduleId],
    ContractAddress
  );

do_query(#{contract_address := ContractAddress}) ->
  do_query_base(
    get_index,
    {binary_index, "contract_address"},
    [ContractAddress],
    ContractAddress
  ).


from_json(Req, #{contract_address := ContractAddress} = State) ->
  {ok, Data, _Req2} = cowboy_req:read_body(Req),
  {Status, Resp0} =
    case catch jsx:decode(Data, [{labels, atom}, return_maps]) of
      {'EXIT', {badarg, Trace}} ->
        logger:error("json decoding failed ~p err: ~p.", [Data, Trace]),
        {400, <<"Json decoding failed.">>};

      PostData ->
        QueryData =
          maps:merge(PostData, #{contract_address => ContractAddress}),
        ?LOG_DEBUG("Query data ~p", [QueryData]),
        {200, do_query(QueryData)}
    end,
  Resp = cowboy_req:set_resp_body(jsx:encode(Resp0), Req),
  cowboy_req:reply(Status, Resp),
  {stop, Resp, State}.


ls(Hash) ->
  {
    ok,
    [#{<<"Objects">> := [#{<<"Hash">> := Hash, <<"Links">> := Links} | _Rest]}]
  } = damage_ipfs:ls(Hash),
  logger:info("get ipfs hash ~p ", [Hash]),
  [maps:get(<<"Name">>, M) || M <- Links].


cat(Hash, Path) ->
  {ok, Data} =
    damage_ipfs:cat(
      list_to_binary(string:join([binary_to_list(Hash), Path], "/"))
    ),
  logger:info("get ipfs hash ~p ", [Hash]),
  Data.


test() ->
  {
    ok,
    [#{<<"Objects">> := [#{<<"Hash">> := Hash, <<"Links">> := Links} | Rest]}]
  } = damage_ipfs:test(),
  logger:info("list ipfs directory ~p ~p ~p", [Hash, Links, Rest]).


clean_record(#{result := Result} = Record, Key) when is_list(Result) ->
  ?LOG_INFO("deleting invalid record~p", [Key]),
  damage_riak:delete(?RUNRECORDS_BUCKET, damage_utils:decrypt(Key)),
  Record;

clean_record(#{run_id := RunId} = Record, Key) when is_list(RunId) ->
  ?LOG_INFO("deleting invalid record~p", [Key]),
  damage_riak:delete(?RUNRECORDS_BUCKET, damage_utils:decrypt(Key)),
  Record;

clean_record(Record, Key) ->
  ?LOG_INFO("record ~p", [Key]),
  Record.


clean_record(RecordId) -> clean_record(get_record(RecordId), RecordId).

clean_reports() ->
  case damage_riak:list_keys(?RUNRECORDS_BUCKET) of
    [] ->
      logger:info("no reports for account"),
      [];

    Found ->
      ?LOG_DEBUG(" reports exists data: ~p ", [Found]),
      Results = [clean_record(X) || X <- Found],
      #{results => Results, status => <<"ok">>, length => length(Results)}
  end.
