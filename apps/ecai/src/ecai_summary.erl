%%%-------------------------------------------------------------------
%%% ecai_summary.erl — Deterministic summarization via elliptic reduction
%%%-------------------------------------------------------------------
-module(ecai_summary).
-author("ECAI").

-export([
    summarize_texts/1,
    summarize_texts/2,
    summarize_texts/3,
    nearest_k/3,
    load_text/1,
    split_sentences/1,
    load_and_summarize/2
]).

-include_lib("kernel/include/logger.hrl").

%%%-------------------------------------------------------------------
%%% Public API & guards
%%%-------------------------------------------------------------------

ensure_nonempty([]) -> error({badarg, empty_input});
ensure_nonempty(_) -> ok.

summarize_texts(Texts) -> summarize_texts(Texts, #{}).

summarize_texts(Texts, Opts) when is_list(Texts) ->
    ensure_nonempty(Texts),
    Curve = maps:get(curve, Opts, prime256v1),
    Ctx = get_ctx_opt(Opts),
    Scalars = map_hash_to_scalars(Texts, Curve),
    SsumBin = sum_scalars(Scalars, Curve),
    SPub = scalar_to_pub(SsumBin, Curve),
    Sx = xcoord(SPub, Curve),
    {PickedText, PickProof} = pick_nearest_text_ctx(Texts, Curve, Sx, Ctx),
    {ok, PickedText, proof(Curve, SsumBin, SPub, Sx, PickProof)}.
%% --- ecai_summary.erl additions/changes --------------------------------
%% Add to -export([...]) list:
%%     summarize_texts/3

summarize_texts(Texts, Opts, KernelSpec) when is_list(Texts) ->
    ensure_nonempty(Texts),
    Curve = maps:get(curve, Opts, prime256v1),
    Ctx = get_ctx_opt(Opts),

    Scalars = map_hash_to_scalars(Texts, Curve),
    SsumBin0 = sum_scalars(Scalars, Curve),

    %% 1) derive kernel scalar from the given index ctx + kernel spec
    Kbin = kernel_scalar(Ctx, Curve, KernelSpec),

    %% 2) mix kernel into the summarizer accumulator (deterministic “isogeny-like” bias)
    SsumBin = add_scalars(SsumBin0, Kbin, Curve),

    SPub = scalar_to_pub(SsumBin, Curve),
    Sx = xcoord(SPub, Curve),

    {PickedText, PickProof} = pick_nearest_text_ctx(Texts, Curve, Sx, Ctx),

    {ok, PickedText, proof_kernel(Curve, SsumBin0, Kbin, SsumBin, SPub, Sx, KernelSpec, PickProof)}.

%% kernel spec examples:
%%   {term, <<"abstract:bitcoin">>}
%%   {terms, [<<"name:satoshi">>, <<"abstract:lightning">>]}
%%   {query, #{name => <<"bitcoin">>, prefix => true}}
kernel_scalar(Ctx, Curve, {term, T}) ->
    kernel_scalar(Ctx, Curve, {terms, [T]});
kernel_scalar(Ctx, Curve, {terms, Terms}) when is_list(Terms) ->
    %% Use index commitments: term_tag + term_root + df
    %% (all deterministic; can be anchored)
    Parts =
        [term_kernel_material(Ctx, T) || T <- lists:usort(Terms)],
    hash_parts_to_scalar(Parts, Curve);
kernel_scalar(Ctx, Curve, {query, Qmap}) when is_map(Qmap) ->
    %% Expand query into terms (same rules as search)
    Terms = ecai_search:terms_from_query(Qmap, true),
    kernel_scalar(Ctx, Curve, {terms, Terms});
kernel_scalar(_Ctx, Curve, undefined) ->
    %% no kernel
    pad_scalar(1, Curve);
kernel_scalar(_Ctx, Curve, _Other) ->
    %% unknown spec -> stable fallback
    pad_scalar(1, Curve).

term_kernel_material(Ctx, TermBin) ->
    %% term_tag gives you hash-to-curve tag (tuple/list); root is postings merkle root
    Tag = ecai_search:term_tag(Ctx, TermBin),
    Root = ecai_search:term_root(Ctx, TermBin),
    DF = ecai_search:term_df(Ctx, TermBin),
    %% Pack as iodata (stable)
    iolist_to_binary([
        <<"term=">>,
        TermBin,
        <<"\n">>,
        <<"df=">>,
        integer_to_binary(DF),
        <<"\n">>,
        <<"root=">>,
        Root,
        <<"\n">>,
        <<"tag=">>,
        term_to_binary(Tag),
        <<"\n">>
    ]).

hash_parts_to_scalar(Parts, Curve) ->
    N = curve_order(Curve),
    Bin = crypto:hash(sha256, iolist_to_binary(Parts)),
    <<I0:256/unsigned-big>> = Bin,
    I1 =
        case I0 rem N of
            0 -> 1;
            V -> V
        end,
    pad_scalar(I1, Curve).

add_scalars(A, B, Curve) ->
    N = curve_order(Curve),
    IA = bin_to_int(A),
    IB = bin_to_int(B),
    pad_scalar(((IA + IB) rem N), Curve).

proof_kernel(Curve, Ssum0, Kbin, Ssum, SPub, Sx, KernelSpec, PickProof) ->
    #{
        curve => Curve,
        s_sum0 => Ssum0,
        kernel_scalar => Kbin,
        s_sum => Ssum,
        s_pub => SPub,
        s_x => Sx,
        kernel_spec => KernelSpec,
        picked => PickProof
    }.

