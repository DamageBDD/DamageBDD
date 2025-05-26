-module(steps_docker).

-author("Steven Joseph <steven@stevenjoseph.in>").
-copyright("Steven Joseph <steven@stevenjoseph.in>").
-license("Apache-2.0").

-include_lib("damage.hrl").
-include_lib("kernel/include/logger.hrl").

-export([step/6]).
-export([test/0]).

step(_Config, Context, _Bindings, _StepN, ["the system has unused Docker containers or resources since", Relative], _Meta) ->
    {ok, ISODate} = relative_string_to_date(Relative),
    logger:notice("Checking for Docker resources older than ~s", [ISODate]),
    Context#{since => ISODate};

step(_Config, Context, _Bindings, _StepN, ["I clean up all unused Docker containers, images, volumes and networks since", Relative], _Meta) ->
    {ok, ISODate} = relative_string_to_date(Relative),
    Command = "docker system prune -a --force --filter \"until=" ++ ISODate ++ "\"",
    Output = os:cmd(Command),
    logger:notice("Docker cleanup output: ~s", [Output]),
    maps:merge(Context, #{cleanup_output => Output, since => ISODate});

step(_Config, Context, _Bindings, _StepN, ["the Docker system should have no unused resources older than", Relative], _Meta) ->
    {ok, ISODate} = relative_string_to_date(Relative),
    CheckCmd = "docker ps -a --filter \"status=exited\" --filter \"until=" ++ ISODate ++ "\" --format '{{.ID}}'",
    Output = os:cmd(CheckCmd),
    case string:trim(Output) of
        "" ->
            Context;
        _ ->
            erlang:error({docker_cleanup_failed, Output})
    end;

step(_, Context, _, _, _, _) ->
    Context.

%% Convert "3 days ago" into "YYYY-MM-DD" using date_util
relative_string_to_date(Relative) ->
    try
        case string:tokens(string:lowercase(Relative), " ") of
            [NumStr, Unit, "ago"] ->
                {ok, Num} = string:to_integer(NumStr),
                Seconds = seconds_for_unit(Unit, Num),
                EpochAgo = date_util:epoch() - Seconds,
                {{Y, M, D}, _Time} = date_util:timestamp_to_datetime(EpochAgo),
                {ok, lists:flatten(io_lib:format("~4..0B-~2..0B-~2..0B", [Y, M, D]))};
            _ ->
                erlang:error({unrecognized_format, Relative})
        end
    catch
        _:Reason -> {error, {invalid_relative_date, Relative, Reason}}
    end.

seconds_for_unit("second", N) -> N;
seconds_for_unit("seconds", N) -> N;
seconds_for_unit("minute", N) -> N * 60;
seconds_for_unit("minutes", N) -> N * 60;
seconds_for_unit("hour", N) -> N * 3600;
seconds_for_unit("hours", N) -> N * 3600;
seconds_for_unit("day", N) -> date_util:days_to_seconds(N);
seconds_for_unit("days", N) -> date_util:days_to_seconds(N);
seconds_for_unit("week", N) -> date_util:days_to_seconds(N * 7);
seconds_for_unit("weeks", N) -> date_util:days_to_seconds(N * 7);
seconds_for_unit("month", N) -> date_util:days_to_seconds(N * 30);
seconds_for_unit("months", N) -> date_util:days_to_seconds(N * 30);
seconds_for_unit("year", N) -> date_util:days_to_seconds(N * 365);
seconds_for_unit("years", N) -> date_util:days_to_seconds(N * 365);
seconds_for_unit(Unit, _) -> erlang:error({unknown_unit, Unit}).

test() ->
    {ok, _Date} = relative_string_to_date("3 days ago"),
    ok.
