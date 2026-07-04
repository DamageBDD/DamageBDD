#!/usr/bin/env sh
set -eu

FILES="${*:-config/sys.config.nsecbunker.standard.fragment.config config/sys.config.nsecbunker.phase4a.dev.standard.fragment.config}"

bad=0
for f in $FILES; do
  if [ ! -f "$f" ]; then
    echo "missing: $f" >&2
    bad=1
    continue
  fi
  if grep -n '^[[:space:]]*[^%].*#{' "$f"; then
    echo "bad: map syntax found in $f" >&2
    bad=1
  fi
  if grep -n '^[[:space:]]*[^%].*<<"' "$f"; then
    echo "bad: binary string syntax found in $f" >&2
    bad=1
  fi
  echo "checked: $f"
done

exit "$bad"
