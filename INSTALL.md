# Installing and Operating a DamageBDD Node

This guide covers packaged installation, source builds, production configuration, systemd, reverse proxying, secrets, integrations, validation, upgrades, backup, troubleshooting, WSL2, and macOS.

**Last verified:** 3 September 2026  
**Release/service name:** `damage`  
**Default HTTP listener:** `127.0.0.1:4888`  
**Canonical configuration:** `/etc/damage/damage.config`

## 1. Choose an installation path

| Goal | Recommended path |
|---|---|
| Operate a Linux node with the least manual setup | Install a package from <https://damagebdd.com/node>. |
| Develop DamageBDD or modify Erlang modules | Clone the repository and run `rebar3 shell`. |
| Produce a self-contained deployment | Build a relx release with `rebar3 as prod release`. |
| Run on macOS | Build from source with the `mac,prod` profile or use a current CI artifact when one is published. |
| Run on Windows | Use WSL2 for source builds, or follow the cross-platform Docker guide at <https://damagebdd.com/docker.html>. Native Windows is not a current BEAM release-build target. |
| Run in a container/chroot | Start the release in the foreground; package hooks intentionally avoid `systemctl` when systemd is not PID 1. |

The current CI release baseline is Erlang/OTP **28** and rebar3 **3.26.0**. A packaged relx release includes ERTS, so the destination host does not need a separate Erlang installation.

CUDA is optional. The default and `prod` profiles do not require `nvcc`.

## 2. Package installation on Linux

The public package page currently provides the authoritative download links. Do not hard-code a package version or IPFS CID into automation without first verifying the release:

<https://damagebdd.com/node>

Typical package-manager commands are:

```bash
# Debian, Ubuntu, Linux Mint
sudo apt install ./damage_*.deb

# Arch Linux, Manjaro, EndeavourOS
sudo pacman -U ./damage-*.pkg.tar.zst

# RPM-family systems, when an RPM is published
sudo dnf install ./damage-*.rpm
```

### Package layout

| Purpose | Path or name |
|---|---|
| Release | `/opt/damage` |
| Executable | `/opt/damage/bin/damage` |
| Convenience symlink | `/usr/bin/damage` |
| Configuration | `/etc/damage/damage.config` |
| Optional environment file | `/etc/default/damage` |
| Persistent state | `/var/lib/damage` |
| Logs | `/var/log/damage` |
| Installer log | `/var/log/damage/install.log` |
| Service account | `damage:damage` |
| systemd unit | `damage.service` |

The package post-install hooks create the dedicated system account and directories, preserve an existing configuration, install the canonical systemd unit, and enable/start the service when systemd is running. The current hook also installs Kubo when no `ipfs` executable is available; it does not replace an existing IPFS installation.

### Start and inspect the service

```bash
sudo systemctl enable --now damage
sudo systemctl status damage --no-pager
sudo journalctl -u damage -n 100 --no-pager
```

Follow logs during startup:

```bash
sudo journalctl -u damage -f
```

Validate the HTTP listener:

```bash
curl --fail-with-body http://127.0.0.1:4888/api/version | jq
```

Do not use `/health`; it is not the canonical health/build probe in the current HTTP resource.

## 3. Source-build prerequisites

### Ubuntu or Debian

Install the native libraries used by the current Linux release workflow:

```bash
sudo apt update
sudo apt install -y \
  git curl jq build-essential make pkg-config python3 \
  libgmp-dev libssl-dev libsodium-dev libgtk-4-dev
```

Install Erlang/OTP 28 and rebar3 3.26.0 or newer through a trusted package/toolchain manager. Ubuntu 22.04 distribution packages may be older than the release baseline, so verify rather than assume:

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

Verify that the installed Erlang and rebar3 versions meet the baseline shown above.

### Fedora or RHEL-family systems

Package names vary by release, but the equivalent development set is:

```bash
sudo dnf install -y \
  git curl jq gcc gcc-c++ make pkgconf-pkg-config python3 \
  erlang rebar3 gmp-devel openssl-devel libsodium-devel gtk4-devel
```

Use a BEAM toolchain manager when the distribution Erlang/rebar3 packages are older than the current baseline.

### macOS

The current CI builds both Apple Silicon and Intel releases. Install the same core native dependencies used by that workflow:

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

