#!/usr/bin/env bash
#
# Single, feature-by-feature DamageBDD runner for the ECAI Wikimedia API.
#
# This replaces the operational need for separate run_feature.sh,
# run_contract_suite.sh, run_fixture_suite.sh, run_ipfs_fixture_suite.sh,
# run_network_suite.sh, run_auth_suite.sh and run_pending_suite.sh scripts.
#
# The script intentionally runs ONE named feature (or one compatible group)
# at a time because the durable queue contract and the fixture integration
# require different ECAI runtime profiles:
#
#   contract profile:    index_jobs_max_concurrency = 0
#   integration profile: index_jobs_max_concurrency = 1
#
# Examples:
#   bash scripts/ecai-bdd/run_wikimedia_features.sh list
#   bash scripts/ecai-bdd/run_wikimedia_features.sh auth
#   bash scripts/ecai-bdd/run_wikimedia_features.sh wikimedia-contract
#   bash scripts/ecai-bdd/run_wikimedia_features.sh jobs-contract
#   bash scripts/ecai-bdd/run_wikimedia_features.sh fixture
#   bash scripts/ecai-bdd/run_wikimedia_features.sh ipfs
#   bash scripts/ecai-bdd/run_wikimedia_features.sh network
#   bash scripts/ecai-bdd/run_wikimedia_features.sh pending
#   bash scripts/ecai-bdd/run_wikimedia_features.sh contract-suite
#
set -Eeuo pipefail

###############################################################################
# Repository and output paths
###############################################################################

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

# DAMAGEBDD_ROOT can override repository discovery, which is useful when this
# script is invoked from another checkout or a CI workspace.
if [[ -n "${DAMAGEBDD_ROOT:-}" ]]; then
  REPO_ROOT=$(cd -- "$DAMAGEBDD_ROOT" && pwd)
elif git -C "$SCRIPT_DIR" rev-parse --show-toplevel >/dev/null 2>&1; then
  REPO_ROOT=$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)
else
  # Expected installed location: <repo>/scripts/ecai-bdd/this-script.sh
  REPO_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd)
fi

FEATURE_DIR="$REPO_ROOT/features/ecai"
FIXTURE_DIR="$FEATURE_DIR/fixtures"
RESULTS_DIR=${BDD_RESULTS_DIR:-"$REPO_ROOT/artifacts/ecai-bdd"}
mkdir -p "$RESULTS_DIR"

###############################################################################
# Shared command and environment validation
###############################################################################

require_command() {
  local command_name=$1
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "error: required command not found: $command_name" >&2
    exit 2
  }
}

require_env() {
  local variable_name=$1
  if [[ -z "${!variable_name:-}" ]]; then
    echo "error: required environment variable is not set: $variable_name" >&2
    exit 2
  fi
}

require_file() {
  local path=$1
  [[ -f "$path" ]] || {
    echo "error: required file not found: $path" >&2
    exit 2
  }
}

require_command curl
require_command python3

###############################################################################
# Temporary-file and fixture-server lifecycle
###############################################################################

TMP_FILES=()
FIXTURE_SERVER_PID=""

cleanup() {
  local status=$?
  trap - EXIT INT TERM

  # Stop only the fixture server started by this script.
  if [[ -n "$FIXTURE_SERVER_PID" ]]; then
    kill "$FIXTURE_SERVER_PID" 2>/dev/null || true
    wait "$FIXTURE_SERVER_PID" 2>/dev/null || true
  fi

  for path in "${TMP_FILES[@]:-}"; do
    rm -f -- "$path"
  done

  exit "$status"
}
trap cleanup EXIT INT TERM

wait_for_url() {
  local url=$1
  local attempts=${2:-50}
  local delay=${3:-0.1}

  for _ in $(seq 1 "$attempts"); do
    if curl --silent --fail --max-time 2 "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep "$delay"
  done

  echo "error: service did not become ready: $url" >&2
  return 1
}

