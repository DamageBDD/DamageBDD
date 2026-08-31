#!/usr/bin/env bash
set -euo pipefail

root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
src="$root/apps/damage/src"
main_c="$root/priv/crypto/damage-nsecbunker-crypto-c/src/main.c"
base_rebar="$root/rebar.config"
aws_config="$root/config/sys.config.aws.production.fragment.config"

fail() {
  echo "nsecbunker AWS invariant failed: $*" >&2
  exit 1
}

count_fixed() {
  local pattern="$1"
  shift
  { grep -R --include='*.erl' -F "$pattern" "$@" 2>/dev/null || true; } |
    wc -l |
    tr -d ' '
}

# One build: AWS packages live in the normal dependency graph.
grep -Fq '{aws, "1.3.2", {pkg, aws_erlang}}' "$base_rebar" ||
  fail "aws_erlang missing from normal dependency graph"
grep -Fq '{aws_credentials, "1.0.4"}' "$base_rebar" ||
  fail "aws_credentials missing from normal dependency graph"

if grep -R -n \
    --exclude-dir=_build \
    --exclude-dir=.git \
    --exclude=check-nsecbunker-aws-invariants.sh \
    'DAMAGE_AWS_BUILD' \
    "$root/rebar.config" \
    "$root/apps" \
    "$root/config" \
    "$root/doc" 2>/dev/null; then
  fail "separate AWS build switch remains"
fi

# The production provider uses normal static SDK calls.
[[ "$(count_fixed 'aws_credentials:get_credentials' "$src")" == "1" ]] ||
  fail "expected one aws_credentials:get_credentials call"
[[ "$(count_fixed 'aws_secrets_manager:get_secret_value' "$src")" == "1" ]] ||
  fail "expected one Secrets Manager GetSecretValue call"

if grep -R --include='*.erl' -n 'apply(aws_' "$src"; then
  fail "dynamic AWS SDK dispatch remains"
fi

# One local secret-store boundary.
[[ "$(count_fixed 'secrets:retrieve_decrypt' "$src")" == "1" ]] ||
  fail "expected one secrets:retrieve_decrypt boundary"

grep -Fq 'secrets:retrieve_decrypt' \
  "$src/damage_nsecbunker_local_secret_provider.erl" ||
  fail "local secret lookup is not owned by local provider"

# Local and managed transports each have one owner; facades have none.
[[ "$(grep -Fc 'open_port({spawn_executable' \
      "$src/damage_nsecbunker_legacy_backend.erl" || true)" == "1" ]] ||
  fail "legacy backend must own exactly one one-shot port"
[[ "$(grep -Fc 'open_port({spawn_executable' \
      "$src/damage_nsecbunker_port.erl" || true)" == "1" ]] ||
  fail "managed backend must own exactly one persistent port"

if grep -n 'open_port' \
    "$src/damage_nsecbunker_vault.erl" \
    "$src/damage_nsecbunker_ops.erl"; then
  fail "transport leaked back into vault/ops facade"
fi

# Managed custody cannot downgrade or choose trusted modules from sys.config.
if grep -n 'damage_nsecbunker_local_secret_provider' \
    "$src/damage_aws_secret_provider.erl"; then
  fail "AWS provider contains a local fallback"
fi

if grep -nE \
    'maps:get\((backend_module|backend_owner|secret_provider_module)' \
    "$src/damage_nsecbunker_secret_owner.erl" \
    "$src/damage_nsecbunker_sup.erl"; then
  fail "production custody module remains runtime-configurable"
fi

if grep -n 'aws_secret_bootstrap' \
    "$src/damage_nsecbunker_secret_owner.erl" \
    "$src/damage_aws_secret_provider.erl"; then
  fail "old aws_secret_bootstrap runtime wiring remains"
fi

grep -Fq '{secret_provider, aws_secrets_manager}' "$aws_config" ||
  fail "AWS provider is not explicit in config fragment"
grep -Fq '{aws_secret, [' "$aws_config" ||
  fail "AWS settings are not nested under aws_secret"

if grep -Eq \
    'aws_secret_bootstrap|backend_owner|backend_module|secret_provider_module|version_stage|credential_source|require_imdsv2' \
    "$aws_config"; then
  fail "implementation invariants leaked into deployment config"
fi

# Framed C protocol and secret hygiene.
grep -Fq 'DAMAGE_FRAME_OPERATION_RESPONSE' "$main_c" ||
  fail "framed C protocol missing"

if grep -R --include='*.erl' -q \
    'phase4b-bdd-production-passphrase' "$src"; then
  fail "production passphrase literal remains"
fi

if grep -n 'DAMAGE_NSECBUNKER_VAULT_PASSPHRASE' \
    "$src/damage_nsecbunker_secret_owner.erl"; then
  fail "managed secret owner uses environment passphrase transport"
fi

grep -Fq '"DAMAGE_NSECBUNKER_VAULT_PASSPHRASE"' \
  "$src/damage_aws_secret_provider.erl" ||
  fail "AWS provider no longer rejects environment passphrase override"

echo "nsecbunker single-build AWS/provider invariants: ok"
