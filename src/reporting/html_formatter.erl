-module(html_formatter).


-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-export([format/3]).

get_keyword(then_keyword) -> "Then";
get_keyword(when_keyword) -> "When";
get_keyword(and_keyword) -> "And";
get_keyword(given_keyword) -> "Given";
get_keyword(KeyWord) when is_binary(KeyWord) -> binary_to_list(KeyWord).

write_file(#{output := Output}, FormatStr, Args) ->
  [_, _, PidStr0] = string:replace(pid_to_list(self()), "<", "", all),
  [PidStr, _, _] = string:replace(PidStr0, ">", "", all),
  OutputFile =
    mustache:render(
      binary_to_list(Output),
      [{process_id, PidStr}, {node_id, node()}]
    ),
  ok =
    file:write_file(
      OutputFile,
      lists:flatten(io_lib:format(FormatStr, Args)),
      [append]
    ).


format(Config, feature, {FeatureName, LineNo, Tags, Description}) ->
  ok =
    write_file(
      Config,
      "<tr>\n<td>\nFeature\n</td>\n <td>~s</td> <td>tags: ~p</td> <td>~p</td> <td>~p</td></tr>",
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
        binary_to_list(StepStatement),
        Args,
        LineNo,
        Status
      ]
    );

format(
  Config,
  print,
  {_Keyword, _LineNo, _StepStatement, Args, _Context, _Status}
) ->
  ok = write_file(Config, "<tr><td>~s</td></tr>", [format_args(Args)]);

format(Config, summary, #{report_dir := FeatureHash, run_id := RunId}) ->
  ok = write_file(Config, "<h2>Summary</h2>: ~s ~p\n", [FeatureHash, RunId]).

format_args([]) -> <<"\n">>;
format_args({fail, Reason}) -> io_lib:format(<<"Fail: ~p<br>">>, [Reason]);

format_args(Args) when is_list(Args); is_binary(Args) ->
  Data =
    damage_utils:binarystr_join(
      [<<"<p>", A/binary, "</p>">> || A <- string:split(Args, "\n", all)],
      <<"<br>">>
    ),
  <<"    \"\"\"<br>", Data/binary, "<br>    \"\"\"">>.
