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
-export([load_all_webhooks/1]).
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
  #{result := #{returnType := <<"ok">>}} =
    case catch jsx:decode(Data, [{labels, atom}, return_maps]) of
      {'EXIT', {badarg, Trace}} ->
        logger:error("json decoding failed ~p err: ~p.", [Data, Trace]),
        {400, <<"Json decoding failed.">>};

      #{name := _WebhookName, url := _WebhookUrl} = Webhook ->
        create_webhook(Webhook, Req, State)
    end,
  Resp = cowboy_req:set_resp_body(jsx:encode(#{status => <<"ok">>}), Req),
  {stop, cowboy_req:reply(201, Resp), State}.


to_json(Req, #{username := Username} = State) ->
  Body = jsx:encode(damage_ae:get_webhooks(Username)),
  logger:info("Loading webhooks for ~p ~p", [Username, Body]),
  {Body, Req, State}.


create_webhook(
  #{name := WebhookName, url := WebhookUrl} = _WebhookData,
  _Req,
  #{username := Username} = _State
) ->
  damage_ae:add_webhook(Username, WebhookName, WebhookUrl).

load_all_webhooks(#{username := Username} = Context) ->
  maps:put(webhooks, damage_ae:get_webhooks(Username), Context).

gun_await(ConnPid, StreamRef) ->
  case gun:await(ConnPid, StreamRef, ?DEFAULT_HTTP_TIMEOUT) of
    {response, fin, _Status, _Headers} -> closed;

    {response, nofin, _Status, _Headers} ->
      {ok, Body} = gun:await_body(ConnPid, StreamRef),
      Body
  end.


trigger_webhook(#{url := Url} = Webhook, #{fail := FailMessage} = Context) ->
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
  TemplateContext =
    maps:put(fail_message, damage_utils:safe_json(FailMessage), Context),
  Body =
    damage_utils:load_template(
      "webhooks/" ++ Template ++ ".mustache",
      TemplateContext
    ),
  %?LOG_DEBUG("webhook post ~p ~p.", [Body, TemplateContext]),
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
