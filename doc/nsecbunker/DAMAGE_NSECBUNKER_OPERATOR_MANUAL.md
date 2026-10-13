# Damage nsecbunker Operations Manual

## 1. Purpose

This manual describes how to operate `nsecbunker` on a Damage node.

`nsecbunker` is a supervised NIP-46 signer running inside the existing `damage` OTP application. It uses a process-isolated C crypto backend for key generation, vault access, Nostr event signing, and NIP-44 operations.

The operator goal is simple:

- deploy the release,
- verify the crypto backend,
- create a disposable rehearsal identity,
- create the production node identity,
- update `sys.config` with public identity material,
- verify runtime status,
- enable relay handling only after local verification passes,
- export only public custody material.

This manual assumes the current implementation uses:

```text
/opt/damage
/opt/damage/bin/damage
/opt/damage/bin/damage-nsecbunker-crypto-c
/var/lib/damage/nsecbunker
/var/log/damage/nsecbunker_audit.log
```

---

## 2. Custody rules

The private key must never leave the encrypted vault boundary.

Never print, paste, commit, upload, log, or send:

```text
nsec
private key
secret key
seed
mnemonic
vault passphrase
raw vault file
```

Allowed public material:

```text
pubkey_hex
npub
relay URLs
allowed methods
allowed event kinds
backend binary hash
verification report URLs
verification hashes
run IDs
transaction hashes
public recovery statement
```

The signing decision and relay publication are separate responsibilities:

```text
The bunker decides whether to sign.
The relay layer publishes.
Relay publication success or failure must not change the signing decision.
```

---

## 3. Release layout

Expected release root:

```sh
cd /opt/damage
```

Expected release artifacts:

```text
bin/damage
bin/damage-nsecbunker-crypto-c
lib/
releases/
priv/
doc/nsecbunker/
features/nsecbunker/        # optional; verification may be external
```

Check the release root:

```sh
ls -la /opt/damage
ls -la /opt/damage/bin
ls -la /opt/damage/lib
ls -la /opt/damage/releases
```

The C backend must be executable:

```sh
test -x /opt/damage/bin/damage-nsecbunker-crypto-c && echo ok
```

---

## 4. Host directories and permissions

Create the runtime directories:

```sh
sudo install -d -o damage -g damage -m 0700 /var/lib/damage/nsecbunker
sudo install -d -o damage -g damage -m 0750 /var/log/damage
sudo touch /var/log/damage/nsecbunker_audit.log
sudo chown damage:damage /var/log/damage/nsecbunker_audit.log
sudo chmod 0640 /var/log/damage/nsecbunker_audit.log
```

Verify:

```sh
stat -c '%a %U %G %n' /var/lib/damage/nsecbunker
stat -c '%a %U %G %n' /var/log/damage/nsecbunker_audit.log
```

Expected:

```text
700 damage damage /var/lib/damage/nsecbunker
640 damage damage /var/log/damage/nsecbunker_audit.log
```

---

## 5. Unified `sys.config`

All `nsecbunker` configuration must live under the existing `damage` application environment.

Use this shape:

```erlang
{damage, [
    {nsecbunker, [
        {enabled, true},
        {relay_client_enabled, false},

        {crypto_backend_cmd, "/opt/damage/bin/damage-nsecbunker-crypto-c"},
        {vault_path, "/var/lib/damage/nsecbunker/node_production.vault"},
        {audit_log, "/var/log/damage/nsecbunker_audit.log"},

        {bunker_pubkey_hex, ""},
        {bunker_npub, ""},

        {authorized_clients, [
            "REPLACE_WITH_AUTHORIZED_CLIENT_PUBKEY_HEX"
        ]},

        {allowed_methods, [connect, ping, get_public_key, sign_event]},
        {allowed_kinds, [1, 30023]},

        {relays, [
            "wss://relay.damus.io",
            "wss://relay.primal.net",
            "wss://nos.lol"
        ]},

        {rate_backend, ets},
        {rate_limit, [
            {max_requests, 30},
            {window_seconds, 60}
        ]},

        {limits, [
            {created_at_skew_seconds, 600},
            {max_kind_1_bytes, 4096},
            {max_kind_30023_bytes, 131072},
            {request_timeout_ms, 10000}
        ]},

        {kind_30023, [
            {require_tags, ["d", "title", "published_at"]},
            {reject_html, true}
        ]},

        {genesis, [
            {enabled, false},
            {allowed_content_sha256, []}
        ]}
    ]}
]}.
```

---

## 6. Starting and stopping the node

Start the node with the configured release service, or manually from the release root if needed:

```sh
/opt/damage/bin/damage start
```

Open a remote console:

```sh
/opt/damage/bin/damage remote_console
```

Stop the node:

```sh
/opt/damage/bin/damage stop
```

---

## 7. Release artifact check

From a remote console:

```erlang
damage_nsecbunker_ops:check_release_artifacts("/opt/damage").
```

