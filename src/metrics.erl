%%%-------------------------------------------------------------------
%% @doc damage public API
%% @end
%%%-------------------------------------------------------------------

-module(metrics).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").

-export([init/0, update/2]).
-export([fetch_metrics/1]).

-define(DEFAULT_HTTP_TIMEOUT, 60000).

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
        {labels, ["ae_account"]}
      ],
      [
        {name, error},
        {help, "number of errors"},
        {labels, ["ae_account"]}
      ],
      [{name, fail}, {help, "number of fails"}, {labels, ["ae_account"]}],
      [
        {name, notfound},
        {help, "number of notfounds"},
        {labels, ["ae_account"]}
      ]
    ]].

update(Event, AeAccount) ->
  %?LOG_DEBUG("update prometheus_data  for event ~p ", [Event]),
  prometheus_gauge:inc(Event, ["all"]),
  prometheus_gauge:inc(Event, [AeAccount]).


%curl -g 'http://localhost:9090/api/v1/series?' --data-urlencode 'match[]={ae_account=~".+"}'|jq
fetch_metrics(AeAccount) when is_binary(AeAccount) ->
  fetch_metrics(binary_to_list(AeAccount));

fetch_metrics(AeAccount) ->
  Host = "localhost",
  Port = 9090,
  Headers = #{"Content-Type" => "application/x-www-form-urlencoded"},
  Query =
    "/api/v1/query?query=sum(success{ae_account=\""
    ++
    AeAccount
    ++
    "\"})",
  {ok, ConnPid} = gun:open(Host, Port, #{}),
  %% Construct the request body
  %% Send the HTTP POST request
  StreamRef = gun:get(ConnPid, Query, Headers),
  Response0 =
    case gun:await(ConnPid, StreamRef) of
      {response, fin, _Status, _Headers0} -> no_data;

      {response, nofin, _Status, _Headers0} ->
        {ok, Body} = gun:await_body(ConnPid, StreamRef),
        Body
    end,
  %% Parse the response JSON
  ?LOG_DEBUG("Got prometheus_data ~p for query ~p ", [Response0, Query]),
  %% Parse the response JSON
  Response = jsx:decode(Response0),
  gun:cancel(ConnPid, StreamRef),
  gun:close(ConnPid),
  Response.

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
