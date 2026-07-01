#!/usr/bin/env sh
set -eu

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BACKEND="$ROOT/priv/crypto/damage-nsecbunker-crypto-c/damage-nsecbunker-crypto-c"
VAULT="${DAMAGE_NSECBUNKER_TEST_VAULT:-/tmp/damage-nsecbunker-phase2b-c.vault}"

export DAMAGE_NSECBUNKER_VAULT_PASSPHRASE="${DAMAGE_NSECBUNKER_VAULT_PASSPHRASE:-phase2b-c-local-test-passphrase}"
export DAMAGE_NSECBUNKER_ALLOW_PLAIN_NIP44=1

rm -f "$VAULT"

printf '\n[1/6] health\n'
printf '%s\n' '{"op":"health"}' | "$BACKEND"

printf '\n[2/6] generate_identity\n'
printf '{"op":"generate_identity","vault_path":"%s"}\n' "$VAULT" | "$BACKEND" | tee /tmp/nsecbunker-c-generate.json

printf '\n[3/6] get_public_key\n'
printf '{"op":"get_public_key","vault_path":"%s"}\n' "$VAULT" | "$BACKEND" | tee /tmp/nsecbunker-c-public.json
PUBKEY="$(python3 - <<'PY'
import json
print(json.load(open('/tmp/nsecbunker-c-public.json'))['result']['pubkey_hex'])
PY
)"

printf '\n[4/6] npub\n'
printf '{"op":"npub","pubkey_hex":"%s"}\n' "$PUBKEY" | "$BACKEND"

printf '\n[5/6] sign_event\n'
printf '{"op":"sign_event","vault_path":"%s","event":{"pubkey":"%s","created_at":1778000000,"kind":1,"tags":[],"content":"phase2b c backend smoke"}}\n' "$VAULT" "$PUBKEY" | "$BACKEND" | tee /tmp/nsecbunker-c-sign.json
python3 - <<'PY'
import json, re
obj=json.load(open('/tmp/nsecbunker-c-sign.json'))
ev=obj['result']['event']
assert re.fullmatch(r'[0-9a-f]{64}', ev['id'])
assert re.fullmatch(r'[0-9a-f]{128}', ev['sig'])
print('signature shape ok')
PY

printf '\n[6/6] plain NIP44 loopback\n'
printf '%s\n' '{"op":"nip44_encrypt","plaintext":"{\"id\":\"phase2b\",\"result\":\"pong\"}"}' | "$BACKEND" | tee /tmp/nsecbunker-c-enc.json
CT="$(python3 - <<'PY'
import json
print(json.load(open('/tmp/nsecbunker-c-enc.json'))['result']['ciphertext'])
PY
)"
printf '{"op":"nip44_decrypt","ciphertext":"%s"}\n' "$CT" | "$BACKEND"

printf '\nC backend smoke: ok\n'
