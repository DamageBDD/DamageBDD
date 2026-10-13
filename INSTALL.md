# Installing and Operating a DamageBDD Node

This guide covers package installation, source builds, runtime configuration, systemd, secrets, IPFS, Aeternity, SMTP, Lightning, Nostr, NWC, NIP-46 custody, reverse proxying, validation, upgrades, backup, and troubleshooting.

**Last reviewed:** 3 September 2026  
**Release/application name:** `damage`  
**systemd unit:** `damage.service`  
**Default HTTP listener:** `127.0.0.1:4888`  
**Packaged configuration:** `/etc/damage/damage.config`  
**Reference configuration:** `config/sys.config.sample`

## 1. Choose an installation path

| Goal | Recommended path |
|---|---|
| Operate a Linux node with the least manual setup | Install a package from <https://damagebdd.com/node>. |
| Develop DamageBDD or modify Erlang modules | Clone the repository and run `rebar3 shell`. |
| Produce a self-contained deployment | Build a relx release with `rebar3 as prod release`. |
| Build the Linux native release profile | Use `rebar3 as linux,prod release`. |
| Build on macOS | Use `rebar3 as mac,prod release`. |
| Run on Windows | Use WSL2 or the Docker guide at <https://damagebdd.com/docker.html>. |
| Run in a container/chroot | Run the release in the foreground; do not assume systemd is PID 1. |

The current release CI baseline is Erlang/OTP **28** and rebar3 **3.26.0**. A packaged relx release includes ERTS, so the destination host normally does not require a separate Erlang installation.

CUDA is optional. Do not select the `cuda` profile unless the host has a compatible CUDA toolkit and `nvcc`.

## 2. Install a Linux package

Use the package page for current download locations and filenames:

<https://damagebdd.com/node>

Typical installation commands are:

```bash
# Debian, Ubuntu, Linux Mint
sudo apt install ./damage_*.deb

# Arch Linux, Manjaro, EndeavourOS
sudo pacman -U ./damage-*.pkg.tar.zst

# RPM-family systems, when an RPM is published
sudo dnf install ./damage-*.rpm
```

### Canonical package layout

| Purpose | Path or name |
|---|---|
| Release | `/opt/damage` |
| Executable | `/opt/damage/bin/damage` |
| Optional convenience command | `/usr/bin/damage` |
| Configuration | `/etc/damage/damage.config` |
| Optional environment file | `/etc/default/damage` |
| Persistent state | `/var/lib/damage` |
| Logs | `/var/log/damage` |
| Service account | `damage:damage` |
| systemd unit | `damage.service` |

The canonical service command is:

```text
/opt/damage/bin/damage foreground -config /etc/damage/damage.config
```

### Start and inspect the service

```bash
sudo systemctl enable --now damage
sudo systemctl status damage --no-pager
sudo journalctl -u damage -n 100 --no-pager
```

Follow startup logs:

```bash
sudo journalctl -u damage -f
```

Check the HTTP process/build endpoint:

```bash
curl --fail-with-body http://127.0.0.1:4888/api/version | jq
```

Do not use `/health`; it is not the current canonical DamageBDD probe.

## 3. Source-build prerequisites

### Ubuntu or Debian

Install the native libraries used by the current Linux release workflow:

```bash
sudo apt update
sudo apt install -y \
  git curl jq build-essential make pkg-config python3 \
  libgmp-dev libssl-dev libsodium-dev libgtk-4-dev
```

Install Erlang/OTP 28 and rebar3 3.26.0 or newer through a trusted package or toolchain manager. Distribution packages can be older than the current release baseline, so verify the actual versions:

```bash
erl -noshell \
  -eval 'io:format("OTP ~s~n", [erlang:system_info(otp_release)]), halt().'
rebar3 --version
```

### Arch Linux

```bash
sudo pacman -S --needed \
  git curl jq base-devel python \
  erlang rebar3 gmp openssl libsodium gtk4
```

Verify the installed versions before building.

### Fedora or RHEL-family systems

Package names vary by distribution release. The equivalent development set is generally:

```bash
sudo dnf install -y \
  git curl jq gcc gcc-c++ make pkgconf-pkg-config python3 \
  erlang rebar3 gmp-devel openssl-devel libsodium-devel gtk4-devel
```

Use a BEAM toolchain manager when the distribution Erlang or rebar3 packages are older than the current baseline.

### macOS

The current CI builds Apple Silicon and Intel releases. Install the core native dependencies:

```bash
brew update
brew install erlang rebar3 libsodium gmp openssl@3 pkg-config jq
```

Confirm the toolchain:

```bash
erl -noshell \
  -eval 'io:format("OTP ~s~n", [erlang:system_info(otp_release)]), halt().'
rebar3 --version
```

### WSL2

Use an Ubuntu or Debian WSL2 distribution and follow the corresponding instructions above. Native Windows is not a current BEAM release-build target.

