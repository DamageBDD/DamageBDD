# DamageBDD secure AWS secret bootstrap

DamageBDD includes a production-only path for retrieving the nsecbunker vault
passphrase from AWS Secrets Manager on an EC2-hosted DamageBDD node.

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


## Deployment order

1. Build the normal production release:

   ```sh
   rebar3 as prod release
   ```

2. Merge `config/sys.config.aws.production.fragment.config` into the release
   configuration.
3. Replace the example AWS region, account, role and secret identifier.
4. For an existing vault, keep `vault_mode` set to `open_existing` and replace
   the example `bunker_pubkey_hex` with the approved 64-character identity.
5. Use `create_if_missing` only for an explicitly approved initial key
   ceremony.
6. After an initial ceremony, record the exported bunker public key and return
   the deployment configuration to `open_existing`.
7. Deploy the EC2 instance profile and launch template from `infra`.
8. Run:

   # Source/security-boundary invariants.
   ```sh
   apps/damage/scripts/check-nsecbunker-aws-invariants.sh

   # Validate the rendered production configuration. Replace the second
   # argument with the actual deployed sys.config path.
   apps/damage/scripts/check-nsecbunker-aws-invariants.sh \
       "$(pwd)" \
       /etc/damage/sys.config

   # Validate EC2/IAM/IMDS control-plane settings.
   apps/damage/scripts/validate-ec2-security.sh
   ```
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

The AWS provider, managed OTP secret owner and packet-framed C transport are
part of the normal Damage source and release build.

Production deployment still requires successful Erlang and C compilation,
EUnit/common-test coverage, the source invariant scan, and EC2 control-plane
validation.

Selecting `aws_secrets_manager` alone is not proof that the deployment meets
the production custody requirements.
