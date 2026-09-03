# DamageBDD

**Behaviour verification at planetary scale.**

DamageBDD is an Erlang/OTP platform for expressing expected software behaviour in human-readable [Gherkin](https://cucumber.io/docs/gherkin/) and verifying that behaviour across APIs, browsers, infrastructure, distributed systems, and blockchain-connected services.

A feature file can be written by product, support, QA, operations, security, or development teams. The same feature can then be used for functional verification, scheduled regression, and controlled concurrent execution without replacing the business-readable specification with test-tool code.

- Website: <https://damagebdd.com/>
- Hosted dashboard: <https://run.damagebdd.com/>
- Manual: <https://damagebdd.com/manual>
- Module reference: <https://damagebdd.com/modules/>
- Live step catalogue: <https://run.damagebdd.com/steps.yaml>
- Installation guide: [INSTALL.md](INSTALL.md)
- Docker full-stack guide: <https://damagebdd.com/docker.html>
- Security policy: [SECURITY.txt](SECURITY.txt)

## What DamageBDD provides

The current codebase includes:

- Gherkin feature parsing and parameterised step matching.
- HTTP/API verification with request headers, cookies, authentication, JSONPath/YAML assertions, polling, and TLS controls.
- Browser and UI verification through the available WebDriver/CDP-oriented step modules.
- Concurrent execution for authorised targets, plus dry-run cost calculation before a paid run.
- Scheduled regression, reports, webhooks, and execution metadata.
- IPFS-backed reports and execution of feature files referenced by CID.
- DAMAGE and Aeternity account integration, Lightning-related flows, and L402 challenge support.
- Build and runtime identity through the public version endpoint.
- Optional Nostr capabilities, including NIP-46 policy guards and NIP-47/Nostr Wallet Connect components.
- Optional hybrid post-quantum secret envelopes when a PQC backend is configured.

Some integrations are configuration-dependent or still evolving. Treat payment, custody, distributed execution, browser automation, and advanced Nostr features as operator-managed capabilities and validate them in a staging environment before production use.

## Hosted quick start

### 1. Create and confirm an account

The simplest route is the hosted dashboard at <https://run.damagebdd.com/>.

Account creation is also available through the API:

```bash
curl --fail-with-body \
  -X POST 'https://run.damagebdd.com/accounts/create' \
  -H 'content-type: application/json' \
  --data '{"email":"you@example.com","full_name":"Example User"}'
```

Open the confirmation link sent by the server and set a password. Passwords must contain at least eight characters, including uppercase, lowercase, numeric, and special characters.

### 2. Obtain a bearer token

```bash
export DAMAGEBDD_URL='https://run.damagebdd.com'
export DAMAGEBDD_EMAIL='you@example.com'

read -r -s -p 'DamageBDD password: ' DAMAGEBDD_PASSWORD
printf '\n'

export DAMAGEBDD_TOKEN="$(
  jq -n \
    --arg username "$DAMAGEBDD_EMAIL" \
    --arg password "$DAMAGEBDD_PASSWORD" \
    '{username:$username,password:$password}' \
  | curl --fail-with-body --silent --show-error \
      -X POST "$DAMAGEBDD_URL/accounts/auth/" \
      -H 'content-type: application/json' \
      --data-binary @- \
  | jq -r '.access_token'
)"
unset DAMAGEBDD_PASSWORD

test -n "$DAMAGEBDD_TOKEN" && test "$DAMAGEBDD_TOKEN" != 'null'
```

Keep the token private. A browser login may also set an access cookie.

### 3. Write a feature

Create `smoke.feature`:

```gherkin
Feature: DamageBDD public API smoke test

  Scenario: Read the running build identity
    Given I am using server "https://run.damagebdd.com"
    When I make a GET request to "/api/version"
    Then the response status must be "200"
    Then the response must contain text "git_sha"
```

### 4. Execute the feature

```bash
curl --fail-with-body --no-buffer \
  -X POST "$DAMAGEBDD_URL/execute_feature/" \
  -H "authorization: Bearer $DAMAGEBDD_TOKEN" \
  -H 'content-type: text/plain' \
  -H 'x-damage-concurrency: 1' \
  --data-binary @smoke.feature
```

DamageBDD performs a dry run before a paid execution. The account must have sufficient execution balance, or the node must be configured for the applicable Lightning/L402 flow. Concurrent load execution can require target-domain authorisation.

## Run a Damage Node

### Install a package

Use the current installer page rather than copying a versioned package filename from documentation:

<https://damagebdd.com/node>

The packaged release is named **`damage`**, uses the **`damage.service`** systemd unit, and stores its primary configuration at:

```text
/etc/damage/damage.config
```

After installation:

```bash
sudo systemctl status damage --no-pager
curl --fail-with-body http://127.0.0.1:4888/api/version | jq
```

See [INSTALL.md](INSTALL.md) for package paths, source builds, macOS/WSL2 notes, systemd operation, Nginx/TLS, upgrades, backups, and troubleshooting.

### Run from source

The current release-build baseline is Erlang/OTP 28 with rebar3 3.26.0. Install the native dependencies listed in [INSTALL.md](INSTALL.md), then:

```bash
git clone https://github.com/DamageBDD/DamageBDD.git
cd DamageBDD

test -f config/sys.config || cp config/sys.config.sample config/sys.config
# Review config/sys.config before starting. In particular, use writable
# data/log paths and replace example integration values.

rebar3 compile
rebar3 shell
```

The shell profile loads `config/sys.config`.

Build a self-contained production release with its own Erlang runtime:

```bash
rebar3 as prod release
```

CUDA is optional and is deliberately excluded from the normal/default production build. Enable it explicitly only on a configured CUDA host:

```bash
rebar3 as prod,cuda release
```

## Runtime configuration

DamageBDD uses Erlang `sys.config` syntax. The application key is **`damage`**, not `damagebdd`.

A minimal package-compatible configuration is:

```erlang
%%% /etc/damage/damage.config
[
    {
        damage,
        [
            {ip, {127, 0, 0, 1}},
            {port, 4888},
            {api_url, "http://127.0.0.1:4888"},
            {data_dir, "/var/lib/damage/"},
            {node_admins, []}
        ]
    }
].
```

Important rules:

- Keep `{ip, {127, 0, 0, 1}}` when Nginx or another reverse proxy fronts the node.
- Set `{ip, {0, 0, 0, 0}}` only when direct network exposure is intentional and protected by firewall policy.
- Set `api_url` to the externally reachable HTTPS origin when account email links or browser sessions are used.
- Add only trusted Aeternity accounts to `node_admins`; they receive node-administration authority.
- File logging is configured under the `kernel` logger section in `sys.config`. It is not controlled by a `log_dir` key in the `damage` application block.
- The complete reference configuration is `config/sys.config.sample` in the repository.

## Encrypted secrets

Integration credentials belong in the encrypted secrets store, not in source control or plaintext `sys.config` values.

Open an Erlang shell or a running release console. For the standard integrations, start the masked interactive setup:

```erlang
damage:check_setup().
```

You can also store individual credentials directly when required:

```erlang
secrets:encrypt_store(bitcoin_rpc_password, "REPLACE_ME").
secrets:encrypt_store(nostr_nsec, "nsec1_REPLACE_ME").
secrets:encrypt_store(smtp_pass, "REPLACE_ME").
secrets:encrypt_store(cln_rune, "REPLACE_ME").
secrets:encrypt_store(lnd_macaroon, "REPLACE_ME").
```

The current SMTP key is **`smtp_pass`**. Do not use the obsolete `smtp_password` name from older documentation. Literal secret values entered at a console may be retained in shell history; use the masked setup flow where possible and securely clear any persistent history.

For the NWC service identity, deployments may also require:

```erlang
secrets:encrypt_store(damage_nostr_nsec, "nsec1_REPLACE_ME").
```

Create supporting credentials with the upstream tools where applicable:

```bash
# Bitcoin Core rpcauth helper
python3 ./bin/bitcoin_rpcauth.py

# Core Lightning restricted rune
lightning-cli createrune
```

## Useful endpoints

| Endpoint | Authentication | Purpose |
|---|---:|---|
| `GET /api/version` | Public | Application version, Git SHA, build time/environment, OTP and ERTS versions. |
| `GET /api/node/balances` | Public | Node public key plus configured DAMAGE, AE, and BTC balances. Restrict at the proxy if this metadata should not be public. |
| `POST /accounts/create` | Public | Begin email account registration. |
| `POST /accounts/auth/` | Public | Authenticate and receive an access token. |
| `POST` or `PUT /execute_feature/` | Bearer, wallet, or configured L402 path | Execute inline Gherkin. |
| `PUT /execute_feature_from_ipfs/` | Bearer, wallet, or configured L402 path | Fetch and execute a feature by `feature_cid`; optional `vars` are merged into context. |
| `GET /steps.yaml` | Public | Current step catalogue for the running node. |

Example IPFS execution request:

```bash
curl --fail-with-body \
  -X PUT "$DAMAGEBDD_URL/execute_feature_from_ipfs/" \
  -H "authorization: Bearer $DAMAGEBDD_TOKEN" \
  -H 'content-type: application/json' \
  --data '{
    "feature_cid": "bafy...",
    "vars": {"environment": "staging"}
  }'
```

## Build identity

Never rely on a version copied from a README. Ask the running node:

```bash
curl --fail-with-body http://127.0.0.1:4888/api/version | jq
```

A successful response includes the application version, full and short Git SHA, build timestamp, build environment, OTP release, and ERTS version.

## Advanced optional components

### L402

Protected execution routes can issue an L402 payment challenge when normal authentication is absent and the node has an `l402_account` and Lightning integration configured. The challenge can be priced from the feature dry run. Treat L402 as an explicit deployment choice rather than an automatic replacement for account authentication.

### Nostr Wallet Connect (NIP-47)

The current tree contains authenticated APIs for minting and revoking NWC connections, listing sessions, reading ledger balances, and managing top-ups. The request handler implements `get_info`, `get_balance`, `pay_invoice`, `make_invoice`, `lookup_invoice`, and `list_transactions` paths. Explicitly review the ledger mode, relay allowlist, signing authority, and Lightning backend before enabling NWC.

### NIP-46 custody controls

The NIP-46 policy layer includes vault-readiness checks, client/method/kind allowlists, stale-event and size limits, required tags, active-content rejection, replay detection, rate limiting, signing timeouts, and deterministic redacted audit records. These controls are fail-closed prerequisites; they do not remove the need for secure key generation, vault operation, monitoring, backup, and incident response.

### Post-quantum secret envelopes

`secrets_pqc` implements a hybrid ML-KEM/AES-256-GCM envelope, but it requires a configured `pqc_backend_module`. Baseline node installation does not require PQC support.

## Security baseline

- Bind the node to loopback and expose it through a maintained TLS reverse proxy.
- Never expose EPMD (`4369`) or Erlang distribution ports to the public Internet.
- Run the release as the dedicated `damage` system user.
- Keep `/etc/damage` root-managed; grant the service only the state, log, and release paths it needs.
- Keep secrets out of Git, shell history, process arguments, and static environment files.
- Use a firewall, reverse-proxy rate limits, and resource limits.
- Back up the configuration, encrypted secret store, node identity, and required state before upgrades.
- Review access to `/api/node/balances`, because it is intentionally public in the current HTTP resource.
- Report vulnerabilities privately as described in [SECURITY.txt](SECURITY.txt) or at <https://damagebdd.com/security/>.

## Development

Before opening a pull request:

```bash
rebar3 compile
rebar3 eunit
rebar3 ct
```

The build runs a check that rejects unsafe catch-all step definitions. New Gherkin steps should use explicit, parameterised patterns so dry-run validation can identify unsupported behaviour before execution.

## License

DamageBDD is licensed under the [Apache License 2.0](LICENSE). The original runner was inspired by [behave](https://github.com/behave/behave).
