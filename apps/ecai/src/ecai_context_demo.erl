%%%-------------------------------------------------------------------
%%% ecai_context_demo.erl
%%% Context-aware toy "isogeny" demo (kernels = H2C(context))
%%%-------------------------------------------------------------------
-module(ecai_context_demo).
-export([new/0, set_kernel/3, respond/3, test/0]).
-export([on_curve/1, add/2, double/1, mul/2]).

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
        {true, true}  -> inf;
        {true, false} -> double(P1);
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
mul(N, P0) when N < 0 -> mul(-N, P0);
mul(N, P0) -> mul_loop(N, P0, inf).
mul_loop(0, _Q, Acc) -> Acc;
mul_loop(N, Q, Acc) when N band 1 =:= 1 ->
    mul_loop(N bsr 1, double(Q), add(Acc, Q));
mul_loop(N, Q, Acc) ->
    mul_loop(N bsr 1, double(Q), Acc).

%%% ---------- toy hash-to-curve ----------
-define(G, {3,10}).  % fixed on-curve base (toy)

hash_to_scalar(Bin) ->
    S = binary:decode_unsigned(crypto:hash(sha256, Bin)),
    %% map to 1..(?P-1) to avoid zero
    (S rem (?P - 1)) + 1.

h2c(Bin) ->
    mul(hash_to_scalar(Bin), ?G).

%%% ---------- kernels (overrides + default = H2C(context)) ----------
new() ->
    application:ensure_all_started(crypto),
    #{ kernels_overrides => #{}     %% Context => KernelPoint
     , responses => default_responses()
     }.

set_kernel(State, Context, KernelPoint) ->
    true = on_curve(KernelPoint),
    K0 = maps:get(kernels_overrides, State),
    State#{ kernels_overrides := K0#{ Context => KernelPoint } }.

context_kernel(Context, State) ->
    K0 = maps:get(kernels_overrides, State),
    case maps:get(Context, K0, undefined) of
        undefined -> h2c(Context);   % default: derive from Context
        K         -> K
    end.

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

%%% ---------- φ_c and response ----------
phi_ctx(Point, KernelPoint) ->
    add(Point, KernelPoint).

phrase_point(PhraseBin) ->
    mul(hash_to_scalar(PhraseBin), ?G).

pick_response(Context, PhiPoint, State) ->
    RespMap = maps:get(responses, State),
    List = maps:get(Context, RespMap, [<<"OK">>]),
    Len  = length(List),
    Idx  = case PhiPoint of
               inf    -> 1;
               {X,_Y} -> (X rem Len) + 1
           end,
    lists:nth(Idx, List).

respond(Phrase, Context, State) when is_list(Phrase) ->
    respond(unicode:characters_to_binary(Phrase), Context, State);
respond(PhraseBin, Context, State) when is_binary(PhraseBin) ->
    Kctx    = context_kernel(Context, State),
    P0      = phrase_point(PhraseBin),
    Phi     = phi_ctx(P0, Kctx),
    Response= pick_response(Context, Phi, State),
    #{ phrase   => PhraseBin
     , context  => Context
     , kernel   => Kctx
     , base_pt  => P0
     , phi_pt   => Phi
     , response => Response
     }.

%%% ---------- demo ----------
test() ->
    S0 = new(),
    Phrase = <<"open the pod bay doors">>,

    io:format("== Phrase: ~s ==~n", [Phrase]),
    io:format("math:    ~p~n", [respond(Phrase, <<"math">>, S0)]),
    io:format("security:~p~n", [respond(Phrase, <<"security">>, S0)]),
    io:format("legal:   ~p~n", [respond(Phrase, <<"legal">>, S0)]),

    %% Override example:
    S1 = set_kernel(S0, <<"math">>, mul(17, ?G)),
    io:format("math (override): ~p~n", [respond(Phrase, <<"math">>, S1)]),

    ok.
