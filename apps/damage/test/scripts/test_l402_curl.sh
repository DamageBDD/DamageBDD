#!/usr/bin/env bash
set -euo pipefail

# l402-feature-run.sh
#
# Run a DamageBDD feature file against an L402-protected endpoint.
#
# Usage:
#   ./l402-feature-run.sh path/to/feature.feature
#   ./l402-feature-run.sh path/to/feature.feature --pay
#   ./l402-feature-run.sh path/to/feature.feature --display-only
#   ./l402-feature-run.sh path/to/feature.feature --host run.damagebdd.com
#   ./l402-feature-run.sh path/to/feature.feature --method PUT --pay
#
# Host selection:
#   Default host: run.dev.damagebdd.com
#   Built-in choices:
#     - run.dev.damagebdd.com
#     - run.damagebdd.com
#
# Modes:
#   --pay           Pay the invoice with lightning-cli, then replay the request
#   --display-only  Only show the invoice QR and stop
#
# Requirements:
#   curl, grep, sed, jq, qrencode
#   lightning-cli only if using --pay

DEFAULT_HOST="run.dev.damagebdd.com"
ENDPOINT_PATH="/execute_feature"
SCHEME="https"
HOST="$DEFAULT_HOST"
METHOD="POST"
MODE="display-only"
CONTENT_TYPE="text/plain"
VERBOSE=0
KEEP_FILES=0

