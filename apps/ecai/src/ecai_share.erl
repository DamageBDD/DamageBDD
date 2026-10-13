%% Explicit private ingestion of an accepted local share. No URL fetching,
%% public indexing, publishing, tools, or automatic LLM invocation.
-module(ecai_share).
-export([ingest/4, records/2, ask/4]).

ask(Corpus, Principal, Question, Destination) ->
    ecai_llm_bridge:ask(Corpus, Principal, Question, Destination).

ingest(Item, Bytes, Corpus, Principal) ->
    case records(Item, Bytes) of
        {ok, Records} ->
            Id = maps:get(id, Item),
            case ecai_private_index:index(Corpus, Principal, Id, Records) of
                {error, batch_already_exists} ->
                    %% A crash may happen after append but before the inbox marks
                    %% success. Verify identity before acknowledging the retry.
                    case ecai_private_index:fetch(Corpus, Principal, <<Id/binary, ":1">>) of
                        {ok, #{source_key := Id, source_version := Hash}} ->
                            case Hash =:= maps:get(sha256, Item) of
                                true -> {ok, #{batch_id => Id, recovered => true}};
                                false -> {error, batch_identity_mismatch}
                            end;
                        _ ->
                            {error, batch_recovery_unavailable}
                    end;
                Result ->
                    Result
            end;
        Error ->
            Error
    end.

records(Item, Bytes) when is_binary(Bytes), byte_size(Bytes) > 0, byte_size(Bytes) =< 4194304 ->
    case supported(Item) andalso valid_text(Bytes) of
        true ->
            Parts = chunks(unicode:characters_to_list(Bytes), [], [], 0),
            {ok, [
                #{
                    title => maps:get(name, Item),
                    text => Text,
                    type => <<"share">>,
                    tags => [<<"share-to-ecai">>, maps:get(transport, Item)],
                    source_key => maps:get(id, Item),
                    source_version => maps:get(sha256, Item),
                    chunk_ordinal => N
                }
             || {N, Text} <- lists:zip(lists:seq(1, length(Parts)), Parts)
            ]};
        false ->
            {error, unsupported_content}
    end;
records(_, <<>>) ->
    {error, empty_content};
records(_, _) ->
    {error, text_limit}.

supported(#{kind := Kind}) when Kind =:= text; Kind =:= url -> true;
supported(#{name := Name}) ->
    lists:member(
        string:lowercase(filename:extension(binary_to_list(Name))),
        [
            ".txt",
            ".md",
            ".org",
            ".json",
            ".csv",
            ".tsv",
            ".feature",
            ".erl",
            ".hrl",
            ".log",
            ".xml",
            ".html",
            ".url",
            ".webloc",
            ".yaml",
            ".yml",
            ".rst"
        ]
    );
supported(_) ->
    false.

valid_text(B) ->
    is_binary(unicode:characters_to_binary(B)) andalso binary:match(B, <<0>>) =:= nomatch.

%% Split on Unicode code points, keeping every chunk below the private record
%% limit. 4 MiB input yields at most 129 records (private API permits 256).
chunks([], [], Acc, _) ->
    lists:reverse(Acc);
chunks([], Part, Acc, _) ->
    lists:reverse([unicode:characters_to_binary(lists:reverse(Part)) | Acc]);
chunks([C | Rest], Part, Acc, Size) when Size >= 32764 ->
    chunks([C | Rest], [], [unicode:characters_to_binary(lists:reverse(Part)) | Acc], 0);
chunks([C | Rest], Part, Acc, Size) ->
    chunks(Rest, [C | Part], Acc, Size + byte_size(unicode:characters_to_binary([C]))).
