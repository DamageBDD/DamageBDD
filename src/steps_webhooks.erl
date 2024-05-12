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
  ["I notify", Event, "to", Webhook, "webhook"],
  _
) ->
  ?LOG_DEBUG("notify webhook ~p", [Event]),
  case maps:get(webhooks, Context, none) of
    none ->
      maps:put(
        fail,
        damage_utils:strf("Webhook not configured: ~s", [Webhook]),
        Context
      );

    Webhooks ->
      case maps:get(Webhook, Webhooks, none) of
        none ->
          maps:put(
            fail,
            damage_utils:strf("Webhook not configured: ~s", [Webhook]),
            Context
          );

        Url ->
          NotifyUrls = maps:get(notify_urls, Context, []),
          maps:put(notify_urls, NotifyUrls ++ Url, Context)
      end
  end.