%% Choose sentence minimizing:  score = D - Alpha * IDFsum
%% D is distance on x-line; IDFsum from loaded context
pick_nearest_text_ctx(Texts, Curve, Sx, Ctx) ->
    %% tuning knob: how strongly to prefer rare/meaningful tokens
    Alpha = 10,
    pick_nearest_text_ctx_loop(Texts, Curve, Sx, Ctx, Alpha, undefined, infinity).

pick_nearest_text_ctx_loop([], _Curve, _Sx, _Ctx, _A, BestText, _BestScore) ->
    % attach proof details if you want
    {BestText, #{}};
pick_nearest_text_ctx_loop([T | R], Curve, Sx, Ctx, A, BestText, BestScore) ->
    Sbin = hash_to_scalar(T, Curve),
    Pub = scalar_to_pub(Sbin, Curve),
    Xbin = xcoord(Pub, Curve),
    D = dist_x(Xbin, Sx, Curve),
    Idf = sentence_idf_sum(Ctx, T),
    Score = D - A * Idf,
    case (BestScore =:= infinity) orelse (Score < BestScore) of
        true -> pick_nearest_text_ctx_loop(R, Curve, Sx, Ctx, A, T, Score);
        false -> pick_nearest_text_ctx_loop(R, Curve, Sx, Ctx, A, BestText, BestScore)
    end.

nearest_k(Texts, K, Opts) when is_integer(K), K > 0 ->
    Curve = maps:get(curve, Opts, prime256v1),
    Ctx = get_ctx_opt(Opts),
    Scalars = map_hash_to_scalars(Texts, Curve),
    SsumBin = sum_scalars(Scalars, Curve),
    SPub = scalar_to_pub(SsumBin, Curve),
    Sx = xcoord(SPub, Curve),
    nearest_k_ctx(Texts, K, Curve, Sx, Ctx).

nearest_k_ctx(Texts, K, Curve, Sx, Ctx) ->
    Alpha = 10,
    Scored = [
        begin
            Sbin = hash_to_scalar(T, Curve),
            Pub = scalar_to_pub(Sbin, Curve),
            Xbin = xcoord(Pub, Curve),
            D = dist_x(Xbin, Sx, Curve),
            Idf = sentence_idf_sum(Ctx, T),
            {T, D - Alpha * Idf}
        end
     || T <- Texts
    ],
    Sorted = lists:sort(fun({_, S1}, {_, S2}) -> S1 =< S2 end, Scored),
    lists:sublist(Sorted, K).

%%%-------------------------------------------------------------------
%%% File helpers (optional)
%%%-------------------------------------------------------------------
%% map Texts -> list of scalar binaries (plain loops)
map_hash_to_scalars(Texts, Curve) ->
    map_hash_to_scalars(Texts, Curve, []).
map_hash_to_scalars([], _Curve, Acc) ->
    lists:reverse(Acc);
map_hash_to_scalars([T | R], Curve, Acc) ->
    S = hash_to_scalar(T, Curve),
    map_hash_to_scalars(R, Curve, [S | Acc]).

%% map {Id,Text} -> list of scalar binaries

%% filter nonempty binaries (for sentence splitter)
filter_nonempty(List) -> filter_nonempty_loop(List, []).
filter_nonempty_loop([], Acc) ->
    lists:reverse(Acc);
filter_nonempty_loop([B | R], Acc) ->
    case byte_size(B) > 0 of
        true -> filter_nonempty_loop(R, [B | Acc]);
        false -> filter_nonempty_loop(R, Acc)
    end.

load_text(File) when is_list(File) -> file:read_file(File).

split_sentences(Bin) when is_binary(Bin) ->
    Clean = re:replace(Bin, "[\\n\\r]+", <<" ">>, [global, {return, binary}]),
    Parts = re:split(Clean, "[\\.\\!\\?]+\\s*", [trim, {return, binary}]),
    filter_nonempty(Parts).

load_and_summarize(File, Opts) ->
    case load_text(File) of
        {ok, Bin} ->
            Sents = split_sentences(Bin),
            summarize_texts(Sents, Opts);
        Error ->
            Error
    end.

%%%-------------------------------------------------------------------
%%% Proof object
%%%-------------------------------------------------------------------

proof(Curve, SsumBin, SPub, Sx, PickProof) ->
    #{
        curve => Curve,
        s_sum => SsumBin,
        s_pub => SPub,
        s_x => Sx,
        picked => PickProof
    }.

