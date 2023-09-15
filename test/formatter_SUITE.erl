-module(formatter_SUITE).

%-compile([export_all, nowarn_export_all]).
-export(
  [
    all/0,
    groups/0,
    init_per_suite/1,
    end_per_suite/1,
    html_formatter_test/1,
    text_formatter_test/1
  ]
).

-define(CONFIG,).

-import(ct_helper, [config/2]).
-import(ct_helper, [doc/1]).

all() -> [{group, formatter}].

groups() ->
  [{formatter, [parallel], [html_formatter_test, text_formatter_test]}].

init_per_suite(Config) ->
  [
    {host, localhost},
    {feature_dirs, ["../../../../features/", "../features/"]},
    {account, "test"} | Config
  ].

end_per_suite(Config) -> damage_test:end_per_suite(Config).

delete_file_if_exists(FilePath) ->
  case file:read_file_info(FilePath) of
    {ok, _} ->
      % The file exists, so delete it
      case file:delete(FilePath) of
        ok -> io:format("File ~s deleted.~n", [FilePath]);

        {error, Reason} ->
          io:format("Failed to delete file ~s: ~p~n", [FilePath, Reason])
      end;

    {error, _} ->
      % The file does not exist
      io:format("File ~p does not exist.~n", [FilePath])
  end.


text_formatter_test(Config0) ->
  Output = "report.txt",
  Config = [{formatters, [{text, #{output => Output}}]} | Config0],
  delete_file_if_exists(Output),
  ok =
    formatter:invoke_formatters(
      Config,
      step,
      {
        then_keyword,
        13,
        ["the json at path", "$.status", "must be", "ok"],
        <<>>,
        #{},
        fail
      }
    ),
  ok =
    test_file_contains_expected_data(
      Output,
      "Then the json at path $.status must be ok"
    ).


html_formatter_test(Config0) ->
  Output = "report.html",
  Config = [{formatters, [{html, #{output => Output}}]} | Config0],
  delete_file_if_exists(Output),
  ok =
    formatter:invoke_formatters(
      Config,
      step,
      {
        then_keyword,
        13,
        ["the json at path", "$.status", "must be", "ok"],
        <<>>,
        #{},
        fail
      }
    ),
  ok =
    test_file_contains_expected_data(
      Output,
      "<tr><td>Then</td><td>the json at path $.status must be ok</td><td><<>></td><td>13</td><td>fail</td></tr>"
    ).


test_file_contains_expected_data(File, Expected) ->
  %% Open the file in read-only mode
  {ok, Device} = file:open(File, [read]),
  %% Read the entire contents of the file
  {ok, Content} = file:read(Device, filelib:file_size(File)),
  %% Close file
  file:close(Device),
  %% Check if expected data is present in file
  case string:str(Content, Expected) of
    X when X > 0 -> ok;
    _ -> {fail, {Content, Expected}}
  end.
