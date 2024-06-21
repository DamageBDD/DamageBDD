-module(steps_webhooks).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/logger.hrl").

-export([step/6]).

step(
  _Config,
  Context,
  <<"Given">>,
  _N,
  ["I notify", Event, "to", WebhookName0, "webhook"],
  _
) ->
  WebhookName = list_to_binary(WebhookName0),
  ?LOG_DEBUG("notify webhook ~p", [Event]),
  case maps:get(webhooks, Context, none) of
    none ->
      maps:put(
        fail,
        damage_utils:strf("Webhook not configured: ~s", [WebhookName]),
        Context
      );

    Webhooks ->
      ?LOG_DEBUG("notify webhook ~p ~p", [WebhookName, Webhooks]),
      case maps:get(WebhookName, Webhooks, none) of
        none ->
          maps:put(
            Event,
            damage_utils:strf("Webhook not configured: ~p", [WebhookName]),
            Context
          );

        Url ->
          case maps:get(notify_urls, Context, none) of
            none ->
              maps:put(
                notify_urls,
                maps:put(Event, sets:from_list([Url]), #{}),
                Context
              );

            NotifyUrls ->
              EventUrls = maps:get(Event, NotifyUrls, sets:new()),
              maps:put(
                notify_urls,
                maps:put(Event, sets:add_element(Url, EventUrls), #{}),
                Context
              )
          end
      end
  end.
