#!/usr/bin/env sh
set -eu

DAMAGE_URL="${DAMAGE_URL:-http://localhost:8080}"
FEATURE="${FEATURE:-features/nsecbunker/clawdog_nsecbunker_contract.feature}"
OUT="${OUT:-/tmp/nsecbunker-clawdog-dryrun.json}"

if [ ! -f "$FEATURE" ]; then
  echo "Feature file not found: $FEATURE" >&2
  exit 1
fi

# Damage's HTTP flow may perform dry-run then paid run depending on node config.
# For signoff, prefer a local/dev node with dry-run-only overrides where available.
# If your local API requires tx mode instead, use /api/tx or the local damage:execute_file path.
python3 - <<PY > /tmp/nsecbunker-feature-payload.json
import json, pathlib
feature = pathlib.Path("$FEATURE").read_text()
print(json.dumps({"feature": feature, "concurrency": 1, "stream": False}))
PY

curl -sS \
  -X PUT \
  -H 'content-type: application/json' \
  --data-binary @/tmp/nsecbunker-feature-payload.json \
  "$DAMAGE_URL/execute_feature/" | tee "$OUT"

echo
echo "Wrote $OUT"