Use an Ubuntu or Debian WSL2 distribution and follow the corresponding instructions above. Native Windows is not part of the current release matrix.

Check whether systemd is active:

```bash
ps -p 1 -o comm=
```

When PID 1 is not `systemd`, run the source shell or release in the foreground instead of using `systemctl`.

## 4. Clone and configure a development checkout

```bash
git clone https://github.com/DamageBDD/DamageBDD.git
cd DamageBDD

test -f config/sys.config || cp config/sys.config.sample config/sys.config
```

The rebar3 shell profile loads `config/sys.config`. Review that file before first boot:

1. Replace all example hosts, accounts, contract IDs, and credentials with valid deployment values or disable unused integrations.
2. Set the `damage` listener to loopback for local development.
3. Set `api_url` to the URL users and email links will actually use.
4. Make `data_dir` writable.
5. Change `/var/log/damage/...` logger paths to a writable development directory, or create `/var/log/damage` with suitable ownership.
6. Never put passwords, private keys, runes, macaroons, or nsecs in `sys.config`.

A minimal `damage` block looks like this:

```erlang
{
    damage,
    [
        {ip, {127, 0, 0, 1}},
        {port, 4888},
        {api_url, "http://127.0.0.1:4888"},
        {data_dir, "./var/lib/damage/"},
        {feature_dirs, ["./features/"]},
        {node_admins, []}
    ]
}
```

Remember that a complete Erlang `sys.config` is a list terminated by a period:

```erlang
[
    {
        damage,
        [
            {ip, {127, 0, 0, 1}},
            {port, 4888},
            {api_url, "http://127.0.0.1:4888"},
            {data_dir, "./var/lib/damage/"},
            {feature_dirs, ["./features/"]},
            {node_admins, []}
        ]
    }
].
```

The correct application key is `damage`. Older examples using `{damagebdd, [...]}`, `bind_addr`, `/etc/damagebdd`, or `/var/lib/damagebdd` do not match the current packaged runtime.

## 5. Compile and run from source

Fetch dependencies and compile:

```bash
rebar3 compile
```

Start the development shell:

```bash
rebar3 shell
```

The node should listen on the configured IP and port. In another terminal:

```bash
curl --fail-with-body http://127.0.0.1:4888/api/version | jq
```

Stop the shell with `q().` or `Ctrl-C` twice.

### Build a production release

Portable production profile:

```bash
rebar3 as prod release
```

Linux release profile, including the Linux native helper build:

```bash
rebar3 as linux,prod release
```

macOS release profile:

```bash
rebar3 as mac,prod release
```

Optional CUDA profile:

```bash
rebar3 as prod,cuda release
```

Only use the CUDA profile after installing and validating the CUDA toolkit and `nvcc`. A normal DamageBDD release is complete without it.

The generic production release executable is normally:

```text
_build/prod/rel/damage/bin/damage
```

Combined profiles may use a combined directory name under `_build`. Locate the generated script when necessary:

```bash
find _build -path '*/rel/damage/bin/damage' -type f -print
```

Start a release in the foreground:

```bash
_build/prod/rel/damage/bin/damage foreground \
  -config "$PWD/config/sys.config"
```

## 6. Install a source-built release under systemd

Packages are preferred because they apply the project’s post-install hooks. For a manual source deployment, build with the `prod` profile and then install the release deliberately.

Create the account and directories:

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

Copy the release:

```bash
sudo cp -a _build/prod/rel/damage/. /opt/damage/
sudo chown -R damage:damage /opt/damage /var/lib/damage /var/log/damage
```

Create the initial configuration:

```bash
sudo tee /etc/damage/damage.config >/dev/null <<'EOF_CONFIG'
%%% -*- mode: erlang; erlang-indent-level: 2; -*-
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
EOF_CONFIG
sudo chmod 0644 /etc/damage/damage.config
```

Install the canonical service shipped by the repository:

```bash
sudo install -m 0644 \
  apps/damage/priv/pkg/damage.service \
  /etc/systemd/system/damage.service

sudo systemctl daemon-reload
sudo systemctl enable --now damage
```

The canonical unit runs `/opt/damage/bin/damage foreground -config /etc/damage/damage.config` as `damage:damage` and applies filesystem, capability, process, and kernel hardening. Do not replace it with an older `damagebdd.service` example.

