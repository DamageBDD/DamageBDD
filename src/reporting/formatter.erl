-module(formatter).

-behaviour(gen_server).

-include_lib("reporting/formatter.hrl").

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-export([start_link/0, format/3]).
-export([init/1, handle_call/3, handle_cast/2]).
-export([invoke_formatters/3]).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
  CallbackModule =
    application:get_env(my_app, formatter_callback_module, default_formatter),
  {ok, CallbackModule}.


handle_call(invoke_formatters, Args, State) ->
  {reply, gen_server:call(?MODULE, {invoke_formatters, Args}), State}.

handle_cast({invoke_formatters, Args}, State) ->
  gen_server:cast(?MODULE, {invoke_formatters, Args}),
  {noreply, State}.


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


format(Config, Keyword, Data) ->
  CallbackModule = whereis(?MODULE),
  gen_server:call(CallbackModule, [invoke_formatters, Config, Keyword, Data]).
