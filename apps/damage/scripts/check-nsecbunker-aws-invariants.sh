#!/usr/bin/env bash
set -euo pipefail

root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
src="$root/apps/damage/src"
main_c="$root/priv/crypto/damage-nsecbunker-crypto-c/src/main.c"
base_rebar="$root/rebar.config"
aws_config="$root/config/sys.config.aws.production.fragment.config"


# Optional rendered deployment configuration.
#
# Source validation accepts placeholders in the checked-in template.
# Deployment validation must pass the rendered production config explicitly:
#
#   check-nsecbunker-aws-invariants.sh /repo /etc/damage/sys.config
deployment_aws_config="${2:-}"

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

# One local secret-store boundary inside the nsecbunker subsystem.
#
# The rest of Damage legitimately has other secret consumers, so do not
# enforce a repository-wide count here.
nsecbunker_sources=(
  "$src"/damage_nsecbunker*.erl
  "$src"/damage_aws_secret_provider.erl
)

[[ "$(count_fixed \
      'secrets:retrieve_decrypt' \
      "${nsecbunker_sources[@]}")" == "1" ]] ||
  fail "expected exactly one nsecbunker secrets:retrieve_decrypt boundary"

grep -Fq 'secrets:retrieve_decrypt' \
  "$src/damage_nsecbunker_local_secret_provider.erl" ||
  fail "local secret lookup is not owned by local provider"

if grep -Fq \
    'secrets:retrieve_decrypt' \
    "$src/damage_aws_secret_provider.erl"; then
  fail "AWS provider accesses the local Damage secret store"
fi

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
grep -Fq '{vault_mode, open_existing}' "$aws_config" ||
  fail "AWS production config must explicitly use open_existing"

grep -Fq '{bunker_pubkey_hex,' "$aws_config" ||
  fail "AWS production config must pin bunker_pubkey_hex"

if grep -Eq \
    'aws_secret_bootstrap|backend_owner|backend_module|secret_provider_module|version_stage|credential_source|require_imdsv2' \
    "$aws_config"; then
  fail "implementation invariants leaked into deployment config"
fi

# When a rendered production configuration is supplied, enforce deployable
# identity values rather than merely checking the source template structure.
if [[ -n "$deployment_aws_config" ]]; then
  [[ -f "$deployment_aws_config" ]] ||
    fail "rendered deployment config not found: $deployment_aws_config"

  grep -Fq '{secret_provider, aws_secrets_manager}' \
    "$deployment_aws_config" ||
    fail "rendered config does not select aws_secrets_manager"

  grep -Fq '{vault_mode, open_existing}' \
    "$deployment_aws_config" ||
    fail "rendered config must explicitly use open_existing"

  if grep -Fq \
      'REPLACE_WITH_64_CHARACTER_HEX_BUNKER_PUBLIC_KEY' \
      "$deployment_aws_config"; then
    fail "rendered config still contains placeholder bunker_pubkey_hex"
  fi

  grep -Eq \
    '\{bunker_pubkey_hex,[[:space:]]*"[0-9A-Fa-f]{64}"\}' \
    "$deployment_aws_config" ||
    fail "rendered bunker_pubkey_hex must be exactly 64 hexadecimal characters"
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
