#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "usage: $0 path/to/sys.config [more.config...]" >&2
  exit 64
fi

failed=0
for file in "$@"; do
  echo "checking $file"
  if [ ! -f "$file" ]; then
    echo "missing: $file" >&2
    failed=1
    continue
  fi

  if grep -n '#{' "$file"; then
    echo "ERROR: map syntax is not allowed in nsecbunker sys.config" >&2
    failed=1
  fi

  if grep -n '<<"' "$file"; then
    echo "ERROR: binary strings are not allowed in nsecbunker sys.config" >&2
    failed=1
  fi

  if grep -n '{damage_nsecbunker,' "$file"; then
    echo "ERROR: nsecbunker config must be under {damage, [{nsecbunker, [...]}]}" >&2
    failed=1
  fi

  if ! grep -q '{damage,' "$file" && ! grep -q '{nsecbunker, \[' "$file"; then
    echo "ERROR: file does not look like a damage/nsecbunker config fragment" >&2
    failed=1
  fi

done

if [ "$failed" -ne 0 ]; then
  exit 1
fi

echo "nsecbunker sys.config format looks standard"
