-module(steps_ai).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([step/6]).

step(Config, Context, <<"And">>, _N, ["I am using ai ", AiProvider], Args) ->
    ?LOG_DEBUG("and config: ~p context: ~p  args: ~p", [Config, AiProvider, Args]),
    Context;
step(
    Config,
    Context,
    <<"And">>,
    _N,
    ["I set the messages context", GptContext],
    Args
) ->
    ?LOG_DEBUG("and config: ~p context: ~p  args: ~p", [Config, GptContext, Args]),
    Context.
