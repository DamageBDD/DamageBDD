-module(text_formatter).

-include_lib("reporting/formatter.hrl").

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-export([format/3]).

get_keyword(#{color := false}, then_keyword) -> "Then";
get_keyword(#{color := false}, when_keyword) -> "When";
get_keyword(#{color := false}, and_keyword) -> "And";
get_keyword(#{color := false}, given_keyword) -> "Given";
get_keyword(#{color := false}, scenario_keyword) -> "Scenario:";
get_keyword(#{color := false}, feature_keyword) -> "Feature:";

get_keyword(#{color := false}, KeyWord) when is_binary(KeyWord) ->
  binary_to_list(KeyWord);

get_keyword(#{color := true}, Keyword) ->
  color:cyan(get_keyword(#{color => false}, Keyword)).

get_status_text(#{color := true}, fail) -> color:red("fail");

get_status_text(#{color := true}, {fail, Reason}) ->
  color:red(damage_utils:strf("fail:~p", [Reason]));

get_status_text(#{color := false}, {fail, Reason}) ->
  damage_utils:strf("fail:~p", [Reason]);

get_status_text(#{color := true}, error) -> color:red("error");
get_status_text(#{color := true}, success) -> color:green("success");
get_status_text(#{color := true}, skip) -> color:yellow("skip");
get_status_text(#{color := true}, notfound) -> color:cyan("notfound");
get_status_text(#{color := false}, Status) -> Status.

write_file(#{output := Req}, FormatStr, Args) when is_map(Req) ->
  cowboy_req:stream_body(
    lists:flatten(damage_utils:strf(FormatStr ++ "\n", Args)),
    nofin,
    Req
  ),
  ok;

write_file(#{output := Output}, FormatStr, Args) when is_binary(Output) ->
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
      lists:flatten(damage_utils:strf(FormatStr ++ "\n", Args)),
      [append]
    ).


format(Config, feature, {FeatureName, LineNo, [], Description}) ->
  ok =
    write_file(
      Config,
      "~s ~s line:~p desc: ~s",
      [get_keyword(Config, feature_keyword), FeatureName, LineNo, Description]
    );

format(Config, feature, {FeatureName, LineNo, Tags, Description}) ->
  ok =
    write_file(
      Config,
      "~s ~s line:~p tags: [~p], desc: ~s",
      [
        get_keyword(Config, feature_keyword),
        FeatureName,
        LineNo,
        damage_utils:binarystr_join([X || {_Line, X} <- Tags], ","),
        Description
      ]
    );

format(Config, scenario, {ScenarioName, LineNo, []}) ->
  ok =
    write_file(
      Config,
      "  ~s ~s line:~p",
      [get_keyword(Config, <<"Scenario:">>), ScenarioName, LineNo]
    );

format(Config, scenario, {ScenarioName, LineNo, Tags}) ->
  ok =
    write_file(
      Config,
      "  ~s ~s line:~p tags: [~p]",
      [
        get_keyword(Config, <<"Scenario:">>),
        ScenarioName,
        LineNo,
        damage_utils:binarystr_join([X || {_Line, X} <- Tags], ",")
      ]
    );

format(Config, step, {Keyword, LineNo, StepStatement, <<>>, _Context, Status}) ->
  ok =
    write_file(
      Config,
      "    ~s ~s line:~p  ~s",
      [
        get_keyword(Config, Keyword),
        StepStatement,
        LineNo,
        get_status_text(Config, Status)
      ]
    );

format(Config, step, {Keyword, LineNo, StepStatement, Args, _Context, Status}) ->
  ok =
    write_file(
      Config,
      "    ~s ~s line:~p  ~s\n~s ",
      [
        get_keyword(Config, Keyword),
        StepStatement,
        %%     rows = [["Top left", "Top right"], ["Bottom left", "Bottom right"]],
        LineNo,
        get_status_text(Config, Status),
        format_args(Args)
      ]
    );

format(
  Config,
  print,
  {_Keyword, _LineNo, _StepStatement, Args, _Context, _Status}
) ->
  ok = write_file(Config, "~s\n", [format_args(Args)]);

format(Config, summary, #{report_dir := ReportDir, run_id := RunId}) ->
  ok = write_file(Config, "Summary: ~s ~p\n", [ReportDir, RunId]).


format_args([]) -> <<"\n">>;
format_args({fail, Reason}) -> io_lib:format(<<"Fail: ~p\n">>, [Reason]);

format_args(Args) when is_list(Args); is_binary(Args) ->
  Data =
    damage_utils:binarystr_join(
      [<<"        ", A/binary>> || A <- string:split(Args, "\n", all)],
      <<"\n">>
    ),
  <<"    \"\"\"\n", Data/binary, "\n    \"\"\"">>.
