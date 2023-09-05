%%%-------------------------------------------------------------------
%% @doc damage public API
%% @end
%%%-------------------------------------------------------------------

-module(metrics).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-export([init/0, update/2]).

init() ->
  prometheus_gauge:new(
    [{name, success}, {help, "number of success"}, {labels, ["account"]}]
  ),
  prometheus_gauge:new(
    [{name, error}, {help, "number of errors"}, {labels, ["account"]}]
  ),
  prometheus_gauge:new(
    [{name, fail}, {help, "number of fails"}, {labels, ["account"]}]
  ),
  prometheus_gauge:new(
    [{name, notfound}, {help, "number of notfounds"}, {labels, ["account"]}]
  ).


update(Event, Config) ->
  prometheus_gauge:inc(Event, [{account, "all"}]),
  {account, Account} = lists:keyfind(account, 1, Config),
  prometheus_gauge:inc(Event, [{account, Account}]).
