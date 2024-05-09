-module(formatter).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("reporting/formatter.hrl").

-behaviour(gen_server).
-behaviour(poolboy_worker).

-export([start_link/1, format/3]).
-export(
  [
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
  ]
).
-export([invoke_formatters/3]).

start_link(_Args) ->
  logger:info("formater process started ~p~n", [self()]),
  gen_server:start_link(?MODULE, [], []).


init([]) -> {ok, undefined}.

handle_call({invoke_formatters, Config, Keyword, Data}, _From, State) ->
  {reply, invoke_formatters(Config, Keyword, Data), State}.

handle_cast({invoke_formatters, _Args}, State) -> {noreply, State}.

handle_info(_Info, State) -> {noreply, State}.

invoke_formatters(Config, Keyword, Data) ->
  {formatters, Formatters} = lists:keyfind(formatters, 1, Config),
  lists:foreach(
    fun
      ({Formatter, FormatterConfig}) ->
        apply(
          list_to_atom(
            lists:flatten(io_lib:format("~p_formatter", [Formatter]))
          ),
          format,
          [FormatterConfig, Keyword, Data]
        )
    end,
    Formatters
  ),
  ok.


code_change(_OldVsn, State, _Extra) -> {ok, State}.

format(Config, step, {StepKeyWord, LineNo, Body, Args, Context, Status})
when is_list(Body) ->
  {Body0, Args0} =
    damage_accounts:clean_secrets(
      Context,
      list_to_binary(lists:flatten(string:join([[X] || X <- Body], " "))),
      Args
    ),
  format(Config, step, {StepKeyWord, LineNo, Body0, Args0, Context, Status});

format(Config, Keyword, Data) ->
  poolboy:transaction(
    formatter,
    fun
      (Worker) ->
        gen_server:call(Worker, {invoke_formatters, Config, Keyword, Data})
    end
  ).


terminate(Reason, _State) ->
  logger:info("Server ~p terminating with reason ~p~n", [self(), Reason]),
  ok.