Expected shape:

```erlang
{ok, _}
```

If the check fails, verify:

```text
/opt/damage/bin/damage-nsecbunker-crypto-c
/opt/damage/doc/nsecbunker
/var/lib/damage/nsecbunker
/var/log/damage/nsecbunker_audit.log
```

---

## 8. Crypto backend checks

From a remote console, check the backend path:

```erlang
damage_nsecbunker_ops:crypto_backend_path().
```

Run the backend boundary smoke check:

```erlang
damage_nsecbunker_ops:smoke_phase2b_crypto_c_backend().
```

Run the vector smoke check:

```erlang
damage_nsecbunker_ops:smoke_phase2c_crypto_vectors().
```

Both should return `{ok, _}` or a success map. If either fails, do not create a production key.

Record the backend binary hash:

```erlang
damage_nsecbunker_ops:lower_hex_sha256_file("/opt/damage/bin/damage-nsecbunker-crypto-c").
```

---

## 9. Disposable rehearsal identity

Always create a disposable identity before creating a production identity.

From the remote console:

```erlang
damage_nsecbunker_ops:phase4a_create_dev_key(#{
    vault_path => "/var/lib/damage/nsecbunker/dev_rehearsal.vault",
    passphrase => "replace-with-disposable-passphrase",
    report_dir => "/opt/damage/doc/nsecbunker/reports",
    reset => true
}).
```

Expected:

```erlang
{ok, Report}
```

The report must contain public values only:

```text
pubkey_hex
npub
vault_path
backend
secret_exported = false
```

Verify the vault is private:

```sh
stat -c '%a %U %G %n' /var/lib/damage/nsecbunker/dev_rehearsal.vault
```

Expected mode should not be world-readable.

Remove the disposable vault only when you no longer need it:

```sh
sudo rm -f /var/lib/damage/nsecbunker/dev_rehearsal.vault
```

---

## 10. Production node identity ceremony

The production ceremony must be deliberate. Confirm before continuing:

- the backend checks pass,
- the disposable rehearsal passes,
- the vault path is correct,
- the passphrase is known only to the operator or approved custody process,
- the terminal session is private,
- logging does not expose secrets,
- relay mode is still disabled.

Set approval in the environment of the running node or pass `approved => true` in the operation options.

Recommended remote console call:

```erlang
damage_nsecbunker_ops:phase4b_create_production_damagebdd_node_key(#{
    prod_vault_path => "/var/lib/damage/nsecbunker/node_production.vault",
    passphrase => "replace-with-production-passphrase",
    report_dir => "/opt/damage/doc/nsecbunker/reports",
    approved => true
}).
```

Expected:

```erlang
{ok, Report}
```

The operation creates or reopens the production vault and writes public-only reports under:

```text
/opt/damage/doc/nsecbunker/reports
```

The report must include:

```text
pubkey_hex
npub
backend_sha256
vault_path
vault_mode_octal
secret_exported = false
```

The report must not contain:

```text
nsec
private_key
secret_key
seed
mnemonic
passphrase
```

Verify the production vault permissions:

```sh
stat -c '%a %U %G %n' /var/lib/damage/nsecbunker/node_production.vault
```

Expected: private to the service user, not world-readable.

---

## 11. Update `sys.config` with public identity

After production identity creation, copy only these public values into `sys.config`:

```erlang
{bunker_pubkey_hex, "<PRODUCTION_PUBKEY_HEX>"},
{bunker_npub, "<PRODUCTION_NPUB>"}
```

Keep relay disabled for the first restart:

```erlang
{enabled, true},
{relay_client_enabled, false}
```

Restart the node:

```sh
/opt/damage/bin/damage stop
/opt/damage/bin/damage start
```

---

## 12. Runtime verification

Open a remote console:

```sh
/opt/damage/bin/damage remote_console
```

Check status:

```erlang
damage_nsecbunker:status().
```

Export public identity:

```erlang
damage_nsecbunker:export_identity().
```

The output must include public identity material only. It must not include private key material, passphrases, seeds, mnemonics, or raw vault bytes.

Check audit log redaction:

```sh
grep -Ein 'nsec|private_key|secret_key|seed|mnemonic|passphrase' /var/log/damage/nsecbunker_audit.log \
  && echo "check audit log" \
  || echo "audit log clean"
```

If the grep reports only safe field names from test data, inspect manually. The audit log must not contain actual secret values.

---

## 13. External verification

Run verification from outside the production Damage runtime. Use CI, an operator workstation, or another verifier.

Generic command shape:

```sh
curl -v --data-binary @<feature-file> \
  -H "Authorization: Bearer $AUTH_TOKEN" \
  https://run.dev.damagebdd.com/execute_feature
```

Recommended verification order:

```text
1. baseline custody contract
2. C backend contract
3. crypto vector contract
4. relay bridge contract with disposable values
5. disposable key rehearsal contract
6. production key ceremony contract
7. final custody export contract
```