start_fixture_server() {
  # The packaged catalog points at 127.0.0.1:9876, so changing this port also
  # requires regenerating the fixture catalog.
  local port=${WIKIMEDIA_FIXTURE_PORT:-9876}
  if [[ "$port" != "9876" ]]; then
    echo "error: fixture catalog is pinned to port 9876; got $port" >&2
    exit 2
  fi

  require_file "$FIXTURE_DIR/wikimedia-catalog.json"
  require_file "$FIXTURE_DIR/pageviews-202606-user.bz2"
  require_file "$FIXTURE_DIR/enwiki_content-20260720-00000.json.bz2"

  # Reuse an already-running fixture server only when it serves the expected
  # catalog. Otherwise start an isolated local Python HTTP server.
  if curl --silent --fail --max-time 2 \
      "http://127.0.0.1:${port}/wikimedia-catalog.json" >/dev/null 2>&1; then
    echo "==> Reusing existing Wikimedia fixture server on port $port"
    return 0
  fi

  local log_path="$RESULTS_DIR/fixture-server.log"
  echo "==> Starting Wikimedia fixture server on 127.0.0.1:$port"
  python3 -m http.server "$port" \
    --bind 127.0.0.1 \
    --directory "$FIXTURE_DIR" \
    >"$log_path" 2>&1 &
  FIXTURE_SERVER_PID=$!

  wait_for_url "http://127.0.0.1:${port}/wikimedia-catalog.json"
}

###############################################################################
# Feature rendering
###############################################################################

render_feature() {
  local source_feature=$1
  local rendered_feature=$2

  # Replace only uppercase environment placeholders such as
  # {{ECAI_BASE_URL}}. DamageBDD scenario variables such as {{RunId}},
  # {{IndexJobId}} and {{ManifestCid}} are deliberately preserved.
  python3 - "$source_feature" "$rendered_feature" <<'PY'
from __future__ import annotations

import os
import re
import sys
from pathlib import Path

source_path = Path(sys.argv[1])
output_path = Path(sys.argv[2])
pattern = re.compile(r"\{\{([A-Z][A-Z0-9_]*)\}\}")
source = source_path.read_text(encoding="utf-8")
missing: set[str] = set()


def replace(match: re.Match[str]) -> str:
    name = match.group(1)
    value = os.environ.get(name)
    if value is None:
        missing.add(name)
        return match.group(0)
    return value


rendered = pattern.sub(replace, source)
if missing:
    print(
        "missing environment variables for "
        f"{source_path.name}: {', '.join(sorted(missing))}",
        file=sys.stderr,
    )
    raise SystemExit(2)

output_path.write_text(rendered, encoding="utf-8")
output_path.chmod(0o600)
PY
}

###############################################################################
# DamageBDD execution primitive
###############################################################################

run_feature_file() {
  local feature_file=$1
  local label=$2

  require_file "$feature_file"

  # These variables authorize the call from this script to the DamageBDD
  # feature-execution service. They are checked here so `list` and `help` work
  # without a configured runtime.
  require_env DAMAGEBDD_RUNNER_URL
  require_env DAMAGEBDD_RUNNER_TOKEN

  local rendered response timestamp result_path endpoint
  rendered=$(mktemp "${TMPDIR:-/tmp}/ecai-wikimedia-bdd.XXXXXX.feature")
  response=$(mktemp "${TMPDIR:-/tmp}/ecai-wikimedia-bdd.XXXXXX.response.json")
  chmod 600 "$rendered" "$response"
  TMP_FILES+=("$rendered" "$response")
  timestamp=$(date -u +%Y%m%dT%H%M%SZ)
  result_path="$RESULTS_DIR/${timestamp}-${label}.json"
  endpoint="${DAMAGEBDD_RUNNER_URL%/}/execute_feature/"

  echo
  echo "============================================================================="
  echo "==> FEATURE: $label"
  echo "==> FILE:    $feature_file"
  echo "==> RUNNER:  $endpoint"
  echo "============================================================================="

  render_feature "$feature_file" "$rendered"

  # --fail-with-body preserves the runner's error response while still making
  # HTTP 4xx/5xx fail the script. Scenario-level output is written to an
  # operator artifact and also printed below.
  if ! curl --fail-with-body --silent --show-error \
      --request PUT "$endpoint" \
      --header "Authorization: Bearer $DAMAGEBDD_RUNNER_TOKEN" \
      --header 'content-type: text/plain' \
      --header 'accept: application/json' \
      --data-binary @"$rendered" \
      --output "$response"; then
    cp "$response" "$result_path" 2>/dev/null || true
    echo "error: DamageBDD execution failed for $label" >&2
    [[ -s "$response" ]] && cat "$response" >&2
    return 1
  fi

  cp "$response" "$result_path"

  if command -v jq >/dev/null 2>&1; then
    jq . "$response"
  else
    cat "$response"
    echo
  fi

  echo "==> Saved runner response: $result_path"
}

