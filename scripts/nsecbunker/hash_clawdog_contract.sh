#!/usr/bin/env sh
set -eu
FEATURE="${1:-features/nsecbunker/clawdog_nsecbunker_contract.feature}"
if [ ! -f "$FEATURE" ]; then
  echo "Feature file not found: $FEATURE" >&2
  exit 1
fi
if command -v sha256sum >/dev/null 2>&1; then
  HASH=$(sha256sum "$FEATURE" | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
  HASH=$(shasum -a 256 "$FEATURE" | awk '{print $1}')
else
  echo "Need sha256sum or shasum" >&2
  exit 1
fi
printf '%s  %s\n' "$HASH" "$FEATURE"
printf '\nConfig value:\ncontract_sha => <<"%s">>\n' "$HASH"
