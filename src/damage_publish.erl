-module(damage_publish).

-vsn("0.1.0").

-include_lib("eunit/include/eunit.hrl").

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-export([init/2]).
-export([content_types_accepted/2]).
-export([content_types_provided/2]).
-export([to_html/2]).
-export([to_json/2]).
-export([to_text/2]).
-export([from_json/2, allowed_methods/2, from_html/2]).
-export([is_authorized/2]).
-export([trails/0]).

-include_lib("kernel/include/logger.hrl").
-include_lib("damage.hrl").

-define(TRAILS_TAG, ["Publish Tests For Open Market Execution"]).

trails() ->
  [
    trails:trail(
      "/publish_feature/",
      damage_publish,
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


to_text(Req, #{contract_address := ContractAddress} = State) ->
  Reports = do_query(#{contract_address => ContractAddress}),
  ?LOG_DEBUG("list published contracts ~p ", [Reports]),
  {jsx:encode(Reports), Req, State}.


from_json(Req, State) ->
  {ok, Data, _Req2} = cowboy_req:read_body(Req),
  {Status, Resp0} =
    case jsx:decode(Data, [{labels, atom}, return_maps]) of
      #{feature := FeatureData, concurrency := Concurrency} = FeatureJson ->
        Fee = binary_to_integer(maps:get(fee, FeatureJson, <<"4000">>)),
        check_publish_bdd(
          #{feature => FeatureData, concurrency => Concurrency, fee => Fee},
          State,
          Req
        );

      Err ->
        logger:error("json decoding failed ~p.", [Data]),
        {400, jsx:encode(#{status => <<"notok">>, result => [Err]})}
    end,
  Resp = cowboy_req:set_resp_body(Resp0, Req),
  cowboy_req:reply(Status, Resp),
  {stop, Resp, State}.


from_html(Req0, State) ->
  {ok, Body, Req} = cowboy_req:read_body(Req0),
  _UserAgent = cowboy_req:header(<<"user-agent">>, Req0, ""),
  Concurrency =
    binary_to_integer(
      cowboy_req:header(<<"x-damage-concurrency">>, Req0, <<"1">>)
    ),
  Fee =
    binary_to_integer(cowboy_req:header(<<"x-damage-fee">>, Req0, <<"4000">>)),
  {Status, Resp0} =
    check_publish_bdd(
      #{feature => Body, concurrency => Concurrency, fee => Fee},
      State,
      Req0
    ),
  Res1 = cowboy_req:set_resp_body(Resp0, Req),
  cowboy_req:reply(Status, Res1),
  {stop, Res1, State}.


get_record(Id) ->
  {ok, Record} =
    damage_riak:get(?PUBLISHED_FEATURES_BUCKET, damage_utils:decrypt(Id)),
  Record.


do_query(#{contract_address := ContractAddress}) ->
  case
  damage_riak:get_index(
    ?PUBLISHED_FEATURES_BUCKET,
    {binary_index, "contract_address"},
    ContractAddress
  ) of
    [] ->
      logger:info("no reports for account"),
      [];

    Found ->
      ?debugFmt(" reports exists data: ~p ", [Found]),
      Results = [get_record(X) || X <- Found],
      #{results => Results, status => <<"ok">>, length => length(Results)}
  end.


check_publish_bdd(
  #{concurrency := Concurrency0} = FeaturePayload,
  #{contract_address := ContractAddress} = State,
  Req0
) ->
  Concurrency = damage_utils:get_concurrency_level(Concurrency0),
  IP = damage_utils:get_ip(Req0),
  case throttle:check(damage_api_rate, IP) of
    {limit_exceeded, _, _} ->
      lager:warning("IP ~p exceeded api limit", [IP]),
      {error, 429, Req0};

    _ ->
      case damage_ae:balance(ContractAddress) of
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


publish_bdd(
  #{feature := FeatureData, concurrency := Concurrency, fee := Fee} =
    _FeaturePayload,
  #{contract_address := ContractAddress} = _State
) ->
  Config = damage:get_default_config(ContractAddress, Concurrency, []),
  case damage:publish_data([{fee, Fee} | Config], FeatureData) of
    [#{fail := _FailReason, failing_step := {_KeyWord, Line, Step, _Args}} | _] ->
      Response =
        #{
          status => <<"notok">>,
          failing_step => list_to_binary(damage_utils:lists_concat(Step, " ")),
          line => Line
        },
      {400, jsx:encode(Response)};

    {parse_error, LineNo, Message} ->
      ?LOG_DEBUG("failure ~p.", [Message]),
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
