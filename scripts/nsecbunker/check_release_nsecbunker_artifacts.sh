#!/usr/bin/env sh
set -eu

REL_ROOT="${1:-/opt/damage}"

need_exec() {
  if [ ! -x "$REL_ROOT/$1" ]; then
    echo "MISSING OR NOT EXECUTABLE: $REL_ROOT/$1" >&2
    exit 1
  fi
  echo "ok executable: $REL_ROOT/$1"
}

need_dir() {
  if [ ! -d "$REL_ROOT/$1" ]; then
    echo "MISSING DIR: $REL_ROOT/$1" >&2
    exit 1
  fi
  echo "ok dir: $REL_ROOT/$1"
}

need_exec bin/damage-nsecbunker-crypto-c
need_dir scripts/nsecbunker
need_dir features/nsecbunker
need_dir doc/nsecbunker

if [ -f "$REL_ROOT/scripts/nsecbunker/phase4b_create_production_damagebdd_node_key.sh" ]; then
  chmod +x "$REL_ROOT/scripts/nsecbunker/phase4b_create_production_damagebdd_node_key.sh" 2>/dev/null || true
  echo "ok script: $REL_ROOT/scripts/nsecbunker/phase4b_create_production_damagebdd_node_key.sh"
else
  echo "MISSING script: $REL_ROOT/scripts/nsecbunker/phase4b_create_production_damagebdd_node_key.sh" >&2
  exit 1
fi

sha256sum "$REL_ROOT/bin/damage-nsecbunker-crypto-c" || shasum -a 256 "$REL_ROOT/bin/damage-nsecbunker-crypto-c"
