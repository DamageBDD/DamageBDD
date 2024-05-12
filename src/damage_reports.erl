-module(damage_reports).

-vsn("0.1.0").

-include_lib("kernel/include/logger.hrl").

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-export([init/2]).
-export([content_types_provided/2]).
-export([to_json/2]).
-export(
  [from_json/2, allowed_methods/2, is_authorized/2]
).
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
          produces => ["text/plain"]
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
          produces => ["text/html"]
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

is_authorized(Req, State) -> damage_http:is_authorized(Req, State).

content_types_provided(Req, State) ->
  {
    [
      {{<<"application">>, <<"json">>, []}, to_json}
    ],
    Req,
    State
  }.

content_types_accepted(Req, State) ->
  {
    [
      {{<<"application">>, <<"json">>, '*'}, from_json}
    ],
    Req,
    State
  }.

allowed_methods(Req, State) -> {[<<"GET">>, <<"POST">>], Req, State}.

to_json(
  Req,
  #{action := features, contract_address := _ContractAddress} = State
) ->
  ?LOG_DEBUG("feature to ", []),
  case cowboy_req:binding(hash, Req) of
    undefined -> {<<"Path required">>, Req, State};

    Hash0 ->
      Hash = binary_to_list(Hash0),
      {cat(list_to_binary(Hash), <<"">>), Req, State}
  end;

to_json(Req, #{contract_address := ContractAddress} = State) ->
  case cowboy_req:binding(hash, Req) of
    undefined ->
      Reports =
        case cowboy_req:match_qs([{schedule_id, [], none}], Req) of
          #{schedule_id := none} ->
            do_query(#{contract_address => ContractAddress});

          #{schedule_id := ScheduleId} ->
            do_query(
              #{contract_address => ContractAddress, schedule_id => ScheduleId}
            )
        end,
      ?LOG_DEBUG("list ipfs reports ~p ", [Reports]),
      {jsx:encode(Reports), Req, State};

    Hash0 ->
      Hash = binary_to_list(Hash0),
      case cowboy_req:binding(path, Req) of
        undefined ->
          HashBin = list_to_binary(Hash),
          HashLen = length(Hash),
          List =
            list_to_binary(
              lists:join(
                <<"\n">>,
                [
                  <<
                    "<a href=\"",
                    HashBin:HashLen/binary,
                    "/",
                    X/binary,
                    "\">",
                    HashBin:HashLen/binary,
                    "/",
                    X/binary,
                    "</a><br>"
                  >>
                  ||
                  X
                  <-
                  ls(list_to_binary(string:join([Hash, "reports"], "/")))
                ]
              )
            ),
          Data = <<"<html><body>", List/binary, "</body></html>">>,
          logger:info("to text ipfs hash ~p ", [Data]),
          {Data, Req, State};

        Path ->
          Path0 = string:join(["reports", binary_to_list(Path)], "/"),
          logger:info("to text ipfs hash ~p ~p", [Hash, Path0]),
          {cat(list_to_binary(Hash), Path0), Req, State}
      end
  end.


get_record(Id) ->
  case damage_riak:get(?RUNRECORDS_BUCKET, damage_utils:decrypt(Id)) of
    {ok, Record} -> Record;
    notfound -> none
  end.
do_query_base(Fun, Index, Args, ContractAddress) ->
  case
  apply(damage_riak,Fun,[
    ?RUNRECORDS_BUCKET,
    Index] ++ Args
  ) of
    [] ->
      logger:info("no reports for account"),
      #{results => [], status => <<"ok">>, length => 0};

    Found ->
      ?LOG_DEBUG(" reports exists data: ~p ", [Found]),
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
    
do_query(#{contract_address := ContractAddress, since := Since}) ->
    StartDateTime = date_util:epoch() - 3600,
    EndDateTime = date_util:epoch(),
    ?LOG_DEBUG("Since 1 hour",[]),
    do_query_base(get_index_range, {integer_index, "created"},[StartDateTime, EndDateTime],ContractAddress);

do_query(#{contract_address := ContractAddress, schedule_id := ScheduleId}) ->
    do_query_base(get_index,
    {binary_index, "schedule_id"},
[ScheduleId],ContractAddress);

do_query(#{contract_address := ContractAddress}) ->
    do_query_base(get_index,
    {binary_index, "contract_address"},
[ContractAddress],ContractAddress).



from_json(Req, #{contract_address := ContractAddress}=State) ->
  {ok, Data, _Req2} = cowboy_req:read_body(Req),
  {Status, Resp0} =
    case catch jsx:decode(Data, [{labels, atom}, return_maps]) of
      {'EXIT', {badarg, Trace}} ->
        logger:error("json decoding failed ~p err: ~p.", [Data, Trace]),
        {400, <<"Json decoding failed.">>};
      PostData ->
            QueryData = maps:merge(PostData,#{contract_address => ContractAddress}),
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
