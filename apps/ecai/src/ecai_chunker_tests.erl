-module(ecai_chunker_tests).

-include_lib("eunit/include/eunit.hrl").

empty_input_test() ->
    ?assertEqual({ok, []}, ecai_chunker:chunk_utf8(<<>>, 4, 1)).

short_input_test() ->
    {ok, [Chunk]} = ecai_chunker:chunk_utf8(<<"abc">>, 4, 1),
    ?assertEqual(1, maps:get(ordinal, Chunk)),
    ?assertEqual(0, maps:get(byte_start, Chunk)),
    ?assertEqual(3, maps:get(byte_end, Chunk)),
    ?assertEqual(<<"abc">>, maps:get(text, Chunk)).

ascii_overlap_and_offsets_test() ->
    {ok, Chunks} = ecai_chunker:chunk_utf8(<<"abcdefghij">>, 4, 1),
    ?assertEqual(
        [
            #{ordinal => 1, byte_start => 0, byte_end => 4, text => <<"abcd">>},
            #{ordinal => 2, byte_start => 3, byte_end => 7, text => <<"defg">>},
            #{ordinal => 3, byte_start => 6, byte_end => 10, text => <<"ghij">>}
        ],
        Chunks
    ).

utf8_boundaries_test() ->
    Bin = unicode:characters_to_binary("aé🙂bcé🙂d"),
    {ok, Chunks} = ecai_chunker:chunk_utf8(Bin, 4, 1),
    ?assertEqual(
        [
            unicode:characters_to_binary("aé🙂b"),
            unicode:characters_to_binary("bcé🙂"),
            unicode:characters_to_binary("🙂d")
        ],
        [maps:get(text, Chunk) || Chunk <- Chunks]
    ),
    ?assertEqual(
        [{0, 8}, {7, 15}, {11, 16}],
        [
            {maps:get(byte_start, Chunk), maps:get(byte_end, Chunk)}
         || Chunk <- Chunks
        ]
    ).

invalid_utf8_rejected_before_callback_test() ->
    put(callback_count, 0),
    Invalid = <<"valid-prefix", 16#F0, 16#28, 16#8C, 16#28>>,
    Result = ecai_chunker:fold_utf8(
        Invalid,
        4,
        1,
        fun(_Chunk, Acc) ->
            put(callback_count, get(callback_count) + 1),
            {ok, Acc}
        end,
        ok
    ),
    ?assertEqual({error, {invalid_utf8, 12}}, Result),
    ?assertEqual(0, get(callback_count)),
    erase(callback_count).

bad_arguments_test() ->
    ?assertEqual({error, badarg}, ecai_chunker:chunk_utf8(<<"abc">>, 0, 0)),
    ?assertEqual({error, badarg}, ecai_chunker:chunk_utf8(<<"abc">>, 4, 4)),
    ?assertEqual({error, badarg}, ecai_chunker:chunk_utf8(not_binary, 4, 1)).

callback_error_is_propagated_test() ->
    Result = ecai_chunker:fold_utf8(
        <<"abcdefghij">>,
        4,
        1,
        fun(Chunk, Acc) ->
            case maps:get(ordinal, Chunk) of
                2 -> {error, stopped};
                _ -> {ok, Acc + 1}
            end
        end,
        0
    ),
    ?assertEqual({error, stopped}, Result).

all_ascii_windows_reconstruct_without_gaps_test() ->
    lists:foreach(
        fun({Length, Size, Overlap}) ->
            assert_reconstructs(Length, Size, Overlap)
        end,
        [
            {Length, Size, Overlap}
         || Length <- lists:seq(1, 80),
            Size <- lists:seq(1, 12),
            Overlap <- lists:seq(0, Size - 1)
        ]
    ).

assert_reconstructs(Length, Size, Overlap) ->
    Bin = binary:copy(<<"x">>, Length),
    {ok, Chunks} = ecai_chunker:chunk_utf8(Bin, Size, Overlap),
    ?assertEqual(Bin, reconstruct_ascii(Chunks, Overlap)),
    assert_ordinals_and_ranges(Chunks, 1, 0).

reconstruct_ascii([], _Overlap) ->
    <<>>;
reconstruct_ascii([First | Rest], Overlap) ->
    lists:foldl(
        fun(Chunk, Acc) ->
            Text = maps:get(text, Chunk),
            TailLength = byte_size(Text) - erlang:min(Overlap, byte_size(Text)),
            Tail = binary:part(Text, byte_size(Text) - TailLength, TailLength),
            <<Acc/binary, Tail/binary>>
        end,
        maps:get(text, First),
        Rest
    ).

assert_ordinals_and_ranges([], _ExpectedOrdinal, _PreviousStart) ->
    ok;
assert_ordinals_and_ranges([Chunk | Rest], ExpectedOrdinal, PreviousStart) ->
    Start = maps:get(byte_start, Chunk),
    End = maps:get(byte_end, Chunk),
    Text = maps:get(text, Chunk),
    ?assertEqual(ExpectedOrdinal, maps:get(ordinal, Chunk)),
    ?assert(Start >= PreviousStart),
    ?assertEqual(byte_size(Text), End - Start),
    assert_ordinals_and_ranges(Rest, ExpectedOrdinal + 1, Start).
