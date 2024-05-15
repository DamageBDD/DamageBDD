-module(damage_webhooks).

-vsn("0.1.0").

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
-export([load_all_webhooks/2]).
-export([list_all_webhooks/0]).
-export([trigger_webhooks/1]).

-define(DEFAULT_HTTP_TIMEOUT, 60000).
-define(
  DEFAULT_HEADERS,
  [
    {<<"accept">>, "application/json,text/html"},
    {<<"user-agent">>, "damagebdd/1.0"},
    {<<"content-type">>, "application/json"}
  ]
).

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
  #{name := WebhookName, url := _WebhookUrl} = WebhookData,
  _Req,
  #{contract_address := ContractAddress} = _State
) ->
  WebhookId = damage_utils:idhash_keys([ContractAddress, WebhookName]),
  Webhook1 =
    case damage_riak:get(?WEBHOOKS_BUCKET, WebhookId) of
      notfound ->
        logger:error("failed to load  webhook ~p", [WebhookId]),
        WebhookData;

      {ok, WebhookObj} ->
        ?LOG_DEBUG("loaded  webhook ~p", [WebhookObj]),
        maps:merge(WebhookObj, WebhookData)
    end,
  Webhook0 = maps:put(id, WebhookId, Webhook1),
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
      ?LOG_DEBUG("Loaded WebhookId ~p", [WebhookId]),
      Webhook;

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
      get_webhook(WebhookId)
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


load_all_webhooks(ContractAddress, Context) ->
  maps:put(
    webhooks,
    maps:from_list(
      [
        {maps:get(name, Webhook), Webhook}
        || Webhook <- list_webhooks(ContractAddress)
      ]
    ),
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

gun_await(ConnPid, StreamRef) ->
  case gun:await(ConnPid, StreamRef, ?DEFAULT_HTTP_TIMEOUT) of
    {response, fin, _Status, _Headers} -> closed;

    {response, nofin, _Status, _Headers} ->
      {ok, Body} = gun:await_body(ConnPid, StreamRef),
      Body
  end.


trigger_webhook(#{url := Url} = Webhook, #{fail := FailMessage} = _Context) ->
  %?LOG_DEBUG("post_webhook for with context to urls ~p", [Context, Url]),
  {Host0, Port0, Path0} =
    case uri_string:parse(binary_to_list(Url)) of
      #{port := Port, scheme := _Scheme, path := Path, host := Host} ->
        {Host, Port, Path};

      #{scheme := "https", host := Host, path := Path} -> {Host, 443, Path};
      #{scheme := "http", host := Host, path := Path} -> {Host, 80, Path}
    end,
  {ok, ConnPid} =
    gun:open(Host0, Port0, #{tls_opts => [{verify, verify_none}]}),
  Template = binary_to_list(maps:get(template, Webhook, <<"discord">>)),
  Body =
    damage_utils:load_template(
      "webhooks/" ++ Template ++ ".mustache",
      #{content => FailMessage}
    ),
  %?LOG_DEBUG("webhook post ~p.", [Body]),
  StreamRef = gun:post(ConnPid, Path0, ?DEFAULT_HEADERS, Body),
  Resp = gun_await(ConnPid, StreamRef),
  ?LOG_DEBUG("Got response from webhook url ~p ~p.", [Url, Resp]);

trigger_webhook(#{url := _Url} = _Webhook, _Context) -> ok.


trigger_webhooks(FinalContext) ->
  case maps:get(notify_urls, FinalContext, none) of
    none -> ok;

    #{"fail" := EventHooks} = _NotifyHooks ->
      [
        trigger_webhook(Webhook, FinalContext)
        || Webhook <- sets:to_list(EventHooks)
      ]
  end.
