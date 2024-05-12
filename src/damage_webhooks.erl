-module(damage_webhooks).

-vsn("0.1.0").

-include_lib("eunit/include/eunit.hrl").

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-export([init/2]).
-export([content_types_accepted/2]).
-export([content_types_provided/2]).
-export([to_json/2]).
-export([from_json/2]).
-export([allowed_methods/2]).
-export([trails/0]).
-export([is_authorized/2]).
-export([load_all_webhooks/1]).

-include_lib("kernel/include/logger.hrl").

-define(WEBHOOKS_BUCKET, {<<"Default">>, <<"Webhooks">>}).
-define(TRAILS_TAG, ["Manage Webhooks"]).

trails() ->
  [
    trails:trail(
      "/webhooks/[...]",
      damage_webhooks,
      #{},
      #{
        get
        =>
        #{
          tags => ?TRAILS_TAG,
          description => "Form to webhook a test execution.",
          produces => ["text/html"]
        },
        put
        =>
        #{
          tags => ?TRAILS_TAG,
          description => "Webhook a test on post",
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
  {[{{<<"application">>, <<"json">>, []}, to_json}], Req, State}.

content_types_accepted(Req, State) ->
  {[{{<<"application">>, <<"json">>, '*'}, from_json}], Req, State}.

allowed_methods(Req, State) -> {[<<"GET">>, <<"POST">>], Req, State}.

from_json(Req, State) ->
  {ok, Data, _Req2} = cowboy_req:read_body(Req),
  {ok, true} =
    case catch jsx:decode(Data, [{labels, atom}, return_maps]) of
      {'EXIT', {badarg, Trace}} ->
        logger:error("json decoding failed ~p err: ~p.", [Data, Trace]),
        {400, <<"Json decoding failed.">>};

      #{name := _WebhookName, url := _WebhookUrl} = Webhook ->
        create_webhook(Webhook, Req, State)
    end,
  Resp = cowboy_req:set_resp_body(jsx:encode(#{status => <<"ok">>}), Req),
  {stop, cowboy_req:reply(201, Resp), State}.


to_json(Req, #{contract_address := ContractAddress} = State) ->
  Body = jsx:encode(list_webhooks(ContractAddress)),
  logger:info("Loading webhooks for ~p ~p", [ContractAddress, Body]),
  {Body, Req, State}.


create_webhook(
  #{name := WebhookName, url := WebhookUrl} = WebhookData,
  _Req,
  #{contract_address := ContractAddress} = _State
) ->
  WebhookId =
    damage_utils:idhash_keys([ContractAddress, WebhookName, WebhookUrl]),
  Body = jsx:encode(list_webhooks(ContractAddress)),
  logger:info("Loading webhooks for ~p ~p", [ContractAddress, Body]),
  Webhook0 =
    case damage_riak:get(?WEBHOOKS_BUCKET, WebhookId) of
      notfound ->
        logger:error("failed to load  webhook ~p", [WebhookId]),
        WebhookData;

      {ok, WebhookObj} ->
        ?LOG_DEBUG("loaded  webhook ~p", [WebhookObj]),
        maps:merge(WebhookObj, WebhookData)
    end,
  ?LOG_DEBUG("saving  webhook ~p", [Webhook0]),
  {ok, true} =
    damage_riak:put(
      ?WEBHOOKS_BUCKET,
      WebhookId,
      Webhook0,
      [{{binary_index, "contract_address"}, [ContractAddress]}]
    ).


get_webhook_unencrypted(WebhookId) ->
  case damage_riak:get(?WEBHOOKS_BUCKET, WebhookId) of
    {ok, Webhook} ->
      ?LOG_DEBUG("Loaded Schedulid ~p", [WebhookId]),
      maps:put(id, WebhookId, Webhook);

    _ -> none
  end.


get_webhook(WebhookId) when is_binary(WebhookId) ->
  case catch damage_utils:decrypt(WebhookId) of
    error ->
      ?LOG_DEBUG("WebhookId Decryption error ~p ", [WebhookId]),
      get_webhook_unencrypted(WebhookId);

    {'EXIT', _Error} ->
      ?LOG_DEBUG("WebhookId Decryption error ~p ", [WebhookId]),
      get_webhook_unencrypted(WebhookId);

    WebhookIdDecrypted -> get_webhook_unencrypted(WebhookIdDecrypted)
  end;

get_webhook(_) -> none.


list_webhooks(ContractAddress) ->
  ?LOG_DEBUG("Contract ~p", [ContractAddress]),
  lists:filter(
    fun (none) -> false; (_Other) -> true end,
    [
      get_webhook(damage_utils:decrypt(WebhookId))
      ||
      WebhookId
      <-
      damage_riak:get_index(
        ?WEBHOOKS_BUCKET,
        {binary_index, "contract_address"},
        ContractAddress
      )
    ]
  ).


load_webhook(Webhook) -> logger:info("load_webhook: ~p", [Webhook]).

load_all_webhooks(Context) ->
  maps:put(
    webhooks,
    [load_webhook(Webhook) || Webhook <- list_all_webhooks()],
    Context
  ).

list_all_webhooks() ->
  lists:filter(
    fun (none) -> false; (_Other) -> true end,
    [
      get_webhook(WebhookId)
      || WebhookId <- damage_riak:list_keys(?WEBHOOKS_BUCKET)
    ]
  ).
