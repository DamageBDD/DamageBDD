# DamageBDD secure AWS secret bootstrap

This bundle implements a production-only path for retrieving the nsecbunker
vault passphrase from AWS Secrets Manager on an EC2-hosted DamageBDD node.

## Security properties

- The only credential provider is `aws_credentials_ec2`.
- Long-lived or operator-supplied AWS credentials are rejected.
- An explicit IMDSv2 token exchange validates the expected instance role.
- STS validates the account and assumed-role identity before secret retrieval.
- Only a non-empty `SecretString` carrying `AWSCURRENT` is accepted.
- There is no production fallback to an environment variable, local secret
  store, prompt, literal default, or BDD context value.
- A single OTP process owns secret retrieval and the crypto backend port.
- The passphrase is sent once over a private packet-framed stdin channel.
- The passphrase is absent from argv, child environment, JSON operations,
  application state after unlock, reports, logs, and status output.
- Any AWS, identity, metadata, or backend failure leaves the vault sealed.

## Integration order

1. Merge `rebar.config.fragment` and the production `sys.config` fragment.
2. Add the Erlang modules under `apps/damage/src`.
3. Integrate `priv/crypto/damage_secure_port_protocol.c` and the secure
   backend-loop example into the C crypto backend, following
   `docs/secure-backend-protocol.md`.
4. Start `damage_nsecbunker_secret_owner` before `damage_nsecbunker`.
5. Apply the semantic changes in `patches/integration.patch`.
6. Deploy the instance profile and launch template from `infra`.
7. Run `scripts/validate-ec2-security.sh` from deployment automation.
8. Execute the DamageBDD feature in `features`.

## Required production removals

Delete every production path that reads
`DAMAGE_NSECBUNKER_VAULT_PASSPHRASE`, supplies a built-in passphrase, stores a
passphrase in an options/context map, or forwards the passphrase through
`open_port` environment options. Development-only disposable fixtures must be
separated by an explicit non-production mode branch.

## Rotation

Do not automatically rotate an encryption passphrase for an existing vault.
Rotation requires a deliberate migration that opens the vault with the old
version, re-encrypts it with the new version, verifies the result, and only then
retires the old version.

## Validation status

The JSON, YAML, shell, configuration fragments, and forbidden-name scan can be
validated independently. The Erlang modules must still be compiled and tested
inside the actual DamageBDD checkout, and the C backend must implement the
framed protocol before the production path can be considered complete.