Check whether systemd is active:

```bash
ps -p 1 -o comm=
```

When PID 1 is not `systemd`, run the source shell or release in the foreground instead of using `systemctl`.

## 4. Clone the repository

```bash
git clone https://github.com/DamageBDD/DamageBDD.git
cd DamageBDD
```

Create the development configuration:

```bash
cp config/sys.config.sample config/sys.config
```

Do not edit `config/sys.config.sample` for a private deployment. Keep it as the tracked reference and put host-specific values in `config/sys.config` or `/etc/damage/damage.config`.

## 5. Prepare `sys.config`

DamageBDD uses normal Erlang `sys.config` syntax. The application key is **`damage`**, not `damagebdd`.

The file is a single Erlang list terminated with a period:

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

Older examples using `{damagebdd, [...]}`, `bind_addr`, `/etc/damagebdd`, `/var/lib/damagebdd`, or `damagebdd.service` do not match the current packaged runtime.

### The configuration does not expand environment variables

This is valid Erlang configuration:

```erlang
{api_url, "https://bdd.example.com"}
```

This remains the literal string `${DAMAGE_API_URL}` and is not automatically expanded:

```erlang
{api_url, "${DAMAGE_API_URL}"}
```

`/etc/default/damage` can provide environment variables only to code that explicitly reads them. It does not preprocess the Erlang term file.

### Development checkout edits

The reference sample uses package paths and the `damage` service user. For an unprivileged source checkout, either create those paths with appropriate ownership or change every relevant path to a writable local directory.

A local directory layout can be created with:

```bash
mkdir -p var/lib/damage \
             var/lib/damage/ecai \
             var/lib/damage/nsecbunker \
             var/log/damage
```

Then update the copied `config/sys.config`, for example:

```erlang
{data_dir, "./var/lib/damage/"},
{keystore, "./var/lib/damage/damage.key"},
```

Update logger files as well:

```erlang
file => "./var/log/damage/info.log"
```

```erlang
file => "./var/log/damage/error.log"
```

The nsecbunker vault/audit paths and ECAI context path must also be writable if those components are used.

For local source execution, set `run_user` and the `erlexec` user/allowlist to your actual local account, or create the dedicated `damage` account. Do not grant `erlexec` a broader user allowlist than required.

### Package configuration deployment

Back up an existing configuration before replacing it:

```bash
sudo install -d -m 0755 /etc/damage
sudo cp -a \
  /etc/damage/damage.config \
  "/etc/damage/damage.config.backup-$(date +%F-%H%M%S)" \
  2>/dev/null || true

sudo install -o root -g root -m 0644 \
  config/sys.config.sample \
  /etc/damage/damage.config

sudoedit /etc/damage/damage.config
```

The configuration itself can be root-owned and world-readable only when it contains no secrets. Persistent key material remains under `/var/lib/damage` with restrictive permissions.

### Validate Erlang syntax

Validate the term before restarting:

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

For a source checkout, change `Path` to `config/sys.config`.

`file:consult/1` confirms Erlang syntax and the outer shape; it does not prove that every hostname, file, contract, credential, or backend is operational.

### Safe defaults in the reference sample

The updated sample deliberately starts with:

- HTTP on loopback only: `127.0.0.1:4888`.
- Strict step matching: `strict_no_catchall = true`.
- No node administrators.
- No approved shell commands.
- No outbound SOCKS proxy.
- CLN disabled.
- SSH Git and SSH tunnel services disabled.
- NIP-46 nsecbunker disabled.
- NIP-46 relay publication disabled.
- NWC set explicitly to `operator_signed` rather than relying on the current `server_signed` fallback; this is not a global disable switch.
- No automatic Kubo, browser, Bitcoin, or Lightning daemon startup through `abduco_workers`.
- Conservative worker-pool sizes.

### Core configuration keys

| Key | Purpose | Safe starting value |
|---|---|---|
| `ip` | Cowboy listener address | `{127,0,0,1}` |
| `port` | DamageBDD HTTP port | `4888` |
| `api_url` | Public origin used in links, emails, and browser flows | `http://127.0.0.1:4888` locally; HTTPS in production |
| `data_dir` | Persistent application state | `/var/lib/damage/` |
| `keystore` | Encrypted node keystore | `/var/lib/damage/damage.key` |
| `feature_dirs` | Local feature search paths | `["./features/"]` |
| `logo_image` | Dashboard logo URL/path | `/static/img/logo.png` |
| `run_user` | Intended release user | `damage` |
| `allowance` | Initial account allowance | `0` on a private node |
| `cookie_secure` | Secure browser cookie flag | `false` for local HTTP, `true` for HTTPS |
| `strict_no_catchall` | Reject unsafe broad step definitions | `true` |
| `node_admins` | Trusted Aeternity admin accounts | `[]` |
| `cmd_allowed` | Exact commands permitted by command steps | `[]` |