%%%-------------------------------------------------------------------
%%% Math helpers
%%%-------------------------------------------------------------------

%% Σ scalars mod n -> fixed-size binary scalar
sum_scalars(ScalarBins, Curve) ->
    N = curve_order(Curve),
    Ints = bins_to_ints(ScalarBins, []),
    Sum = lists:foldl(fun(S, Acc) -> ((Acc + S) rem N) end, 0, Ints),
    pad_scalar(Sum, Curve).

bins_to_ints([], Acc) -> lists:reverse(Acc);
bins_to_ints([B | R], Acc) -> bins_to_ints(R, [bin_to_int(B) | Acc]).

%% Hash text -> scalar (big-endian integer -> reduced -> fixed-size binary)
hash_to_scalar(Text, Curve) ->
    N = curve_order(Curve),
    Bin = crypto:hash(sha256, unicode:characters_to_binary(Text, utf8)),
    <<I0:256/unsigned-big>> = Bin,
    I1 =
        case I0 rem N of
            0 -> 1;
            V -> V
        end,
    pad_scalar(I1, Curve).

%% Scalar -> public key (uncompressed 0x04 || X || Y)
scalar_to_pub(Sbin, Curve) when is_binary(Sbin) ->
    {Pub, _Priv} = crypto:generate_key(ecdh, curve_name(Curve), Sbin),
    Pub.

%% Extract X coordinate from uncompressed point
xcoord(PubBin, Curve) ->
    Sz = scalar_size(Curve),
    case PubBin of
        <<4, X:Sz/binary, _Y:Sz/binary>> -> X;
        _ -> error({bad_ec_point_format, PubBin})
    end.

%% Distance on x-line modulo field prime
dist_x(AxBin, BxBin, Curve) ->
    P = field_prime(Curve),
    Ax = bin_to_int(AxBin),
    Bx = bin_to_int(BxBin),
    D = erlang:abs(Ax - Bx),
    ((D rem P) + P) rem P.

%% Helpers
%modp(X, P) -> ((X rem P) + P) rem P.

bin_to_int(Bin) when is_binary(Bin) ->
    Sz = byte_size(Bin),
    <<I:Sz/unit:8>> = Bin,
    I.

pad_scalar(I, Curve) ->
    Sz = scalar_size(Curve),
    <<I:Sz/unit:8>>.

scalar_size(prime256v1) -> 32;
scalar_size(secp256k1) -> 32.

curve_name(prime256v1) -> prime256v1;
curve_name(secp256k1) -> secp256k1.

%% Curve parameters
curve_order(prime256v1) ->
    115792089210356248762697446949407573529996955224135760342422259061068512044369;
curve_order(secp256k1) ->
    115792089237316195423570985008687907852837564279074904382605163141518161494337.

field_prime(prime256v1) ->
    115792089210356248762697446949407573530086143415290314195533631308867097853951;
field_prime(secp256k1) ->
    115792089237316195423570985008687907852837564279074904382605163141518161494337.

%% ----- Opt/context helpers -----
get_ctx_opt(Opts) ->
    case Opts of
        M when is_map(M) ->
            maps:get(ctx, Opts, safe_ctx());
        _ ->
            safe_ctx()
    end.

safe_ctx() ->
    %% If the server isn't started yet, fall back to an empty ctx
    try
        ecai_search_server:get_ctx()
    catch
        _:_ -> ecai_search:new()
    end.

docs_count(Ctx) ->
    %% #docs in the loaded index
    case catch ecai_search:size(Ctx) of
        #{docs := N} when is_integer(N) -> N;
        _ -> 1
    end.
%% ----- IDF weighting from loaded context -----
%% integer IDF-ish: round( log((N - df + 0.5)/(df + 0.5)) * 50 ), min 1
idf_int(NDocs, _DF) when NDocs =< 0 -> 1;
idf_int(_NDocs, DF) when DF =< 0 -> 100;
idf_int(NDocs, DF) ->
    Val = math:log(((float(NDocs) - float(DF) + 0.5) / (float(DF) + 0.5)) + 1.0e-12),
    I = round(Val * 50.0),
    case I < 1 of
        true -> 1;
        false -> I
    end.

%% Sum IDF over tokens in a sentence (very light tokenizer)
sentence_idf_sum(Ctx, Bin) ->
    Toks = ecai_tokenizer:tokens(ecai_tokenizer:normalize(Bin)),
    N = docs_count(Ctx),
    lists:sum([idf_int(N, ecai_search:term_df(Ctx, Tok)) || Tok <- Toks]).
