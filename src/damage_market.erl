-module(damage_market).

-vsn("0.1.0").

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([init/2]).
-export([content_types_accepted/2]).
-export([content_types_provided/2]).
-export([to_html/2]).
-export([to_json/2]).
-export([to_text/2]).
-export([from_json/2, from_yaml/2, allowed_methods/2, from_html/2]).
-export([is_authorized/2]).
-export([trails/0]).

-include_lib("kernel/include/logger.hrl").
-include_lib("damage.hrl").

-define(TRAILS_TAG, ["Publish Tests For Open Market Execution"]).

trails() ->
  [
    trails:trail(
      "/publish_feature/",
      damage_market,
      #{action => publish},
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
          produces => ["application/json", "application/x-yaml"],
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
        }
      }
    ),
    trails:trail(
      "/bid_feature/",
      damage_market,
      #{action => bid},
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
          produces => ["application/json", "application/x-yaml"],
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

to_html(Req, State) ->
  logger:error("to text ipfs hash ~p ", [Req]),
  to_text(Req, State).


%logger:error("to text ipfs hash ~p ", [Req]),
%Body = damage_utils:load_template("report.mustache", [{body, <<"Test">>}]),
%logger:info("get ipfs hash ~p ", [Body]),
%{Body, Req, State}.
to_json(Req, State) ->
  logger:error("to text ipfs hash ~p ", [Req]),
  to_text(Req, State).


to_text(Req, #{ae_account := AeAccount} = State) ->
  Reports = do_query(#{ae_account => AeAccount}),
  ?LOG_DEBUG("list published contracts ~p ", [Reports]),
  {jsx:encode(Reports), Req, State}.


from_yaml(Req, #{action := reset_password, action := Action} = State) ->
  {ok, Data, _Req2} = cowboy_req:read_body(Req),
  {Status0, Response0} =
    case fast_yaml:decode(Data, [maps, {plain_as_atom, true}]) of
      {ok, [#{feature := _FeatureData, concurrency := _Concurrency} = Data0]} ->
        do_action(Action, Data0, State);

      {error, Message} -> {400, #{status => <<"failed">>, message => Message}}
    end,
  ?LOG_DEBUG("post action ~p resp ~p", [Data, Response0]),
  {
    stop,
    cowboy_req:reply(
      Status0,
      cowboy_req:set_resp_body(fast_yaml:encode(Response0), Req)
    ),
    State
  }.


from_json(Req, #{action := Action} = State) ->
  {ok, Data, _Req2} = cowboy_req:read_body(Req),
  {Status, Resp0} =
    case jsx:decode(Data, [{labels, atom}, return_maps]) of
      #{feature := _FeatureData, concurrency := _Concurrency} = FeatureJson ->
        do_action(Action, FeatureJson, State);

      Err ->
        logger:error("json decoding failed ~p.", [Data]),
        {400, jsx:encode(#{status => <<"notok">>, result => [Err]})}
    end,
  Resp = cowboy_req:set_resp_body(Resp0, Req),
  cowboy_req:reply(Status, Resp),
  {stop, Resp, State}.


from_html(Req0, #{action := Action} = State) ->
  {ok, Body, Req} = cowboy_req:read_body(Req0),
  Concurrency =
    binary_to_integer(
      cowboy_req:header(<<"x-damage-concurrency">>, Req0, <<"1">>)
    ),
  Fee =
    binary_to_integer(cowboy_req:header(<<"x-damage-fee">>, Req0, <<"4000">>)),
  {Status, Resp0} =
    do_action(
      Action,
      #{feature => Body, concurrency => Concurrency, fee => Fee},
      State
    ),
  Res1 = cowboy_req:set_resp_body(Resp0, Req),
  cowboy_req:reply(Status, Res1),
  {stop, Res1, State}.


do_query(#{ae_account := AeAccount}) ->
  case damage_ae:get_published(AeAccount) of
    [] ->
      logger:info("no reports for account"),
      [];

    Results ->
      #{results => Results, status => <<"ok">>, length => length(Results)}
  end.


do_action(bid_feature, Data, State) -> check_bid_feature(Data, State);
do_action(publish_feature, Data, State) -> check_publish_bdd(Data, State).

check_bid_feature(
  #{feature := FeatureHash} = _FeaturePayload,
  #{ae_account := AeAccount, ip := IP} = State
) ->
  case throttle:check(damage_api_rate, IP) of
    {limit_exceeded, _, _} ->
      lager:warning("IP ~p exceeded api limit", [IP]),
      {error, 429, "Rate limited"};

    _ ->
      case damage_ae:balance(AeAccount) of
        Balance when Balance > 0 ->
          case bid_feature(FeatureHash, State) of
            {Status, Response} -> {Status, Response}
          end;

        Other ->
          {
            400,
            <<
              "Insufficient balance, please top up balance at `/api/accounts/topup` balance:",
              Other/binary
            >>
          }
      end
  end.


check_publish_bdd(#{concurrency := Concurrency} = FeaturePayload, State)
when is_binary(Concurrency) ->
  check_publish_bdd(
    maps:put(concurrency, binary_to_integer(Concurrency), FeaturePayload),
    State
  );

check_publish_bdd(#{fee := Fee} = FeaturePayload, State) when is_binary(Fee) ->
  check_publish_bdd(
    maps:put(fee, binary_to_integer(Fee), FeaturePayload),
    State
  );

check_publish_bdd(
  #{concurrency := Concurrency0} = FeaturePayload,
  #{ae_account := AeAccount, ip := IP} = State
) ->
  Concurrency = damage_utils:get_concurrency_level(Concurrency0),
  case throttle:check(damage_api_rate, IP) of
    {limit_exceeded, _, _} ->
      lager:warning("IP ~p exceeded api limit", [IP]),
      {error, 429, "Rate limited"};

    _ ->
      case damage_ae:balance(AeAccount) of
        Balance when Balance >= Concurrency ->
          case publish_bdd(FeaturePayload, State) of
            {Status, Response} -> {Status, Response}
          end;

        Other ->
          {
            400,
            <<
              "Insufficient balance, please top up balance at `/api/accounts/topup` balance:",
              Other/binary
            >>
          }
      end
  end.


publish_data(RunDir, Username, AeAccount, FeatureData, Fee, Concurrency) ->
  BddFileName =
    filename:join(RunDir, string:join(["adhoc_http_publish.feature"], "")),
  ok = file:write_file(BddFileName, FeatureData),
  publish_file(Username, AeAccount, BddFileName, Fee, Concurrency).


publish_file(Username, AeAccount, Filename, Fee, Concurrency) ->
  {ok, [#{<<"Hash">> := Hash, <<"Name">> := _Name, <<"Size">> := _Size}]} =
    damage_ipfs:add({file, Filename}),
  {ok, AccountContract} = application:get_env(damage, account_contract),
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
      "contracts/market.aes",
      "publish_feature",
      [Hash, Fee, Concurrency]
    ),
  ?LOG_DEBUG(
    "call AE contract ~p gasprice ~p gasused ~p",
    [AeAccount, GasPrice, GasUsed]
  ).


publish_bdd(
  #{feature := FeatureData, concurrency := Concurrency, fee := Fee} =
    _FeaturePayload,
  #{ae_account := AeAccount, username := Username} = _State
) ->
  Config = damage:get_default_config(AeAccount, Concurrency),
  {run_dir, RunDir} = lists:keyfind(run_dir, 1, Config),
  case publish_data(RunDir, Username, AeAccount, FeatureData, Fee, Concurrency) of
    [#{fail := _FailReason, failing_step := {_KeyWord, Line, Step, _Args}} | _] ->
      Response =
        #{
          status => <<"notok">>,
          failing_step => list_to_binary(damage_utils:lists_concat(Step, " ")),
          line => Line
        },
      {400, jsx:encode(Response)};

    {parse_error, LineNo, Message} ->
      ?LOG_DEBUG("publish failure ~p.", [Message]),
      {
        400,
        jsx:encode(
          #{
            status => <<"notok">>,
            message => list_to_binary(Message),
            line => LineNo,
            hint
            =>
            <<
              "Make sure post data is in binary eg: curl --data-binary @features/test.feature ..."
            >>
          }
        )
      };

    ResultOk ->
      ?LOG_DEBUG("No failure ~p.", [ResultOk]),
      {200, jsx:encode(ResultOk)}
  end.


bid_feature(
  #{feature := FeatureHash, bid := Bid} = _FeaturePayload,
  #{ae_account := AeAccount, username := Username} = _State
) ->
  {ok, AccountContract} = application:get_env(damage, account_contract),
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
      "contracts/market.aes",
      "submit_bid",
      [FeatureHash, Bid]
    ),
  ?LOG_DEBUG(
    "call AE contract ~p gasprice ~p gasused ~p",
    [AeAccount, GasPrice, GasUsed]
  ).
