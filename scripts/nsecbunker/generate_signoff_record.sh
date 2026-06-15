#!/usr/bin/env sh
set -eu

FEATURE="${FEATURE:-features/nsecbunker/clawdog_nsecbunker_contract.feature}"
REPORT_JSON="${REPORT_JSON:-/tmp/nsecbunker-clawdog-dryrun.json}"
OUT="${OUT:-doc/nsecbunker/CLAWDOG_SIGNOFF_RECORD.generated.md}"

HASH_LINE=$(scripts/nsecbunker/hash_clawdog_contract.sh "$FEATURE" | head -n1)
FEATURE_HASH=$(printf '%s' "$HASH_LINE" | awk '{print $1}')
REPORT_HASH="TBD"

if [ -f "$REPORT_JSON" ]; then
  REPORT_HASH=$(python3 - <<PY || true
import json
try:
    data=json.load(open("$REPORT_JSON"))
    print(data.get("report_hash") or data.get("reportHash") or "TBD")
except Exception:
    print("TBD")
PY
)
fi

cat > "$OUT" <<DOC
# ClawDog signoff record — generated

Feature file: \\`$FEATURE\\`

Feature SHA-256:

\\`\\`\\`text
$FEATURE_HASH
\\`\\`\\`

DamageBDD dry-run report hash:

\\`\\`\\`text
$REPORT_HASH
\\`\\`\\`

Decision:

\\`\\`\\`text
PENDING CLAWDOG REVIEW
\\`\\`\\`

Config update after approval:

\\`\\`\\`erlang
contract_sha => <<"$FEATURE_HASH">>
\\`\\`\\`
DOC

echo "Wrote $OUT"
