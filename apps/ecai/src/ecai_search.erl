%%%-------------------------------------------------------------------
%%% ecai_search.erl  — ECAI directory index (exact+prefix) with proofs
%%%-------------------------------------------------------------------
-module(ecai_search).
-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").
-compile(warn_export_all).

-include_lib("kernel/include/logger.hrl").
-include_lib("ecai_search.hrl").

%% Public API
-export([
    % -> Ctx
    new/0,
    % (Ctx, DocIdBin, Map) -> ok
    add_record/3,
    % idem (add or replace)
    upsert_record/3,
    % (Ctx, DocIdBin) -> ok
    remove_record/2,

    % (Ctx, QueryMap, Limit) -> {Results, ProofHeaders}
    search/3,
    % (Ctx, TermBin) -> #{df:=..., root:=..., tag:=...}
    info_term/2,
    % (Ctx) -> [#{tag:=Bin, root:=Hex, df:=Int}]
    export_onchain_headers/1,

    % (Ctx, TermBin, DocIdBin) -> {ok, Path, Dirs} | not_found
    proof_for/3,
    term_root/2,
    term_tag/2,
    term_df/2,
    set_opts/2,
    get_opts/1,
    % rebuild all roots (for bulk loads)
    finalize/1,

    % diagnostics
    size/1,
    % drop all ETS tables
    wipe/1,
    % (Ctx, FilePath) -> ok | {error, Reason}
    save/2,
    save/1,
    % (FilePath) -> {ok, Ctx} | {error, Reason}
    load/1,
    load/2
]).

-export([
    % (Ctx, YelpReviewMap|#{}) -> ok
    add_review/2,
    % (Ctx, DocIdBin) -> #{count:=..., avg:=..., useful:=..., funny:=..., cool:=...}
    get_review_stats/2,
    add_review_stats/6,
    index_text/5
]).
-export([enable_gpu/1, disable_gpu/1, gpu_refresh/1]).
-export([export_compact/1]).
-import(ecai_utils, [hex/1]).

-define(WEIGHTS, #{
    <<"name">> => 3,
    <<"cat">> => 2,
    <<"city">> => 2,
    <<"tag">> => 1,
    <<"phone">> => 4
}).

-define(P_MIN, 2).
-define(P_MAX, 8).

set_opts(Ctx = #ctx{}, OptsMap) when is_map(OptsMap) ->
    Ctx#ctx{opts = maps:merge(Ctx#ctx.opts, OptsMap)}.

get_opts(#ctx{opts = O}) -> O.

%%%===================================================================
%%% Init / Tables
%%%===================================================================

new() ->
    application:ensure_all_started(crypto),

    PostTab = ets:new(ecai_postings, [
        ordered_set,
        public,
        {read_concurrency, true},
        {write_concurrency, true}
    ]),
    RootTab = ets:new(ecai_root, [
        set,
        public,
        {read_concurrency, true},
        {write_concurrency, true}
    ]),
    RecTab = ets:new(ecai_rec, [
        set,
        named_table,
        public,
        {write_concurrency, true}
    ]),
    DfTab = ets:new(ecai_df, [
        set,
        named_table,
        public,
        {write_concurrency, true}
    ]),
    TagTab = ets:new(ecai_tag, [
        set,
        named_table,
        public,
        {write_concurrency, true}
    ]),
    I2DTab = ets:new(ecai_i2d, [
        set,
        named_table,
        public,
        {write_concurrency, true}
    ]),
    D2ITab = ets:new(ecai_d2i, [
        set,
        named_table,
        public,
        {write_concurrency, true}
    ]),
    SeqTab = ets:new(ecai_seq, [
        set,
        named_table,
        public,
        {write_concurrency, true}
    ]),

    ets:insert(SeqTab, {seq, 1}),

    #ctx{
        post_tab = PostTab,
        df_tab = DfTab,
        tag_tab = TagTab,
        root_tab = RootTab,
        rec_tab = RecTab,
        id2doc_tab = I2DTab,
        doc2id_tab = D2ITab,
        next_id_tab = SeqTab
    }.

%%%===================================================================
%%% Public mutators
%%%===================================================================

add_record(Ctx = #ctx{doc2id_tab = DocT}, DocId, Rec) ->
    case ets:insert_new(DocT, {DocId, Rec}) of
        true ->
            do_add(Ctx, DocId, Rec),
            ok;
        false ->
            %% already present – do NOT crash
            {error, exists}
    end.

upsert_record(Ctx, DocId, Map) ->
    case ets:lookup(Ctx#ctx.doc2id_tab, DocId) of
        [] ->
            do_add(Ctx, DocId, Map);
        _ ->
            remove_record(Ctx, DocId),
            do_add(Ctx, DocId, Map)
    end,
    ok.

remove_record(Ctx, DocId) ->
    case ets:lookup(Ctx#ctx.rec_tab, DocId) of
        [] ->
            ok;
        [{DocId, Rec}] ->
            DocInt = maps:get(int, Rec),
            Terms = maps:get(terms, Rec, []),
            [remove_posting(Ctx, T, DocInt) || T <- Terms],
            ets:delete(Ctx#ctx.rec_tab, DocId),
            ets:delete(Ctx#ctx.doc2id_tab, DocId),
            ets:delete(Ctx#ctx.id2doc_tab, DocInt),
            ok
    end.
-spec add_review(#ctx{}, map()) -> ok.
%% Yelp review JSON → update doc aggregates + index review text
%% Expected keys: <<"business_id">>, <<"stars">>, <<"useful">>, <<"funny">>, <<"cool">>, <<"text">>
add_review(Ctx, R) when is_map(R) ->
    BID = maps:get(<<"business_id">>, R, undefined),
    case BID of
        % ignore malformed
        undefined ->
            ok;
        _ ->
            case ets:lookup(Ctx#ctx.doc2id_tab, BID) of
                % review for a business we didn't index (skip)
                [] ->
                    ok;
                [{_, DocInt}] ->
                    %% 1) merge aggregates
                    Stars = to_float(maps:get(<<"stars">>, R, 0)),
                    Useful = to_int(maps:get(<<"useful">>, R, 0)),
                    Funny = to_int(maps:get(<<"funny">>, R, 0)),
                    Cool = to_int(maps:get(<<"cool">>, R, 0)),
                    Text = maps:get(<<"text">>, R, <<>>),
                    ok = update_review_stats(Ctx, BID, Stars, Useful, Funny, Cool),
                    %% 2) index review text tokens under field <<"rev">>
                    Toks = ecai_tokenizer:tokens(Text),
                    %% keep it tight to avoid bloat; cap #terms per review
                    ToksCap = lists:sublist(Toks, 40),
                    RevTerms = [term_key(<<"rev">>, T) || T <- ToksCap],
                    Touched = add_terms(Ctx, RevTerms, DocInt),
                    recompute_roots(Ctx, Touched),
                    ok
            end
    end.

update_review_stats(Ctx, DocId, Stars, Useful, Funny, Cool) ->
    case ets:lookup(Ctx#ctx.rec_tab, DocId) of
        [] ->
            ok;
        [{DocId, Rec}] ->
            RS0 = maps:get(reviews, Rec, #{
                count => 0, sum_stars => 0.0, useful => 0, funny => 0, cool => 0
            }),
            RS1 = RS0#{
                count := maps:get(count, RS0, 0) + 1,
                sum_stars := maps:get(sum_stars, RS0, 0.0) + Stars,
                useful := maps:get(useful, RS0, 0) + Useful,
                funny := maps:get(funny, RS0, 0) + Funny,
                cool := maps:get(cool, RS0, 0) + Cool
            },
            ets:insert(Ctx#ctx.rec_tab, {DocId, Rec#{reviews => RS1}}),
            ok
    end.

get_review_stats(Ctx, DocId) ->
    case ets:lookup(Ctx#ctx.rec_tab, DocId) of
        [] ->
            #{count => 0, avg => 0.0, useful => 0, funny => 0, cool => 0};
        [{_, Rec}] ->
            RS = maps:get(reviews, Rec, #{
                count => 0, sum_stars => 0.0, useful => 0, funny => 0, cool => 0
            }),
            C = maps:get(count, RS, 0),
            Avg =
                case C of
                    0 -> 0.0;
                    _ -> maps:get(sum_stars, RS, 0.0) / C
                end,
            #{
                count => C,
                avg => Avg,
                useful => maps:get(useful, RS, 0),
                funny => maps:get(funny, RS, 0),
                cool => maps:get(cool, RS, 0)
            }
    end.

to_int(I) when is_integer(I) -> I;
to_int(B) when is_binary(B) ->
    case catch erlang:binary_to_integer(B) of
        V when is_integer(V) -> V;
        _ -> 0
    end;
to_int(_) ->
    0.

to_float(F) when is_float(F) -> F;
to_float(I) when is_integer(I) -> float(I);
to_float(B) when is_binary(B) ->
    case string:to_float(binary_to_list(B)) of
        {V, _} -> V;
        _ -> 0.0
    end;
to_float(_) ->
    0.0.

%% business_id may equal DocId; use whatever you indexed with add_record/3
add_review_stats(Ctx, DocIdBin, StarsF, UsefulI, FunnyI, CoolI) ->
    %% update ETS aggregate (same as earlier, but without Yelp parsing)
    update_review_stats(Ctx, DocIdBin, StarsF, UsefulI, FunnyI, CoolI).

%% index free text into a named field, with token cap
index_text(Ctx, DocIdBin, FieldBin, TextBin, CapN) ->
    case ets:lookup(Ctx#ctx.doc2id_tab, DocIdBin) of
        [] ->
            ok;
        [{_, DocInt}] ->
            Toks = lists:sublist(ecai_tokenizer:tokens(TextBin), CapN),
            Terms = [term_key(FieldBin, T) || T <- Toks],
            Touched = add_terms(Ctx, Terms, DocInt),
            recompute_roots(Ctx, Touched),
            ok
    end.
%%%===================================================================
%%% Search
%%%===================================================================

%% QueryMap supports (all optional):
%%  #{name => <<"acme">>, category => <<"plumber">>, city => <<"sydney">>,
%%    tags => [<<"24x7">>, <<"emergency">>],
%%    phone => <<"0291">>, prefix => true}
%search(Ctx, Q, Limit) when is_map(Q) ->
%    Prefix = maps:get(prefix, Q, true),
%    Terms = terms_from_query(Q, Prefix),
%    %% Collect candidates per term (doc-int lists)
%    TermDocs = [{T, postings(Ctx, T)} || T <- Terms],
%    %% Simple weighted score: +W per term hit
%    Scores0 = score_candidates(Ctx, TermDocs),
%    Scores = boost_multi_term_field(TermDocs, Scores0),
%    Top = take_top(Scores, Limit),
%    Proofs = proof_headers(Ctx, Terms),
%    {[{docid(Ctx, I), Score} || {I, Score} <- Top], Proofs}.

%% ================================================================
%% Search: build terms -> gather postings -> score -> enrich results
%% Returns {Results, ProofHeaders}
%%   Results = [#{doc_id=>binary(), score=>float(), record=>map(), preview=>binary()}]
%% ================================================================
search(Ctx = #ctx{}, QueryMap, Limit0) ->
    Limit =
        case Limit0 of
            I when is_integer(I), I > 0 -> I;
            _ -> 10
        end,

    %% 1) expand the structured query into index terms
    Terms = terms_from_query(QueryMap, true),

    %% 2) fetch postings per term
    TermDocs = [{T, postings(Ctx, T)} || T <- Terms],

    %% 3) score & rank
    Scores0 = score_candidates(Ctx, TermDocs),
    Scores1 = boost_multi_term_field(TermDocs, Scores0),
    Scores = apply_review_signals(Ctx, Scores1),
    TopInts = take_top(Scores, Limit),

    %% 4) enrich each doc with its stored record and a human preview
    Results = [enrich_int(Ctx, DocInt, Score) || {DocInt, Score} <- TopInts],
    ?LOG_DEBUG("Results  ~p", [Results]),

    %% 5) light proof headers for the terms used (df + postings root + tag)
    Proofs = proof_headers(Ctx, Terms),

    {Results, Proofs}.

%% Convert internal doc-int -> {doc_id, record, preview}
enrich_int(Ctx, DocInt, Score) ->
    DocId = docid(Ctx, DocInt),
    Rec = lookup_record(Ctx, DocId),
    %?LOG_DEBUG("Rec  ~tp", [Rec]),
    #{
        doc_id => DocId,
        score => Score,
        record => Rec,
        preview => preview_text(Rec)
    }.

lookup_record(Ctx, DocId) ->
    case ets:lookup(Ctx#ctx.rec_tab, DocId) of
        %% you store #{int=>DocInt, data=>Map, terms=>Terms}
        [{_, #{data := Data}}] ->
            Data;
        [{_, M}] when is_map(M) ->
            %% backward/experimental shapes
            maps:get(data, M, M);
        [] ->
            #{}
    end.

%% Replace your current preview_text/1 with this:
preview_text(RecMap) when is_map(RecMap) ->
    N = maps:get(name, RecMap, <<>>),
    C = maps:get(city, RecMap, <<>>),
    K = maps:get(category, RecMap, <<>>),

    iolist_to_binary(
        case {N =/= <<>>, C =/= <<>>, K =/= <<>>} of
            {true, false, false} -> [N];
            {true, true, false} -> [N, <<" — ">>, C];
            {true, true, true} -> [N, <<" — ">>, C, <<" (">>, K, <<")">>];
            {true, false, true} -> [N, <<" (">>, K, <<")">>];
            {false, true, true} -> [C, <<" (">>, K, <<")">>];
            {false, true, false} -> [C];
            {false, false, true} -> [K];
            _ -> <<>>
        end
    );
preview_text(_) ->
    <<>>.

info_term(Ctx, Term) ->
    #{
        df => term_df(Ctx, Term),
        root => hex(term_root(Ctx, Term)),
        tag => term_tag(Ctx, Term)
    }.

export_onchain_headers(Ctx) ->
    lists:map(
        fun({Term, Root}) ->
            #{
                tag => term_tag(Ctx, Term),
                root => hex(Root),
                df => term_df(Ctx, Term)
            }
        end,
        ets:tab2list(Ctx#ctx.root_tab)
    ).
%% Add a tiny, explainable boost from reviews (doesn't dominate text relevance)
apply_review_signals(Ctx, ScoreMap) ->
    %% weight for average star (centered at 3.5)
    A = 0.15,
    %% weight for log review count
    B = 0.10,
    maps:map(
        fun(DocInt, S0) ->
            DocId = docid(Ctx, DocInt),
            RS = get_review_stats(Ctx, DocId),
            Avg = maps:get(avg, RS, 0.0),
            Cnt = maps:get(count, RS, 0),
            Boost = A * (Avg - 3.5) + B * math:log(1 + Cnt),
            S0 + Boost
        end,
        ScoreMap
    ).

%%%===================================================================
%%% Proof / headers
%%%===================================================================

proof_for(Ctx, Term, DocId) ->
    case ets:lookup(Ctx#ctx.doc2id_tab, DocId) of
        [] ->
            not_found;
        [{DocId, Int}] ->
            Docs = postings(Ctx, Term),
            case lists:member(Int, Docs) of
                false -> not_found;
                true -> merkle_path_for(Docs, Int)
            end
    end.

term_root(Ctx, Term) ->
    case ets:lookup(Ctx#ctx.root_tab, Term) of
        [] -> <<1, (crypto:hash(sha256, <<>>))/binary>>;
        [{_, R}] -> R
    end.

term_tag(Ctx, Term) ->
    case ets:lookup(Ctx#ctx.tag_tab, Term) of
        [] ->
            Tag = h2c_tag(Term),
            ets:insert(Ctx#ctx.tag_tab, {Term, Tag}),
            tuple_to_list(Tag);
        [{_, T}] ->
            tuple_to_list(T)
    end.

term_df(Ctx, Term) ->
    case ets:lookup(Ctx#ctx.df_tab, Term) of
        [] -> 0;
        [{_, N}] -> N
    end.

%%%===================================================================
%%% Diagnostics / housekeeping
%%%===================================================================

size(Ctx) ->
    #{
        postings => ets:info(Ctx#ctx.post_tab, size),
        terms => ets:info(Ctx#ctx.df_tab, size),
        docs => ets:info(Ctx#ctx.rec_tab, size)
    }.

wipe(Ctx) ->
    [
        ets:delete(T)
     || T <- [
            Ctx#ctx.post_tab,
            Ctx#ctx.df_tab,
            Ctx#ctx.tag_tab,
            Ctx#ctx.root_tab,
            Ctx#ctx.rec_tab,
            Ctx#ctx.id2doc_tab,
            Ctx#ctx.doc2id_tab,
            Ctx#ctx.next_id_tab
        ]
    ],
    ok.

%%%===================================================================
%%% Internals: add/remove + indexing
%%%===================================================================

do_add(Ctx, DocId, Map) ->
    DocInt = next_id(Ctx),
    ets:insert(Ctx#ctx.doc2id_tab, {DocId, DocInt}),
    ets:insert(Ctx#ctx.id2doc_tab, {DocInt, DocId}),
    Terms = terms_from_record(Map),
    Touched = add_terms(Ctx, Terms, DocInt),
    ets:insert(
        Ctx#ctx.rec_tab,
        {DocId, #{
            int => DocInt,
            data => Map,
            terms => Terms,
            reviews => #{count => 0, sum_stars => 0.0, useful => 0, funny => 0, cool => 0}
        }}
    ),

    recompute_roots(Ctx, Touched),
    ok.

add_terms(Ctx0, Terms, DocInt) ->
    %% We rely on ETS insert_new/2 to de-duplicate {Term, DocInt}.
    %% On a *new* posting:
    %%   - bump DF
    %%   - append to GPU dynamic slabs (if enabled)
    {TouchedRev, _Ctx1} =
        lists:foldl(
            fun(T, {Acc, CAcc}) ->
                case ets:insert_new(CAcc#ctx.post_tab, {{T, DocInt}, true}) of
                    true ->
                        bump_df(CAcc, T, +1),
                        {[T | Acc], append_gpu(CAcc, T, DocInt)};
                    false ->
                        {Acc, CAcc}
                end
            end,
            {[], Ctx0},
            Terms
        ),
    lists:usort(TouchedRev).

remove_posting(Ctx, Term, DocInt) ->
    case ets:lookup(Ctx#ctx.post_tab, {Term, DocInt}) of
        [] ->
            ok;
        _ ->
            ets:delete(Ctx#ctx.post_tab, {Term, DocInt}),
            bump_df(Ctx, Term, -1),
            recompute_roots(Ctx, [Term]),
            ok
    end.

bump_df(Ctx, Term, Delta) ->
    case ets:lookup(Ctx#ctx.df_tab, Term) of
        [] when Delta > 0 ->
            ets:insert(Ctx#ctx.df_tab, {Term, 1});
        [{Term, N}] ->
            N1 = N + Delta,
            if
                N1 =< 0 ->
                    ets:delete(Ctx#ctx.df_tab, Term),
                    ets:delete(Ctx#ctx.root_tab, Term),
                    ets:delete(Ctx#ctx.tag_tab, Term);
                true ->
                    ets:insert(Ctx#ctx.df_tab, {Term, N1})
            end;
        _ ->
            ok
    end.

recompute_roots(Ctx, Terms) ->
    [recompute_root(Ctx, T) || T <- lists:usort(lists:sublist(Terms, 500))],
    ok.

recompute_root(Ctx, T) ->
    spawn(fun() ->
        Docs = postings(Ctx, T),
        Root = compute_root_intlist(Docs),
        ets:insert(Ctx#ctx.root_tab, {T, Root}),
        _ = term_tag(Ctx, T)
    end).

next_id(Ctx) ->
    [{seq, N}] = ets:lookup(Ctx#ctx.next_id_tab, seq),
    ets:insert(Ctx#ctx.next_id_tab, {seq, N + 1}),
    N.

%%%===================================================================
%%% Term extraction
%%%===================================================================

terms_from_record(Map) ->
    %% normalize fields
    Name = ecai_tokenizer:normalize(maps:get(name, Map, <<>>)),
    City = ecai_tokenizer:normalize(maps:get(city, Map, <<>>)),
    Cat = ecai_tokenizer:lower_ascii(maps:get(category, Map, <<>>)),
    Tags = [ecai_tokenizer:lower_ascii(T) || T <- maps:get(tags, Map, [])],
    Phone = ecai_tokenizer:digits_only(maps:get(phone, Map, <<>>)),

    %% tokenize to lowercase binaries
    NameTokens = ecai_tokenizer:tokens(Name),
    CityTokens = ecai_tokenizer:tokens(City),

    %% read opts once
    %% (we don't have Ctx here; we assume default full features for popular fields)
    %% -> if you want strict runtime toggles, move this function to accept Ctx.
    PMin = ?P_MIN,
    PMax = ?P_MAX,
    % default off (record-only version); query path also handles ng
    NGN = 0,
    %% name
    TermName = [term_key(<<"name">>, T) || T <- NameTokens],
    PfxName = [term_pfx(<<"name">>, P) || P <- prefixes_many(NameTokens, PMin, PMax)],
    SfxName = [term_sfx(<<"name">>, reverse_bin(S)) || S <- suffixes_many(NameTokens, PMin, PMax)],
    NGName = [term_ng(<<"name">>, Ng) || Ng <- ngrams_many(NameTokens, NGN)],
    %% category
    TermCat =
        if
            Cat =:= <<>> -> [];
            true -> [term_key(<<"cat">>, Cat)]
        end,
    %% city
    TermCity = [term_key(<<"city">>, T) || T <- CityTokens],
    PfxCity = [term_pfx(<<"city">>, P) || P <- prefixes_many(CityTokens, PMin, 6)],
    %% tags
    TermTags = [term_key(<<"tag">>, T) || T <- Tags],
    %% phone (exact + prefix)
    TermPhone =
        if
            Phone =:= <<>> ->
                [];
            true ->
                [term_key(<<"phone">>, Phone)] ++
                    [term_pfx(<<"phone">>, P) || P <- pfx1(Phone, 3, 8)]
        end,

    lists:usort(
        TermName ++ PfxName ++ SfxName ++ NGName ++
            TermCat ++ TermCity ++ PfxCity ++ TermTags ++ TermPhone
    ).

%% helpers to fan out across word lists
suffixes_many(Toks, Min, Max) ->
    lists:usort(lists:append([suffixes(T, Min, Max) || T <- Toks])).

ngrams_many(_Toks, 0) -> [];
ngrams_many(Toks, N) -> lists:usort(lists:append([ngrams(T, N) || T <- Toks])).

terms_from_query(Q, PrefixDefault) ->
    Prefix = maps:get(prefix, Q, PrefixDefault),
    Suffix = maps:get(suffix, Q, false),
    InfixN = maps:get(infix_n, Q, 0),

    %% NAME
    AccName =
        case maps:get(name, Q, undefined) of
            undefined ->
                [];
            N ->
                Ns = ecai_tokenizer:tokens(ecai_tokenizer:normalize(N)),
                Exact = [term_key(<<"name">>, T) || T <- Ns],
                Pfx =
                    case Prefix of
                        true -> [term_pfx(<<"name">>, P) || P <- prefixes_many(Ns, ?P_MIN, ?P_MAX)];
                        _ -> []
                    end,
                Sfx =
                    case Suffix of
                        true ->
                            [
                                term_sfx(<<"name">>, reverse_bin(S))
                             || S <- suffixes_many(Ns, ?P_MIN, ?P_MAX)
                            ];
                        _ ->
                            []
                    end,
                NG =
                    case InfixN of
                        0 -> [];
                        Nn -> [term_ng(<<"name">>, Ng) || Ng <- ngrams_many(Ns, Nn)]
                    end,
                Exact ++ Pfx ++ Sfx ++ NG
        end,

    %% CATEGORY
    AccCat =
        case maps:get(category, Q, undefined) of
            undefined -> [];
            C -> [term_key(<<"cat">>, ecai_tokenizer:lower_ascii(C))]
        end,

    %% CITY
    AccCity =
        case maps:get(city, Q, undefined) of
            undefined ->
                [];
            Cty ->
                Cs = ecai_tokenizer:tokens(ecai_tokenizer:normalize(Cty)),
                Exact0 = [term_key(<<"city">>, T) || T <- Cs],
                Pfx0 =
                    case Prefix of
                        true -> [term_pfx(<<"city">>, P) || P <- prefixes_many(Cs, ?P_MIN, 6)];
                        _ -> []
                    end,
                Exact0 ++ Pfx0
        end,

    %% TAGS
    AccTags =
        case maps:get(tags, Q, undefined) of
            undefined -> [];
            L when is_list(L) -> [term_key(<<"tag">>, ecai_tokenizer:lower_ascii(T)) || T <- L]
        end,

    %% PHONE
    AccPhone =
        case maps:get(phone, Q, undefined) of
            undefined ->
                [];
            P ->
                case ecai_tokenizer:digits_only(P) of
                    <<>> ->
                        [];
                    D ->
                        Exact1 = [term_key(<<"phone">>, D)],
                        ?LOG_DEBUG("pfx phone ~p", [D]),
                        Pfx1 =
                            case Prefix of
                                true ->
                                    [term_pfx(<<"phone">>, Pfx) || Pfx <- pfx1(D, 3, 8)];
                                _ ->
                                    []
                            end,
                        Exact1 ++ Pfx1
                end
        end,

    lists:usort(AccName ++ AccCat ++ AccCity ++ AccTags ++ AccPhone).
term_key(Namespace, Token0) ->
    Token = binary:copy(Token0),
    <<Namespace/binary, $:, Token/binary>>.
term_pfx(Namespace, Prefix0) ->
    Prefix = binary:copy(Prefix0),
    <<"pfx:", Namespace/binary, $:, Prefix/binary>>.
term_sfx(Field, Suffix0) ->
    Suffix = binary:copy(Suffix0),
    <<"sfx:", Field/binary, $:, Suffix/binary>>.
term_ng(Field, Ng0) ->
    Ng = binary:copy(Ng0),
    <<"ng:", Field/binary, $:, Ng/binary>>.

reverse_bin(B) ->
    <<<<C>> || C <- lists:reverse(binary:bin_to_list(B))>>.

suffixes(Bin, Min, Max) ->
    Len = byte_size(Bin),
    From = min(Len, Max),
    [binary:part(Bin, Len - N, N) || N <- lists:seq(Min, From)].

ngrams(Bin, N) when N >= 1 ->
    L = byte_size(Bin),
    if
        L < N -> [];
        true -> [binary:part(Bin, I, N) || I <- lists:seq(0, L - N)]
    end.

prefixes_many(Tokens, Min, Max) ->
    lists:usort(lists:append([pfx1(T, Min, Max) || T <- Tokens])).

pfx1(Bin, Min, Max) ->
    Len = byte_size(Bin),
    To = min(Max, Len),
    [binary:part(Bin, 0, N) || N <- lists:seq(Min, To)].

%%%===================================================================
%%% Posting access (exact + prefix)
%%%===================================================================

postings(#ctx{backend = gpu, dyn = H, term_ids = Map}, Term) ->
    case maps:get(Term, Map, undefined) of
        undefined ->
            [];
        Tid ->
            Bin = ecai_gpu:get_postings_dyn(H, Tid),
            postings_from_bin(Bin)
    end;
postings(#ctx{backend = ets} = Ctx, Term) ->
    range_docs(Ctx#ctx.post_tab, Term).

%% decode <<DocInt:32-little, ...>> -> [Int]
postings_from_bin(<<>>) -> [];
postings_from_bin(Bin) -> postings_from_bin(Bin, []).
postings_from_bin(<<>>, Acc) -> lists:reverse(Acc);
postings_from_bin(<<I:32/little-unsigned, Rest/binary>>, Acc) -> postings_from_bin(Rest, [I | Acc]).
%% Build a compact snapshot for the GPU: {terms, term_ids, offsets, postings, df}

export_compact(Ctx = #ctx{}) ->
    %% 1) gather & sort all terms
    Terms = [T || {T, _} <- ets:tab2list(Ctx#ctx.df_tab)],
    Sorted = lists:sort(Terms),
    IdMap = maps:from_list(lists:zip(Sorted, lists:seq(0, length(Sorted) - 1))),
    %% 2) build CSR offsets + postings and pack into binaries
    {OffsList, PostsList} = build_csr(Ctx, Sorted),
    OffBin = pack_u32_le(OffsList),
    PostBin = pack_u32_le(PostsList),
    DFs = [term_df(Ctx, T) || T <- Sorted],
    DFBin = pack_u32_le(DFs),
    #{
        terms => Sorted,
        term_ids => IdMap,
        offsets => OffBin,
        postings => PostBin,
        df => DFBin
    }.

build_csr(Ctx, Terms) ->
    {Offs, Posts, _N} =
        lists:foldl(
            fun(T, {AccOffs, AccPosts, Cur}) ->
                %% read from ETS only
                Docs = postings(Ctx#ctx{backend = ets}, T),
                Len = length(Docs),
                {AccOffs ++ [Cur], AccPosts ++ Docs, Cur + Len}
            end,
            {[], [], 0},
            Terms
        ),
    %% trailing sentinel
    {Offs ++ [length(Posts)], Posts}.

pack_u32_le(List) ->
    Sz = length(List) * 4,
    Bin = <<<<X:32/little-unsigned>> || X <- List>>,
    %% ensure exactly Sz bytes (defensive)
    case byte_size(Bin) of
        Sz -> Bin;
        _ -> erlang:error({pack_size_mismatch, Sz, byte_size(Bin)})
    end.

range_docs(Tab, TermBin) ->
    Start = {TermBin, -1 bsl 62},
    fetch_range(Tab, Start, TermBin, []).

fetch_range(Tab, Key, TermBin, Acc) ->
    case ets:next(Tab, Key) of
        '$end_of_table' ->
            lists:reverse(Acc);
        {T, DocInt} = K ->
            if
                T =:= TermBin ->
                    fetch_range(Tab, K, TermBin, [DocInt | Acc]);
                true ->
                    lists:reverse(Acc)
            end
    end.

%% Prefix range: use the fact keys are ordered; start at <<"pfx:ns:prefix">>
%postings_prefix(Ctx, PfxKey) ->
%    Start = {PfxKey, -1 bsl 62},
%    fetch_pfx(Ctx#ctx.post_tab, Start, PfxKey, []).
%
%fetch_pfx(Tab, Key, PfxKey, Acc) ->
%    case ets:next(Tab, Key) of
%        '$end_of_table' ->
%            lists:reverse(Acc);
%        {KTerm, DocInt} = K ->
%            case has_prefix(KTerm, PfxKey) of
%                true -> fetch_pfx(Tab, K, PfxKey, [DocInt | Acc]);
%                false -> lists:reverse(Acc)
%            end
%    end.
%
%has_prefix(Bin, Pfx) ->
%    Sz = byte_size(Pfx),
%    case Bin of
%        <<Pfx:Sz/binary, _/binary>> -> true;
%        _ -> false
%    end.

%%%===================================================================
%%% Scoring and results
%%%===================================================================

%% -------------------------------------------------------------------
%% BM25-lite + field-aware de-dup
%%  - Adds IDF: log((N - df + 0.5)/(df + 0.5))
%%  - Counts at most ONCE per {Doc, Field} for an entire query
%%  - Kind weights: exact=1.00, prefix=0.85, suffix=0.85, ngram=0.70
%% -------------------------------------------------------------------
score_candidates(Ctx, TermDocs) ->
    N = doc_count(Ctx),
    FieldW = ?WEIGHTS,
    {Scores, _Seen} =
        lists:foldl(
            fun({Term, Docs}, {ScoreAcc, SeenAcc}) ->
                {Kind, Field} = kind_field(Term),
                KF = kind_weight(Kind),
                FW = maps:get(Field, FieldW, 1),
                DF = term_df(Ctx, Term),
                IDF = idf(N, DF),
                lists:foldl(
                    fun(DocInt, {SA, SM}) ->
                        %% only count once per {Doc,Field} per query
                        SeenFields = maps:get(DocInt, SM, #{}),
                        case maps:is_key(Field, SeenFields) of
                            true ->
                                {SA, SM};
                            false ->
                                Add = FW * KF * IDF,
                                SA1 = maps:update_with(DocInt, fun(V) -> V + Add end, Add, SA),
                                SM1 = maps:put(DocInt, maps:put(Field, true, SeenFields), SM),
                                {SA1, SM1}
                        end
                    end,
                    {ScoreAcc, SeenAcc},
                    Docs
                )
            end,
            {#{}, #{}},
            TermDocs
        ),
    Scores.

doc_count(Ctx) ->
    ets:info(Ctx#ctx.rec_tab, size).

idf(N, DF) ->
    %% natural log; tiny stabilizer to avoid log(0)
    math:log(((float(N) - float(DF) + 0.5) / (float(DF) + 0.5)) + 1.0e-12).

kind_field(Term) ->
    case binary:split(Term, <<":">>, [global]) of
        [F, _Tok] -> {exact, F};
        [<<"pfx">>, F, _Tok] -> {pfx, F};
        [<<"sfx">>, F, _Tok] -> {sfx, F};
        [<<"ng">>, F, _Tok] -> {ng, F};
        _ -> {exact, <<"">>}
    end.

kind_weight(exact) -> 1.00;
kind_weight(pfx) -> 0.85;
kind_weight(sfx) -> 0.85;
kind_weight(ng) -> 0.70;
kind_weight(_) -> 0.80.

take_top(ScoreMap, K) ->
    lists:sublist(
        lists:sort(
            fun({A, S1}, {B, S2}) ->
                if
                    S1 =:= S2 -> A =< B;
                    true -> S1 > S2
                end
            end,
            maps:to_list(ScoreMap)
        ),
        K
    ).

docid(Ctx, Int) ->
    case ets:lookup(Ctx#ctx.id2doc_tab, Int) of
        [] -> <<>>;
        [{_, D}] -> D
    end.

boost_multi_term_field(TermDocs, Scores0) ->
    %% Build Doc -> #{Field => true}
    Hit = lists:foldl(
        fun({Term, Docs}, Acc) ->
            {_Kind, Field} = kind_field(Term),
            lists:foldl(
                fun(DI, A2) ->
                    FSet = maps:get(DI, A2, #{}),
                    maps:put(DI, maps:put(Field, true, FSet), A2)
                end,
                Acc,
                Docs
            )
        end,
        #{},
        TermDocs
    ),
    Boost = 0.05,
    maps:map(
        fun(DI, Score) ->
            Fields = maps:get(DI, Hit, #{}),
            Extra = max(0, maps:size(Fields) - 1) * Boost,
            Score + Extra
        end,
        Scores0
    ).

%%%===================================================================
%%% Merkle (int leaves) + proofs
%%%===================================================================

compute_root_intlist([]) ->
    <<1, (crypto:hash(sha256, <<>>))/binary>>;
compute_root_intlist(Ints) ->
    Leaves = [leaf(encode_int(I)) || I <- lists:usort(Ints)],
    tree_root(Leaves).

leaf(Data) -> <<0, (crypto:hash(sha256, Data))/binary>>.
node(L, R) -> <<1, (crypto:hash(sha256, <<L/binary, R/binary>>))/binary>>.

tree_root([X]) ->
    X;
tree_root(Level) ->
    Pairs = pairup(Level),
    tree_root([
        node(
            A,
            (case B of
                undefined -> A;
                _ -> B
            end)
        )
     || {A, B} <- Pairs
    ]).

pairup([]) -> [];
pairup([A]) -> [{A, undefined}];
pairup([A, B | Rest]) -> [{A, B} | pairup(Rest)].

encode_int(I) -> <<I:64/unsigned-big>>.

merkle_path_for(Ints, Target) ->
    Sorted = lists:usort(Ints),
    Leaves = [leaf(encode_int(I)) || I <- Sorted],
    case pos(Sorted, Target, 1) of
        0 ->
            not_found;
        N ->
            {Path, Dirs} = build_path(Leaves, N),
            {ok, Path, Dirs}
    end.

pos([], _T, _N) -> 0;
pos([T | _], T, N) -> N;
pos([_ | Xs], T, N) -> pos(Xs, T, N + 1).

build_path(Leaves, Index) ->
    build_path_levels(Leaves, Index, [], []).
build_path_levels([_], _Idx, AccP, AccD) ->
    {lists:reverse(AccP), lists:reverse(AccD)};
build_path_levels(Level, Index, AccP, AccD) ->
    {PairIx, IsRight} =
        if
            Index rem 2 =:= 0 -> {Index - 1, true};
            true -> {Index + 1, false}
        end,
    Sib = lists:nth(min(PairIx, length(Level)), Level),
    Next = next_level(Level),
    NextIdx = (Index + 1) div 2,
    build_path_levels(Next, NextIdx, [Sib | AccP], [IsRight | AccD]).

next_level([]) -> [];
next_level([A]) -> [node(A, A)];
next_level([A, B | Rest]) -> [node(A, B) | next_level(Rest)].

%%%===================================================================
%%% Proof headers
%%%===================================================================

proof_headers(Ctx, Terms) ->
    maps:from_list(
        [
            {T, #{
                term_tag => term_tag(Ctx, T),
                postings_root => hex(term_root(Ctx, T)),
                df => term_df(Ctx, T)
            }}
         || T <- lists:usort(Terms)
        ]
    ).

%%%===================================================================
%%% ECAI TermTag
%%%===================================================================

hash_to_curve(Arg) when is_binary(Arg) -> hash_to_curve(binary_to_list(Arg));
hash_to_curve(Arg) -> ecai:hash_to_curve(Arg).
h2c_tag(TermBin) ->
    hash_to_curve(TermBin).

finalize(Ctx0 = #ctx{backend = gpu}) ->
    %% your existing root rebuild loop…

    %% (keep your existing code)
    Ctx1 = Ctx0,
    %% swap GPU snapshot
    enable_gpu(Ctx1);
finalize(Ctx = #ctx{}) ->
    Terms = [T || {T, _} <- ets:tab2list(Ctx#ctx.df_tab)],
    %% rebuild roots (can parallelize trivially)
    [
        begin
            Docs = postings(Ctx, T),
            Root = compute_root_intlist(Docs),
            ets:insert(Ctx#ctx.root_tab, {T, Root}),
            _ = term_tag(Ctx, T)
        end
     || T <- Terms
    ],
    Ctx.
%% ---------------------------------------------------------------
%% Snapshot the entire index to disk (single compressed term)
%% ---------------------------------------------------------------
save(File) ->
    save(ecai_search_server:get_ctx(), File).
save(Ctx = #ctx{}, File) ->
    try
        %% Optional: for very large tables you can fixtable (omitted for simplicity)
        Data = #{
            version => 1,
            opts => Ctx#ctx.opts,
            %% {{TermBin, DocInt}} -> true
            postings => ets:tab2list(Ctx#ctx.post_tab),
            %% TermBin -> DF
            df => ets:tab2list(Ctx#ctx.df_tab),
            %% TermBin -> TermTag(any())
            tag => ets:tab2list(Ctx#ctx.tag_tab),
            %% TermBin -> RootBin
            root => ets:tab2list(Ctx#ctx.root_tab),
            %% DocIdBin -> #{int,data,terms,reviews}
            rec => ets:tab2list(Ctx#ctx.rec_tab),
            %% DocInt -> DocIdBin
            i2d => ets:tab2list(Ctx#ctx.id2doc_tab),
            %% DocIdBin -> DocInt
            d2i => ets:tab2list(Ctx#ctx.doc2id_tab),
            seq =>
                case ets:lookup(Ctx#ctx.next_id_tab, seq) of
                    [{seq, N}] -> N;
                    _ -> 1
                end
        },
        Bin = term_to_binary(Data, [compressed]),
        file:write_file(File, Bin)
    catch
        C:R:Stk -> {error, {C, R, Stk}}
    end.

%% ---------------------------------------------------------------
%% Load a snapshot from disk and rehydrate ETS + options
%% ---------------------------------------------------------------
load(File) ->
    %% Construct fresh context (new ETS tables)
    load(new(), File).

load(Ctx0, File) ->
    case file:read_file(File) of
        {ok, Bin} ->
            try
                Map = binary_to_term(Bin),
                %% Restore opts first
                Ctx1 = Ctx0#ctx{opts = maps:get(opts, Map, Ctx0#ctx.opts)},
                %% Bulk insert into ETS
                ets:insert(Ctx1#ctx.post_tab, maps:get(postings, Map, [])),
                ets:insert(Ctx1#ctx.df_tab, maps:get(df, Map, [])),
                ets:insert(Ctx1#ctx.tag_tab, maps:get(tag, Map, [])),
                ets:insert(Ctx1#ctx.root_tab, maps:get(root, Map, [])),
                ets:insert(Ctx1#ctx.rec_tab, maps:get(rec, Map, [])),
                ets:insert(Ctx1#ctx.id2doc_tab, maps:get(i2d, Map, [])),
                ets:insert(Ctx1#ctx.doc2id_tab, maps:get(d2i, Map, [])),
                ets:insert(Ctx1#ctx.next_id_tab, {seq, maps:get(seq, Map, 1)}),
                {ok, Ctx1}
            catch
                C:R:Stk -> {error, {C, R, Stk}}
            end;
        Error ->
            Error
    end.
enable_gpu(Ctx0 = #ctx{}) ->
    Snap = export_compact(Ctx0),
    case
        ecai_gpu:load_compact(#{
            offsets => maps:get(offsets, Snap),
            postings => maps:get(postings, Snap),
            df => maps:get(df, Snap)
        })
    of
        {ok, Handle} ->
            Ctx0#ctx{
                backend = gpu,
                gpu = Handle,
                term_ids = maps:get(term_ids, Snap)
            };
        Error ->
            error_logger:error_msg("GPU load failed ~p", [Error]),
            Ctx0
    end.

disable_gpu(Ctx = #ctx{backend = ets}) ->
    Ctx;
disable_gpu(Ctx = #ctx{backend = gpu, gpu = H}) ->
    catch ecai_gpu:free(H),
    Ctx#ctx{backend = ets, gpu = undefined, term_ids = #{}}.

%% Rebuild device snapshot (call after a bulk index or finalize/1)
gpu_refresh(Ctx = #ctx{backend = gpu}) ->
    Ctx1 = disable_gpu(Ctx),
    enable_gpu(Ctx1);
gpu_refresh(Ctx) ->
    enable_gpu(Ctx).
%% ----- GPU helpers -------------------------------------------------

%% Ensure a stable term-id for a Term (allocate next_tid if missing)
ensure_tid(Ctx = #ctx{term_ids = Map, next_tid = N}, Term) ->
    case maps:get(Term, Map, undefined) of
        undefined ->
            Tid = N,
            {Tid, Ctx#ctx{term_ids = Map#{Term => Tid}, next_tid = N + 1}};
        Tid ->
            {Tid, Ctx}
    end.

%% Append one posting into the GPU dynamic index (if enabled)
append_gpu(Ctx = #ctx{backend = gpu, dyn = H}, Term, DocInt) when H =/= undefined ->
    {Tid, Ctx1} = ensure_tid(Ctx, Term),
    ok = ecai_gpu:append(H, Tid, DocInt),
    ?LOG_DEBUG("append_gpu ~p", [DocInt]),
    Ctx1;
append_gpu(Ctx, _Term, _DocInt) ->
    %% No GPU (or not enabled yet) — noop
    Ctx.
