%%% damage_hwmon_sink.erl
-module(damage_hwmon_sink).
-author("Steven Joseph <steven@damagebdd.com>").

-copyright("Steven Joseph <steven@damagebdd.com>").

-license("Apache-2.0").
-export([emit/1]).

emit(Sample) ->
    %% Replace with your internal event bus / telemetry / DB / chain anchor.
    %% Example:
    %% damage_events:emit(hw_sample, Sample),
    %% damage_telemetry:hw_sample(Sample),
    %io:format("HW EVENT ~p~n", [Sample]),
    ok.
