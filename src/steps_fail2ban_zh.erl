-module(steps_fail2ban_zh).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("damage.hrl").

-export([step/6]).

step(Config, Context, KeyWord, _N, ["我将IP排除列表设置为"], Body) ->
  step(Config, Context, KeyWord, _N, ["I set the IP exclusion list to"], Body);

step(
  Config,
  Context,
  <<"Then">>,
  N,
  ["该IP必须被禁止", BanTime, "秒"],
  Body
) ->
  step(
    Config,
    Context,
    <<"Then">>,
    N,
    ["the IP must be banned for", BanTime, "seconds"],
    Body
  );

step(
  Config,
  Context,
  KeyWord,
  _N,
  [
    "该IP在最近",
    SinceSeconds,
    "秒内发出了超过",
    NumRequests,
    "次状态为",
    Status,
    "的请求"
  ],
  Body
) ->
  step(
    Config,
    Context,
    KeyWord,
    _N,
    [
      "the IP has made more than",
      NumRequests,
      "requests with status",
      Status,
      "in the last",
      SinceSeconds,
      "seconds"
    ],
    Body
  ).
