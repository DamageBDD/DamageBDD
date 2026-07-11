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
  TxHash = maps:get(tx_hash, Summary, undefined),
  ok = write_file(
         Config,
         "<h2>Summary</h2><br>Feature: ~s<br>Report: ~s<br>RunId: ~s<br><br>Address: ~s"
         "<br>Cost DAMAGE: ~p<br>Cost hits: ~p<br>Cost BTC: ~p<br>Cost sats: ~p<br>Cost AE: ~p"
         "<br>tx_hash: ~p<br>",
         [FeatureHash, ReportDir, RunId, Address, CostDamage, CostHits, CostBtc, CostSats, CostAe, TxHash]).

format_args([]) -> <<"\n">>;
format_args({fail, Reason}) -> io_lib:format(<<"Fail: ~p<br>">>, [Reason]);

format_args(Args) when is_list(Args); is_binary(Args) ->
  Data =
    damage_utils:binarystr_join(
      [<<"<p>", A/binary, "</p>">> || A <- string:split(Args, "\n", all)],
      <<"<br>">>
    ),
  <<"    \"\"\"<br>", Data/binary, "<br>    \"\"\"">>.
