%% -------------------------------------------------------------------
%% L402 (Lightning HTTP 402) gate for DamageBDD
%%
%% Implements standard L402 HTTP flow:
%%   - Challenge: 402 + WWW-Authenticate: L402 macaroon="...", invoice="..."
%%   - Response:  Authorization: L402 <macaroonB64>:<preimageHex>
%%
%% We treat the “macaroon” as an opaque base64 token (stored server-side).
%% Proof-of-payment:
%%   - invoice is PAID in CLN
%%   - sha256(preimage) == payment_hash
%% -------------------------------------------------------------------
-module(damage_l402).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").
-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-export([start_link/0, child_spec/0]).
-export([verify_authorization/2, challenge/3, challenge_with_body/4, parse_authorization/1]).
-export([get_meta/1, get_damage_available/1, consume_damage/2]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(TAB, damage_l402_tokens).
-define(TAB_HASH, damage_l402_by_hash).
-define(TAB_INV, damage_l402_by_inv).

-record(state, {
    subscribed = false
}).

%%% -------------------------------------------------------------------
%%% OTP
%%% -------------------------------------------------------------------

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

child_spec() ->
    #{
        id => ?MODULE,
        start => {?MODULE, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [?MODULE]
    }.

init([]) ->
    ensure_tabs(),
    %% Tell CLN we want invoice events
    %% Your cln already has register_listener/1 and subscribe/0
    true = cln:register_listener(invoice_payment),
    {ok, #state{subscribed = true}}.

handle_call({get_meta, MacB64}, _From, S) ->
    Reply =
        case ets:lookup(?TAB, MacB64) of
            [{_, Meta}] -> {ok, Meta};
            [] -> {error, unknown}
        end,
    {reply, Reply, S};
handle_call({get_damage_available, MacB64}, _From, S) ->
    Reply =
        case ets:lookup(?TAB, MacB64) of
            [{_, Meta}] -> {ok, maps:get(damage_available, Meta, 0)};
            [] -> {error, unknown}
        end,
    {reply, Reply, S};
handle_call({consume_damage, MacB64, AmountDamage}, _From, S) ->
    Reply =
        case ets:lookup(?TAB, MacB64) of
            [{_, Meta0}] ->
                Avail = maps:get(damage_available, Meta0, 0),
                case Avail >= AmountDamage of
                    true ->
                        Meta = Meta0#{damage_available => Avail - AmountDamage},
                        ets:insert(?TAB, {MacB64, Meta}),
                        {ok, Meta};
                    false ->
                        {error, insufficient_damage}
                end;
            [] ->
                {error, unknown}
        end,
    {reply, Reply, S}.

handle_cast(_Msg, S) ->
    {noreply, S}.

%% This is the callback from CLN dispatch (we add that in cln.erl below)
handle_info({cln_event, invoice_payment, Ev}, S) ->
    %% Ev is expected to include payment_hash and amount_msat (or amount_received_msat)
    handle_invoice_paid_event(Ev),
    {noreply, S};
handle_info(_Info, S) ->
    {noreply, S}.

terminate(_Reason, _S) -> ok.
code_change(_Old, S, _Extra) -> {ok, S}.

%%% -------------------------------------------------------------------
%%% Public API wrappers
%%% -------------------------------------------------------------------

get_meta(MacB64) ->
    gen_server:call(?MODULE, {get_meta, MacB64}).

get_damage_available(MacB64) ->
    gen_server:call(?MODULE, {get_damage_available, MacB64}).

consume_damage(MacB64, AmountDamage) when is_integer(AmountDamage), AmountDamage >= 0 ->
    gen_server:call(?MODULE, {consume_damage, MacB64, AmountDamage}).

%%% -------------------------------------------------------------------
%%% L402: verify + challenge
%%% -------------------------------------------------------------------

-spec verify_authorization(binary() | undefined, cowboy_req:req()) -> {ok, map()} | {error, atom()}.
verify_authorization(undefined, _Req) ->
    {error, missing};
verify_authorization(AuthHeader, Req) ->
    ensure_tabs(),
    case parse_authorization(AuthHeader) of
        {ok, MacB64, PreimageHex} ->
            verify_token(MacB64, PreimageHex, Req);
        _ ->
            {error, invalid}
    end.

-spec challenge(cowboy_req:req(), binary(), integer()) -> {cowboy_req:req(), map()}.
challenge(Req0, Scope, AmountMsat) ->
    Body =
        jsx:encode(#{
            code => 402,
            message => <<"payment required">>,
            scheme => <<"L402">>,
            scope => Scope,
            amount_msat => AmountMsat
        }),
    challenge_with_body(Req0, Scope, AmountMsat, Body).

-spec challenge_with_body(cowboy_req:req(), binary(), integer(), binary()) ->
    {cowboy_req:req(), map()}.
challenge_with_body(Req0, Scope, AmountMsat, BodyBin) ->
    ensure_tabs(),
    Expiry = application:get_env(damage, l402_invoice_expiry, 600),
    Uses = application:get_env(damage, l402_uses, 1),

    MacB64 = base64:encode(crypto:strong_rand_bytes(32)),

    {ok, Timestamp} = datestring:format("YmdHMS", erlang:localtime()),
    Label = <<"l402:", Scope/binary, ":", (list_to_binary(Timestamp))/binary, ":", MacB64/binary>>,
    Desc = <<"DamageBDD L402 ", Scope/binary>>,

    InvoiceMap = cln:create_invoice(AmountMsat, Desc, Expiry, Label),
    Bolt11 = maps:get(bolt11, InvoiceMap, maps:get(<<"bolt11">>, InvoiceMap, undefined)),
    PaymentHash0 = maps:get(
        payment_hash, InvoiceMap, maps:get(<<"payment_hash">>, InvoiceMap, undefined)
    ),
    PaymentHashHex = normalize_hex(PaymentHash0),

    Now = erlang:system_time(second),
    ExpiresAt = Now + Expiry,

    Meta = #{
        scope => Scope,
        amount_msat => AmountMsat,
        macaroon => MacB64,
        invoice => Bolt11,
        payment_hash_hex => PaymentHashHex,
        expires_at => ExpiresAt,
        uses_left => Uses,

        %% new:
        paid => false,
        paid_msat => 0,
        sats_paid => 0,
        damage_available => 0
    },

    ets:insert(?TAB, {MacB64, Meta}),
    ets:insert(?TAB_HASH, {PaymentHashHex, MacB64}),
    ets:insert(?TAB_INV, {Bolt11, MacB64}),

    HeaderVal = iolist_to_binary(["L402 macaroon=\"", MacB64, "\", invoice=\"", Bolt11, "\""]),
    Req1 =
        cowboy_req:reply(
            402,
            #{
                <<"content-type">> => <<"application/json">>,
                <<"www-authenticate">> => HeaderVal
            },
            BodyBin,
            Req0
        ),
    {Req1, Meta}.

