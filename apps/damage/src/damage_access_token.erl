%%%-------------------------------------------------------------------
%%% damage_access_token.erl
%%% Token: ae1.<payload_b64url>.<sig_b64url>
%%% Message signed: <<"DamageBDD Access Token\n", PayloadB64/binary>>
%%% Payload JSON: #{typ,v,sub,iat,exp,nonce,aud}
%%%-------------------------------------------------------------------
-module(damage_access_token).
-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-compile(warn_export_all).
-include_lib("damage.hrl").

-export([
    make_payload/3,
    message_to_sign/1,
    encode_token/2,
    verify_token/1,
    generate_access_token/1,
    decode_payload/1,
    token_expiry/1,
    token_valid/1,
    maybe_refresh/2,
    get_access_token/1,
    set_access_cookie/2,
    clear_access_cookie/1
]).
-include_lib("kernel/include/logger.hrl").
-define(TOKEN_TIMEOUT, 86400).

make_payload(AkAccount, TtlSeconds, AudBin) when is_list(AkAccount) ->
    make_payload(list_to_binary(AkAccount), TtlSeconds, AudBin);
make_payload(AkAccountBin, TtlSeconds, AudBin) when is_binary(AkAccountBin) ->
    Now = date_util:now_to_seconds(os:timestamp()),
    Exp = Now + TtlSeconds,
    Nonce = crypto:strong_rand_bytes(16),
    #{
        typ => <<"damage-access">>,
        v => 1,
        sub => AkAccountBin,
        iat => Now,
        exp => Exp,
        nonce => base64url_encode(Nonce),
        aud => AudBin
    }.

message_to_sign(PayloadB64Url) when is_binary(PayloadB64Url) ->
    <<"DamageBDD Access Token\n", PayloadB64Url/binary>>.

encode_token(PayloadMap, SigB64Url) when is_map(PayloadMap), is_binary(SigB64Url) ->
    PayloadJson = jsx:encode(PayloadMap),
    PayloadB64 = base64url_encode(PayloadJson),
    <<"ae1.", PayloadB64/binary, ".", SigB64Url/binary>>.

get_access_token(Req) ->
    case cowboy_req:header(?AUTH_HEADER, Req) of
        <<"L402 ", Token/binary>> ->
            {l402, <<"L402 ", Token/binary>>};
        <<"Nostr ", Token/binary>> ->
            {nostr, Token};
        <<"Bearer null">> ->
            {error, missing};
        <<"Bearer ", Token/binary>> ->
            {access_token, Token};
        _ ->
            case catch cowboy_req:match_qs([access_token], Req) of
                #{access_token := null} ->
                    {error, missing};
                #{access_token := Token} ->
                    {access_token, Token};
                _ ->
                    Cookies = cowboy_req:parse_cookies(Req),
                    case lists:keyfind(<<"sessionid">>, 1, Cookies) of
                        {<<"sessionid">>, Token} -> {access_token, Token};
                        _ -> {error, missing}
                    end
            end
    end.
verify_token(TokenBin) when is_binary(TokenBin) ->
    case binary:split(TokenBin, <<".">>, [global]) of
        [<<"ae1">>, PayloadB64, Sig] ->
            case catch jsx:decode(base64url_decode(PayloadB64), [{labels, atom}, return_maps]) of
                #{sub := Account, exp := Exp} = Payload ->
                    Now = date_util:now_to_seconds(os:timestamp()),
                    case Exp > Now of
                        false ->
                            {error, expired};
                        true ->
                            Msg = <<"DamageBDD Access Token\n", PayloadB64/binary>>,
                            %% Sig is e.g. <<"sg_....">> (pass-through)
                            case vanillae:verify_signature(Sig, Msg, Account) of
                                {ok, true} -> {ok, Account, Payload};
                                {ok, false} -> {error, badsig};
                                {error, R} -> {error, R}
                            end
                    end;
                _ ->
                    {error, badpayload}
            end;
        _ ->
            {error, badtoken}
    end.

%% ---- base64url helpers ----
base64url_encode(Bin) when is_binary(Bin) ->
    B64 = base64:encode(Bin),
    %% base64:encode can insert \n on some impls; be safe:
    B64a = binary:replace(B64, <<"\n">>, <<>>, [global]),
    B64b = binary:replace(B64a, <<"+">>, <<"-">>, [global]),
    B64c = binary:replace(B64b, <<"/">>, <<"_">>, [global]),
    %% strip '=' padding
    binary:replace(B64c, <<"=">>, <<>>, [global]).

base64url_decode(B64Url) when is_binary(B64Url) ->
    B64a = binary:replace(B64Url, <<"-">>, <<"+">>, [global]),
    B64b = binary:replace(B64a, <<"_">>, <<"/">>, [global]),
    PadLen = (4 - (byte_size(B64b) rem 4)) rem 4,
    Pad =
        case PadLen of
            0 -> <<>>;
            1 -> <<"=">>;
            2 -> <<"==">>;
            3 -> <<"===">>
        end,
    base64:decode(<<B64b/binary, Pad/binary>>).
%% In whatever module currently has generate_access_token/1
%% (e.g. damage_accounts, secrets, etc.)

