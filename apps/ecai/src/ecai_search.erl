%%%-------------------------------------------------------------------
%%% ecai_search.erl  — ECAI directory index (exact+prefix) with proofs
%%%-------------------------------------------------------------------
-module(ecai_search).
-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").
-compile(warn_export_all).

-include_lib("kernel/include/logger.hrl").

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
    wipe/1
]).

%% ----- Context holds ETS tables (opaque to callers) -----
-record(ctx, {
    % ETS ordered_set: {{TermBin, DocIdInt}} -> true
    post_tab,
    % ETS set: TermBin -> DF (int)
    df_tab,
    % ETS set: TermBin -> TermTag(any())  (ecai:hash_to_curve/1)
    tag_tab,
    % ETS set: TermBin -> RootBin(sha256 scheme)
    root_tab,
    % ETS set: DocIdBin -> #{terms:= [TermBin], data:= map(), int:= DocIdInt}
    rec_tab,
    % ETS set: DocIdInt -> DocIdBin
    id2doc_tab,
    % ETS set: DocIdBin -> DocIdInt
    doc2id_tab,
    % ETS set: <<"seq">> -> NextInt
    next_id_tab,
    opts = #{
        % enable prefix terms
        prefix => true,
        % enable suffix terms (reversed)
        suffix => false,
        % 0=off, else 2 or 3 is typical
        infix_n => 0,
        % enable per-field expansion
        fields => #{
            name => #{prefix => true, suffix => true, infix => true},
            city => #{prefix => true, suffix => false, infix => false},
            cat => #{prefix => false, suffix => false, infix => false},
            tag => #{prefix => false, suffix => false, infix => false},
            phone => #{prefix => true, suffix => false, infix => false}
        }
    }
}).

-define(TNAME(T), list_to_atom(T)).

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
    Post = ets:new(?TNAME("ecai_postings"), [
        ordered_set, public, {read_concurrency, true}, {write_concurrency, true}
    ]),
    Df = ets:new(?TNAME("ecai_df"), [set, public]),
    Tag = ets:new(?TNAME("ecai_tag"), [set, public]),
    Root = ets:new(?TNAME("ecai_root"), [set, public]),
    Rec = ets:new(?TNAME("ecai_rec"), [set, public]),
    I2D = ets:new(?TNAME("ecai_i2d"), [set, public]),
    D2I = ets:new(?TNAME("ecai_d2i"), [set, public]),
    Seq = ets:new(?TNAME("ecai_seq"), [set, public]),
    ets:insert(Seq, {seq, 1}),
    #ctx{
        post_tab = Post,
        df_tab = Df,
        tag_tab = Tag,
        root_tab = Root,
        rec_tab = Rec,
        id2doc_tab = I2D,
        doc2id_tab = D2I,
        next_id_tab = Seq
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
    TopInts = take_top(Scores1, Limit),

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
    ets:insert(Ctx#ctx.rec_tab, {DocId, #{int => DocInt, data => Map, terms => Terms}}),
    recompute_roots(Ctx, Touched),
    ok.

add_terms(Ctx, Terms, DocInt) ->
    lists:usort(
        [
            begin
                New = ets:insert_new(Ctx#ctx.post_tab, {{T, DocInt}, true}),
                if
                    New -> bump_df(Ctx, T, +1);
                    true -> ok
                end,
                T
            end
         || T <- Terms
        ]
    ).

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
    [
        spawn(fun() ->
            Docs = postings(Ctx, T),
            Root = compute_root_intlist(Docs),
            ets:insert(Ctx#ctx.root_tab, {T, Root}),
            _ = term_tag(Ctx, T)
        end)
     || T <- lists:usort(Terms)
    ],
    ok.

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

term_key(Namespace, Token) ->
    <<Namespace/binary, $:, Token/binary>>.
term_pfx(Namespace, Prefix) ->
    <<"pfx:", Namespace/binary, $:, Prefix/binary>>.
term_sfx(Field, Suffix) ->
    <<"sfx:", Field/binary, $:, Suffix/binary>>.

term_ng(Field, Ng) ->
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

postings(Ctx, TermBin) ->
    %% Exact: just range over key {Term, _}
    range_docs(Ctx#ctx.post_tab, TermBin).

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

hex(Bin) when is_binary(Bin) ->
    lists:flatten([io_lib:format("~2.16.0B", [X]) || <<X:8>> <= Bin]).

%%%===================================================================
%%% ECAI TermTag
%%%===================================================================

hash_to_curve(Arg) when is_binary(Arg) -> hash_to_curve(binary_to_list(Arg));
hash_to_curve(Arg) -> ecai:hash_to_curve(Arg).
h2c_tag(TermBin) ->
    hash_to_curve(TermBin).

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
