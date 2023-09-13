-module(text_formatter).

-include_lib("reporting/formatter.hrl").

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-export([format_step/4]).

get_keyword(then_keyword) -> "Then";
get_keyword(when_keyword) -> "When";
get_keyword(given_keyword) -> "Given".

write_file(Output, StepKeyword, StepStatement, Args, LineNo, Status) ->
  ok =
    file:write_file(
      Output,
      lists:flatten(
        io_lib:format(
          "~s ~s, Args: ~p line:~p  ~p",
          [
            StepKeyword,
            lists:flatten(string:join([[X] || X <- StepStatement], " ")),
            Args,
            LineNo,
            Status
          ]
        )
      )
    ).

format_step(
  #{output := Output} = _FormatterConfig,
  {Keyword, LineNo, StepStatement, Args},
  _Context,
  Status
) ->
  ok =
    write_file(
      Output,
      get_keyword(Keyword),
      StepStatement,
      Args,
      LineNo,
      Status
    ).
