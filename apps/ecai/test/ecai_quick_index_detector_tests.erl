-module(ecai_quick_index_detector_tests).
-include_lib("eunit/include/eunit.hrl").

markdown_test() ->
    {ok, A} = ecai_quick_index_detector:analyze(<<"# Title\n\nHello\n## Next\n">>, #{filename => <<"notes.md">>}),
    ?assertEqual(markdown, maps:get(format, A)),
    ?assertEqual(true, maps:get(indexable, A)),
    ?assertEqual(5, maps:get(line_count, A)).

json_test() ->
    {ok, A} = ecai_quick_index_detector:analyze(<<"[{\"a\":1},{\"a\":2}]">>, #{filename => <<"rows.json">>}),
    ?assertEqual(json, maps:get(format, A)),
    ?assertEqual(2, maps:get(records_estimate, A)).

jsonl_test() ->
    {ok, A} = ecai_quick_index_detector:analyze(<<"{\"a\":1}\n{\"a\":2}\n">>, #{filename => <<"rows.ndjson">>}),
    ?assertEqual(jsonl, maps:get(format, A)),
    ?assertEqual(2, maps:get(records_estimate, A)).

mixed_jsonl_falls_back_to_text_test() ->
    {ok, A} = ecai_quick_index_detector:analyze(
        <<"{\"a\":1}\nnot-json\n">>,
        #{filename => <<"mixed.txt">>}
    ),
    ?assertEqual(text, maps:get(format, A)),
    ?assertEqual(true, maps:get(indexable, A)).

csv_test() ->
    {ok, A} = ecai_quick_index_detector:analyze(<<"name,city\na,Sydney\nb,Perth\n">>, #{filename => <<"people.csv">>}),
    ?assertEqual(csv, maps:get(format, A)),
    ?assertEqual(2, maps:get(field_count, A)).

pdf_rejected_test() ->
    {ok, A} = ecai_quick_index_detector:analyze(<<"%PDF-1.7\n...">>, #{filename => <<"paper.pdf">>}),
    ?assertEqual(pdf, maps:get(format, A)),
    ?assertEqual(false, maps:get(indexable, A)).

binary_rejected_test() ->
    {ok, A} = ecai_quick_index_detector:analyze(<<0, 255, 0, 17>>, #{filename => <<"blob.bin">>}),
    ?assertEqual(binary, maps:get(format, A)),
    ?assertEqual(false, maps:get(indexable, A)).