Record for each passing run:

```text
feature hash
report URL
run ID
transaction hash
cost/spend
```

Do not run external verification from inside the production node unless explicitly intended by the operator.

---

## 14. Relay enablement

Enable relay handling only after local and external verification pass.

Update `sys.config`:

```erlang
{relay_client_enabled, true}
```

Confirm the relay vector:

```erlang
{relays, [
    "wss://relay.damus.io",
    "wss://relay.primal.net",
    "wss://nos.lol"
]}
```

Restart:

```sh
/opt/damage/bin/damage stop
/opt/damage/bin/damage start
```

Verify status:

```erlang
damage_nsecbunker:status().
```

Relay publication errors must be handled as publication errors, not signing-policy changes.

---

## 15. Public operator handoff record

Create a public record containing only:

```text
node_pubkey_hex: <hex>
node_npub: <npub>
crypto_backend_sha256: <sha256>
vault_path: /var/lib/damage/nsecbunker/node_production.vault
relay_vector:
  - wss://relay.damus.io
  - wss://relay.primal.net
  - wss://nos.lol
allowed_methods:
  - connect
  - ping
  - get_public_key
  - sign_event
allowed_kinds:
  - 1
  - 30023
verification:
  - feature_hash: <hash>
    report: <url>
    run_id: <run id>
    tx_hash: <tx hash>
recovery: privately documented; private key material is not exported
```

Do not include:

```text
vault passphrase
raw vault
nsec
private key
secret key
seed
mnemonic
```

---

## 16. Backup and recovery

Back up the encrypted vault only through the operator’s approved secure backup process.

Minimum backup metadata:

```text
vault file path
backend binary hash
node public key
npub
creation timestamp
operator recovery note
```

Do not place the vault backup in the source repository.

Do not upload the vault backup to public issue trackers, chat, CI logs, or artifact stores.

Recovery test:

1. copy the encrypted vault to a controlled recovery host,
2. install the same or reviewed-compatible C backend,
3. open with the passphrase,
4. confirm `get_public_key` returns the expected pubkey,
5. destroy the recovery copy if it is no longer needed.

---

## 17. Rollback

Rollback should disable signing before replacing binaries or configuration.

Set:

```erlang
{enabled, false},
{relay_client_enabled, false}
```

Restart:

```sh
/opt/damage/bin/damage stop
/opt/damage/bin/damage start
```

Confirm:

```erlang
damage_nsecbunker:status().
```

Then roll back the release package or configuration as needed.

Never delete the production vault during rollback unless the operator has a verified backup and an approved destruction record.

---

## 18. Troubleshooting

### Backend executable missing

Check:

```sh
ls -l /opt/damage/bin/damage-nsecbunker-crypto-c
```

Fix permissions:

```sh
sudo chmod 0755 /opt/damage/bin/damage-nsecbunker-crypto-c
```

### Vault passphrase missing

Production key creation requires a passphrase. Provide it as an option to the Erlang operation or through the approved runtime environment.

Do not put the passphrase in `sys.config`.

### Wrong passphrase

Expected failure shape:

```text
vault open fails
public key cannot be exported
signing fails closed
```

Use the correct passphrase or restore from the approved recovery process.

### Relay failures

Relay failure must not alter signing policy. Check relay connectivity separately from signer decisions.

### Config not loaded

Inspect the runtime config:

```erlang
damage_nsecbunker:config().
```

Confirm the config is under:

```erlang
{damage, [{nsecbunker, [...]}]}
```

---

## 18. Repository safety checks

Before committing operator documentation or config changes:

```sh
git diff --cached --name-only | grep -E '(_build|target|\.vault|\.zip|nsec1|private[_-]?key|secret[_-]?key|passphrase)' \
  && echo "CHECK STAGED FILES BEFORE COMMIT" \
  || echo "staged set looks clean"
```

Never commit:

```text
*.vault
raw vault backups
passphrase files
private key material
compiled local scratch artifacts
operator screenshots containing secrets
```

---

## 19. Final checklist

Before enabling relay mode or publishing the public handoff record:

```text
[ ] release contains /opt/damage/bin/damage-nsecbunker-crypto-c
[ ] runtime directories exist with correct ownership and modes
[ ] sys.config uses {damage, [{nsecbunker, [...]}]}
[ ] relay_client_enabled is false during identity creation
[ ] backend smoke check passes
[ ] vector smoke check passes
[ ] disposable identity rehearsal passes
[ ] production identity ceremony returns public-only report
[ ] production vault is not world-readable
[ ] sys.config contains production pubkey_hex and npub
[ ] damage_nsecbunker:status() is healthy
[ ] damage_nsecbunker:export_identity() returns only public material
[ ] audit log contains no secret values
[ ] external verification passes
[ ] relay mode is enabled only after verification
[ ] public handoff record excludes all secret material
[ ] encrypted vault backup is handled through approved private recovery process
```
