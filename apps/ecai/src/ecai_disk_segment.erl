%%--------------------------------------------------------------------
%% ecai_disk_segment.erl
%% Immutable CSR-style disk segment
%%--------------------------------------------------------------------
-module(ecai_disk_segment).
-export([write/3, open/1, close/1, get_postings/2, get_postings/3, prefix_terms/3]).

-record(seg, {fd, terms, posts_base, term_keys}).

-define(MAGIC, <<"ECS1">>).

write(BaseDir, SegName, TermDocs) ->
    ok = ecai_private_store:assert_public(BaseDir),
    Path = filename:join(BaseDir, SegName),
    Tmp = Path ++ ".tmp",
    {ok, FD} = file:open(Tmp, [raw, binary, write]),

    Terms = lists:sort(maps:keys(TermDocs)),
    TermCount = length(Terms),

    {TermMeta, PostsBin, PostsCount} = build_csr(Terms, TermDocs),

    ok = file:write(
        FD, <<?MAGIC/binary, TermCount:32/little-unsigned, PostsCount:32/little-unsigned>>
    ),
    ok = file:write(FD, iolist_to_binary(TermMeta)),
    ok = file:write(FD, PostsBin),
    ok = file:sync(FD),
    ok = file:close(FD),
    ok = file:rename(Tmp, Path),
    ok.

build_csr(Terms, TermDocs) ->
    {Meta, Posts, Cur} =
        lists:foldl(
            fun(T, {MAcc, PAcc, Off}) ->
                Docs = lists:usort(maps:get(T, TermDocs)),
                Len = length(Docs),
                TL = byte_size(T),
                MAcc1 =
                    [<<TL:16/little, T/binary, Off:32/little, Len:32/little>> | MAcc],
                PAcc1 = [<<<<D:32/little>> || D <- Docs>> | PAcc],
                {MAcc1, PAcc1, Off + Len}
            end,
            {[], [], 0},
            Terms
        ),
    {lists:reverse(Meta), iolist_to_binary(lists:reverse(Posts)), Cur}.

open(Path) ->
    {ok, FD} = file:open(Path, [raw, binary, read]),
    try
        {ok, <<Magic:4/binary, TermCount:32/little-unsigned, _PostCount:32/little-unsigned>>} =
            file:pread(FD, 0, 12),
        true = (Magic =:= ?MAGIC),
        {TermsMap, PostsBase} = read_terms(FD, 12, TermCount, #{}),
        %% Transient dictionary only: ECS1 bytes and term pipeline stay intact.
        Keys = list_to_tuple(lists:sort(maps:keys(TermsMap))),
        {ok, #seg{fd = FD, terms = TermsMap, posts_base = PostsBase, term_keys = Keys}}
    catch Class:Reason:Stack ->
        _ = file:close(FD),
        erlang:raise(Class, Reason, Stack)
    end.

close(#seg{fd = FD}) ->
    file:close(FD).

get_postings(#seg{fd = FD, terms = Map, posts_base = Base}, Term) ->
    case maps:get(Term, Map, undefined) of
        undefined ->
            [];
        {Off, Len} ->
            Bytes = Len * 4,
            {ok, Bin} = file:pread(FD, Base + Off * 4, Bytes),
            decode_u32(Bin)
    end.

%% Bounded pread; a frequent prefix must not allocate its entire postings list.
get_postings(#seg{fd = FD, terms = Map, posts_base = Base}, Term, Max) ->
    case maps:find(Term, Map) of
        error -> {[], false};
        {ok, {_Off, 0}} -> {[], false};
        {ok, {Off, Len}} ->
            Count = erlang:min(Len, Max),
            {ok, Bin} = file:pread(FD, Base + Off * 4, Count * 4),
            {decode_u32(Bin), Len > Count}
    end.

%% Binary seek in the already-read dictionary, then a bounded lexical range.
prefix_terms(#seg{term_keys = Keys}, Prefix, Max) ->
    Start = lower_bound(Keys, Prefix, 1, tuple_size(Keys) + 1),
    prefix_range(Keys, Prefix, Start, Max, []).
lower_bound(_Keys, _Prefix, Lo, Lo) -> Lo;
lower_bound(Keys, Prefix, Lo, Hi) ->
    Mid = (Lo + Hi) div 2,
    case element(Mid, Keys) < Prefix of
        true -> lower_bound(Keys, Prefix, Mid+1, Hi);
        false -> lower_bound(Keys, Prefix, Lo, Mid)
    end.
prefix_range(Keys, _Prefix, Pos, _Max, Acc) when Pos > tuple_size(Keys) ->
    {lists:reverse(Acc), false};
prefix_range(Keys, Prefix, Pos, Max, Acc) ->
    Term = element(Pos, Keys), N = byte_size(Prefix),
    case byte_size(Term) >= N andalso binary:part(Term, 0, N) =:= Prefix of
        false -> {lists:reverse(Acc), false};
        true when Max =:= 0 -> {lists:reverse(Acc), true};
        true -> prefix_range(Keys, Prefix, Pos+1, Max-1, [Term|Acc])
    end.

decode_u32(<<>>) -> [];
decode_u32(<<I:32/little, R/binary>>) -> [I | decode_u32(R)].

read_terms(_FD, Pos, 0, Acc) ->
    {Acc, Pos};
read_terms(FD, Pos, N, Acc) ->
    {ok, <<TL:16/little>>} = file:pread(FD, Pos, 2),
    {ok, T} = file:pread(FD, Pos + 2, TL),
    {ok, <<Off:32/little, Len:32/little>>} =
        file:pread(FD, Pos + 2 + TL, 8),
    Next = Pos + 2 + TL + 8,
    read_terms(FD, Next, N - 1, Acc#{T => {Off, Len}}).
