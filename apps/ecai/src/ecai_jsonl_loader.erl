-module(ecai_jsonl_loader).

-export([load_all_jsonl/0, read_jsonl/1, read_lines/1, process_json/1]).

%% External deps: jsx
%% Internal deps: ecai_point (must implement from_integer/1)

load_all_jsonl() ->
    %% Adjust path if needed
    Files = filelib:wildcard("wikipedia-structured-contents/enwiki_namespace_0/*.jsonl"),
    lists:foreach(fun read_jsonl/1, Files).

read_jsonl(File) ->
    io:format("Loading ~s~n", [File]),
    {ok, Io} = file:open(File, [read]),
    read_lines(Io).

read_lines(Io) ->
    case io:get_line(Io, "") of
        eof -> 
            file:close(Io),
            done;
        Line ->
            process_json(Line),
            read_lines(Io)
    end.

process_json(Line) ->
    try
        Json = jsx:decode(Line, [return_maps]),
        ecai_mapper(Json)
    catch
        _:Error -> io:format("JSON decode error: ~p~n", [Error])
    end.

%% Extract title + text and hash to EC point
ecai_mapper(#{<<"title">> := Title, <<"text">> := Text}) when is_binary(Title), is_binary(Text) ->
    Hash = crypto:hash(sha256, <<Title/binary, Text/binary>>),
    <<X:256>> = binary:part(Hash, {0, 32}),
    Point = ecai_point:from_integer(X),
    io:format("~s => ~p~n", [Title, Point]);
ecai_mapper(_) ->
    ok.