usage() {
  cat <<'EOF'
Usage:
  l402-feature-run.sh FEATURE_FILE [options]

Positional arguments:
  FEATURE_FILE                 Path to the .feature file to send

Options:
  --pay                        Pay the invoice with lightning-cli and replay request
  --display-only               Only display QR and invoice, do not pay
  --host HOST                  Host to use
  --url URL                    Full URL override
  --method METHOD              HTTP method to use (default: POST)
  --content-type TYPE          Content-Type header (default: text/plain)
  -v, --verbose                Enable verbose curl output
  --keep-files                 Keep temp header/body files
  -h, --help                   Show this help

Built-in host choices:
  run.dev.damagebdd.com        Default
  run.damagebdd.com

Examples:
  l402-feature-run.sh features/nfts/package.feature
  l402-feature-run.sh features/nfts/package.feature --pay
  l402-feature-run.sh features/nfts/package.feature --host run.damagebdd.com --pay
  l402-feature-run.sh features/nfts/package.feature --host run.damagebdd.com --display-only
  l402-feature-run.sh features/nfts/package.feature --url https://custom.example.com/execute_feature
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

build_url() {
  printf '%s://%s%s' "$SCHEME" "$HOST" "$ENDPOINT_PATH"
}

extract_header_value() {
  local key="$1"
  local file="$2"
  grep -i '^www-authenticate:' "$file" | sed -n "s/.*${key}=\"\\([^\"]*\\)\".*/\\1/p" | head -n1
}

run_initial_request() {
  local feature_file="$1"
  local headers_file="$2"
  local body_file="$3"
  local url="$4"

  if [[ "$VERBOSE" -eq 1 ]]; then
    curl -v -sS -X "$METHOD" \
      --data-binary @"$feature_file" \
      -H "Content-Type: $CONTENT_TYPE" \
      "$url" \
      -D "$headers_file" \
      -o "$body_file"
  else
    curl -sS -X "$METHOD" \
      --data-binary @"$feature_file" \
      -H "Content-Type: $CONTENT_TYPE" \
      "$url" \
      -D "$headers_file" \
      -o "$body_file"
  fi
}

run_authorized_request() {
  local feature_file="$1"
  local macaroon="$2"
  local preimage="$3"
  local url="$4"

  if [[ "$VERBOSE" -eq 1 ]]; then
    curl -v -sS -X "$METHOD" \
      --data-binary @"$feature_file" \
      -H "Content-Type: $CONTENT_TYPE" \
      -H "Authorization: L402 ${macaroon}:${preimage}" \
      "$url" 
  else
    curl -sS -X "$METHOD" \
      --data-binary @"$feature_file" \
      -H "Content-Type: $CONTENT_TYPE" \
      -H "Authorization: L402 ${macaroon}:${preimage}" \
      "$url"
  fi
}

print_summary() {
  local body_file="$1"
  echo "Challenge response:"
  if jq . "$body_file" >/dev/null 2>&1; then
    jq . "$body_file"
  else
    cat "$body_file"
  fi
}


main() {
  [[ $# -ge 1 ]] || { usage; exit 1; }

  local feature_file=""
  local url=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pay)
        MODE="pay"
        shift
        ;;
      --display-only)
        MODE="display-only"
        shift
        ;;
      --host)
        [[ $# -ge 2 ]] || die "--host requires a value"
        HOST="$2"
        shift 2
        ;;
      --url)
        [[ $# -ge 2 ]] || die "--url requires a value"
        url="$2"
        shift 2
        ;;
      --method)
        [[ $# -ge 2 ]] || die "--method requires a value"
        METHOD="$2"
        shift 2
        ;;
      --content-type)
        [[ $# -ge 2 ]] || die "--content-type requires a value"
        CONTENT_TYPE="$2"
        shift 2
        ;;
      -v|--verbose)
        VERBOSE=1
        shift
        ;;
      --keep-files)
        KEEP_FILES=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      -*)
        die "unknown option: $1"
        ;;
      *)
        if [[ -z "$feature_file" ]]; then
          feature_file="$1"
        else
          die "unexpected extra argument: $1"
        fi
        shift
        ;;
    esac
  done

  [[ -n "$feature_file" ]] || die "missing FEATURE_FILE"
  [[ -f "$feature_file" ]] || die "feature file not found: $feature_file"

  if [[ -z "$url" ]]; then
    url="$(build_url)"
  fi

  need_cmd curl
  need_cmd grep
  need_cmd sed
  need_cmd jq
  need_cmd qrencode
  if [[ "$MODE" == "pay" ]]; then
    need_cmd lightning-cli
  fi

  local headers_file body_file
  headers_file="$(mktemp -t l402_headers.XXXXXX)"
  body_file="$(mktemp -t l402_body.XXXXXX)"

  if [[ "$KEEP_FILES" -eq 0 ]]; then
    trap 'rm -f "$headers_file" "$body_file"' EXIT
  fi

  echo "Requesting L402 challenge..."
  echo "  URL:    $url"
  echo "  METHOD: $METHOD"
  echo "  FILE:   $feature_file"
  echo "  MODE:   $MODE"
  echo

  run_initial_request "$feature_file" "$headers_file" "$body_file" "$url"

  local macaroon invoice
  macaroon="$(extract_header_value macaroon "$headers_file")"
  invoice="$(extract_header_value invoice "$headers_file")"

  echo "Response body:"
  print_summary "$body_file"
  echo

  [[ -n "$macaroon" ]] || die "failed to extract macaroon from WWW-Authenticate header"
  [[ -n "$invoice" ]] || die "failed to extract invoice from WWW-Authenticate header"

  echo "Macaroon:"
  echo "$macaroon"
  echo
  echo "Invoice:"
  echo "$invoice"
  echo
  echo "QR:"
  qrencode -t ANSIUTF8 "$invoice"
  echo

  if [[ "$MODE" == "display-only" ]]; then
    echo "Display-only mode selected. Not paying invoice."
    if [[ "$KEEP_FILES" -eq 1 ]]; then
      echo "Saved headers: $headers_file"
      echo "Saved body:    $body_file"
    fi
    exit 0
  fi

  echo "Paying invoice with lightning-cli..."
  local payjson preimage
  payjson="$(lightning-cli pay "$invoice")"
  preimage="$(printf '%s\n' "$payjson" | jq -r '.payment_preimage // .preimage')"

  [[ -n "$preimage" && "$preimage" != "null" ]] || die "failed to extract preimage from lightning-cli output"

  echo "Payment succeeded."
  sleep 1
  echo
  echo "Replaying authorized request..."
  run_authorized_request "$feature_file" "$macaroon" "$preimage" "$url"
}

main "$@"
