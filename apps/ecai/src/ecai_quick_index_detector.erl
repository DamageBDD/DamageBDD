%%--------------------------------------------------------------------
%% Lightweight, deterministic source inspection for the dashboard Quick Index.
%% This module only classifies content; the durable IPFS index path remains the
%% authority for chunking, persistence and artifact construction.
%%--------------------------------------------------------------------
-module(ecai_quick_index_detector).

-export([analyze/2]).

-define(SAMPLE_LINES, 64).

-spec analyze(binary(), map()) -> {ok, map()}.
analyze(Bytes, Meta) when is_binary(Bytes), is_map(Meta) ->
    Name = text(maps:get(filename, Meta, <<>>)),
    Mime = text(maps:get(mime, Meta, <<>>)),
    Sha = lower_hex(crypto:hash(sha256, Bytes)),
    Base = #{
        size_bytes => byte_size(Bytes),
        sha256 => Sha,
        filename => Name,
        mime => Mime,
        pipeline => <<"ipfs_cid -> searchable_disk -> UTF-8 windows">>
    },
    {ok, maps:merge(Base, classify(Bytes, Name, Mime))}.

classify(<<>>, _Name, _Mime) ->
    unsupported(empty, <<"Empty source">>, <<"Add content before indexing.">>);
classify(<<"%PDF-", _/binary>>, _Name, _Mime) ->
    unsupported(pdf, <<"PDF document">>, <<"Extract PDF text before indexing in this pipeline.">>);
classify(<<"PK", 3, 4, _/binary>>, Name, _Mime) ->
    Label = case extension(Name) of
        <<"docx">> -> <<"DOCX document">>;
        <<"xlsx">> -> <<"XLSX workbook">>;
        <<"pptx">> -> <<"PPTX presentation">>;
        _ -> <<"ZIP archive">>
    end,
    unsupported(zip, Label, <<"Archive/container extraction is not enabled for Quick Index.">>);
classify(Bytes, Name, Mime) ->
    case utf8(Bytes) andalso binary:match(Bytes, <<0>>) =:= nomatch of
        false -> unsupported(binary, <<"Binary data">>, <<"Quick Index accepts UTF-8 text and structured-text sources.">>);
        true -> classify_text(Bytes, Name, Mime)
    end.

classify_text(Bytes, Name, Mime) ->
    Ext = extension(Name),
    Lines = binary:split(Bytes, <<"\n">>, [global]),
    NonEmpty = [trim(Line) || Line <- Lines, trim(Line) =/= <<>>],
    Base = #{
        indexable => true,
        encoding => <<"utf-8">>,
        line_count => length(Lines),
        warning => null
    },
    case decode_json(Bytes) of
        {ok, Json} -> maps:merge(Base, json_analysis(Json));
        error ->
            case jsonl_analysis(NonEmpty) of
                {ok, Jsonl} -> maps:merge(Base, Jsonl);
                error -> maps:merge(Base, text_analysis(Bytes, NonEmpty, Ext, Mime))
            end
    end.

json_analysis(Map) when is_map(Map) ->
    #{
        format => json,
        label => <<"JSON object">>,
        structure => <<"object">>,
        field_count => map_size(Map),
        records_estimate => 1
    };
json_analysis(List) when is_list(List) ->
    #{
        format => json,
        label => <<"JSON array">>,
        structure => <<"array">>,
        field_count => null,
        records_estimate => length(List)
    };
json_analysis(_Scalar) ->
    #{
        format => json,
        label => <<"JSON scalar">>,
        structure => <<"scalar">>,
        field_count => null,
        records_estimate => 1
    }.

jsonl_analysis(Lines) when length(Lines) >= 2 ->
    Sample = lists:sublist(Lines, ?SAMPLE_LINES),
    Parsed = [decode_json(Line) || Line <- Sample],
    case lists:all(fun json_object_result/1, Parsed) of
        true ->
            {ok, #{
                format => jsonl,
                label => <<"JSON Lines / NDJSON">>,
                structure => <<"one JSON object per line">>,
                field_count => null,
                records_estimate => length(Lines)
            }};
        false -> error
    end;
jsonl_analysis(_) -> error.

json_object_result({ok, Value}) when is_map(Value) -> true;
json_object_result(_) -> false.

text_analysis(Bytes, Lines, Ext, Mime) ->
    case format_hint(Bytes, Lines, Ext, Mime) of
        {csv, Delim, Columns} -> #{
            format => csv,
            label => case Delim of $\t -> <<"Tab-separated values">>; _ -> <<"Comma-separated values">> end,
            structure => case Delim of $\t -> <<"tabular / TSV">>; _ -> <<"tabular / CSV">> end,
            field_count => Columns,
            records_estimate => erlang:max(0, length(Lines) - 1)
        };
        {Format, Label, Structure} -> #{
            format => Format,
            label => Label,
            structure => Structure,
            field_count => null,
            records_estimate => null
        }
    end.

