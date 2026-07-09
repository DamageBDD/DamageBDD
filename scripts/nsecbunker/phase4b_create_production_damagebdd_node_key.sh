#!/usr/bin/env bash
set -euo pipefail

ROOT="${DAMAGE_ROOT:-$(pwd)}"
cd "$ROOT"

APPROVAL_REQUIRED="I_UNDERSTAND_THIS_CREATES_A_PRODUCTION_DAMAGEBDD_NODE_KEY"
if [ "${DAMAGE_NSECBUNKER_PRODUCTION_CEREMONY_APPROVED:-}" != "$APPROVAL_REQUIRED" ]; then
  echo "ERROR: production key ceremony approval missing." >&2
  echo "Set:" >&2
  echo "  export DAMAGE_NSECBUNKER_PRODUCTION_CEREMONY_APPROVED=$APPROVAL_REQUIRED" >&2
  exit 10
fi

if [ -n "${DAMAGE_NSECBUNKER_CRYPTO_CMD:-}" ]; then
  BACKEND="$DAMAGE_NSECBUNKER_CRYPTO_CMD"
elif [ -x "/opt/damage/bin/damage-nsecbunker-crypto-c" ]; then
  BACKEND="/opt/damage/bin/damage-nsecbunker-crypto-c"
else
  BACKEND="$ROOT/priv/crypto/damage-nsecbunker-crypto-c/damage-nsecbunker-crypto-c"
fi
VAULT="${DAMAGE_NSECBUNKER_PROD_VAULT:-/var/lib/damage/nsecbunker/damagebdd_node_production.vault}"
REPORT_DIR="${DAMAGE_NSECBUNKER_REPORT_DIR:-$ROOT/doc/nsecbunker/reports}"
JSON_REPORT="$REPORT_DIR/PHASE4B_DAMAGEBDD_NODE_PRODUCTION_KEY.json"
MD_REPORT="$REPORT_DIR/PHASE4B_DAMAGEBDD_NODE_PRODUCTION_KEY.md"

if [ ! -x "$BACKEND" ] && [ -x "$ROOT/scripts/nsecbunker/build_phase2c_crypto_c_backend.sh" ]; then
  "$ROOT/scripts/nsecbunker/build_phase2c_crypto_c_backend.sh"
fi

if [ ! -x "$BACKEND" ]; then
  echo "ERROR: backend not executable: $BACKEND" >&2
  exit 1
fi

umask 077
mkdir -p "$(dirname "$VAULT")" "$REPORT_DIR"
chmod 700 "$(dirname "$VAULT")" || true

if [ -e "$VAULT" ] && [ "${DAMAGE_NSECBUNKER_ALLOW_PROD_VAULT_RESET:-}" != "" ]; then
  echo "ERROR: production vault reset is blocked by default." >&2
  echo "Refusing to delete existing production vault: $VAULT" >&2
  exit 11
fi

if [ -z "${DAMAGE_NSECBUNKER_VAULT_PASSPHRASE:-}" ]; then
  printf "Enter PRODUCTION DamageBDD node vault passphrase: " >&2
  stty -echo
  read -r DAMAGE_NSECBUNKER_VAULT_PASSPHRASE
  stty echo
  printf "\n" >&2
  export DAMAGE_NSECBUNKER_VAULT_PASSPHRASE
fi

if [ -z "${DAMAGE_NSECBUNKER_VAULT_PASSPHRASE:-}" ]; then
  echo "ERROR: empty production vault passphrase refused" >&2
  exit 12
fi

python3 - "$BACKEND" "$VAULT" "$JSON_REPORT" "$MD_REPORT" <<'PY_INNER'
import datetime, hashlib, json, os, re, stat, subprocess, sys
from pathlib import Path

backend, vault, json_report, md_report = sys.argv[1:5]

secret_keys = {"nsec","private_key","private_key_hex","privkey","privkey_hex",
               "secret_key","secret_key_hex","mnemonic","seed","seed_hex","sk"}
secret_values = [re.compile(r"nsec1[02-9ac-hj-np-z]+", re.I),
                 re.compile(r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----")]

def call(payload):
    p = subprocess.run([backend], input=json.dumps(payload,separators=(",",":"))+"\n",
                       text=True, capture_output=True, timeout=45, env=os.environ.copy())
    if p.returncode != 0:
        raise SystemExit(f"backend exit {p.returncode}\nstdout={p.stdout}\nstderr={p.stderr}")
    try:
        r = json.loads(p.stdout)
    except Exception as e:
        raise SystemExit(f"invalid backend JSON: {e}\nstdout={p.stdout!r}")
    if r.get("ok") is not True:
        raise SystemExit("backend returned not-ok: " + json.dumps(r, indent=2))
    if not isinstance(r.get("result"), dict):
        raise SystemExit("backend result is not object: " + json.dumps(r, indent=2))
    return r["result"]

def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()

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

vault_exists_before = Path(vault).exists()
if vault_exists_before:
    gen = {}
    status = "existing_vault_public_identity_exported"
else:
    gen = call({"op":"generate_identity","vault_path":vault})
    status = "generated"

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

vault_path = Path(vault)
if not vault_path.exists():
    raise SystemExit(f"vault was not created: {vault}")
try:
    os.chmod(vault, 0o600)
except PermissionError:
    pass
mode = stat.S_IMODE(vault_path.stat().st_mode)
if mode & 0o077:
    raise SystemExit(f"production vault permissions too open: {oct(mode)}")

created = datetime.datetime.now(datetime.timezone.utc).isoformat()
backend_sha256 = sha256_file(backend)
record = {
    "phase":"4B",
    "purpose":"production_damagebdd_node_key",
    "status":status,
    "created_at_utc":created,
    "backend":backend,
    "backend_sha256":backend_sha256,
    "vault_path":vault,
    "vault_exists_before":vault_exists_before,
    "vault_mode_octal":oct(mode),
    "pubkey_hex":pubkey,
    "npub":npub,
    "secret_exported":False,
    "scope":"PRODUCTION DamageBDD node nsecbunker identity - not LodgeiT publisher identity"
}
yes, where = leak(record)
if yes:
    raise SystemExit(f"secret-shaped report field/value detected at {where}")

Path(json_report).parent.mkdir(parents=True, exist_ok=True)
Path(json_report).write_text(json.dumps(record, indent=2, sort_keys=True)+"\n")
Path(md_report).write_text(f"""# Phase 4B production DamageBDD node key ceremony

Status: {status}

Created UTC: {created}

Backend: `{backend}`
Backend sha256: `{backend_sha256}`
Vault path: `{vault}`
Vault mode: `{oct(mode)}`

Public identity:

```text
pubkey_hex: {pubkey}
npub: {npub}
```

Scope:

```text
PRODUCTION DamageBDD node nsecbunker identity.
Not the LodgeiT publisher identity.
```

Secret handling:

```text
nsec exported: no
private key printed: no
secret-shaped fields in report: no
production vault overwritten: no
```
""")
os.chmod(json_report, 0o644)
os.chmod(md_report, 0o644)
print("Phase 4B production DamageBDD node key ceremony complete")
print(f"status: {status}")
print(f"pubkey_hex: {pubkey}")
print(f"npub: {npub}")
print(f"vault_path: {vault}")
print(f"vault_mode: {oct(mode)}")
print(f"report: {md_report}")
PY_INNER

echo "Safety: do not git-add vault material: $VAULT"
