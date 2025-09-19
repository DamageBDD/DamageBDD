%%%-------------------------------------------------------------------
%%% ecai_context_demo.erl
%%% Context-aware toy "isogeny" demo (pure Erlang)
%%%-------------------------------------------------------------------
-module(ecai_context_demo).
-export([new/0, set_kernel/3, respond/3, test/0]).
-export([on_curve/1, add/2, double/1, mul/2]). % exposed for tinkering

-define(A, -1).
-define(B,  1).
-define(P, 23).

%%% ---------- utilities ----------
modp(N) -> ((N rem ?P) + ?P) rem ?P.

inv(A) -> modinv(modp(A), ?P).
modinv(0, _P) -> error(no_inverse);
modinv(A, P) ->
    {G, X, _Y} = egcd(A, P),
    case G of 1 -> modp(X); _ -> error(no_inverse) end.

egcd(0, B) -> {B, 0, 1};
egcd(A, B) ->
    {G, X1, Y1} = egcd(B rem A, A),
    {G, Y1 - (B div A) * X1, X1}.

%%% ---------- curve predicates ----------
on_curve(inf) -> true;
on_curve({X, Y}) ->
    modp(Y*Y) =:= modp(X*X*X + ?A*X + ?B).

%%% ---------- group law ----------
add(inf, Q) -> Q;
add(Pt, inf) -> Pt;
add({X1,Y1}=P1, {X2,Y2}=_P2) ->
    case {X1 =:= X2, modp(Y1 + Y2) =:= 0} of
        {true, true}  -> inf;        % P + (-P) = O
        {true, false} -> double(P1); % doubling
        {false,_} ->
            Lambda = modp(Y2 - Y1) * inv(modp(X2 - X1)),
            X3 = modp(Lambda*Lambda - X1 - X2),
            Y3 = modp(Lambda*(X1 - X3) - Y1),
            {X3, Y3}
    end.

double(inf) -> inf;
double({X,Y}) ->
    case modp(Y) of
        0 -> inf;
        _ ->
            Lambda = modp(3*X*X + ?A) * inv(modp(2*Y)),
            X3 = modp(Lambda*Lambda - 2*X),
            Y3 = modp(Lambda*(X - X3) - Y),
            {X3, Y3}
    end.

mul(_, inf) -> inf;
mul(0, _P) -> inf;
mul(N, P0) when N < 0 -> mul(-N, P0); % toy
mul(N, P0) ->
    mul_loop(N, P0, inf).
mul_loop(0, _Q, Acc) -> Acc;
mul_loop(N, Q, Acc) when N band 1 =:= 1 ->
    mul_loop(N bsr 1, double(Q), add(Acc, Q));
mul_loop(N, Q, Acc) ->
    mul_loop(N bsr 1, double(Q), Acc).

%%% ---------- hashing phrase -> scalar -> base point ----------
-define(G, {3,10}).  % known on-curve point (toy base)

phrase_scalar(PhraseBin) ->
    %% map sha256 to 1..(?P-1) so scalar is nonzero in tiny group
    S = binary:decode_unsigned(crypto:hash(sha256, PhraseBin)),
    (S rem (?P - 1)) + 1.

phrase_point(PhraseBin) ->
    mul(phrase_scalar(PhraseBin), ?G).

%%% ---------- state & kernels ----------
%% Default kernels derived from multiples of G to ensure on-curve
default_kernels() ->
    #{ <<"math">>     => mul(5,  ?G),
       <<"security">> => mul(9,  ?G),
       <<"legal">>    => mul(13, ?G)
     }.

default_responses() ->
    #{ <<"math">> => [
          <<"Formal equivalence holds.">>,
          <<"Invariant preserved under φ_c.">>,
          <<"Witness verified on subgroup.">>
        ],
       <<"security">> => [
          <<"Provenance locked.">>,
          <<"Tamper check: clean.">>,
          <<"Attestation OK.">>
        ],
       <<"legal">> => [
          <<"Clause matched to precedent.">>,
          <<"Chain of custody intact.">>,
          <<"Compliance state: GREEN.">>
        ]
     }.

new() ->
    application:ensure_all_started(crypto),
    #{ kernels   => default_kernels()
     , responses => default_responses()
     }.

set_kernel(CtxState, Context, KernelPoint) ->
    true = on_curve(KernelPoint), % guard in dev
    Kernels1 = maps:get(kernels, CtxState),
    CtxState#{ kernels := Kernels1#{ Context => KernelPoint } }.

%%% ---------- context-aware "isogeny" ----------
%% φ_c(P) = P + K_context
phi_ctx(Point, KernelPoint) ->
    add(Point, KernelPoint).

pick_response(Context, PhiPoint, State) ->
    RespMap = maps:get(responses, State),
    List = maps:get(Context, RespMap, [<<"OK">>]),
    Len  = length(List),
    Idx  = case PhiPoint of
               inf     -> 1;
               {X,_Y}  -> (X rem Len) + 1
           end,
    lists:nth(Idx, List).

respond(Phrase, Context, State) when is_list(Phrase) ->
    respond(unicode:characters_to_binary(Phrase), Context, State);
respond(PhraseBin, Context, State) when is_binary(PhraseBin) ->
    Kernels = maps:get(kernels, State),
    Kernel  = maps:get(Context, Kernels, mul(3, ?G)), % default kernel
    P0      = phrase_point(PhraseBin),
    Phi     = phi_ctx(P0, Kernel),
    Response= pick_response(Context, Phi, State),
    #{ phrase   => PhraseBin
     , context  => Context
     , base_pt  => P0
     , phi_pt   => Phi
     , response => Response
     }.

%%% ---------- demo ----------
test() ->
    S0 = new(),
    Phrase = <<"open the pod bay doors">>,
    io:format("== Phrase: ~s ==~n", [Phrase]),

    R_math = respond(Phrase, <<"math">>, S0),
    R_sec  = respond(Phrase, <<"security">>, S0),
    R_leg  = respond(Phrase, <<"legal">>, S0),

    io:format("math:    ~p~n", [R_math]),
    io:format("security:~p~n", [R_sec]),
    io:format("legal:   ~p~n", [R_leg]),

    %% show determinism: same phrase + same context => same output
    R_math2 = respond(Phrase, <<"math">>, S0),
    io:format("math deterministic? ~p~n", [R_math2 =:= R_math]),

    ok.