###############################################################################
# Feature-specific execution functions
###############################################################################

run_auth_feature() {
  # FEATURE 1: authorization contract
  #
  # Verifies that missing and invalid bearer tokens are rejected. This feature
  # intentionally does not use ECAI_ACCESS_TOKEN, because it tests unauthenticated
  # and invalidly authenticated requests.
  require_env ECAI_BASE_URL
  export ECAI_BASE_URL

  run_feature_file \
    "$FEATURE_DIR/ecai_wikimedia_api_auth.feature" \
    "01-wikimedia-api-auth"
}

run_wikimedia_contract_feature() {
  # FEATURE 2: Wikimedia operator API contract
  #
  # Verifies parameter validation, malformed JSON handling, search request
  # validation and deterministic queue submission without requiring live source
  # downloads. Run this against the contract configuration.
  require_env ECAI_BASE_URL
  require_env ECAI_ACCESS_TOKEN
  export ECAI_BASE_URL ECAI_ACCESS_TOKEN

  run_feature_file \
    "$FEATURE_DIR/ecai_wikimedia_api_contract.feature" \
    "02-wikimedia-api-contract"
}

run_jobs_contract_feature() {
  # FEATURE 3: durable index-job API contract
  #
  # IMPORTANT: the feature asserts max_concurrency == 0 so jobs stay queued
  # while pause/resume/cancel/idempotency/SSE behavior is tested. Start ECAI
  # with the contract profile before running this selector.
  require_env ECAI_BASE_URL
  require_env ECAI_ACCESS_TOKEN
  export ECAI_BASE_URL ECAI_ACCESS_TOKEN

  echo "==> Required ECAI setting: index_jobs_max_concurrency = 0"
  run_feature_file \
    "$FEATURE_DIR/ecai_index_jobs_api_contract.feature" \
    "03-index-jobs-api-contract"
}

run_fixture_feature() {
  # FEATURE 4: deterministic local end-to-end fixture pipeline
  #
  # Starts a local HTTP server for the pinned pageview and Cirrus fixtures,
  # enqueues one Wikimedia job, waits for completion, validates the finalized
  # artifact and verifies entity-deduplicated search.
  #
  # Run ECAI with index_jobs_max_concurrency = 1 and the integration profile.
  require_env ECAI_BASE_URL
  require_env ECAI_ACCESS_TOKEN
  export ECAI_BASE_URL ECAI_ACCESS_TOKEN

  start_fixture_server

  export WIKIMEDIA_FIXTURE_CATALOG_PATH="$FIXTURE_DIR/wikimedia-catalog.json"
  export WIKIMEDIA_JOB_WAIT_SECONDS="${WIKIMEDIA_JOB_WAIT_SECONDS:-20}"
  export WIKIMEDIA_EXPECTED_TERMINAL_STATE="${WIKIMEDIA_EXPECTED_TERMINAL_STATE:-completed}"

  echo "==> Required ECAI setting: index_jobs_max_concurrency = 1"
  run_feature_file \
    "$FEATURE_DIR/ecai_wikimedia_fixture_pipeline.feature" \
    "04-wikimedia-fixture-pipeline"
}

run_ipfs_feature() {
  # FEATURE 5: NFT-ready IPFS artifact contract
  #
  # Uses the same deterministic local corpus, but enables IPFS publication and
  # verifies that the completed job reaches ready_to_mint, exposes
  # ecai-index-nft/v1 metadata and can retrieve the manifest CID through the
  # configured gateway. It does not submit an on-chain mint transaction.
  require_env ECAI_BASE_URL
  require_env ECAI_ACCESS_TOKEN
  export ECAI_BASE_URL ECAI_ACCESS_TOKEN

  start_fixture_server

  export WIKIMEDIA_FIXTURE_CATALOG_PATH="$FIXTURE_DIR/wikimedia-catalog.json"
  export WIKIMEDIA_JOB_WAIT_SECONDS="${WIKIMEDIA_JOB_WAIT_SECONDS:-30}"
  export IPFS_GATEWAY_URL="${IPFS_GATEWAY_URL:-http://127.0.0.1:8080}"

  echo "==> Required: ECAI integration profile, writable IPFS API and gateway"
  echo "==> IPFS gateway: $IPFS_GATEWAY_URL"
  run_feature_file \
    "$FEATURE_DIR/ecai_wikimedia_ipfs_artifact.feature" \
    "05-wikimedia-ipfs-artifact"
}

