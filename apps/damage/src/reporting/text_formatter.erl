-module(text_formatter).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").
-include_lib("kernel/include/logger.hrl").

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

get_status_text(#{color := true}, dry) -> color:magenta("dry");
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

write_file(#{output := Output}, FormatStr, Args) when is_binary(Output) or is_list(Output)->
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
  ok = write_file(Config, "stdout> ~s", [Bin]);
format(#{output := _} = Config, stderr, Bin) when is_binary(Bin); is_list(Bin) ->
  ok = write_file(Config, "stderr> ~s", [Bin]);

%% Non-streaming / non-HTTP runs: ignore docker chunks
format(_Config, raw, _Bin) ->
  ok;


format(Config, error, {LineNo, Message}) ->
  ok =
    write_file(
      Config,
      "~s line:~p desc: ~s",
      [get_status_text(Config, fail), LineNo, Message]
    );

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
      "~s ~s line:~p tags: [~s], desc: ~s",
      [
        get_keyword(Config, feature_keyword),
        FeatureName,
        LineNo,
        damage_utils:binarystr_join([X || {_Line, X} <- Tags], <<",">>),
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
      "  ~s ~s line:~p tags: [~s]",
      [
        get_keyword(Config, <<"Scenario:">>),
        ScenarioName,
        LineNo,
        damage_utils:binarystr_join([X || {_Line, X} <- Tags], <<",">>)
      ]
    );

format(Config, step, {Keyword, LineNo, StepStatement, Args, _Context, Status}) ->
    Text =
        io_lib:format(
          "    ~s ~s line:~p  ~s",
          [
            get_keyword(Config, Keyword),
            StepStatement,
            LineNo,
            get_status_text(Config, Status)
          ]
        ),

    case ecai_compress:compress(Config, Text) of
        {compressed, Ref} ->
            ok = ecai_cache:remember_ref(iolist_to_binary(Ref), iolist_to_binary(Text)),
            write_file(Config, "    ~s", [Ref]);
        {raw, Raw} ->
            write_file(Config, "~s", [Raw])
    end,


    case Args of
        <<>> -> ok;
        []   -> ok;
        _    -> write_file(Config, "~s", [format_args(Args)])
    end;
format(
  Config,
  print,
  {_Keyword, _LineNo, StepStatement, Args, _Context, _Status}
) ->
  ok = write_file(Config, "\n~s \n\n~s\n", [StepStatement, Args]);

format(Config, summary, #{report_dir := ReportDir, run_id := RunId, feature_hash := FeatureHash, public_key :=Address, spend := Spend, tx_hash := TxHash}) ->
    ok = write_file(Config, "\nSummary: \n Feature: ~s\nReport ~s\nRunId: ~s\nAccount: ~s\nCost: ~p\ntx_hash: ~p", [FeatureHash, ReportDir, RunId, Address, Spend, TxHash]),
    %% new: persist the dictionary beside the report artifacts
    case maps:get(ecai, Config, false) of
        true ->
            MapFile = filename:join([ReportDir, "ecai_map.term"]),
            _ = ecai_cache:export_ref_map(MapFile),
            ok;
        false ->
            ok
    end.


format_args([]) -> <<"\n">>;
format_args({fail, Reason}) -> io_lib:format(<<"Fail: ~p\n">>, [Reason]);

format_args(Args) when is_list(Args); is_binary(Args) ->
  Data =
    damage_utils:binarystr_join(
      [<<"        ", A/binary>> || A <- string:split(Args, "\n", all)],
      <<"\n">>
    ),
  <<"    \"\"\"\n", Data/binary, "\n    \"\"\"">>.
