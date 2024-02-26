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
      [
        {name, success},
        {help, "number of success"},
        {labels, ["contract_address"]}
      ],
      [
        {name, error},
        {help, "number of errors"},
        {labels, ["contract_address"]}
      ],
      [{name, fail}, {help, "number of fails"}, {labels, ["contract_address"]}],
      [
        {name, notfound},
        {help, "number of notfounds"},
        {labels, ["contract_address"]}
      ]
    ]].

update(Event, Config) ->
  prometheus_gauge:inc(Event, [{contract_address, "all"}]),
  {contract_address, ContractAddress} =
    lists:keyfind(contract_address, 1, Config),
  prometheus_gauge:inc(Event, [{contract_address, ContractAddress}]).

%%setup_prometheus_metrics()->
%%
%%  prometheus_counter:declare([{name, cowboy_early_errors_total},
%%                              {registry, registry()},
%%                              {labels, early_error_labels()},
%%                              {help, "Total number of Cowboy early errors."}]),
%%  prometheus_histogram:declare([{name, cowboy_receive_body_duration_seconds},
%%                                {registry, registry()},
%%                                {labels, request_labels()},
%%                                {buckets, duration_buckets()},
%%                                {help, "Request body receiving duration."}]),
%%  prometheus_gauge:declare([{name, my_pool_size},
%%                            {help, "Pool size."}]),
%%  prometheus_gauge:declare([{name, my_pool_checked_out},
%%                             {help, "Number of checked out sockets"}]).
%%
%% set_size(Size) ->
%%   prometheus_gauge:set(my_pool_size, Size)
%%
%% track_checked_out_sockets(CheckoutFun) ->
%%   prometheus_gauge:track_inprogress(my_pool_checked_out, CheckoutFun)..