run_network_feature() {
  # FEATURE 6: live Wikimedia source discovery
  #
  # Contacts official Wikimedia endpoints through the ECAI API. Keep it out of
  # deterministic per-commit CI because availability and dump layout are
  # external dependencies.
  require_env ECAI_BASE_URL
  require_env ECAI_ACCESS_TOKEN
  export ECAI_BASE_URL ECAI_ACCESS_TOKEN

  export WIKIMEDIA_MONTH="${WIKIMEDIA_MONTH:-2026-06}"
  export WIKIMEDIA_RELEASE="${WIKIMEDIA_RELEASE:-20260720}"

  echo "==> Live pageview month:  $WIKIMEDIA_MONTH"
  echo "==> Live Cirrus release: $WIKIMEDIA_RELEASE"
  run_feature_file \
    "$FEATURE_DIR/ecai_wikimedia_discovery_network.feature" \
    "06-wikimedia-discovery-network"
}

run_pending_feature() {
  # FEATURE 7: pending security-hardening contracts
  #
  # These scenarios describe controls that may intentionally fail until source
  # path restrictions, duplicate-month rejection and allowed-root validation
  # are implemented. Run explicitly; do not include in a required green gate.
  require_env ECAI_BASE_URL
  require_env ECAI_ACCESS_TOKEN
  export ECAI_BASE_URL ECAI_ACCESS_TOKEN

  echo "==> WARNING: pending hardening scenarios may be expected to fail"
  run_feature_file \
    "$FEATURE_DIR/ecai_wikimedia_api_hardening_pending.feature" \
    "07-wikimedia-hardening-pending"
}

###############################################################################
# CLI dispatch
###############################################################################

usage() {
  cat <<'USAGE'
Usage:
  run_wikimedia_features.sh list
  run_wikimedia_features.sh auth
  run_wikimedia_features.sh wikimedia-contract
  run_wikimedia_features.sh jobs-contract
  run_wikimedia_features.sh fixture
  run_wikimedia_features.sh ipfs
  run_wikimedia_features.sh network
  run_wikimedia_features.sh pending
  run_wikimedia_features.sh contract-suite

Required for every selector:
  DAMAGEBDD_RUNNER_URL
  DAMAGEBDD_RUNNER_TOKEN

Required by API features except auth:
  ECAI_BASE_URL
  ECAI_ACCESS_TOKEN

Optional overrides:
  DAMAGEBDD_ROOT
  BDD_RESULTS_DIR
  WIKIMEDIA_JOB_WAIT_SECONDS
  WIKIMEDIA_EXPECTED_TERMINAL_STATE
  IPFS_GATEWAY_URL
  WIKIMEDIA_MONTH
  WIKIMEDIA_RELEASE

Profile guidance:
  jobs-contract  -> ECAI contract profile, max_concurrency = 0
  fixture/ipfs   -> ECAI integration profile, max_concurrency = 1
USAGE
}

list_features() {
  cat <<'LIST'
Available selectors:
  auth                 Wikimedia authorization challenge behavior
  wikimedia-contract   Wikimedia operator API validation contract
  jobs-contract        Durable queue, controls, idempotency and SSE contract
  fixture              Local deterministic corpus end-to-end pipeline
  ipfs                 IPFS publication and NFT-ready artifact contract
  network              Live Wikimedia source discovery and planning
  pending              Pending source/path hardening contracts
  contract-suite       auth + wikimedia-contract + jobs-contract
LIST
}

selector=${1:-list}

case "$selector" in
  list|-l|--list)
    list_features
    ;;
  help|-h|--help)
    usage
    ;;
  auth)
    run_auth_feature
    ;;
  wikimedia-contract)
    run_wikimedia_contract_feature
    ;;
  jobs-contract)
    run_jobs_contract_feature
    ;;
  fixture)
    run_fixture_feature
    ;;
  ipfs)
    run_ipfs_feature
    ;;
  network)
    run_network_feature
    ;;
  pending)
    run_pending_feature
    ;;
  contract-suite)
    # These three features are compatible with the contract runtime profile.
    run_auth_feature
    run_wikimedia_contract_feature
    run_jobs_contract_feature
    ;;
  *)
    echo "error: unknown selector: $selector" >&2
    usage >&2
    exit 2
    ;;
esac