### Logger configuration

Runtime logging is configured under the `kernel` application, not through a `log_dir` key in the `damage` block.

The reference sample writes:

```text
/var/log/damage/info.log
/var/log/damage/error.log
```

It also writes to the default logger handler, which systemd captures in the journal.

Ensure the directory exists before startup:

```bash
sudo install -d -o damage -g damage -m 0750 /var/log/damage
```

To enable temporary debug logging, lower both `logger_level` and the applicable handler level to `debug`. Restore `info` after diagnosis because debug output can be large and may contain operational metadata.

### Request throttling

The `throttle` block defines scope-specific limits. The default driver is node-local ETS. Use a cluster-wide backend only after deliberately designing consistency and failure behaviour.

Keep the whitelist narrow. The sample whitelists only IPv4 loopback; do not copy private workstation addresses into a public reference file.

### Aeternity endpoints

The current application expects:

```erlang
{ae_network_id, "ae_mainnet"},
{ae_nodes, [{Host, Port, PathPrefix}]},
{ae_mdw_nodes, [{Host, Port, PathPrefix}]},
{ae_mdw_ws_nodes, [{Host, Port, PathPrefix}]}
```

The sample points all three groups at public Aeternity mainnet services. When using testnet or a local stack, change the network ID and every REST/WebSocket endpoint together.

Fee and gas safety multipliers default in the sample to:

```erlang
{ae_fee_multiplier, 2},
{ae_gas_multiplier, 2},
{ae_gas_price_multiplier, 3}
```

Increase them only to address measured underestimation; excessive values can increase transaction cost.

### Outbound proxying

Direct egress is the default:

```erlang
{proxy, none}
```

A SOCKS5 proxy can be configured explicitly:

```erlang
{proxy, {socks5, "127.0.0.1", 9050}}
```

Use `proxy_exclude` for loopback, local domains, and container/service names that must never be routed through the proxy. `damage_gun` performs peer verification for TLS connections unless a specific test step deliberately disables certificate verification.

### Worker pools

The `pools` setting controls the runner, formatter, AI, IPFS, and optional integration pools. Start conservatively. Raising concurrency without measuring downstream capacity can exhaust:

- BEAM schedulers and memory.
- File descriptors and ephemeral ports.
- Browser processes.
- IPFS, wallet, relay, and middleware connections.
- Target-system capacity.

The `damage_ipfs` worker pool uses Kubo's RPC API, not the public HTTP gateway.

## 6. Compile and run from source

Fetch dependencies and compile:

```bash
rebar3 compile
```

Start the development shell:

```bash
rebar3 shell
```

The shell profile loads `config/sys.config`.

In another terminal:

```bash
curl --fail-with-body http://127.0.0.1:4888/api/version | jq
```

Stop the shell with `q().` or `Ctrl-C` twice.

### Common source-start failures

If startup fails before the HTTP listener appears, check these first:

1. Every logger, data, keystore, vault, and companion-app path is writable.
2. `run_user` and the `erlexec` user exist.
3. `ae_network_id`, `ae_nodes`, `ae_mdw_nodes`, and `ae_mdw_ws_nodes` are present and reachable.
4. Optional worker pools do not include an unconfigured LND or CLN backend.
5. The copied configuration is valid Erlang and ends with `].`.

## 7. Build a production release

Generic production release:

```bash
rebar3 as prod release
```

Linux profile:

```bash
rebar3 as linux,prod release
```

macOS profile:

```bash
rebar3 as mac,prod release
```

Optional CUDA profile:

```bash
rebar3 as prod,cuda release
```

A normal DamageBDD release does not require CUDA.

Locate the generated release:

```bash
find _build -path '*/rel/damage/bin/damage' -type f -print
```

A generic production build is normally under:

```text
_build/prod/rel/damage
```

Start the release in the foreground:

```bash
_build/prod/rel/damage/bin/damage foreground \
  -config "$PWD/config/sys.config"
```

## 8. Install a source-built release under systemd

Packages are preferred because they apply the project’s packaging hooks. For a manual deployment, install the release deliberately.

### Create the service account and directories

```bash
sudo groupadd --system damage 2>/dev/null || true
NOLOGIN_SHELL="$(command -v nologin || printf '%s' /bin/false)"
sudo useradd \
  --system \
  --gid damage \
  --home-dir /var/lib/damage \
  --no-create-home \
  --shell "$NOLOGIN_SHELL" \
  damage 2>/dev/null || true

sudo install -d -m 0755 /etc/damage
sudo install -d -o damage -g damage -m 0750 \
  /opt/damage /var/lib/damage /var/log/damage
```

### Copy the release

```bash
sudo cp -a _build/prod/rel/damage/. /opt/damage/
sudo chown -R damage:damage /opt/damage /var/lib/damage /var/log/damage
```

### Install and edit the configuration

