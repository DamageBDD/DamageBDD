#!/usr/bin/env bash
set -euo pipefail

sha256sum \
  scripts/nsecbunker/phase4b_create_production_damagebdd_node_key.sh \
  apps/damage/src/steps_nsecbunker_phase4b.erl \
  features/nsecbunker/phase4b_damagebdd_node_production_key.feature \
  config/sys.config.nsecbunker.phase4b.damagebdd.production.fragment.config \
  doc/nsecbunker/PHASE4B_DAMAGEBDD_PRODUCTION_KEY_CEREMONY.md \
  scripts/nsecbunker/run_phase4b_prod_key_feature.sh \
  > MANIFEST.phase4b.prod_key.sha256

cat MANIFEST.phase4b.prod_key.sha256
