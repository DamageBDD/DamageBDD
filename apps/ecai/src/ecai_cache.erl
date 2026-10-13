%%%-------------------------------------------------------------------
%%% ecai_cache.erl — Global ETS cache for ECAI semantic “compression”
%%%
%%% Key idea:
%%%   Text -> Ref (stable), Count, Point
%%%   Repeated text collapses to the same Ref deterministically.
%%%-------------------------------------------------------------------
-module(ecai_cache).
-author("Steven Joseph <steven@stevenjoseph.in>").
-license("Apache-2.0").

-export([
    ensure/0,
    get_ref/1,
    stats/1,
    reset/0
]).
-export([remember_ref/2, export_ref_map/1]).

-define(TAB, ecai_cache).

%% Ensure the ETS table exists (safe to call often)
ensure() ->
    case ets:info(?TAB) of
        undefined ->
            ets:new(?TAB, [
                named_table,
                public,
                set,
                {read_concurrency, true},
                {write_concurrency, true}
            ]),
            ok;
        _ ->
            ok
    end.

%% get_ref(Text) -> {ok, Ref, Count, Point}
get_ref(Text) when is_binary(Text); is_list(Text) ->
    ok = ensure(),
    Bin = iolist_to_binary(Text),
    Key = crypto:hash(sha256, Bin),

    case ets:lookup(?TAB, Key) of
        [{Key, Ref, Count, Point}] ->
            %% Increment count (write) but keep lookup cheap.
            _ = ets:update_counter(?TAB, Key, {3, 1}),
            {ok, Ref, Count + 1, Point};
        [] ->
            %% First time: compute EC point (expensive), store once.
            Point = ecai:hash_to_curve(Bin),
            Ref = make_ref(Point),
            true = ets:insert(?TAB, {Key, Ref, 1, Point}),
            {ok, Ref, 1, Point}
    end.

%% stats(Text) -> {ok, Ref, Count, Point} | notfound
stats(Text) when is_binary(Text); is_list(Text) ->
    ok = ensure(),
    Bin = iolist_to_binary(Text),
    Key = crypto:hash(sha256, Bin),
    case ets:lookup(?TAB, Key) of
        [{Key, Ref, Count, Point}] -> {ok, Ref, Count, Point};
        [] -> notfound
    end.

%% Clear cache (useful in tests)
reset() ->
    ok = ensure(),
    ets:delete_all_objects(?TAB),
    ok.

make_ref({X, Y}) ->
    Hash = crypto:hash(sha256, term_to_binary({X, Y})),
    Short = binary:part(Hash, 0, 8),
    <<"ECAI[", (base16:encode(Short))/binary, "]">>.

remember_ref(Ref, Text) when is_binary(Ref), (is_binary(Text) orelse is_list(Text)) ->
    ok = ensure(),
    %% separate table or same table — simplest: a second named table
    ensure_ref_tab(),
    ets:insert(ecai_cache_refs, {Ref, iolist_to_binary(Text)}),
    ok.

export_ref_map(FilePath) ->
    ensure_ref_tab(),
    Map =
        maps:from_list(
            [{Ref, Text} || {Ref, Text} <- ets:tab2list(ecai_cache_refs)]
        ),
    file:write_file(FilePath, term_to_binary(Map), [write]).

ensure_ref_tab() ->
    case ets:info(ecai_cache_refs) of
        undefined ->
            ets:new(ecai_cache_refs, [
                named_table,
                public,
                set,
                {read_concurrency, true},
                {write_concurrency, true}
            ]),
            ok;
        _ ->
            ok
    end.
