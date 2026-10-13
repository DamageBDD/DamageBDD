# DamageBDD

**Behaviour verification at planetary scale.**

DamageBDD is an Erlang/OTP platform for describing expected software behaviour in human-readable [Gherkin](https://cucumber.io/docs/gherkin/) and verifying it across APIs, browsers, infrastructure, distributed systems, and blockchain-connected services.

The same feature file can be reviewed by product, support, QA, operations, security, and development teams, then reused for functional verification, scheduled regression, and controlled load execution.

- Website: <https://damagebdd.com/>
- Hosted dashboard: <https://run.damagebdd.com/>
- Manual: <https://damagebdd.com/manual>
- Module reference: <https://damagebdd.com/modules/>
- Live hosted step catalogue: <https://run.damagebdd.com/steps.yaml>
- Installation and operations guide: [INSTALL.md](INSTALL.md)
- Reference runtime configuration: [`config/sys.config.sample`](config/sys.config.sample)
- Docker guide: <https://damagebdd.com/docker.html>
- Security policy: [SECURITY.txt](SECURITY.txt)

## What DamageBDD provides

The current codebase includes:

- Gherkin feature parsing, scenario execution, parameterised steps, and dry-run validation.
- HTTP/API verification with headers, cookies, authentication, JSONPath/YAML assertions, polling, and TLS controls.
- Browser and UI verification through the available WebDriver/CDP-oriented step modules.
- Controlled concurrent execution for authorised targets.
- Scheduled regression, reports, webhooks, and execution metadata.
- IPFS-backed reports and feature execution from a CID.
- DAMAGE and Aeternity account integration.
- Optional Bitcoin, Lightning, L402, Nostr, NIP-46, and NIP-47/Nostr Wallet Connect components.
- Runtime/build identity through the public version endpoint.
- Optional hybrid post-quantum secret envelopes when a compatible backend is configured.

Payment, custody, distributed execution, browser automation, and advanced Nostr capabilities are operator-managed security boundaries. Validate them in a staging environment before production use.

## Hosted quick start

### 1. Create and confirm an account

The simplest route is the hosted dashboard:

<https://run.damagebdd.com/>

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

Keep the token private. A browser login may also establish an authenticated session cookie.

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

DamageBDD performs a dry run before a paid execution. The account must have sufficient execution balance, or the node must be configured for the applicable payment flow. Concurrent load execution can also require target-domain authorisation.

## Run a Damage node

### Install a package

Use the current package page rather than copying a versioned package filename from documentation:

<https://damagebdd.com/node>

The packaged release is named **`damage`**. Its canonical layout is:

| Purpose | Path or name |
|---|---|
| Release | `/opt/damage` |
| Executable | `/opt/damage/bin/damage` |
| Configuration | `/etc/damage/damage.config` |
| Optional environment file | `/etc/default/damage` |
| State | `/var/lib/damage` |
| Logs | `/var/log/damage` |
| Service | `damage.service` |
| Service account | `damage:damage` |

After installation:

```bash
sudo systemctl enable --now damage
sudo systemctl status damage --no-pager
curl --fail-with-body http://127.0.0.1:4888/api/version | jq
```

See [INSTALL.md](INSTALL.md) for operating-system prerequisites, source builds, systemd, Nginx/TLS, integration setup, upgrades, backup, and troubleshooting.

### Run from source

The current release-build baseline is Erlang/OTP **28** with rebar3 **3.26.0**. Install the native dependencies listed in [INSTALL.md](INSTALL.md), then:

```bash
git clone https://github.com/DamageBDD/DamageBDD.git
cd DamageBDD

cp config/sys.config.sample config/sys.config
# Review config/sys.config before starting. For a non-root checkout, replace
# /var/lib/damage and /var/log/damage with writable development paths.

rebar3 compile
rebar3 shell
```

The shell profile loads `config/sys.config`.

Build a self-contained production release with its own Erlang runtime:

```bash
rebar3 as prod release
```

Platform-specific release profiles are also available:

```bash
rebar3 as linux,prod release
rebar3 as mac,prod release
```

CUDA support is optional and is not required for a normal node:

```bash
rebar3 as prod,cuda release
```

Use the CUDA profile only after installing and validating a compatible CUDA toolkit and `nvcc`.

## Runtime configuration

DamageBDD uses Erlang `sys.config` syntax. The application key is **`damage`**, not `damagebdd`.

Use the supplied reference as the starting point:

```bash
# Source checkout
cp config/sys.config.sample config/sys.config

# Packaged/manual systemd installation
sudo install -m 0644 \
  config/sys.config.sample \
  /etc/damage/damage.config
```

The release loads the packaged configuration with:

```text
/opt/damage/bin/damage foreground -config /etc/damage/damage.config
```

### Important syntax rules

A `sys.config` file is one Erlang term: a list of `{Application, Options}` tuples terminated with a period.

```erlang
[
    {
        damage,
        [
            {ip, {127, 0, 0, 1}},
            {port, 4888},
            {api_url, "http://127.0.0.1:4888"},
            {data_dir, "/var/lib/damage/"},
            {feature_dirs, ["./features/"]},
            {node_admins, []}
        ]
    }
].
```

The file does **not** interpolate `${ENVIRONMENT_VARIABLES}`. `/etc/default/damage` can supply process environment variables only to code that explicitly reads them; it does not transform arbitrary placeholders inside `damage.config`.

Validate the syntax before restarting a node:

```bash
ERL_BIN="$(
  command -v erl 2>/dev/null \
  || find /opt/damage -type f -path '*/bin/erl' -print -quit 2>/dev/null
)"
test -n "$ERL_BIN" && test -x "$ERL_BIN"

"$ERL_BIN" -noshell -eval '
Path = "/etc/damage/damage.config",
case file:consult(Path) of
    {ok, [Config]} when is_list(Config) ->
        io:format("valid sys.config: ~s~n", [Path]),
        halt(0);
    Error ->
        io:format("invalid sys.config: ~p~n", [Error]),
        halt(1)
end.'
```

### Safe defaults in the sample

The updated sample intentionally starts conservatively:

- The DamageBDD HTTP listener binds to `127.0.0.1:4888`.
- `strict_no_catchall` is enabled.
- `node_admins` and `cmd_allowed` are empty.
- `cookie_secure` is false only for local HTTP; set it to true with production HTTPS.
- Outbound proxying is disabled, while local service names are on the bypass list.
- CLN startup is explicitly disabled until its endpoint, certificates, and encrypted rune are configured.
- SSH Git and SSH tunnel services are disabled.
- NIP-46 nsecbunker custody and relay publication are disabled.
- NWC ledger mode is explicitly `operator_signed`, avoiding the omission fallback to `server_signed`; this is not a global NWC disable switch.
- External daemons are not auto-started through `abduco_workers`; operate Kubo, browsers, Bitcoin, and Lightning through systemd or containers.

### Settings to review before production

At minimum, review:

| Setting | Production decision |
|---|---|
| `api_url` | Set the exact externally reachable HTTPS origin. |
| `ip` and `port` | Keep loopback behind a reverse proxy; expose directly only with deliberate firewall policy. |
| `cookie_secure` | Set `true` once the public origin is HTTPS. |
| `data_dir`, `keystore`, logger paths | Use persistent, permission-controlled storage and include it in backups. |
| `ae_network_id`, `ae_nodes`, `ae_mdw_nodes`, `ae_mdw_ws_nodes` | Keep all endpoints on the same Aeternity network and configure fallbacks. |
| `node_admins` | Add only explicitly trusted Aeternity accounts. |
| `pools` | Size after measuring CPU, memory, browser, file-descriptor, and upstream capacity. |
| `smtp_*` | Configure a real mail transport before enabling email account flows. |
| `nostr_relays` | Review relay trust, availability, privacy, and proxy policy. |
| `nwc_ledger_mode` | Change only after reviewing custody, contract authority, and signing behaviour. |
| `nsecbunker` | Leave disabled until a complete vault ceremony, policy, audit, and recovery process exists. |

The Aeternity node and middleware lists are required by the current application startup. The sample uses public mainnet endpoints; replace all related values together when running against another network or local stack.

File logging is configured under the `kernel` application. There is no generic `log_dir` key in the `damage` application block.

## Encrypted secrets

Passwords and private key material belong in the encrypted secret store, not in Git, `sys.config`, container images, or long-lived service environment files.

In an Erlang shell, the standard masked setup flow is:

```erlang
damage:check_setup().
```

It checks or prompts for the standard integration secrets. Individual values can also be stored directly:

```erlang
secrets:encrypt_store(bitcoin_rpc_password, "REPLACE_ME").
secrets:encrypt_store(nostr_nsec, "nsec1_REPLACE_ME").
secrets:encrypt_store(smtp_pass, "REPLACE_ME").
secrets:encrypt_store(cln_rune, "REPLACE_ME").
secrets:encrypt_store(lnd_macaroon, "REPLACE_ME").
```

The current SMTP secret key is **`smtp_pass`**. Older examples using `smtp_password` are obsolete.

NWC deployments may also require a dedicated service identity:

```erlang
secrets:encrypt_store(damage_nostr_nsec, "nsec1_REPLACE_ME").
```

Create supporting credentials with their upstream tools where applicable:

```bash
# Bitcoin Core rpcauth helper
python3 ./bin/bitcoin_rpcauth.py

# Review the rune syntax supported by the installed CLN version.
# Then create a least-privilege rune limited to the RPC methods DamageBDD needs.
lightning-cli help createrune
```

Do not paste real secret values into tickets, logs, screenshots, shell history, or feature reports.

## Validate a local node

Use the version endpoint as the primary process/build probe:

```bash
curl --fail-with-body http://127.0.0.1:4888/api/version | jq
```

Do not use `/health`; it is not the current canonical probe.

Inspect the live step catalogue:

```bash
curl --fail-with-body http://127.0.0.1:4888/steps.yaml | less
```

Create a local smoke feature:

```gherkin
Feature: Local DamageBDD smoke test

  Scenario: Read node version
    Given I am using server "http://127.0.0.1:4888"
    When I make a GET request to "/api/version"
    Then the response status must be "200"
    Then the response must contain text "git_sha"
```

Authenticated execution:

```bash
curl --fail-with-body --no-buffer \
  -X POST 'http://127.0.0.1:4888/execute_feature/' \
  -H "authorization: Bearer $DAMAGEBDD_TOKEN" \
  -H 'content-type: text/plain' \
  -H 'x-damage-concurrency: 1' \
  --data-binary @smoke.feature
```

## Useful endpoints

| Endpoint | Authentication | Purpose |
|---|---:|---|
| `GET /version/` | Public | Compatibility alias for build/runtime identity. |
| `GET /api/version` | Public | Application version, Git SHA, build time/environment, OTP and ERTS versions. |
| `GET /api/node/balances` | Public | Node public key plus configured DAMAGE, AE, and BTC balances. Restrict at the proxy when this metadata should not be public. |
| `POST /accounts/create` | Public | Begin email account registration. Requires working SMTP for confirmation. |
| `POST /accounts/auth/` | Public | Authenticate and receive an access token. |
| `POST` or `PUT /execute_feature/` | Bearer, wallet, or configured L402 path | Execute inline Gherkin. |
| `PUT /execute_feature_from_ipfs/` | Bearer, wallet, or configured L402 path | Fetch and execute a feature by `feature_cid`; optional `vars` are merged into context. |
| `GET /steps.yaml` | Public | Current step catalogue for the running node. |
| `GET /steps.json` | Public | JSON form of the step catalogue. |
| `GET /metrics/:registry` | Deployment-dependent | Metrics route; restrict it at the proxy unless intentionally public. |

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

## Optional integrations

### IPFS

Feature execution publishes report directories through the configured `damage_ipfs` pool. Run Kubo separately, keep its RPC API private, and point the pool at the correct host and port. The HTTP gateway is not a substitute for the Kubo RPC API.

### Core Lightning and LND

The sample explicitly sets `cln_enabled` to `false`. To enable CLN, configure its host, WebSocket path, TLS files, and encrypted `cln_rune`, then enable the backend. LND requires its own endpoint, TLS files, pool configuration, and encrypted macaroon.

### L402

Protected execution routes can issue an L402 payment challenge when normal authentication is absent and the node has a valid `l402_account` plus a working Lightning backend. Treat L402 as an explicit deployment decision rather than an automatic replacement for account authentication.

### Nostr Wallet Connect (NIP-47)

The tree contains authenticated APIs for minting and revoking NWC connections, listing sessions, reading ledger balances, and managing top-ups. The request handler implements `get_info`, `get_balance`, `pay_invoice`, `make_invoice`, `lookup_invoice`, and `list_transactions`.

The current implementation selects `server_signed` when `nwc_ledger_mode` is omitted. The sample therefore sets `operator_signed` explicitly, the least-permissive recognised selector for existing-ledger mutation paths. It is **not** a global NWC disable: the missing-ledger bootstrap path can still use an available custodial account key. Nodes that do not operate NWC should block `/api/nwc/` at the reverse proxy and avoid provisioning custodial account keys for those flows. Do not switch to `server_signed` until custody, ledger contracts, relay policy, Lightning authority, limits, monitoring, and recovery have all been reviewed.

### NIP-46 nsecbunker custody

The policy layer includes vault-readiness checks, client/method/kind allowlists, stale-event and size limits, required tags, active-content rejection, replay detection, rate limiting, signing timeouts, and deterministic redacted audit records.

The sample keeps nsecbunker disabled. Production mode requires at least a valid crypto backend command and vault path. Use the repository fragments for complete deployments:

- `config/sys.config.nsecbunker.fragment.config`
- `config/sys.config.aws.production.fragment.config`

AWS custody is opt-in and production-only. It additionally requires a region, secret identifier, expected AWS account, expected role, an existing ratified vault identity, and the secure EC2-role bootstrap described in the project documentation.

### Post-quantum secret envelopes

`secrets_pqc` implements a hybrid ML-KEM/AES-256-GCM envelope. It is optional and requires a configured `pqc_backend_module` implementing the expected keypair, encapsulation, and decapsulation adapter.

## Security baseline

- Bind DamageBDD to loopback and expose it through a maintained TLS reverse proxy.
- Never expose EPMD (`4369`) or Erlang distribution ports to the public Internet.
- Run the release as the dedicated `damage` system user.
- Keep `/etc/damage` root-managed and restrict `/var/lib/damage` and `/var/log/damage` to the service account.
- Keep Kubo RPC, wallet RPC, Lightning RPC, vault controls, and internal middleware ports private.
- Keep `node_admins`, `cmd_allowed`, SSH services, CLN, and nsecbunker disabled until intentionally configured; block `/api/nwc/` when NWC is not operated.
- Use reverse-proxy and application rate limits, request-size limits, and resource limits appropriate to the intended concurrency.
- Back up the configuration, encrypted secret store, node identity, vault metadata, and required external state before upgrades.
- Review access to `/api/node/balances`, because it is intentionally public in the current HTTP resource.
- Report vulnerabilities privately as described in [SECURITY.txt](SECURITY.txt) or at <https://damagebdd.com/security/>.

## Development

Before opening a pull request:

```bash
rebar3 compile
rebar3 eunit
rebar3 ct
```

The build rejects unsafe catch-all step definitions. New Gherkin steps should use explicit, parameterised patterns so dry-run validation can identify unsupported behaviour before execution.

## License

DamageBDD is licensed under the [Apache License 2.0](LICENSE). The original runner was inspired by [behave](https://github.com/behave/behave).
