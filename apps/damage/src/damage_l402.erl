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
    %% Listener registration is local gproc state. Do not make a hard match
    %% part of startup even if the CLN facade/backend is temporarily absent.
    Subscribed =
        case damage_cln:register_listener(invoice_paid) of
            true ->
                true;
            Other ->
                logger:warning("L402 CLN listener unavailable at startup: ~p", [Other]),
                false
        end,
    {ok, #state{subscribed = Subscribed}}.

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
handle_info({cln_event, invoice_paid, Ev}, S) ->
    %% Ev is expected to include payment_hash and amount_msat (or amount_received_msat)
    ?LOG_DEBUG("cln_event invoice_paid ~p", [Ev]),
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

-spec challenge(cowboy_req:req(), binary(), integer()) ->
    {cowboy_req:req(), map()} | {error, term()}.
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
    {cowboy_req:req(), map()} | {error, term()}.
challenge_with_body(Req0, Scope, AmountMsat, BodyBin) ->
    Expiry = application:get_env(damage, l402_invoice_expiry, 600),
    Uses = application:get_env(damage, l402_uses, 1),

    MacB64 = base64:encode(crypto:strong_rand_bytes(32)),

    {ok, Timestamp} = datestring:format("YmdHMS", erlang:localtime()),
    Label = <<"l402:", Scope/binary, ":", (list_to_binary(Timestamp))/binary, ":", MacB64/binary>>,
    Desc = <<"DamageBDD L402 ", Scope/binary>>,

    %% The facade returns {error, Reason} for a missing/timed-out backend.
    %% Never read it as a map or create token state from a partial RPC reply.
    case invoice_fields(damage_cln:create_invoice(AmountMsat, Desc, Expiry, Label), Expiry) of
        {ok, Bolt11, PaymentHashHex, ExpiresAt} ->
            issue_challenge(
                Req0, Scope, AmountMsat, BodyBin, MacB64, Uses,
                Bolt11, PaymentHashHex, ExpiresAt
            );
        {error, _} = Error ->
            Error
    end.

issue_challenge(Req0, Scope, AmountMsat, BodyBin, MacB64, Uses, Bolt11, PaymentHashHex, ExpiresAt) ->
    ensure_tabs(),
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
                <<"cache-control">> => <<"no-store">>,
                <<"www-authenticate">> => HeaderVal
            },
            BodyBin,
            Req0
        ),
    {Req1, Meta}.

%% Accept the facade's current map result and an explicitly wrapped success.
%% Error replies deliberately retain their original reason for the HTTP
%% layer's NODE_SECRETS_LOCKED / L402_UNAVAILABLE classification.
invoice_fields({error, _} = Error, _Expiry) ->
    Error;
invoice_fields({ok, Invoice}, Expiry) when is_map(Invoice) ->
    invoice_fields(Invoice, Expiry);
invoice_fields(Invoice, Expiry) when is_map(Invoice) ->
    case lists:any(fun(Key) -> maps:is_key(Key, Invoice) end,
                   [error, <<"error">>, code, <<"code">>]) of
        true ->
            %% Do not reflect backend messages, bodies or secrets to a client.
            {error, {invoice_creation_failed, cln_rpc_error}};
        false ->
            Bolt11 = invoice_binary(invoice_field(bolt11, Invoice)),
            PaymentHash = invoice_binary(invoice_field(payment_hash, Invoice)),
            case {valid_invoice_text(Bolt11), valid_payment_hash(PaymentHash)} of
                {true, true} ->
                    case invoice_expiry(invoice_field(expires_at, Invoice), Expiry) of
                        {ok, ExpiresAt} ->
                            {ok, Bolt11, string:lowercase(PaymentHash), ExpiresAt};
                        {error, _} = Error ->
                            Error
                    end;
                {false, _} ->
                    {error, {invalid_invoice_response, bolt11}};
                {_, false} ->
                    {error, {invalid_invoice_response, payment_hash}}
            end
    end;
invoice_fields(_Other, _Expiry) ->
    {error, invalid_invoice_response}.

invoice_field(Key, Invoice) ->
    maps:get(Key, Invoice, maps:get(atom_to_binary(Key, utf8), Invoice, undefined)).

invoice_binary(Value) when is_binary(Value) ->
    Value;
invoice_binary(Value) when is_list(Value) ->
    try iolist_to_binary(Value) of
        Bin -> Bin
    catch
        error:badarg -> undefined
    end;
invoice_binary(_) ->
    undefined.

%% Structural/header-safety validation, not a BOLT11 signature verifier.
valid_invoice_text(Bolt11) when is_binary(Bolt11), byte_size(Bolt11) =< 16384 ->
    re:run(Bolt11, <<"\\A(?:ln|LN)[A-Za-z0-9]+\\z">>, [{capture, none}]) =:= match;
valid_invoice_text(_) ->
    false.

valid_payment_hash(Hash) when is_binary(Hash), byte_size(Hash) =:= 64 ->
    re:run(Hash, <<"\\A[0-9A-Fa-f]{64}\\z">>, [{capture, none}]) =:= match;
valid_payment_hash(_) ->
    false.

invoice_expiry(InvoiceExpiry, RequestedExpiry) ->
    Now = erlang:system_time(second),
    case InvoiceExpiry of
        undefined -> {ok, Now + RequestedExpiry};
        At when is_integer(At), At > Now -> {ok, min(At, Now + RequestedExpiry)};
        _ -> {error, {invalid_invoice_response, expires_at}}
    end.

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
            case maps:get(paid, Meta0, false) of
                true ->
                    ?LOG_DEBUG("Ignoring duplicate L402 paid event macaroon=~p", [MacB64]),
                    ok;
                false ->
                    PaidMsat1 = to_int(PaidMsat),
                    case PaidMsat1 > 0 of
                        true ->
                            Sats = PaidMsat1 div 1000,
                            Damage = price_feed:sats_to_damage(Sats),
                            Meta =
                                Meta0#{
                                    paid => true,
                                    paid_msat => PaidMsat1,
                                    sats_paid => Sats,
                                    damage_available =>
                                        maps:get(damage_available, Meta0, 0) + Damage
                                },
                            ets:insert(?TAB, {MacB64, Meta}),
                            ?LOG_INFO(
                                "L402 paid macaroon=~p sats=~p damage=~p",
                                [MacB64, Sats, Damage]
                            ),
                            ok;
                        false ->
                            ?LOG_WARNING("Ignoring L402 paid event with zero msat macaroon=~p", [
                                MacB64
                            ]),
                            ok
                    end
            end;
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
            maps:get(
                received_msat,
                Ev,
                maps:get(amount_received_msat, Ev, maps:get(<<"amount_received_msat">>, Ev, 0))
            )
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
    Digits = <<<<C>> || <<C>> <= B, C >= $0, C =< $9>>,
    case Digits of
        <<>> ->
            0;
        _ ->
            try binary_to_integer(Digits) of
                I -> I
            catch
                _:_ -> 0
            end
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
                    drop_token(MacB64, Meta0),
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

drop_token(MacB64, Meta) ->
    ets:delete(?TAB, MacB64),
    ets:delete(?TAB_HASH, maps:get(payment_hash_hex, Meta, <<>>)),
    ets:delete(?TAB_INV, maps:get(invoice, Meta, <<>>)),
    ok.

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