```bash
sudo install -o root -g root -m 0644 \
  config/sys.config.sample \
  /etc/damage/damage.config
sudoedit /etc/damage/damage.config
```

Validate it with the `file:consult/1` command from section 5.

### Install the canonical unit

```bash
sudo install -m 0644 \
  apps/damage/priv/pkg/damage.service \
  /etc/systemd/system/damage.service

sudo systemctl daemon-reload
sudo systemctl enable --now damage
```

The canonical unit runs as `damage:damage`, creates state/log directories, restarts on failure, restricts capabilities and address families, and loads `/etc/damage/damage.config`.

Do not replace it with an older `damagebdd.service` example. Do not add `MemoryDenyWriteExecute=true`; the BEAM JIT requires executable dynamically generated code pages.

## 9. Configure encrypted secrets

Keep passwords, private keys, nsecs, runes, macaroons, vault passphrases, and cloud credentials out of `sys.config`.

The standard setup function is:

```erlang
damage:check_setup().
```

It checks or prompts for:

- `nostr_nsec`
- `bitcoin_rpc_password`
- `lnd_macaroon`
- `cln_rune`
- `smtp_pass`

The current SMTP secret name is `smtp_pass`; `smtp_password` is obsolete.

### Source checkout

Run the setup inside `rebar3 shell`:

```erlang
damage:check_setup().
```

### Packaged release

Stop the service before opening a local release console against the same state:

```bash
sudo systemctl stop damage
sudo -u damage -H \
  /opt/damage/bin/damage console \
  -config /etc/damage/damage.config
```

At the Erlang prompt:

```erlang
damage:check_setup().
```

Exit with `q().`, then restart:

```bash
sudo systemctl start damage
```

When a deployment uses a different console/unlock workflow, run the same Erlang functions through that approved operator path instead of starting a second VM against live state.

### Store individual values

```erlang
secrets:encrypt_store(bitcoin_rpc_password, "REPLACE_ME").
secrets:encrypt_store(nostr_nsec, "nsec1_REPLACE_ME").
secrets:encrypt_store(smtp_pass, "REPLACE_ME").
secrets:encrypt_store(cln_rune, "REPLACE_ME").
secrets:encrypt_store(lnd_macaroon, "REPLACE_ME").
secrets:encrypt_store(damage_nostr_nsec, "nsec1_REPLACE_ME").
```

Check a configured value without printing it:

```erlang
case secrets:retrieve_decrypt(smtp_pass) of
    {ok, _} -> configured;
    _ -> missing
end.
```

Do not print decrypted values into logs or reports.

## 10. Configure supporting services

### 10.1 Aeternity node and middleware

The sample provides public mainnet endpoints so the node has a coherent starting configuration. Production operators should configure multiple known endpoints or a maintained local stack.

Verify basic reachability from the `damage` account:

```bash
sudo -u damage curl --fail-with-body \
  https://mainnet.aeternity.io/v3/status | jq

sudo -u damage curl --fail-with-body \
  https://mainnet.aeternity.io/mdw/status | jq
```

Endpoint paths can evolve independently of DamageBDD. Use the exact paths required by the currently selected node and middleware versions.

A successful local `/api/version` proves the DamageBDD process is running; it does not prove all chain integrations are healthy.

### 10.2 IPFS/Kubo

DamageBDD report publication uses the Kubo RPC API. The sample expects:

```text
RPC API: 127.0.0.1:5001
Gateway: 127.0.0.1:8082
```

Keep the RPC API private. It is a control interface, not a public gateway.

Verify a running daemon:

```bash
ipfs version
ipfs id
curl --fail-with-body -X POST \
  'http://127.0.0.1:5001/api/v0/id' | jq
```

When using containers, replace the IPFS worker host with the internal service name, for example:

```erlang
{
    damage_ipfs,
    [{size, 2}, {max_overflow, 4}],
    [{"ipfs", 5001}]
}
```

Do not route local Kubo traffic through a SOCKS proxy; add the service name to `proxy_exclude`.

### 10.3 SMTP

Configure public metadata in `damage.config`:

```erlang
{smtp_host, "smtp.example.com"},
{smtp_hostname, "bdd.example.com"},
{smtp_from, {"DamageBDD Node", "node@bdd.example.com"}},
{smtp_user, "node@bdd.example.com"},
{smtp_port, 587}
```

Store the password separately:

```erlang
secrets:encrypt_store(smtp_pass, "REPLACE_ME").
```

Also set:

```erlang
{api_url, "https://bdd.example.com"}
```

Account confirmation and password reset links depend on `api_url` being the externally reachable origin.

### 10.4 Bitcoin Core

The public metadata belongs in configuration:

```erlang
{bitcoin_rpc_port, 8332},
{bitcoin_rpc_user, "damage"},
{bitcoin_wallet, "damage"}
```