## 7. Configuration reference

### Core settings

| Key | Meaning |
|---|---|
| `ip` | Listener tuple, normally `{127,0,0,1}` behind a proxy. |
| `port` | HTTP port; package default is `4888`. |
| `api_url` | Public origin used in links, emails, and browser flows. Use HTTPS in production. |
| `data_dir` | Persistent application data directory. |
| `feature_dirs` | Directories searched for local feature files. |
| `node_admins` | Trusted Aeternity accounts with node administration access. |
| `cookie_secure` | Set `true` when the public site is HTTPS. |
| `strict_no_catchall` | Step-definition strictness. New modules should use explicit parameterised patterns. |

### Integration settings

The full examples are in `config/sys.config.sample`. Common groups include:

- SMTP: `smtp_host`, `smtp_hostname`, `smtp_from`, `smtp_user`, `smtp_port`.
- Bitcoin Core: `bitcoin_rpc_port`, `bitcoin_rpc_user`, `bitcoin_wallet`.
- LND: `lnd_host`, `lnd_port`, WebSocket path, and TLS file paths.
- Core Lightning: `cln_host`, `cln_port`, WebSocket path, and client TLS file paths.
- IPFS: the `ipfs` configuration list, including gateway addresses.
- Aeternity: `ae_network_id`, `ae_nodes`, `ae_mdw_nodes`, and `ae_mdw_ws_nodes`.
- Proxying: a SOCKS5 `proxy` and `proxy_exclude` list where required.
- L402: `l402_account` and `l402_price_msat` when payment challenges are intentionally enabled.
- NWC: explicitly review `nwc_ledger_mode`, signing authority, relay policy, and ledger contracts before activation.

Restart after a configuration change:

```bash
sudo systemctl restart damage
sudo journalctl -u damage -n 100 --no-pager
```

### Logging

The current reference configuration defines Erlang logger handlers under the `kernel` section and writes rotating files such as:

```text
/var/log/damage/debug.log
/var/log/damage/info.log
/var/log/damage/error.log
```

The systemd unit also writes stdout/stderr to the journal:

```bash
sudo journalctl -u damage -f
```

There is no current `log_dir` application setting that automatically relocates those logger handlers. Change their `config => #{file => ...}` paths in `sys.config` when a different location is required.

## 8. Store secrets securely

Do not place secrets in Git, `damage.config`, `/etc/default/damage`, command-line arguments, or unit-file overrides.

### Source shell

Run `rebar3 shell`, then enter the required calls.

### Packaged release console

With the service running:

```bash
sudo -u damage -H /opt/damage/bin/damage remote_console
```

Run the masked interactive setup for the standard integrations:

```erlang
damage:check_setup().
```

Store or replace an individual integration secret directly only when needed:

```erlang
%% Bitcoin Core RPC password
secrets:encrypt_store(bitcoin_rpc_password, "REPLACE_ME").

%% General Nostr identity
secrets:encrypt_store(nostr_nsec, "nsec1_REPLACE_ME").

%% SMTP password — this is the current key name
secrets:encrypt_store(smtp_pass, "REPLACE_ME").

%% Core Lightning rune
secrets:encrypt_store(cln_rune, "REPLACE_ME").

%% LND macaroon
secrets:encrypt_store(lnd_macaroon, "REPLACE_ME").

%% Optional NWC service identity
secrets:encrypt_store(damage_nostr_nsec, "nsec1_REPLACE_ME").
```

To detach from `remote_console` without stopping the running service, press `Ctrl-G`, type `q`, and press Enter. Do **not** call `q().` from a remote console, because that can stop the node.

Literal values entered directly may be retained in Erlang shell history. Prefer the masked setup flow and securely clear any persistent history after manual secret entry.

Generate upstream credentials where needed:

```bash
python3 ./bin/bitcoin_rpcauth.py
lightning-cli createrune
```

The old `smtp_password` key is obsolete; the current setup code reads `smtp_pass`.

## 9. Integration checks

### SMTP and account confirmation

Set the non-secret SMTP values in the `damage` application block and store the password as `smtp_pass`. Confirm that `api_url` points to the public origin; otherwise confirmation and reset links will be wrong.

Create a test account only after SMTP is operational:

```bash
curl --fail-with-body \
  -X POST 'https://bdd.example.com/accounts/create' \
  -H 'content-type: application/json' \
  --data '{"email":"operator@example.com","full_name":"Operator"}'
```

### IPFS/Kubo

Feature execution and report publication can depend on IPFS. Verify the daemon and API before accepting production traffic:

```bash
ipfs version
ipfs id
```

Keep the IPFS API on a trusted interface. Expose only a gateway route when public retrieval is required.

### Bitcoin and Lightning

Validate Bitcoin RPC and the selected Lightning backend independently before enabling top-ups, NWC, invoices, or L402. Use restricted credentials, least-privilege CLN runes, and narrowly scoped filesystem access to TLS certificates and macaroons.

### Aeternity

The node needs reachable Aeternity node and middleware endpoints for account, contract, balance, and execution-settlement features. Keep multiple endpoints in the relevant lists when operational resilience is required.

### Nostr, NIP-46, and NWC

Treat the Nostr signer and wallet-connect paths as security-sensitive services:

- Generate signing keys in the intended vault or protected environment.
- Pin the expected bunker public key and authorised client list.
- Keep method and event-kind allowlists narrow.
- Preserve replay, rate, stale-event, size, required-tag, active-content, timeout, and deterministic audit controls.
- Configure only trusted relay URLs and review whether traffic bypasses or uses a proxy.
- Explicitly choose and test the NWC ledger/signing mode rather than depending on a default.

## 10. Nginx and TLS

Install Nginx and an ACME client using the packages for your system. Common examples are:

```bash
# Debian/Ubuntu
sudo apt install -y nginx certbot python3-certbot-nginx

# Arch Linux
sudo pacman -S --needed nginx certbot certbot-nginx

# Fedora/RHEL family
sudo dnf install -y nginx certbot python3-certbot-nginx
```

Keep DamageBDD bound to `127.0.0.1:4888` and publish it through Nginx.

Create `/etc/nginx/conf.d/damage.conf` or the equivalent file for your distribution:

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

Validate and reload:

```bash
sudo nginx -t
sudo systemctl reload nginx
```

Obtain TLS with your normal ACME client. For Certbot on a supported Nginx installation:

```bash
sudo certbot --nginx -d bdd.example.com
sudo certbot renew --dry-run
```

Then update the DamageBDD configuration:

```erlang
{api_url, "https://bdd.example.com"},
{cookie_secure, true}
```

Restart `damage` after editing the configuration.

Do not copy a deployment-specific Nginx file containing internal hostnames, certificates, upstreams, or Lightning routes without reviewing every directive.

## 11. Firewall and network exposure

A typical public node exposes only TCP 80 and 443 through the reverse proxy.

Never expose:

- EPMD on TCP `4369`.
- Erlang distribution ports.
- IPFS API port `5001`.
- Database, wallet, Lightning RPC, or vault-management ports.
- The DamageBDD listener on `4888` when Nginx is the intended entry point.

Confirm the listener:

```bash
ss -ltnp | grep ':4888'
```

Expected production binding:

```text
127.0.0.1:4888
```

## 12. Validate the node

### Build and runtime identity

```bash
curl --fail-with-body http://127.0.0.1:4888/api/version | jq
```

A successful response contains `ok: true` and a nested version object with application version, Git SHA, build time/environment, OTP release, and ERTS version.

### Node balances

```bash
curl --fail-with-body http://127.0.0.1:4888/api/node/balances | jq
```

This endpoint is public in the current HTTP resource. Restrict it in Nginx when publishing node wallet metadata is not acceptable.

### Live step catalogue

```bash
curl --fail-with-body http://127.0.0.1:4888/steps.yaml | less
```

### Authenticated feature execution

Create `smoke.feature`:

```gherkin
Feature: Local DamageBDD smoke test

  Scenario: Read node version
    Given I am using server "http://127.0.0.1:4888"
    When I make a GET request to "/api/version"
    Then the response status must be "200"
    Then the response must contain text "git_sha"
```

Authenticate after creating and confirming an account:

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

The runner first performs a dry run. A valid test can still be rejected when the account lacks execution balance or when the target is not authorised for concurrent load.

### Execute a feature from IPFS

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

## 13. Operations

### Restart and status

```bash
sudo systemctl restart damage
sudo systemctl is-active damage
sudo systemctl status damage --no-pager
```

### Package upgrade

