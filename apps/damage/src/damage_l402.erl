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

-include_lib("kernel/include/logger.hrl").

-export([
    verify_authorization/2,
    challenge/3,
    parse_authorization/1
]).

-define(TAB, damage_l402_tokens).

%% Stored in ETS under key MacaroonB64 (binary):
%% #{payment_hash_hex, invoice, amount_msat, scope, expires_at, uses_left}

-spec verify_authorization(binary() | undefined, cowboy_req:req()) ->
    {ok, map()} | {error, atom()}.
verify_authorization(undefined, _Req) ->
    {error, missing};
verify_authorization(AuthHeader, Req) ->
    ensure_tab(),
    case parse_authorization(AuthHeader) of
        {ok, MacB64, PreimageHex} ->
            verify_token(MacB64, PreimageHex, Req);
        {error, _} ->
            {error, invalid}
    end.

%% Issue an L402 challenge for Scope at AmountMsat.
-spec challenge(cowboy_req:req(), binary(), integer()) ->
    {cowboy_req:req(), map()}.
challenge(Req0, Scope, AmountMsat) when is_binary(Scope), is_integer(AmountMsat) ->
    ensure_tab(),
    Expiry = application:get_env(damage, l402_invoice_expiry, 600),
    Uses = application:get_env(damage, l402_uses, 1),

    %% Opaque “macaroon” token
    MacBin = crypto:strong_rand_bytes(32),
    MacB64 = base64:encode(MacBin),

    {ok, Timestamp} = datestring:format("YmdHMS", erlang:localtime()),
    Label =
        <<"l402:", Scope/binary, ":", (list_to_binary(Timestamp))/binary, ":", MacB64/binary>>,
    Desc = <<"DamageBDD L402 ", Scope/binary>>,

    %% CLN invoice: expect bolt11 + payment_hash
    InvoiceMap = cln:create_invoice(AmountMsat, Desc, Expiry, Label),
    Bolt11 = maps:get(bolt11, InvoiceMap, maps:get(<<"bolt11">>, InvoiceMap, undefined)),
    PaymentHash0 =
        maps:get(payment_hash, InvoiceMap, maps:get(<<"payment_hash">>, InvoiceMap, undefined)),
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
        uses_left => Uses
    },
    ets:insert(?TAB, {MacB64, Meta}),

    HeaderVal =
        iolist_to_binary(["L402 macaroon=\"", MacB64, "\", invoice=\"", Bolt11, "\""]),

    Body = jsx:encode(#{code => 402, message => <<"missing L402">>, scope => Scope}),
    Req =
        cowboy_req:reply(
            402,
            #{
                <<"content-type">> => <<"application/json">>,
                <<"www-authenticate">> => HeaderVal
            },
            Body,
            Req0
        ),
    {Req, Meta}.

%% Expected: "L402 <macaroonsB64>[,<more>...]:<preimageHex>"
-spec parse_authorization(binary()) -> {ok, binary(), binary()} | {error, atom()}.
parse_authorization(<<"L402 ", Token/binary>>) ->
    case binary:split(Token, <<":">>, [global]) of
        [MacsBin, PreHex] when byte_size(MacsBin) > 0, byte_size(PreHex) > 0 ->
            %% Support first macaroon if comma-separated.
            Mac0 = hd(binary:split(MacsBin, <<",">>, [global])),
            {ok, Mac0, PreHex};
        _ ->
            {error, invalid}
    end;
parse_authorization(_) ->
    {error, invalid}.

%% ---------------- Internal ----------------

ensure_tab() ->
    case ets:info(?TAB) of
        undefined ->
            ets:new(?TAB, [named_table, public, set, {read_concurrency, true}]),
            ok;
        _ ->
            ok
    end.

verify_token(MacB64, PreimageHex, _Req) ->
    case ets:lookup(?TAB, MacB64) of
        [{MacB64, Meta0}] ->
            case is_expired(Meta0) of
                true ->
                    ets:delete(?TAB, MacB64),
                    {error, expired};
                false ->
                    case uses_left(Meta0) of
                        0 ->
                            {error, exhausted};
                        _ ->
                            PaymentHashHex = maps:get(payment_hash_hex, Meta0),
                            case proof_ok(PaymentHashHex, PreimageHex) of
                                true ->
                                    case invoice_paid(PaymentHashHex) of
                                        true ->
                                            Meta = dec_uses(MacB64, Meta0),
                                            {ok, Meta};
                                        false ->
                                            {error, unpaid}
                                    end;
                                false ->
                                    {error, bad_preimage}
                            end
                    end
            end;
        [] ->
            {error, unknown}
    end.

is_expired(#{expires_at := ExpiresAt}) ->
    erlang:system_time(second) > ExpiresAt.

uses_left(#{uses_left := N}) when is_integer(N) -> N;
uses_left(_) -> 0.

dec_uses(MacB64, Meta0) ->
    N0 = uses_left(Meta0),
    N = erlang:max(0, N0 - 1),
    Meta = Meta0#{uses_left => N},
    ets:insert(?TAB, {MacB64, Meta}),
    Meta.

%% sha256(preimage) == payment_hash
proof_ok(PaymentHashHex, PreimageHex) ->
    case {safe_hex_to_bin(PaymentHashHex), safe_hex_to_bin(PreimageHex)} of
        {{ok, PHBin}, {ok, PreBin}} ->
            crypto:hash(sha256, PreBin) =:= PHBin;
        _ ->
            false
    end.

invoice_paid(PaymentHashHex) ->
    try
        Resp = cln:list_invoices_by_payment_hash(PaymentHashHex),
        Invoices = maps:get(invoices, Resp, maps:get(<<"invoices">>, Resp, [])),
        lists:any(
            fun(I) ->
                Status = maps:get(status, I, maps:get(<<"status">>, I, <<>>)),
                Status =:= <<"paid">> orelse Status =:= paid
            end,
            Invoices
        )
    catch
        _:E ->
            ?LOG_WARNING("L402 invoice_paid lookup failed: ~p", [E]),
            false
    end.

normalize_hex(undefined) -> <<>>;
normalize_hex(B) when is_binary(B) -> string:lowercase(B);
normalize_hex(L) when is_list(L) -> string:lowercase(list_to_binary(L)).

safe_hex_to_bin(Hex) when is_binary(Hex) ->
    try
        {ok, binary:decode_hex(string:lowercase(Hex))}
    catch
        _:_ -> {error, badhex}
    end.
