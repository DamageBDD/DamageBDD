-module(text_formatter).

-include_lib("reporting/formatter.hrl").

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-export([format/3]).

get_keyword(then_keyword) -> "Then";
get_keyword(when_keyword) -> "When";
get_keyword(and_keyword) -> "And";
get_keyword(given_keyword) -> "Given".

write_file(#{output := Output}, FormatStr, Args) ->
  ok =
    file:write_file(
      Output,
      lists:flatten(io_lib:format(FormatStr ++ "\n", Args)),
      [append]
    ).

format(Config, feature, {FeatureName, LineNo, Tags, Description}) ->
  ok =
    write_file(
      Config,
      "Feature ~s line:~p tags: [~p], desc: ~s",
      [
        FeatureName,
        LineNo,
        lists:flatten(string:join([[X] || X <- Tags], ",")),
        Description
      ]
    );

format(Config, scenario, {ScenarioName, LineNo, Tags}) ->
  ok =
    write_file(
      Config,
      "\tScenario ~s line:~p tags: [~p]",
      [
        ScenarioName,
        LineNo,
        lists:flatten(string:join([[X] || X <- Tags], ","))
      ]
    );

format(Config, step, {Keyword, LineNo, StepStatement, Args, _Context, Status}) ->
    logger:debug("text format ~p ~p", [Config, Status]),
  ok =
    write_file(
      Config,
      "\t\t~s ~p, Args: ~p line:~p  ~s",
      [
        get_keyword(Keyword),
        lists:flatten(string:join([[X] || X <- StepStatement], " ")),
        Args,
        LineNo,
        Status
      ]
    ).
