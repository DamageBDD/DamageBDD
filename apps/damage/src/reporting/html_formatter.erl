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
  [_, PidStr, _] =  string:split(pid_to_list(self()), ".", all),
  OutputFile =
    damage_utils:render(
      Output,
      [{process_id, list_to_binary(PidStr)}, {node_id, atom_to_binary(node())}]
    ),
  ok =
    file:write_file(
      OutputFile,
      lists:flatten(damage_utils:strf(FormatStr ++ "\n", Args)),
      [append]
    ).


%% Stream raw docker output chunks
format(#{output := _} = Config, stdout, Bin) when is_binary(Bin); is_list(Bin) ->
  ok = write_file(Config, "<code class='stdout'> ~s</code>", [Bin]);
format(#{output := _} = Config, stderr, Bin) when is_binary(Bin); is_list(Bin) ->
  ok = write_file(Config, "<code class='stderr'> ~s</code>", [Bin]);
format(Config, error, {LineNo, Message}) ->
  ok =
    write_file(
      Config,
      "<tr>\n<td>\nStatus\n</td>\n <td>Fail</td> <td>LineNo: ~p</td> <td>Message:~p</td></tr>",
      [LineNo, Message]
    );

format(Config, feature, {FeatureName, LineNo, Tags, Description}) ->
  ok =
    write_file(
      Config,
      "<tr>\n<td>\nFeature\n</td>\n <td>~s</td> <td>tags: ~p</td> <td>~p</td> <td>~p</td></tr>",
      [
        FeatureName,
        damage_utils:binarystr_join([X || {_Line, X} <- Tags], <<",">>),
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
        damage_utils:binarystr_join([X || {_Line, X} <- Tags], <<",">>),
        LineNo,
        ""
      ]
    );

format(Config, step, {Keyword, LineNo, StepStatement, Args, _Context, Status}) ->
  StatusText = html_status(Status),
  ok =
    write_file(
      Config,
      "<tr><td>~s</td><td>~p</td><td>~p</td><td>~p</td><td>~s</td></tr>",
      [
        get_keyword(Keyword),
        binary_to_list(StepStatement),
        Args,
        LineNo,
        StatusText
      ]
    ),
  format_failure_html(Config, Status);

format(
  Config,
  print,
  {_Keyword, _LineNo, _StepStatement, Args, _Context, _Status}
) ->
  ok = write_file(Config, "<tr><td>~s</td></tr>", [format_args(Args)]);

format(
  Config,
  summary,
  #{
    report_dir := ReportDir,
    run_id := RunId,
    feature_hash := FeatureHash,
    public_key := Address
  } = Summary
) ->
  CostHits = maps:get(cost_hits, Summary, maps:get(cost, Summary, maps:get(spend, Summary, 0))),
  CostDamage = maps:get(cost_damage, Summary, undefined),
  CostBtc = maps:get(cost_btc, Summary, undefined),
  CostSats = maps:get(cost_sats, Summary, undefined),
  CostAe = maps:get(cost_ae, Summary, undefined),
  TxHash = summary_value(maps:get(tx_hash, Summary, undefined)),
  RunStatus = summary_value(maps:get(status, Summary, undefined)),
  RunResult = summary_value(
    maps:get(result, Summary, maps:get(result_status, Summary, undefined))
  ),
    ContextIpfsUrl = summary_value(maps:get(context_ipfs_url, Summary, undefined)),
  ok = write_file(
         Config,
         "<h2>Summary</h2><br>Feature: ~s<br>Report: ~s<br>Context: ~s<br>RunId: ~s<br><br>Address: ~s"
         "<br>Run status: ~s<br>Run result: ~s"
         "<br>Cost DAMAGE: ~p<br>Cost hits: ~p<br>Cost BTC: ~p<br>Cost sats: ~p<br>Cost AE: ~p"
         "<br>tx_hash: ~s<br>",
         [
           FeatureHash, ReportDir, ContextIpfsUrl, RunId, Address,
           RunStatus, RunResult,
           CostDamage, CostHits, CostBtc, CostSats, CostAe, TxHash
         ]).

summary_value(undefined) -> "unknown";
summary_value(Value) when is_binary(Value) -> binary_to_list(Value);
summary_value(Value) when is_list(Value) -> Value;
summary_value(Value) when is_atom(Value) -> atom_to_list(Value);
summary_value(Value) when is_integer(Value) -> integer_to_list(Value);
summary_value(Value) when is_float(Value) ->
  lists:flatten(io_lib:format("~p", [Value]));
summary_value(Value) -> lists:flatten(io_lib:format("~p", [Value])).


html_status({fail, _Reason}) ->
  "fail";
html_status(Status) when is_atom(Status) ->
  atom_to_list(Status);
html_status(Status) when is_binary(Status) ->
  binary_to_list(Status);
html_status(Status) when is_list(Status) ->
  Status;
html_status(Status) ->
  lists:flatten(io_lib:format("~p", [Status])).

format_failure_html(Config, {fail, Reason}) ->
  Escaped = html_escape(reason_text(Reason)),
  write_file(
    Config,
    "<tr class='failure'><td colspan='5'>"
    "<strong>Failure:</strong>"
    "<pre style='white-space:pre-wrap; margin:0.5em 0 0 0'>~s</pre>"
    "</td></tr>",
    [Escaped]
  );
format_failure_html(_Config, _Status) ->
  ok.

reason_text(Bin) when is_binary(Bin) ->
  unicode:characters_to_list(Bin);
reason_text(List) when is_list(List) ->
  unicode:characters_to_list(List);
reason_text(Atom) when is_atom(Atom) ->
  atom_to_list(Atom);
reason_text(Value) ->
  lists:flatten(io_lib:format("~p", [Value])).

html_escape(Text) ->
  lists:flatten([html_escape_char(C) || C <- Text]).

html_escape_char($&) -> "&amp;";
html_escape_char($<) -> "&lt;";
html_escape_char($>) -> "&gt;";
html_escape_char($") -> "&quot;";
html_escape_char($') -> "&#39;";
html_escape_char(C) -> [C].

format_args([]) -> <<"\n">>;
format_args({fail, Reason}) ->
  unicode:characters_to_binary([
    <<"Fail:<br><pre style='white-space:pre-wrap'>">>,
    html_escape(reason_text(Reason)),
    <<"</pre>">>
  ]);

format_args(Args) when is_list(Args); is_binary(Args) ->
  Data =
    damage_utils:binarystr_join(
      [<<"<p>", A/binary, "</p>">> || A <- string:split(Args, "\n", all)],
      <<"<br>">>
    ),
  <<"    \"\"\"<br>", Data/binary, "<br>    \"\"\"">>.