%% Accept: "L402 <mac>:<preimage>"
-spec parse_authorization(binary()) -> {ok, binary(), binary()} | {error, atom()}.
parse_authorization(<<"L402 ", Rest/binary>>) ->
    case binary:split(Rest, <<":">>, [global]) of
        [MacsBin, PreHex] when byte_size(MacsBin) > 0, byte_size(PreHex) > 0 ->
            Mac0 = hd(binary:split(MacsBin, <<",">>, [global])),
            {ok, Mac0, PreHex};
        _ ->
            {error, invalid}
    end;
parse_authorization(_) ->
    {error, invalid}.

%%% -------------------------------------------------------------------
%%% Invoice-paid event handling
%%% -------------------------------------------------------------------

handle_invoice_paid_event(Ev0) ->
    %% Normalize keys
    Ev = normalize_ev(Ev0),
    PH = maps:get(payment_hash_hex, Ev, undefined),
    Msat = maps:get(amount_msat, Ev, 0),
    case {PH, Msat} of
        {undefined, _} ->
            ok;
        {_, _} ->
            case ets:lookup(?TAB_HASH, PH) of
                [{_, MacB64}] ->
                    mark_paid(MacB64, PH, Msat);
                [] ->
                    ok
            end
    end.

mark_paid(MacB64, _PH, PaidMsat) ->
    case ets:lookup(?TAB, MacB64) of
        [{_, Meta0}] ->
            Sats = cln:msat_to_sats(PaidMsat),
            Damage = price_feed:sats_to_damage(Sats),
            Meta =
                Meta0#{
                    paid => true,
                    paid_msat => PaidMsat,
                    sats_paid => Sats,
                    damage_available => maps:get(damage_available, Meta0, 0) + Damage
                },
            ets:insert(?TAB, {MacB64, Meta}),
            ?LOG_INFO("L402 paid macaroon=~p sats=~p damage=~p", [MacB64, Sats, Damage]),
            ok;
        [] ->
            ok
    end.

