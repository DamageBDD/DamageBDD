-module(html_formatter).

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
      lists:flatten(io_lib:format(FormatStr, Args)),
      [append]
    ).

format(Config, feature, {FeatureName, LineNo, Tags, Description}) ->
  ok =
    write_file(
      Config,
      "<tr><td>Feature</td> <td>~s</td> <td>tags: [~p]</td> <td>~p</td> <td>~p</td></tr>",
      [
        FeatureName,
        lists:flatten(string:join([[X] || X <- Tags], ",")),
        LineNo,
        Description
      ]
    );

format(Config, scenario, {ScenarioName, LineNo, Tags}) ->
  ok =
    write_file(
      Config,
      "<tr><td>Scenario</td> <td>~s</td> <td>tags: [~p]</td> <td>~p </td> <td>~p</td></tr>",
      [
        ScenarioName,
        lists:flatten(string:join([[X] || X <- Tags], ",")),
        LineNo,
        ""
      ]
    );

format(Config, step, {Keyword, LineNo, StepStatement, Args, _Context, Status}) ->
  ok =
    write_file(
      Config,
      "<tr><td>~s</td><td>~p</td><td>~p</td><td>~p</td><td>~p</td></tr>",
      [
        get_keyword(Keyword),
        lists:flatten(string:join([[X] || X <- StepStatement], " ")),
        Args,
        LineNo,
        Status
      ]
    ).
