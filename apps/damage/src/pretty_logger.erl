-module(pretty_logger).
-include_lib("kernel/include/logger.hrl").
%% File: damage_pretty_formatter.erl

-export([format/2]).

-include_lib("kernel/include/logger.hrl").

format(#{level := error, msg := {string, Msg}} = LogEvent, _Config) ->
    Formatted =
        case is_ranch_error(Msg) of
            true ->
                io_lib:format(
                    "==========️[RANCH ERROR]==========~n~s~nStacktrace / Meta:~n~p~n",
                    [Msg, maps:get(meta, LogEvent, #{})]
                );
            false ->
                io_lib:format("[ERROR]: ~s~nMeta: ~p~n", [Msg, maps:get(meta, LogEvent, #{})])
        end,
    lists:flatten(Formatted);
format(#{level := error, msg := {report, Report}} = LogEvent, _Config) ->
    Formatted = io_lib:format(
        "==========[ERROR REPORT ]==========~n~p~nMeta: ~p~n",
        [Report, maps:get(meta, LogEvent, #{})]
    ),
    lists:flatten(Formatted);
format(LogEvent, _Config) ->
    %% Fallback for other log levels (info, warning, etc.)
    MsgStr = io_lib:format("~p", [maps:get(msg, LogEvent, <<"">>)]),
    lists:flatten(io_lib:format("[LOG] ~s~n", [MsgStr])).

is_ranch_error(Msg) ->
    lists:prefix("Ranch listener ", Msg).
