%% Bounded, context-bound serialization around the supplied secrets_pqc API.
%% No separate cryptographic primitive or fallback cipher lives in ECAI.
-module(ecai_private_crypto).
-export([seal/3, open/3, scope/2, context/3, decode/1, max_bytes/0]).

-define(MAX_BYTES, 33554432).
max_bytes() -> ?MAX_BYTES.

scope(Config, PublicKey) ->
    #{<<"domain">> => <<"ecai:private-index:v1">>,
      <<"owner">> => maps:get(owner, Config),
      <<"corpus">> => maps:get(corpus, Config),
      <<"key_id">> => maps:get(key_id, Config),
      <<"recipient_sha256">> => crypto:hash(sha256, PublicKey)}.

context(Config, PublicKey, SegmentId) ->
    (scope(Config, PublicKey))#{<<"segment">> => SegmentId,
                             <<"purpose">> => <<"records-and-postings">>}.

-spec seal(term(), binary(), map()) -> binary().
seal(Term, PublicKey, Context) ->
    Plain = term_to_binary(Term, [deterministic]),
    ecai_private_policy:guard(byte_size(Plain) =< ?MAX_BYTES - 8192),
    Envelope = secrets_pqc:encrypt(ml_kem_768, Plain, PublicKey, Context),
    validate_envelope(Envelope),
    Encoded = term_to_binary(Envelope, [deterministic]),
    ecai_private_policy:guard(byte_size(Encoded) =< ?MAX_BYTES),
    <<"ECP1", Encoded/binary>>.

-spec open(binary(), binary(), map()) -> term().
open(<<"ECP1", Encoded/binary>>, PrivateKey, Context)
  when byte_size(Encoded) =< ?MAX_BYTES ->
    try
        Envelope = decode(Encoded),
        validate_envelope(Envelope),
        Plain = secrets_pqc:decrypt(ml_kem_768, Envelope, PrivateKey, Context),
        decode(Plain)
    catch
        _:_ -> ecai_private_policy:fail(private_authentication_failed)
    end;
open(_, _, _) -> ecai_private_policy:fail(private_authentication_failed).

%% Reject compressed ETF before decoding, reject trailing bytes and never
%% create new atoms from disk. [safe] alone does NOT prevent decompression bombs.
decode(Bin = <<131, Tag, _/binary>>)
  when Tag =/= 80, byte_size(Bin) =< ?MAX_BYTES ->
    {Value, Used} = binary_to_term(Bin, [safe, used]),
    true = Used =:= byte_size(Bin),
    Value;
decode(_) -> ecai_private_policy:fail(invalid_private_encoding).

validate_envelope(#{v := 1, alg := pqc_hybrid_aes_256_gcm, kem := ml_kem_768,
                    kem_ct := Kct, iv := IV, tag := Tag, ct := Ct,
                    aad_sha256 := Hash})
  when is_binary(Kct), byte_size(Kct) > 0, byte_size(Kct) =< 4096,
       is_binary(IV), byte_size(IV) =:= 12,
       is_binary(Tag), byte_size(Tag) =:= 16,
       is_binary(Hash), byte_size(Hash) =:= 32,
       is_binary(Ct), byte_size(Ct) =< ?MAX_BYTES -> ok;
validate_envelope(_) -> ecai_private_policy:fail(invalid_private_envelope).