Store the RPC password as `bitcoin_rpc_password`. Restrict Bitcoin RPC to loopback or a private network and use Bitcoin Core's authentication/allowlist controls.

### 10.5 Core Lightning

The reference sample disables CLN explicitly:

```erlang
{cln_enabled, false}
```

Configure the endpoint and TLS files before enabling it:

```erlang
{cln_enabled, true},
{cln_host, "127.0.0.1"},
{cln_port, 3010},
{cln_wspath, "/"},
{cln_cacertfile, "/var/lib/damage/lightning/ca.pem"},
{cln_certfile, "/var/lib/damage/lightning/client.pem"},
{cln_keyfile, "/var/lib/damage/lightning/client-key.pem"}
```

Review the rune syntax supported by the installed CLN version, then create a least-privilege rune limited to the RPC methods DamageBDD needs:

```bash
lightning-cli help createrune
```

Do not treat a bare, unrestricted rune as production-safe.

```erlang
secrets:encrypt_store(cln_rune, "REPLACE_ME").
```

Inspect the fault-contained CLN manager from an Erlang console:

```erlang
damage_cln:status().
```

Do not enable a payment backend until invoice creation, payment limits, accounting, recovery, and monitoring have been tested.

### 10.6 LND

LND is optional. Configure its host, port, WebSocket path, TLS files, encrypted `lnd_macaroon`, and an LND worker pool only when the endpoint is available.

Do not add an LND pool to `pools` on a node that has no working LND backend; optional integration failures should not become core startup failures.

### 10.7 Nostr

Configure relay URLs as public application settings:

```erlang
{
    nostr_relays,
    [
        "wss://nos.lol",
        "wss://offchain.pub",
        "wss://relay.primal.net"
    ]
}
```

Store private identities separately:

```erlang
secrets:encrypt_store(nostr_nsec, "nsec1_REPLACE_ME").
secrets:encrypt_store(damage_nostr_nsec, "nsec1_REPLACE_ME").
```

`damage_nostr_nsec` is used by NWC service paths. Review each relay's trust, retention, availability, and proxy requirements.

### 10.8 Nostr Wallet Connect (NIP-47)

The current implementation supports authenticated APIs for minting and revoking connections, listing sessions, reading ledger balances, and top-up flows. Its request handler includes:

- `get_info`
- `get_balance`
- `pay_invoice`
- `make_invoice`
- `lookup_invoice`
- `list_transactions`

The current code selects `server_signed` when `nwc_ledger_mode` is absent. The reference sample therefore sets:

```erlang
{nwc_ledger_mode, operator_signed}
```

This is the least-permissive recognised selector for existing-ledger mutation paths. It is not a global NWC disable and is not a substitute for a complete NWC deployment. In the current code, missing-ledger bootstrap can still use an available custodial account key.

Do not switch to:

```erlang
{nwc_ledger_mode, server_signed}
```

until all of the following are deliberate and tested:

1. The server is intended to have custodial access to user Aeternity keys.
2. Registry and NWC ledger contracts are deployed and verified.
3. The NWC service identity is securely stored and recoverable.
4. Relay allowlists and direct/proxy behaviour are approved.
5. Per-connection limits, expiry, revocation, top-up, and debit accounting are tested.
6. CLN authority is restricted to the required operations.
7. Logs and alerts do not disclose connection secrets or payment preimages.
8. Backup and incident-response procedures cover the ledger and service identity.

Omitting the key is not a way to disable NWC. A node that does not operate NWC should also block `/api/nwc/` at its reverse proxy and avoid provisioning custodial account keys for those flows.

### 10.9 L402

L402 challenges remain inactive until a valid Aeternity account and Lightning backend are configured:

```erlang
{l402_account, "ak_REPLACE_ME"},
{l402_price_msat, 1000},
{l402_min_sats, 1}
```

Feature-execution routes can derive a payment amount from the dry-run result. Verify the complete challenge, invoice, preimage, authorisation, expiry, replay, and accounting flow before exposing it publicly.

### 10.10 NIP-46 nsecbunker custody

The reference sample includes a complete shape but keeps it disabled:

```erlang
{nsecbunker, [{enabled, false}, ...]}
```

The gate enforces vault readiness, client/method/kind policy, time windows, event-size limits, required tags, active-content rejection, replay protection, rate limits, signing timeouts, and deterministic redacted audit records.

Production configuration is a custody ceremony, not a single boolean change. Use the repository fragments as the source of truth:

```text
config/sys.config.nsecbunker.fragment.config
config/sys.config.aws.production.fragment.config
```

A local production provider requires at least:

- `enabled = true`
- a production mode
- `secret_provider = local`
- a valid crypto backend command
- an existing vault path or an explicit one-time creation ceremony
- the ratified bunker public key
- an authorised-client allowlist
- a writable, protected audit log
- monitored replay/rate-limit services
- tested backup and recovery

AWS Secrets Manager custody is opt-in and production-only. It additionally requires:

