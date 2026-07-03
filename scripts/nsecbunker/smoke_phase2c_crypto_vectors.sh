#!/usr/bin/env sh
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$ROOT/priv/crypto/damage-nsecbunker-crypto-c/damage-nsecbunker-crypto-c"
VAULT="/tmp/damage-nsecbunker-phase2c-smoke.vault"
rm -f "$VAULT" "$VAULT.corrupt"
export DAMAGE_NSECBUNKER_VAULT_PASSPHRASE="${DAMAGE_NSECBUNKER_VAULT_PASSPHRASE:-phase2c-smoke-passphrase}"

call() { printf '%s\n' "$1" | "$BIN"; }
assert_json() {
  DESC="$1"; EXPECT="$2"; JSON="$3"
  python3 - "$DESC" "$EXPECT" "$JSON" <<'PY'
import json,sys
label=sys.argv[1]
expected=json.loads(sys.argv[2])
obj=json.loads(sys.argv[3])
if not obj.get('ok'):
    raise SystemExit(f'{label}: backend not ok: {obj}')
result=obj.get('result', {})
for k,v in expected.items():
    got=result.get(k)
    if got != v:
        raise SystemExit(f'{label}: {k} expected {v!r} got {got!r}; full={obj!r}')
print(f'ok: {label}')
PY
}

HEALTH=$(call '{"op":"health"}')
assert_json health '{"phase":"2c","nip44":"v2"}' "$HEALTH"

SIG=$(call '{"op":"schnorr_sign_vector","secret_key_hex":"0000000000000000000000000000000000000000000000000000000000000003","message_hex":"0000000000000000000000000000000000000000000000000000000000000000","aux_rand_hex":"0000000000000000000000000000000000000000000000000000000000000000"}')
assert_json bip340_sign '{"pubkey_hex":"f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9","signature_hex":"e907831f80848d1069a5371b402410364bdf1c5f8307b0084c55f1ce2dca821525f66a4a85ea8b71e482a74f382d2ce5ebeee8fdb2172f477df4900d310536c0"}' "$SIG"

VERIFY=$(call '{"op":"schnorr_verify","pubkey_hex":"F9308A019258C31049344F85F89D5229B531C845836F99B08601F113BCE036F9","message_hex":"0000000000000000000000000000000000000000000000000000000000000000","signature_hex":"E907831F80848D1069A5371B402410364BDF1C5F8307B0084C55F1CE2DCA821525F66A4A85EA8B71E482A74F382D2CE5EBEEE8FDB2172F477DF4900D310536C0"}')
assert_json bip340_verify '{"valid":true}' "$VERIFY"

NPUB=$(call '{"op":"npub","pubkey_hex":"79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"}')
assert_json npub_vector '{"npub":"npub10xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7vqpkge6d"}' "$NPUB"

EVENT=$(call '{"op":"event_id","pubkey_hex":"79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798","event":{"created_at":0,"kind":1,"tags":[],"content":"hello"}}')
assert_json event_id_vector '{"id":"5a25a8422478717a983475e3ab77edeb1b72775dde3d2e2dffb054aa98c5cc45"}' "$EVENT"

NIP44=$(call '{"op":"nip44_encrypt_vector","secret_key_hex":"0000000000000000000000000000000000000000000000000000000000000001","peer_pubkey_hex":"c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5","nonce_hex":"0000000000000000000000000000000000000000000000000000000000000001","plaintext":"a"}')
assert_json nip44_encrypt_vector '{"conversation_key":"c41c775356fd92eadc63ff5a0dc1da211b268cbea22316767095b2871ea1412d","payload":"AgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABee0G5VSK0/9YypIObAtDKfYEAjD35uVkHyB0F4DwrcNaCXlCWZKaArsGrY6M9wnuTMxWfp1RTN9Xga8no+kF5Vsb"}' "$NIP44"

NIP44D=$(call '{"op":"nip44_decrypt_vector","secret_key_hex":"0000000000000000000000000000000000000000000000000000000000000002","peer_pubkey_hex":"79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798","payload":"AgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABee0G5VSK0/9YypIObAtDKfYEAjD35uVkHyB0F4DwrcNaCXlCWZKaArsGrY6M9wnuTMxWfp1RTN9Xga8no+kF5Vsb"}')
assert_json nip44_decrypt_vector '{"conversation_key":"c41c775356fd92eadc63ff5a0dc1da211b268cbea22316767095b2871ea1412d","plaintext":"a"}' "$NIP44D"

GEN=$(call "{\"op\":\"generate_identity\",\"vault_path\":\"$VAULT\"}")
python3 - "$GEN" <<'PY'
import json,sys,re
obj=json.loads(sys.argv[1])
assert obj.get('ok'), obj
assert re.fullmatch(r'[0-9a-f]{64}', obj['result']['pubkey_hex']), obj
print('ok: vault generate')
PY

CLIENT=79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798
CIPH=$(call "{\"op\":\"nip44_encrypt\",\"vault_path\":\"$VAULT\",\"client_pubkey\":\"$CLIENT\",\"plaintext\":\"phase2c real nip44\"}")
C=$(python3 - "$CIPH" <<'PY'
import json,sys
obj=json.loads(sys.argv[1])
assert obj.get('ok'), obj
assert obj['result'].get('nip44') == 'v2', obj
print(obj['result']['ciphertext'])
PY
)
DEC=$(call "{\"op\":\"nip44_decrypt\",\"vault_path\":\"$VAULT\",\"client_pubkey\":\"$CLIENT\",\"ciphertext\":\"$C\"}")
assert_json real_nip44_roundtrip '{"plaintext":"phase2c real nip44","nip44":"v2"}' "$DEC"

# wrong passphrase must fail closed
export DAMAGE_NSECBUNKER_VAULT_PASSPHRASE=wrong-passphrase
BAD=$(call "{\"op\":\"get_public_key\",\"vault_path\":\"$VAULT\"}" || true)
python3 - "$BAD" <<'PY'
import json,sys
obj=json.loads(sys.argv[1])
assert obj.get('ok') is False, obj
assert obj.get('error') == 'vault_decrypt_failed', obj
print('ok: wrong passphrase fails closed')
PY

# production must block plain loopback even if old env is set
export DAMAGE_NSECBUNKER_TEST_MODE=1
export DAMAGE_NSECBUNKER_ALLOW_PLAIN_NIP44=1
export DAMAGE_NSECBUNKER_PRODUCTION=1
STATUS=$(call '{"op":"plain_mode_status"}')
assert_json production_blocks_plain '{"plain_allowed":false,"production":true}' "$STATUS"

echo 'Phase 2C crypto vectors smoke: PASS'
