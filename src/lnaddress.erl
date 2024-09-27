-module(lnaddress).

-vsn("0.1.0").

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-export([init/2]).
-export([content_types_accepted/2]).
-export([content_types_provided/2]).
-export([to_json/2]).
-export([from_json/2, allowed_methods/2, from_html/2]).
-export([trails/0]).

-include_lib("kernel/include/logger.hrl").
-include_lib("damage.hrl").

-define(TRAILS_TAG, ["Damage LN Address resolver"]).

trails() ->
  [
    trails:trail(
      "/.well-known/lnurlp/:user/",
      lnaddress,
      #{},
      #{
        get
        =>
        #{
          tags => ?TRAILS_TAG,
          description => "Form to execute a test on this DamageBDD server.",
          produces => ["text/html"]
        }
      }
    ),
    trails:trail(
      "/pay/:user/",
      lnaddress,
      #{action => invoice},
      #{
        post
        =>
        #{
          tags => ?TRAILS_TAG,
          description => "Form to execute a test on this DamageBDD server.",
          produces => ["text/html"]
        }
      }
    )
  ].

init(Req, Opts) -> {cowboy_rest, Req, Opts}.

content_types_provided(Req, State) ->
  {[{{<<"application">>, <<"json">>, []}, to_json}], Req, State}.

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

to_json(Req, #{action := invoices} = State) ->
  Response =
    #{
      callback => <<"https://damagebdd.com/pay/asyncmind">>,
      metadata
      =>
      <<
        "[[\"text/plain\",\"Self-custodial LN address powered by DamageBDD. Invoice will settle when user comes online within 24hrs or you'll be refunded.\"],[\"text/identifier\",\"asyncmind@zeuspay.com\"]]"
      >>,
      tag => "payRequest",
      minSendable => 10000,
      maxSendable => 612000000000,
      allowsNostr => true,
      nostrPubkey
      =>
      <<"abd32a8bc530142cc04a23f9c07239dbbc6664f4f7eeceb8092c0e3530f94e9d">>,
      commentAllowed => 600
    },
  {jsx:encode(Response), Req, State}.


from_html(Req, #{action := reset_password} = State) ->
  {ok, Data, _Req2} = cowboy_req:read_body(Req),
  Data0 = maps:from_list(cow_qs:parse_qs(Data)),
  {Status0, Response0} =
    case damage_oauth:reset_password(Data0) of
      {ok, Message} ->
        {ok, ApiUrl} = application:get_env(damage, api_url),
        {
          200,
          damage_utils:load_template(
            "reset_password_response.html.mustache",
            #{status => <<"ok">>, message => Message, login_url => ApiUrl}
          )
        };

      {error, Message} ->
        {
          400,
          damage_utils:load_template(
            "reset_password_response.html.mustache",
            #{status => <<"failed">>, message => Message}
          )
        }
    end,
  {
    stop,
    cowboy_req:reply(Status0, cowboy_req:set_resp_body(Response0, Req)),
    State
  }.


do_post_action(_Action, _Data, _Req, _State) -> ok.

from_json(Req, #{action := Action} = State) ->
  {ok, Data, Req0} = cowboy_req:read_body(Req),
  ?LOG_DEBUG("post action ~p ", [Data]),
  case catch jsx:decode(Data, [return_maps, {labels, atom}]) of
    badarg ->
      Response =
        cowboy_req:set_resp_body(
          jsx:encode(
            #{status => <<"failed">>, message => <<"Json decode error.">>}
          ),
          Req0
        ),
      cowboy_req:reply(400, Response),
      ?LOG_DEBUG("post response 400 ~p ", [Response]),
      {stop, Response, State};

    {'EXIT', {badarg, _}} ->
      Response =
        cowboy_req:set_resp_body(
          jsx:encode(
            #{status => <<"failed">>, message => <<"Json decode error.">>}
          ),
          Req0
        ),
      cowboy_req:reply(400, Response),
      ?LOG_DEBUG("post response 400 ~p ", [Response]),
      {stop, Response, State};

    Data0 ->
      case do_post_action(Action, Data0, Req0, State) of
        {204, <<"">>} ->
          Response = cowboy_req:reply(204, Req0),
          {stop, Response, State};

        {Status0, Response0} ->
          Response = cowboy_req:set_resp_body(jsx:encode(Response0), Req0),
          cowboy_req:reply(Status0, Response),
          ?LOG_DEBUG("post response ~p ~p ", [Status0, Response]),
          {stop, Response, State}
      end
  end.