generate_access_token(#{public_key := Account, private_key := PrivateKey} = _Keypair) ->
    %% keep your old TTL semantics
    TtlSeconds = ?TOKEN_TIMEOUT,

    %% Aud should match what the browser sets (window.location.host).
    %% If you don't have it here, use your API host or a constant.
    {ok, ApiUrl} = application:get_env(damage, api_url),
    AudBin = list_to_binary(ApiUrl),

    Payload = damage_access_token:make_payload(Account, TtlSeconds, AudBin),

    %% We need the exact payload_b64url bytes to construct the message-to-sign.
    %% encode_token/2 will recompute this internally, but we need it for signing.
    PayloadJson = jsx:encode(Payload),
    PayloadB64 = base64url_encode(PayloadJson),

    Msg = damage_access_token:message_to_sign(PayloadB64),

    %% Produce a signature compatible with vanillae:verify_signature/3
    SigHexBin = sign_message_superhero_hex(PrivateKey, Msg),

    TokenBin = damage_access_token:encode_token(Payload, SigHexBin),
    {ok, TokenBin}.

%% ---- signing: match vanillae:verify_signature2/3 hashing expectations ----
%% vanillae verifies by salting + varint lengths + blake2b-32, then ed25519 verify. :contentReference[oaicite:2]{index=2}

sign_message_superhero_hex(PrivKey, Message) when is_binary(PrivKey) ->
    Prefix = <<"aeternity Signed Message:\n">>,
    {ok, PSize} = vencode(byte_size(Prefix)),
    {ok, MSize} = vencode(byte_size(Message)),
    Smashed = iolist_to_binary([PSize, Prefix, MSize, Message]),
    {ok, Hashed} = eblake2:blake2b(32, Smashed),

    Sig64 = enacl:sign_detached(Hashed, PrivKey),

    %% vanillae currently parses signatures as hex text and rebuilds 64 bytes from it :contentReference[oaicite:3]{index=3}
    string:lowercase(binary:encode_hex(Sig64)).

%% ---- Bitcoin-style varint used by vanillae for message salting ---- :contentReference[oaicite:4]{index=4}
vencode(N) when N < 0 ->
    {error, {negative_N, N}};
vencode(N) when N < 16#FD ->
    {ok, <<N>>};
vencode(N) when N =< 16#FFFF ->
    NBytes = eu(N, 2),
    {ok, <<16#FD, NBytes/binary>>};
vencode(N) when N =< 16#FFFF_FFFF ->
    NBytes = eu(N, 4),
    {ok, <<16#FE, NBytes/binary>>};
vencode(N) when N < (2 bsl 64) ->
    NBytes = eu(N, 8),
    {ok, <<16#FF, NBytes/binary>>}.

eu(N, Size) ->
    Bytes = binary:encode_unsigned(N, little),
    NExtraZeros = Size - byte_size(Bytes),
    ExtraZeros = <<<<0>> || _ <- lists:seq(1, NExtraZeros)>>,
    <<Bytes/binary, ExtraZeros/binary>>.
-spec decode_payload(binary()) -> {ok, map()} | {error, term()}.
decode_payload(TokenBin) when is_binary(TokenBin) ->
    case binary:split(TokenBin, <<".">>, [global]) of
        [<<"ae1">>, PayloadB64, _Sig] ->
            try
                PayloadBin = base64url_decode(PayloadB64),
                Payload = jsx:decode(PayloadBin, [{labels, atom}, return_maps]),
                {ok, Payload}
            catch
                _:_ -> {error, badpayload}
            end;
        _ ->
            {error, badtoken}
    end.
-spec token_expiry(binary()) -> {ok, non_neg_integer()} | {error, term()}.
token_expiry(TokenBin) ->
    case decode_payload(TokenBin) of
        {ok, #{exp := Exp}} when is_integer(Exp) ->
            {ok, Exp};
        {ok, _} ->
            {error, no_exp};
        Error ->
            Error
    end.
-spec token_valid(binary()) -> boolean().
token_valid(TokenBin) ->
    Now = date_util:now_to_seconds(os:timestamp()),
    case token_expiry(TokenBin) of
        {ok, Exp} -> Exp > Now;
        _ -> false
    end.
-spec maybe_refresh(map(), map()) -> map().
maybe_refresh(
    #{access_token := Token} = Ctx,
    #{public_key := _Pub, private_key := _Priv} = Keypair
) when is_binary(Token) ->
    case token_valid(Token) of
        true ->
            Ctx;
        false ->
            refresh(Ctx, Keypair)
    end;
maybe_refresh(Ctx, Keypair) ->
    refresh(Ctx, Keypair).

refresh(Ctx, Keypair) ->
    case generate_access_token(Keypair) of
        {ok, NewToken} ->
            Ctx#{access_token => NewToken};
        {error, _} ->
            Ctx
    end.

set_access_cookie(Req, Token) when is_binary(Token) ->
    Secure =
        case application:get_env(damage, cookie_secure, true) of
            true -> true;
            false -> false
        end,
    cowboy_req:set_resp_cookie(
        <<"sessionid">>,
        Token,
        Req,
        #{
            path => <<"/">>,
            http_only => true,
            secure => Secure,
            same_site => lax
        }
    ).

clear_access_cookie(Req) ->
    cowboy_req:set_resp_cookie(
        <<"sessionid">>,
        <<>>,
        Req,
        #{
            path => <<"/">>,
            http_only => true,
            same_site => lax,
            max_age => 0
        }
    ).