Download the current package from the node page and install it over the existing package. The installer preserves an existing `/etc/damage/damage.config` and persistent state, but take a backup first.

```bash
sudo cp -a /etc/damage "/root/damage-config-backup-$(date +%F)"
sudo tar -C /var/lib -czf "/root/damage-state-$(date +%F).tgz" damage
```

Then install the new package with the same package-manager command used initially and verify `/api/version`.

### Source upgrade

```bash
cd /path/to/DamageBDD
git fetch --all --tags
git pull --ff-only
rebar3 compile
rebar3 eunit
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

### Back up

Back up at least:

- `/etc/damage/damage.config`.
- `/var/lib/damage`, including the encrypted secret store and node identity material.
- Any external vault, wallet, IPFS, database, and Lightning state required by the deployment.
- Recovery instructions and the keys needed to decrypt backups.

Logs are useful for incident response but are usually not the primary recovery state.

## 14. Troubleshooting

### `systemctl status damagebdd` says the unit does not exist

The current service is named `damage`:

```bash
sudo systemctl status damage
```

### Configuration changes have no effect

Check all three current identifiers:

```text
Application key: damage
Configuration:  /etc/damage/damage.config
Service:        damage.service
```

Then inspect the actual command line:

```bash
systemctl cat damage
```

It should load:

```text
-config /etc/damage/damage.config
```

### `/health` returns 404

Use:

```bash
curl http://127.0.0.1:4888/api/version
```

### The node cannot write logs or reports

```bash
sudo install -d -o damage -g damage -m 0750 \
  /var/lib/damage /var/log/damage
sudo chown -R damage:damage /var/lib/damage /var/log/damage /opt/damage
sudo systemctl restart damage
```

Also verify every logger file path in `damage.config`.

### Account confirmation email is not sent

Verify:

- `smtp_host`, `smtp_hostname`, `smtp_from`, `smtp_user`, and `smtp_port`.
- `secrets:retrieve_decrypt(smtp_pass)` succeeds.
- `api_url` is the correct public origin.
- The service can resolve and connect to the SMTP server.
- Spam filtering and sender-domain policy.

### Build fails because `nvcc` is missing

Do not use the `cuda` profile. This is sufficient for a normal release:

```bash
rebar3 as prod release
```

### IPFS operations fail

```bash
command -v ipfs
ipfs version
ipfs id
systemctl status ipfs --no-pager 2>/dev/null || true
```

Confirm that the configured IPFS API/gateway address matches the running daemon and that the `damage` user can access it.

### Aeternity or middleware calls fail

Check DNS, TLS, proxy policy, and every endpoint in `ae_nodes`, `ae_mdw_nodes`, and `ae_mdw_ws_nodes`. Keep the version endpoint as the first local-process check; chain connectivity is a separate dependency.

### Package install fails in a container

The post-install hook intentionally leaves the unit and configuration in place without running `systemctl` when it detects a container/chroot. Start the release directly:

```bash
/opt/damage/bin/damage foreground -config /etc/damage/damage.config
```

### Inspect installer actions

```bash
sudo less /var/log/damage/install.log
```

## 15. Security checklist

Before exposing a node:

- Keep the DamageBDD listener on loopback and terminate TLS at a maintained proxy.
- Expose only necessary ports; never expose EPMD or Erlang distribution.
- Keep `node_admins` empty until trusted accounts are explicitly chosen.
- Use the packaged dedicated `damage` account and canonical hardened unit.
- Store integration credentials with `secrets:encrypt_store/2`.
- Do not persist static cloud credentials or vault passphrases in the systemd environment.
- Restrict and monitor the public node-balances endpoint if wallet metadata is sensitive.
- Use reverse-proxy and application rate limits.
- Set CPU, memory, open-file, and request-size limits appropriate to the intended concurrency.
- Patch Erlang/OTP, native libraries, Nginx, IPFS, wallet software, and DamageBDD regularly.
- Test restoration of the encrypted secret store and node identity from backup.
- Review NIP-46, NWC, L402, and payment features as separate security boundaries.

See [SECURITY.txt](SECURITY.txt) and <https://damagebdd.com/security/> for reporting and hardening guidance.

## 16. Uninstall

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

Package removal may preserve configuration and state. Delete them only after confirming that no keys, reports, balances, or recovery data are still required:

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