format_hint(Bytes, Lines, Ext, Mime) ->
    case {Ext, Mime} of
        {<<"md">>, _} -> {markdown, <<"Markdown document">>, heading_structure(Bytes, markdown)};
        {<<"markdown">>, _} -> {markdown, <<"Markdown document">>, heading_structure(Bytes, markdown)};
        {<<"org">>, _} -> {org, <<"Org document">>, heading_structure(Bytes, org)};
        {<<"html">>, _} -> {html, <<"HTML document">>, <<"HTML markup; indexed as source text">>};
        {<<"htm">>, _} -> {html, <<"HTML document">>, <<"HTML markup; indexed as source text">>};
        {<<"xml">>, _} -> {xml, <<"XML document">>, <<"XML markup; indexed as source text">>};
        {<<"yaml">>, _} -> {yaml, <<"YAML document">>, <<"structured text">>};
        {<<"yml">>, _} -> {yaml, <<"YAML document">>, <<"structured text">>};
        {E, _} when E =:= <<"erl">>; E =:= <<"hrl">>; E =:= <<"ex">>; E =:= <<"exs">>;
                    E =:= <<"py">>; E =:= <<"js">>; E =:= <<"ts">>; E =:= <<"rs">>;
                    E =:= <<"go">>; E =:= <<"c">>; E =:= <<"h">>; E =:= <<"cpp">>;
                    E =:= <<"hpp">>; E =:= <<"java">>; E =:= <<"rb">>; E =:= <<"sh">> ->
            {source_code, <<"Source code">>, <<"code / UTF-8 text">>};
        {_, <<"text/markdown", _/binary>>} -> {markdown, <<"Markdown document">>, heading_structure(Bytes, markdown)};
        {_, <<"text/html", _/binary>>} -> {html, <<"HTML document">>, <<"HTML markup; indexed as source text">>};
        _ -> detect_delimited_or_text(Lines)
    end.

detect_delimited_or_text(Lines) ->
    Sample = lists:sublist(Lines, 8),
    case delimiter_shape(Sample, $,) of
        {ok, Columns} -> {csv, $,, Columns};
        error ->
            case delimiter_shape(Sample, $\t) of
                {ok, Columns} -> {csv, $\t, Columns};
                error -> {text, <<"Plain text">>, <<"UTF-8 text">>}
            end
    end.

delimiter_shape(Lines, Delim) when length(Lines) >= 2 ->
    Counts = [length(binary:split(Line, <<Delim>>, [global])) || Line <- Lines],
    case Counts of
        [Columns | _] when Columns >= 2 ->
            Matching = length([C || C <- Counts, C =:= Columns]),
            case Matching >= erlang:min(3, length(Counts)) of
                true -> {ok, Columns};
                false -> error
            end;
        _ -> error
    end;
delimiter_shape(_, _) -> error.

heading_structure(Bytes, markdown) ->
    Count = count_matching_lines(Bytes, <<"^#{1,6}[[:space:]]+">>),
    iolist_to_binary(io_lib:format("Markdown headings: ~B", [Count]));
heading_structure(Bytes, org) ->
    Count = count_matching_lines(Bytes, <<"^\\*+[[:space:]]+">>),
    iolist_to_binary(io_lib:format("Org headings: ~B", [Count])).

count_matching_lines(Bytes, Pattern) ->
    Lines = binary:split(Bytes, <<"\n">>, [global]),
    length([ok || Line <- Lines, re:run(Line, Pattern, [{capture, none}]) =:= match]).

unsupported(Format, Label, Warning) ->
    #{
        format => Format,
        label => Label,
        structure => <<"binary container">>,
        indexable => false,
        encoding => null,
        line_count => null,
        field_count => null,
        records_estimate => null,
        warning => Warning
    }.

decode_json(Bin) ->
    try jsx:decode(Bin, [return_maps]) of
        Value -> {ok, Value}
    catch
        _:_ -> error
    end.

utf8(Bin) ->
    case unicode:characters_to_binary(Bin, utf8, utf8) of
        Converted when is_binary(Converted) -> true;
        _ -> false
    end.

extension(<<>>) -> <<>>;
extension(Name) ->
    Base = filename:basename(binary_to_list(Name)),
    case filename:extension(Base) of
        [] -> <<>>;
        [$. | Rest] -> string:lowercase(unicode:characters_to_binary(Rest));
        _ -> <<>>
    end.

trim(Bin) -> string:trim(Bin).

text(Bin) when is_binary(Bin) -> Bin;
text(List) when is_list(List) -> unicode:characters_to_binary(List);
text(undefined) -> <<>>;
text(null) -> <<>>;
text(Value) -> iolist_to_binary(io_lib:format("~p", [Value])).

lower_hex(Bin) -> string:lowercase(binary:encode_hex(Bin)).
