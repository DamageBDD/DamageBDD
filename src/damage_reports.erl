-module(damage_reports).

-vsn("0.1.0").

-include_lib("kernel/include/logger.hrl").

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-export([init/2]).
-export([content_types_provided/2]).
-export([to_html/2]).
-export([to_json/2]).
-export([to_text/2]).
-export(
  [from_json/2, allowed_methods/2, from_html/2, from_yaml/2, is_authorized/2]
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
      {{<<"application">>, <<"x-www-form-urlencoded">>, '*'}, from_html},
      {{<<"application">>, <<"x-yaml">>, '*'}, from_yaml},
      {{<<"application">>, <<"json">>, '*'}, from_json}
    ],
    Req,
    State
  }.

allowed_methods(Req, State) -> {[<<"GET">>, <<"POST">>], Req, State}.

to_html(
  Req,
  #{action := features, contract_address := _ContractAddress} = State
) ->
  ?LOG_DEBUG("feature to ", []),
  to_text(Req, State);

to_html(Req, State) -> to_text(Req, State).


%logger:error("to text ipfs hash ~p ", [Req]),
%Body = damage_utils:load_template("report.mustache", [{body, <<"Test">>}]),
%logger:info("get ipfs hash ~p ", [Body]),
%{Body, Req, State}.
to_json(Req, State) -> to_text(Req, State).

to_text(
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

to_text(Req, #{contract_address := ContractAddress} = State) ->
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


do_query(#{contract_address := ContractAddress, schedule_id := ScheduleId}) ->
  case
  damage_riak:get_index(
    ?RUNRECORDS_BUCKET,
    {binary_index, "schedule_id"},
    ScheduleId
  ) of
    [] ->
      logger:info("no reports for account"),
      [];

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
  end;

do_query(#{contract_address := ContractAddress}) ->
  case
  damage_riak:get_index(
    ?RUNRECORDS_BUCKET,
    {binary_index, "contract_address"},
    ContractAddress
  ) of
    [] ->
      logger:info("no reports for account"),
      [];

    Found ->
      ?LOG_DEBUG(" reports exists data: ~p ", [Found]),
      Results =
        lists:filter(
          fun (none) -> false; (_) -> true end,
          [get_record(X) || X <- Found]
        ),
      #{results => Results, status => <<"ok">>, length => length(Results)}
  end.


do_action(<<"query_from_yaml">>, Req) ->
  {ok, Data, _Req2} = cowboy_req:read_body(Req),
  ?LOG_DEBUG(" yaml data: ~p ", [Data]),
  {ok, [Data0]} = fast_yaml:decode(Data, [maps]),
  do_query(Data0);

do_action(<<"create_from_json">>, Req) ->
  {ok, Data, _Req2} = cowboy_req:read_body(Req),
  ?LOG_DEBUG(" json data: ~p ", [Data]),
  Data0 = jsx:decode(Data, [return_maps]),
  do_query(Data0);

do_action(<<"create">>, Req) ->
  {ok, Data, _Req2} = cowboy_req:read_body(Req),
  ?LOG_DEBUG("Form data ~p", [Data]),
  FormData = maps:from_list(cow_qs:parse_qs(Data)),
  do_query(FormData).


from_html(Req, State) ->
  Result = do_action(cowboy_req:binding(action, Req), Req),
  Body = damage_utils:load_template("create_account.mustache", Result),
  Resp = cowboy_req:set_resp_body(Body, Req),
  {stop, cowboy_req:reply(200, Resp), State}.


from_json(Req, #{contract_address := ContractAddress} = State) ->
  Result =
    case cowboy_req:binding(action, Req) of
      undefined -> do_query(#{contract_address => ContractAddress});
      Action -> do_action(<<Action/binary, "_from_json">>, Req)
    end,
  JsonResult = jsx:encode(Result),
  Resp = cowboy_req:set_resp_body(JsonResult, Req),
  {stop, cowboy_req:reply(200, Resp), State}.


from_yaml(Req, State) ->
  Action = cowboy_req:binding(action, Req),
  Result = do_action(<<Action/binary, "_from_yaml">>, Req),
  YamlResult = fast_yaml:encode(Result),
  Resp = cowboy_req:set_resp_body(YamlResult, Req),
  {stop, cowboy_req:reply(200, Resp), State}.


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