normalize_ev(Ev) when is_map(Ev) ->
    %% expect CLN event like #{payment_hash:=..., amount_msat:=...} or binary keys
    PH0 = maps:get(payment_hash, Ev, maps:get(<<"payment_hash">>, Ev, undefined)),
    Msat0 = maps:get(
        amount_msat,
        Ev,
        maps:get(
            <<"amount_msat">>,
            Ev,
            maps:get(amount_received_msat, Ev, maps:get(<<"amount_received_msat">>, Ev, 0))
        )
    ),
    #{
        payment_hash_hex => normalize_hex(PH0),
        amount_msat => to_int(Msat0)
    };
normalize_ev(_) ->
    #{}.

to_int(I) when is_integer(I) -> I;
to_int(B) when is_binary(B) ->
    %% could be "123msat" in some encodings — strip non-digits if you need later
    try
        binary_to_integer(B)
    catch
        _:_ -> 0
    end;
to_int(_) ->
    0.

%%% -------------------------------------------------------------------
%%% Token verification (now includes "paid" and uses_left)
%%% -------------------------------------------------------------------

verify_token(MacB64, PreimageHex, _Req) ->
    case ets:lookup(?TAB, MacB64) of
        [{_, Meta0}] ->
            case is_expired(Meta0) of
                true ->
                    ets:delete(?TAB, MacB64),
                    {error, expired};
                false ->
                    case maps:get(uses_left, Meta0, 0) of
                        0 ->
                            {error, exhausted};
                        _ ->
                            PH = maps:get(payment_hash_hex, Meta0, <<>>),
                            case proof_ok(PH, PreimageHex) of
                                false ->
                                    {error, bad_preimage};
                                true ->
                                    case maps:get(paid, Meta0, false) of
                                        true ->
                                            Meta = dec_uses(MacB64, Meta0),
                                            {ok, Meta};
                                        false ->
                                            {error, unpaid}
                                    end
                            end
                    end
            end;
        [] ->
            {error, unknown}
    end.

is_expired(#{expires_at := ExpiresAt}) ->
    erlang:system_time(second) > ExpiresAt.

dec_uses(MacB64, Meta0) ->
    N0 = maps:get(uses_left, Meta0, 0),
    N = erlang:max(0, N0 - 1),
    Meta = Meta0#{uses_left => N},
    ets:insert(?TAB, {MacB64, Meta}),
    Meta.

proof_ok(PaymentHashHex, PreimageHex) ->
    case {safe_hex_to_bin(PaymentHashHex), safe_hex_to_bin(PreimageHex)} of
        {{ok, PHBin}, {ok, PreBin}} ->
            crypto:hash(sha256, PreBin) =:= PHBin;
        _ ->
            false
    end.

safe_hex_to_bin(Hex) when is_binary(Hex) ->
    try
        {ok, binary:decode_hex(string:lowercase(Hex))}
    catch
        _:_ -> {error, badhex}
    end.

normalize_hex(undefined) -> <<>>;
normalize_hex(B) when is_binary(B) -> string:lowercase(B);
normalize_hex(L) when is_list(L) -> string:lowercase(list_to_binary(L)).

ensure_tabs() ->
    ensure_tab(?TAB),
    ensure_tab(?TAB_HASH),
    ensure_tab(?TAB_INV),
    ok.

ensure_tab(Name) ->
    case ets:info(Name) of
        undefined ->
            ets:new(Name, [named_table, public, set, {read_concurrency, true}]),
            ok;
        _ ->
            ok
    end.
