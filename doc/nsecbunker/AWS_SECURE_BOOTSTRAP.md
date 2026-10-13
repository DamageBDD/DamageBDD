# AWS secure bootstrap for the DamageBDD nsecbunker

Production custody uses one supervised `damage_nsecbunker_secret_owner`.
The owner validates IMDSv2, the EC2 credential provider, the STS caller
identity, and the `AWSCURRENT` Secrets Manager value before unlocking one
persistent C backend.

Damage uses the normal release build:

```sh
rebar3 as prod release
```

## Configuration

Merge `config/sys.config.aws.production.fragment.config` into the release
configuration and replace the account, role, region, secret identifier and
paths. AWS settings stay inside the existing `damage / nsecbunker`
configuration boundary.

For an existing node vault use:

```erlang
{vault_mode, open_existing}
```

Use `create_if_missing` only for an explicitly approved initial key ceremony.
After creation, record the exported 64-character hex public key as
`bunker_pubkey_hex` and switch to `open_existing`.

## Production invariants

- `aws_credentials` is forced to `aws_credentials_ec2` with
  `fail_if_unavailable=true`.
- static, profile, container and web-identity credential sources fail startup.
- the C child receives neither AWS credentials nor the vault passphrase in argv
  or its environment.
- the vault path is bound by framed INIT and cannot be selected per operation.
- request IDs correlate operation responses; timeout or caller death destroys
  the persistent port.
- a managed backend failure restarts dependent bunker children under
  `rest_for_one`.
- AWS bootstrap failure never falls back to local custody.

## Validation

```sh
rebar3 compile
rebar3 eunit
rebar3 ct
rebar3 as prod release

apps/damage/scripts/check-nsecbunker-aws-invariants.sh
```

Deployment automation should additionally run:
`apps/damage/scripts/validate-ec2-security.sh`. Application-side token use
proves IMDSv2 compatibility; EC2 control-plane state is the authoritative
proof that `HttpTokens` is `required`.

```sh
apps/damage/scripts/validate-ec2-security.sh
```

Runtime token use proves IMDSv2 compatibility. EC2 control-plane
`HttpTokens=required` is the authoritative proof that tokenless IMDS access is
disabled.

Do not automatically rotate the vault passphrase until an atomic vault
re-encryption ceremony exists.
