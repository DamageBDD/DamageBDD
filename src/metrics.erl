%%%-------------------------------------------------------------------
%% @doc damage public API
%% @end
%%%-------------------------------------------------------------------

-module(metrics).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-export([init/0, update/2]).

init() -> [try prometheus_gauge:declare(M) of _ -> ok catch
      _ ->
        logger:error("Error initializing metrics"),
        ok end ||
    M
    <-
    [
      [{name, success}, {help, "number of success"}, {labels, ["account"]}],
      [{name, error}, {help, "number of errors"}, {labels, ["account"]}],
      [{name, fail}, {help, "number of fails"}, {labels, ["account"]}],
      [{name, notfound}, {help, "number of notfounds"}, {labels, ["account"]}]
    ]].

update(Event, Config) ->
  prometheus_gauge:inc(Event, [{account, "all"}]),
  {account, Account} = lists:keyfind(account, 1, Config),
  prometheus_gauge:inc(Event, [{account, Account}]).
