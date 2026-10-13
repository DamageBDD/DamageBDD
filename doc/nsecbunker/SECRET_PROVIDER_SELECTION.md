# Nsecbunker secret-provider selection

The nsecbunker chooses custody from configuration. It never probes the host and
silently changes providers.

Damage uses one release artifact and one dependency graph. AWS SDK packages are
part of the release, but AWS applications and the managed secret owner are used
only when `aws_secrets_manager` is explicitly selected.

## Local/default provider

`local` is the compatibility default:

```erlang
{secret_provider, local}
```

Omitting `secret_provider` also resolves to `local`.

The local path:

- retrieves the named passphrase through
  `damage_nsecbunker_local_secret_provider`;
- delegates one-shot C transport to `damage_nsecbunker_legacy_backend`;
- starts no managed secret owner;
- performs no IMDS, STS, or Secrets Manager request.

## AWS-managed provider

Select AWS explicitly:

```erlang
{secret_provider, aws_secrets_manager},

{aws_secret, [
    {region, "ap-southeast-2"},
    {secret_id, "/damage/prod/nsecbunker/vault-passphrase"},
    {expected_account_id, "123456789012"},
    {expected_role_name, "damage-node-prod"}
]}
```

The AWS path enforces these invariants in code:

- credentials come from `aws_credentials_ec2`;
- alternate/static credential sources are rejected;
- IMDSv2 token acquisition must succeed;
- STS account and assumed-role identity must match configuration;
- only a non-empty `AWSCURRENT` SecretString is accepted.

These are not runtime configuration knobs.

## Downgrade rule

Fallback is a provider-selection decision, never error recovery:

- `local` selected -> use local custody;
- `aws_secrets_manager` selected -> any AWS/bootstrap failure is fatal to
  managed custody and the vault remains sealed;
- an AWS failure never retries through the local secret provider.


## Reload rule
A provider change changes the supervisor child set and requires restart.

Same-provider reload remains supported:


- local -> local rebuilds the local vault facade;
- AWS -> AWS transactionally bootstraps and validates a replacement backend
  before replacing the active backend.