- `secret_provider = aws_secrets_manager`
- `vault_mode = open_existing` for normal operation
- the ratified 64-character bunker public key
- AWS region and secret ID
- expected AWS account ID and role name
- EC2 instance-role/IMDSv2/STS validation
- no static long-lived AWS credentials in the service environment

The canonical systemd unit removes inherited static AWS credential variables and vault-passphrase variables. Do not weaken that boundary to make a broken bootstrap appear to work.

### 10.11 Post-quantum secret envelopes

`secrets_pqc` is optional. Configure `pqc_backend_module` only when a reviewed adapter provides the expected keypair, encapsulation, and decapsulation operations.

The hybrid envelope uses ML-KEM to wrap an AES-256-GCM content key. It does not replace the normal node keystore or automatically migrate existing secrets.

### 10.12 Browser automation

The sample points at:

```erlang
{chromedriver, "http://127.0.0.1:9515/"}
```

It does not start ChromeDriver. Run browsers under a separate service/container with explicit resource, sandbox, network, and lifecycle controls. Never expose the ChromeDriver control port publicly.

## 11. Reverse proxy and TLS

Keep DamageBDD bound to `127.0.0.1:4888` and publish it through a maintained reverse proxy.

Install Nginx and an ACME client using your distribution packages, then create an equivalent of `/etc/nginx/conf.d/damage.conf`:

```nginx
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 80;
    listen [::]:80;
    server_name bdd.example.com;

    client_max_body_size 10m;

    location / {
        proxy_pass http://127.0.0.1:4888;
        proxy_http_version 1.1;

        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;

        proxy_buffering off;
        proxy_request_buffering off;
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
    }
}
```

On a node that does **not** intentionally operate Nostr Wallet Connect, place this location before `location /`:

```nginx
location ^~ /api/nwc/ {
    return 404;
}
```

For nodes that do operate NWC, replace that deny rule with explicit authentication, rate-limit, and request-size policy rather than exposing the route family by accident.

Validate and reload:

```bash
sudo nginx -t
sudo systemctl reload nginx
```

Obtain a certificate through your normal ACME process. With Certbot on a supported Nginx installation:

```bash
sudo certbot --nginx -d bdd.example.com
sudo certbot renew --dry-run
```

Update DamageBDD after HTTPS is active:

```erlang
{api_url, "https://bdd.example.com"},
{cookie_secure, true}
```

Then validate the configuration and restart `damage`.

The current `/api/node/balances` endpoint is public. Restrict it at the proxy when node wallet metadata must not be exposed. Apply the same review to metrics, Swagger, debug, administration, and integration-specific routes.

## 12. Firewall and network exposure

A typical public node exposes only TCP 80 and 443 through the reverse proxy.

Never expose directly to the public Internet:

- EPMD on TCP `4369`.
- Erlang distribution ports.
- Kubo RPC on `5001`.
- ChromeDriver on `9515`.
- Bitcoin, Lightning, wallet, vault, or database RPC interfaces.
- Aeternity internal control interfaces.
- DamageBDD `4888` when Nginx is the intended entry point.
- SSH Git or tunnel ports unless those services have been explicitly designed and enabled.

Confirm the DamageBDD binding:

```bash
ss -ltnp | grep ':4888'
```

Expected production output should show loopback, not `0.0.0.0`:

```text
127.0.0.1:4888
```

## 13. Validate the node

### 13.1 Configuration and service

```bash
sudo systemctl cat damage
sudo systemctl is-active damage
sudo systemctl status damage --no-pager
sudo journalctl -u damage -n 100 --no-pager
```

The unit should load:

```text
-config /etc/damage/damage.config
```

### 13.2 Build and runtime identity

```bash
curl --fail-with-body http://127.0.0.1:4888/api/version | jq
```

The response identifies the application version, Git SHA, build time/environment, OTP release, and ERTS version.

### 13.3 Node balances

```bash
curl --fail-with-body http://127.0.0.1:4888/api/node/balances | jq
```

This endpoint can also reveal chain-integration failures. Remember that it is public unless restricted by the proxy.

### 13.4 Live step catalogue

```bash
curl --fail-with-body http://127.0.0.1:4888/steps.yaml | less
curl --fail-with-body http://127.0.0.1:4888/steps.json | jq
```

### 13.5 Authenticated smoke feature

Create `smoke.feature`:

```gherkin
Feature: Local DamageBDD smoke test

  Scenario: Read node version
    Given I am using server "http://127.0.0.1:4888"
    When I make a GET request to "/api/version"
    Then the response status must be "200"
    Then the response must contain text "git_sha"
```

After creating and confirming an account:

```bash
export DAMAGEBDD_URL='http://127.0.0.1:4888'
export DAMAGEBDD_EMAIL='operator@example.com'

read -r -s -p 'Password: ' DAMAGEBDD_PASSWORD
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
```

