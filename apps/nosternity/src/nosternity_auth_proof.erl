%% Cryptographic proof checks. No key custody, account lookup or HTTP side effects.
-module(nosternity_auth_proof).
-export([nostr/4, lightning/3, hex/1, unhex/1]).

nostr(Event, URL, Payload, Now) when is_map(Event), is_binary(URL), is_binary(Payload) ->
    try
        %% Require the wire fields rather than accepting normalization defaults.
        #{
            <<"kind">> := 27235,
            <<"content">> := <<>>,
            <<"created_at">> := At,
            <<"tags">> := Tags,
            <<"id">> := _,
            <<"sig">> := _,
            <<"pubkey">> := _
        } = Event,
        true = is_integer(At) andalso abs(Now - At) =< 60,
        true = is_list(Tags) andalso length(Tags) =< 8,
        [[<<"u">>, URL]] = [T || [<<"u">> | _] = T <- Tags],
        [[<<"method">>, <<"POST">>]] = [T || [<<"method">> | _] = T <- Tags],
        Hash = hex(crypto:hash(sha256, Payload)),
        [[<<"payload">>, Hash]] = [T || [<<"payload">> | _] = T <- Tags],
        {ok, Normalized} = damage_nostr_event:verify(Event),
        {ok, maps:get(pubkey, Normalized)}
    catch
        _:_ -> {error, invalid_proof}
    end;
nostr(_, _, _, _) ->
    {error, invalid_proof}.

%% LUD-04 signs k1 directly as a SHA-256-sized digest with a DER ECDSA signature.
%% Do not hash k1 a second time and do not convert a DER signature as if it were R||S.
lightning(K1, SigHex, KeyHex) ->
    try
        true = is_binary(K1) andalso byte_size(K1) =:= 64,
        true = is_binary(KeyHex) andalso byte_size(KeyHex) =:= 66,
        true = is_binary(SigHex) andalso byte_size(SigHex) >= 16 andalso byte_size(SigHex) =< 144,
        <<Prefix, _X:32/binary>> = Key = unhex(KeyHex),
        true = Prefix =:= 2 orelse Prefix =:= 3,
        Digest = unhex(K1),
        <<48, _/binary>> = Signature = unhex(SigHex),
        true = crypto:verify(ecdsa, sha256, {digest, Digest}, Signature, [Key, secp256k1]),
        {ok, hex(Key)}
    catch
        _:_ -> {error, invalid_proof}
    end.

hex(Bin) -> string:lowercase(binary:encode_hex(Bin)).
unhex(B) when is_binary(B), byte_size(B) rem 2 =:= 0 ->
    <<<<((nibble(A) bsl 4) bor nibble(C))>> || <<A, C>> <= B>>.
nibble(C) when C >= $0, C =< $9 -> C - $0;
nibble(C) when C >= $a, C =< $f -> C - $a + 10;
nibble(C) when C >= $A, C =< $F -> C - $A + 10;
nibble(_) -> error(invalid_hex).
