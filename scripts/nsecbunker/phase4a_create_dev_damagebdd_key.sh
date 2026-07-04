#!/usr/bin/env bash
set -euo pipefail

ROOT="${DAMAGE_ROOT:-$(pwd)}"
cd "$ROOT"

BACKEND="${DAMAGE_NSECBUNKER_CRYPTO_CMD:-$ROOT/priv/crypto/damage-nsecbunker-crypto-c/damage-nsecbunker-crypto-c}"
VAULT="${DAMAGE_NSECBUNKER_DEV_VAULT:-$ROOT/.damage-nsecbunker/dev_damagebdd.vault}"
REPORT_DIR="${DAMAGE_NSECBUNKER_REPORT_DIR:-$ROOT/doc/nsecbunker/reports}"
JSON_REPORT="$REPORT_DIR/PHASE4A_DEV_DAMAGEBDD_KEY.json"
MD_REPORT="$REPORT_DIR/PHASE4A_DEV_DAMAGEBDD_KEY.md"

if [ ! -x "$BACKEND" ] && [ -x "$ROOT/scripts/nsecbunker/build_phase2c_crypto_c_backend.sh" ]; then
  "$ROOT/scripts/nsecbunker/build_phase2c_crypto_c_backend.sh"
fi

if [ ! -x "$BACKEND" ]; then
  echo "ERROR: backend not executable: $BACKEND" >&2
  exit 1
fi

mkdir -p "$(dirname "$VAULT")" "$REPORT_DIR"
chmod 700 "$(dirname "$VAULT")" || true

if [ -e "$VAULT" ]; then
  if [ "${RESET_DEV_VAULT:-0}" = "1" ]; then
    rm -f "$VAULT"
  else
    echo "ERROR: dev vault already exists: $VAULT" >&2
    echo "Set RESET_DEV_VAULT=1 only if you intentionally want a fresh dev key." >&2
    exit 2
  fi
fi

if [ -z "${DAMAGE_NSECBUNKER_VAULT_PASSPHRASE:-}" ]; then
  printf "Enter DEV vault passphrase: " >&2
  stty -echo
  read -r DAMAGE_NSECBUNKER_VAULT_PASSPHRASE
  stty echo
  printf "\n" >&2
  export DAMAGE_NSECBUNKER_VAULT_PASSPHRASE
fi

python3 - "$BACKEND" "$VAULT" "$JSON_REPORT" "$MD_REPORT" <<'PY'
import datetime, json, os, re, subprocess, sys
from pathlib import Path

backend, vault, json_report, md_report = sys.argv[1:5]

secret_keys = {"nsec","private_key","private_key_hex","privkey","privkey_hex",
               "secret_key","secret_key_hex","mnemonic","seed","seed_hex","sk"}
secret_values = [re.compile(r"nsec1[02-9ac-hj-np-z]+", re.I),
                 re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")]

def call(payload):
    p = subprocess.run([backend], input=json.dumps(payload,separators=(",",":"))+"\n",
                       text=True, capture_output=True, timeout=30, env=os.environ.copy())
    if p.returncode != 0:
        raise SystemExit(f"backend exit {p.returncode}\\nstdout={p.stdout}\\nstderr={p.stderr}")
    try:
        r = json.loads(p.stdout)
    except Exception as e:
        raise SystemExit(f"invalid backend JSON: {e}\\nstdout={p.stdout!r}")
    if r.get("ok") is not True:
        raise SystemExit("backend returned not-ok: " + json.dumps(r, indent=2))
    if not isinstance(r.get("result"), dict):
        raise SystemExit("backend result is not object: " + json.dumps(r, indent=2))
    return r["result"]

def leak(obj, path="$"):
    if isinstance(obj, dict):
        for k,v in obj.items():
            if str(k) in secret_keys:
                return True, f"{path}.{k}"
            yes, where = leak(v, f"{path}.{k}")
            if yes: return yes, where
    elif isinstance(obj, list):
        for i,v in enumerate(obj):
            yes, where = leak(v, f"{path}[{i}]")
            if yes: return yes, where
    elif isinstance(obj, str):
        for pat in secret_values:
            if pat.search(obj):
                return True, path
    return False, None

gen = call({"op":"generate_identity","vault_path":vault})
pub = call({"op":"get_public_key","vault_path":vault})
pubkey = pub.get("pubkey_hex") or gen.get("pubkey_hex")
if not isinstance(pubkey, str) or not re.fullmatch(r"[0-9a-f]{64}", pubkey):
    raise SystemExit(f"invalid pubkey_hex: {pubkey!r}")
if gen.get("pubkey_hex") and gen["pubkey_hex"] != pubkey:
    raise SystemExit("generate_identity pubkey mismatch")

npub = gen.get("npub")
if not npub:
    npub = call({"op":"npub","pubkey_hex":pubkey}).get("npub")
if not isinstance(npub, str) or not npub.startswith("npub1"):
    raise SystemExit(f"invalid npub: {npub!r}")

created = datetime.datetime.now(datetime.timezone.utc).isoformat()
record = {
    "phase":"4A",
    "purpose":"dev_damagebdd_key_rehearsal",
    "status":"generated",
    "created_at_utc":created,
    "backend":backend,
    "vault_path":vault,
    "pubkey_hex":pubkey,
    "npub":npub,
    "secret_exported":False,
    "scope":"DEV/DISPOSABLE ONLY - not LodgeiT production custody"
}
yes, where = leak(record)
if yes:
    raise SystemExit(f"secret-shaped report field/value detected at {where}")

Path(json_report).parent.mkdir(parents=True, exist_ok=True)
Path(json_report).write_text(json.dumps(record, indent=2, sort_keys=True)+"\n")
Path(md_report).write_text(f"""# Phase 4A dev DamageBDD key rehearsal

Status: generated

Created UTC: {created}

Backend: `{backend}`
Vault path: `{vault}`

Public identity:

```text
pubkey_hex: {pubkey}
npub: {npub}
```

Scope:

```text
DEV / DISPOSABLE ONLY
Not the real LodgeiT publisher identity.
Do not reuse for Phase 4B.
```

Secret handling:

```text
nsec exported: no
private key printed: no
secret-shaped fields in report: no
```
""")
print("Phase 4A dev DamageBDD key generated")
print(f"pubkey_hex: {pubkey}")
print(f"npub: {npub}")
print(f"vault_path: {vault}")
print(f"report: {md_report}")
PY

chmod 600 "$VAULT" || true
echo "Safety: do not git-add vault material: $VAULT"