Execute:

```bash
curl --fail-with-body --no-buffer \
  -X POST "$DAMAGEBDD_URL/execute_feature/" \
  -H "authorization: Bearer $DAMAGEBDD_TOKEN" \
  -H 'content-type: text/plain' \
  -H 'x-damage-concurrency: 1' \
  --data-binary @smoke.feature
```

The runner first performs a dry run. A syntactically valid feature can still be rejected when the account lacks execution balance or when a target is not authorised for concurrent load.

### 13.6 Execute a feature from IPFS

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

## 14. Day-to-day operations

### Status and restart

```bash
sudo systemctl status damage --no-pager
sudo systemctl restart damage
sudo systemctl is-active damage
```

### Safe configuration change

```bash
sudo cp -a \
  /etc/damage/damage.config \
  "/etc/damage/damage.config.backup-$(date +%F-%H%M%S)"

sudoedit /etc/damage/damage.config
```

Run syntax validation, then:

```bash
sudo systemctl restart damage
sudo systemctl status damage --no-pager
curl --fail-with-body http://127.0.0.1:4888/api/version | jq
```

If startup fails, restore the backup and inspect the journal before making another change.

### Package upgrade

Back up configuration and state first:

```bash
sudo cp -a /etc/damage "/root/damage-config-$(date +%F-%H%M%S)"
sudo tar -C /var/lib \
  -czf "/root/damage-state-$(date +%F-%H%M%S).tgz" \
  damage
```

Install the new package with the same package manager used originally. Verify the effective configuration was preserved, then check `/api/version`, step discovery, IPFS publication, chain connections, and any enabled payment/custody components.

### Source upgrade

```bash
cd /path/to/DamageBDD
git fetch --all --tags
git pull --ff-only
rebar3 compile
rebar3 eunit
rebar3 ct
rebar3 as prod release
```

For a manually installed release:

```bash
sudo systemctl stop damage
sudo cp -a /opt/damage "/opt/damage.backup-$(date +%F-%H%M%S)"
sudo cp -a _build/prod/rel/damage/. /opt/damage/
sudo chown -R damage:damage /opt/damage
sudo systemctl start damage
curl --fail-with-body http://127.0.0.1:4888/api/version | jq
```

### Backups

Back up at least:

- `/etc/damage/damage.config`.
- `/var/lib/damage`, including the encrypted keystore and identity state.
- NIP-46 vault files and the material required to unlock or recover them.
- External IPFS, Aeternity, Bitcoin, Lightning, database, and relay state required by the deployment.
- Contract identifiers and deployment records.
- Recovery instructions and decryption keys stored separately from the backup.

Test restoration. An untested encrypted backup is not a recovery plan.

## 15. Troubleshooting

### `systemctl status damagebdd` says the unit does not exist

The current unit is:

```bash
sudo systemctl status damage
```

### Configuration changes have no effect

Verify all three identifiers:

```text
Application key: damage
Configuration:  /etc/damage/damage.config
Service:        damage.service
```

Then inspect the effective unit:

```bash
systemctl cat damage
```

### The configuration has a syntax error

Run the `file:consult/1` validation command. Common errors are:

- A missing comma between tuples.
- A trailing comma before `]` or `}`.
- A missing quote.
- A missing final period.
- Using JSON syntax instead of Erlang terms.
- Writing a map where a component expects a standard proplist.

Inspect startup errors:

```bash
sudo journalctl -u damage -b --no-pager
```

### `/health` returns 404

Use:

```bash
curl http://127.0.0.1:4888/api/version
```

### The service cannot write logs, reports, or the keystore

```bash
sudo install -d -o damage -g damage -m 0750 \
  /var/lib/damage /var/log/damage
sudo chown -R damage:damage /var/lib/damage /var/log/damage /opt/damage
sudo systemctl restart damage
```

Verify every path in the `kernel` logger and `damage` configuration blocks.

### A source checkout fails because the `damage` user does not exist

Change both the `damage` application's `run_user` and the `erlexec` application's user/allowlist to your local account, or create the dedicated service account. Also replace package paths with writable local paths.

### The port is already in use

```bash
ss -ltnp | grep ':4888'
```

Stop the conflicting service or change the DamageBDD `port` and matching `api_url`/reverse-proxy upstream.

### Account confirmation email is not sent

Verify:

- `smtp_host`, `smtp_hostname`, `smtp_from`, `smtp_user`, and `smtp_port`.
- `secrets:retrieve_decrypt(smtp_pass)` succeeds.
- `api_url` is the correct public origin.
- DNS and outbound SMTP connectivity from the `damage` account.
- Sender-domain SPF/DKIM/DMARC and provider policy.
- Spam filtering.

### IPFS publication fails

```bash
command -v ipfs
ipfs version
ipfs id
curl --fail-with-body -X POST \
  'http://127.0.0.1:5001/api/v0/id' | jq
```

Confirm the `damage_ipfs` pool host/port and ensure the Kubo API is not being sent through a proxy.

### Aeternity or middleware calls fail

Check:

- DNS and TLS from the service account.
- `ae_network_id` matches all endpoints.
- `ae_nodes`, `ae_mdw_nodes`, and `ae_mdw_ws_nodes` contain valid path prefixes.
- Proxy exclusions for local endpoints.
- Fee/gas multipliers for failed transactions.

A local version response is not a chain-health check.

### CLN remains unavailable

Confirm `cln_enabled` is deliberately true, all TLS files are readable by `damage`, `cln_rune` exists, and the endpoint is reachable. Inspect:

```erlang
damage_cln:status().
```

The CLN manager is fault-contained and retries configured backends; disabling it is preferable to repeatedly retrying an intentionally absent service.

### NWC unexpectedly performs or attempts server-signed operations

Set an explicit mode. The current fallback for an absent or unrecognised `nwc_ledger_mode` is `server_signed`.

The reference uses the least-permissive recognised selector:

```erlang
{nwc_ledger_mode, operator_signed}
```

Do not use an unknown atom or string expecting it to disable NWC. `operator_signed` is also not a global disable: missing-ledger bootstrap can still use an available custodial key. Block `/api/nwc/` at the reverse proxy when the service is not intentionally operated.

### NIP-46 nsecbunker does not start

Check the complete `nsecbunker` block and the dedicated fragment documentation. Production validation requires a crypto backend command and vault path. AWS mode also requires every AWS identity field and normal operation should open an existing ratified vault.

Inspect permissions on:

```text
/var/lib/damage/nsecbunker
/var/log/damage/nsecbunker_audit.log
/opt/damage/bin/damage-nsecbunker-crypto-c
```

Do not bypass vault, identity, STS, audit, replay, rate, or timeout checks to make the service start.

### Build fails because `nvcc` is missing

Do not use the CUDA profile:

```bash
rebar3 as prod release
```

### Browser steps cannot connect

Verify ChromeDriver is running only on a private/loopback interface and that the configured URL matches it:

```bash
curl --fail-with-body http://127.0.0.1:9515/status | jq
```

Check browser executable permissions, sandbox policy, display/headless mode, shared memory, and process limits.

### Package install runs inside a container or chroot

Do not rely on `systemctl` when systemd is not PID 1. Start the release directly:

```bash
/opt/damage/bin/damage foreground \
  -config /etc/damage/damage.config
```

### Debug output is too large

Restore `logger_level` and handler levels to `info`, restart, and verify rotating file limits. Do not leave debug logging enabled on payment or custody nodes without reviewing its data exposure.

## 16. Security checklist

Before exposing a node:

- Keep the DamageBDD listener on loopback and terminate TLS at a maintained proxy.
- Expose only required ports; never expose EPMD or Erlang distribution.
- Keep `node_admins`, `cmd_allowed`, SSH services, CLN, L402, and nsecbunker disabled until they are intentionally reviewed; block `/api/nwc/` unless NWC is deliberately operated.
- Run the canonical release as the dedicated `damage` account.
- Keep `/etc/damage` root-managed and state/log paths service-owned with restrictive modes.
- Store integration credentials with `secrets:encrypt_store/2`.
- Do not put long-lived cloud credentials or vault passphrases in systemd environment files.
- Keep Kubo, browser, Bitcoin, Lightning, middleware, database, and vault control interfaces private.
- Restrict and monitor public balance, metrics, Swagger, and administrative routes.
- Use reverse-proxy and application rate limits.
- Set CPU, memory, open-file, process, request-size, and execution-concurrency limits appropriate to the host.
- Patch Erlang/OTP, native libraries, Nginx, Kubo, wallet software, browsers, and DamageBDD regularly.
- Back up and test restoration of the encrypted keystore, node identity, contracts, and custody state.
- Review NIP-46, NWC, L402, and payment features as separate security boundaries.

See [SECURITY.txt](SECURITY.txt) and <https://damagebdd.com/security/> for reporting and hardening guidance.

## 17. Uninstall

### Package installation

Use the distribution package manager:

```bash
# Debian/Ubuntu/Mint
sudo apt remove damage

# Arch
sudo pacman -R damage

# RPM family
sudo dnf remove damage
```

Package removal may preserve configuration and state. Delete them only after confirming that no keys, reports, balances, contracts, vaults, or recovery data are still required:

```bash
sudo rm -rf /etc/damage /var/lib/damage /var/log/damage /opt/damage
```

### Manual installation

```bash
sudo systemctl disable --now damage 2>/dev/null || true
sudo rm -f /etc/systemd/system/damage.service
sudo systemctl daemon-reload
sudo rm -rf /opt/damage
```

Preserve or securely erase `/etc/damage` and `/var/lib/damage` according to the deployment’s retention and key-destruction policy.
