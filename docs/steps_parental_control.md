# DamageBDD Parental Controls for Arch Linux

`steps_parental_control.erl` adds DamageBDD steps for defining, applying, verifying, and removing local parental controls on an Arch Linux host.

The module combines:

- a dedicated Squid proxy bound to `127.0.0.1`;
- per-user nftables output rules;
- blocklist or allowlist domain policy; and
- proxy environment variables for the controlled Unix accounts.

The enforcement is deliberately **fail-closed**. A controlled user is allowed to open TCP connections only to the configured proxy port on loopback. Every other output packet from that UID is rejected. An application that ignores the proxy settings therefore loses network access instead of bypassing the policy.

> **Important:** This module does not intercept or decrypt TLS. HTTPS filtering uses the destination hostname supplied in the Squid `CONNECT` request.

## Enforcement model

```text
Controlled browser or application
              |
              | HTTP/HTTPS proxy
              v
     127.0.0.1:3128 (default)
              |
            Squid
              |
     blocklist or allowlist
              |
           Internet
```

For each controlled UID, the generated nftables chain has the equivalent of:

```nft
meta skuid <UID> oifname "lo" tcp dport <PROXY_PORT> accept
meta skuid <UID> reject
```

This means the controlled account cannot directly use DNS, QUIC, a VPN, a different proxy port, or another loopback service. Only the local Squid listener is reachable from that UID.

## Requirements

The DamageBDD runner must run on a system using systemd and must be able to execute these programs:

```text
/usr/bin/squid
/usr/bin/nft
/usr/bin/ss
/usr/bin/systemctl
/usr/bin/id
/usr/bin/install
/usr/bin/grep
/bin/sh
```

The module also expects:

- an existing unprivileged Squid account named `proxy`;
- an existing local Unix account for every controlled user;
- an authenticated DamageBDD admin context for apply and remove operations;
- root execution, or non-interactive privilege escalation through `sudo -n`; and
- controlled account UIDs of at least `1000` by default.

Check the host before running a feature:

```bash
command -v squid nft ss systemctl id install grep
id proxy
id child
sudo -n true
```

`sudo -n true` is only required when the DamageBDD runner is not already root. The module never opens an interactive password prompt.

## Installing the step module

Add `steps_parental_control.erl` to the DamageBDD application source tree, ensure `steps_parental_control` is included by the project step loader, and compile the application:

```bash
rebar3 compile
```

The module exports both `step/6` and `step_dry/6`. Dry-run matching uses explicit parameterised clauses and does not contain a catch-all clause that could claim unrelated steps.

## Available Gherkin steps

### Select controlled users

```gherkin
Given I manage parental controls for user "child"
```

The step may be repeated to control multiple users. The username must match:

```text
^[a-z_][a-z0-9_-]{0,31}$
```

The user must exist when the policy is applied.

### Select the proxy port

```gherkin
And the parental proxy port is "3128"
```

The valid range is `1` through `65535`. When omitted, the default is `3128`.

### Select the policy mode

```gherkin
And the parental control policy is "blocklist"
```

Supported values are:

- `blocklist`: deny listed domains and permit other web destinations;
- `allowlist`: permit only listed domains.

When omitted, the policy defaults to `blocklist`. Applying an empty allowlist is rejected to avoid accidentally disabling all web access.

### Add blocked domains

```gherkin
And I block parental domain "tiktok.com"
```

The stored Squid entry is `.tiktok.com`, which covers the domain and its subdomains.

### Add allowed domains

```gherkin
And I allow parental domain "wikipedia.org"
```

The stored Squid entry is `.wikipedia.org`, which covers the domain and its subdomains.

### Apply the configuration

```gherkin
When I apply the parental controls
```

This operation requires a DamageBDD admin context. It writes the generated files, validates the Squid and nftables configurations, reloads systemd, enables the service, and starts or restarts it.

### Remove the configuration

```gherkin
When I remove the parental controls
```

This operation requires a DamageBDD admin context. It stops and disables the service, removes the `damage_parental` nftables table, deletes the generated files, and reloads systemd.

### Verify the service and listener

```gherkin
Then the parental controls should be active
```

This verifies all of the following:

- `damage-parental-control.service` is active;
- the `inet damage_parental` nftables table exists; and
- the configured `127.0.0.1:<port>` TCP listener exists.

### Verify per-user enforcement

```gherkin
And user "child" internet access should be proxy only
```

This verifies that the generated nftables output chain contains both the proxy-port accept rule and the final reject rule for the selected UID.

### Verify a blocklist entry

```gherkin
And parental domain "tiktok.com" should be blocked
```

This verifies that `.tiktok.com` exists in `/etc/damagebdd/parental-block.txt`.

### Verify an allowlist entry

```gherkin
And parental domain "wikipedia.org" should be allowed
```

This verifies that `.wikipedia.org` exists in `/etc/damagebdd/parental-allow.txt`.

> The domain assertion steps verify generated policy files. They do not perform a browser request or prove that the remote site is unreachable. Use the manual end-to-end checks below when validating live enforcement.

## Example 1: Block selected sites for one user

```gherkin
@archlinux @parental-control
Feature: Block selected websites for a child account

  Scenario: Apply a blocklist to the child account
    Given I manage parental controls for user "child"
    And the parental control policy is "blocklist"
    And I block parental domain "tiktok.com"
    And I block parental domain "reddit.com"
    And I block parental domain "discord.com"

    When I apply the parental controls

    Then the parental controls should be active
    And user "child" internet access should be proxy only
    And parental domain "tiktok.com" should be blocked
    And parental domain "reddit.com" should be blocked
    And parental domain "discord.com" should be blocked
```

In blocklist mode, other HTTP and HTTPS destinations remain available through Squid unless they are also listed.

## Example 2: Allow only approved educational sites

```gherkin
@archlinux @parental-control
Feature: Restrict a child account to approved educational websites

  Scenario: Apply a strict allowlist
    Given I manage parental controls for user "child"
    And the parental control policy is "allowlist"
    And I allow parental domain "wikipedia.org"
    And I allow parental domain "khanacademy.org"
    And I allow parental domain "archlinux.org"

    When I apply the parental controls

    Then the parental controls should be active
    And user "child" internet access should be proxy only
    And parental domain "wikipedia.org" should be allowed
    And parental domain "khanacademy.org" should be allowed
    And parental domain "archlinux.org" should be allowed
```

Modern sites often load scripts, media, fonts, authentication, or APIs from additional domains. Add each required dependency to the allowlist when a permitted site only loads partially.

## Example 3: Control multiple users on a custom port

```gherkin
@archlinux @parental-control
Feature: Apply one household policy to multiple local accounts

  Scenario: Use a dedicated proxy port for two users
    Given I manage parental controls for user "child"
    And I manage parental controls for user "student"
    And the parental proxy port is "3130"
    And the parental control policy is "blocklist"
    And I block parental domain "example-social.test"
    And I block parental domain "example-video.test"

    When I apply the parental controls

    Then the parental controls should be active
    And user "child" internet access should be proxy only
    And user "student" internet access should be proxy only
    And parental domain "example-social.test" should be blocked
    And parental domain "example-video.test" should be blocked
```

The generated `/etc/profile.d/damage-parental-proxy.sh` exports the custom proxy URL only for `child` and `student`.

## Example 4: Remove parental controls

```gherkin
@archlinux @parental-control
Feature: Remove the local parental-control policy

  Scenario: Restore normal networking
    When I remove the parental controls
```

The current module does not expose a separate `Then the parental controls should be inactive` assertion. Verify removal manually with the commands in the removal section below.

## Example 5: Replace an existing policy

The generated nftables file uses `add table` and `add chain`. In the current implementation, applying or restarting while the fixed `damage_parental` table already exists may fail. Remove the active configuration before applying a replacement policy.

First run:

```gherkin
Feature: Remove the previous parental-control policy

  Scenario: Remove the existing policy
    When I remove the parental controls
```

Then run the new policy as a separate feature or execution:

```gherkin
Feature: Apply the replacement parental-control policy

  Scenario: Replace the policy with an allowlist
    Given I manage parental controls for user "child"
    And the parental control policy is "allowlist"
    And I allow parental domain "wikipedia.org"
    And I allow parental domain "khanacademy.org"

    When I apply the parental controls

    Then the parental controls should be active
    And user "child" internet access should be proxy only
```

## Files created by the module

Applying a policy writes these files:

| File | Purpose |
| --- | --- |
| `/etc/damagebdd/parental-squid.conf` | Dedicated Squid listener and access policy |
| `/etc/damagebdd/parental-block.txt` | Normalised blocklist entries |
| `/etc/damagebdd/parental-allow.txt` | Normalised allowlist entries |
| `/etc/damagebdd/parental-users.txt` | Controlled `username:uid` records |
| `/etc/damagebdd/parental-control.nft` | Per-UID nftables rules |
| `/etc/profile.d/damage-parental-proxy.sh` | Conditional proxy environment variables |
| `/etc/systemd/system/damage-parental-control.service` | Squid and nftables service unit |

The service runs:

```text
/usr/bin/nft -f /etc/damagebdd/parental-control.nft
/usr/bin/squid -N -f /etc/damagebdd/parental-squid.conf
```

If Squid exits after the nftables rules have loaded, the rules remain present. Controlled accounts consequently remain fail-closed until the proxy returns or the policy is explicitly removed.

## Browser configuration

The module writes these variables for each controlled account:

```text
http_proxy
https_proxy
ftp_proxy
HTTP_PROXY
HTTPS_PROXY
FTP_PROXY
no_proxy
NO_PROXY
```

A **new login session is required** after applying or changing the policy so `/etc/profile.d/damage-parental-proxy.sh` is read.

Check the environment as the controlled user:

```bash
sudo -iu child
env | grep -i proxy
```

Some graphical browsers do not use shell proxy environment variables. Configure those browsers to use:

```text
HTTP proxy:  127.0.0.1, port 3128
HTTPS proxy: 127.0.0.1, port 3128
```

Use the custom port from the feature when it is not `3128`. A browser that does not use the proxy will fail to connect because direct output from the controlled UID is rejected.

## Manual end-to-end verification

### Inspect the service

```bash
sudo systemctl status damage-parental-control.service
sudo journalctl -u damage-parental-control.service -n 100 --no-pager
```

### Inspect the listener

```bash
sudo ss -ltnp | grep '127.0.0.1:3128'
```

### Inspect the nftables rules

```bash
sudo nft -n list chain inet damage_parental output
```

Expected shape for UID `1001` and port `3128`:

```text
meta skuid 1001 oifname "lo" tcp dport 3128 accept
meta skuid 1001 reject
```

### Inspect the generated policy

```bash
sudo cat /etc/damagebdd/parental-users.txt
sudo cat /etc/damagebdd/parental-block.txt
sudo cat /etc/damagebdd/parental-allow.txt
sudo cat /etc/damagebdd/parental-squid.conf
```

### Test proxied access as the controlled user

```bash
sudo -u child env \
  http_proxy=http://127.0.0.1:3128/ \
  https_proxy=http://127.0.0.1:3128/ \
  curl -I https://wikipedia.org/
```

For a blocked destination in blocklist mode, or a non-allowed destination in allowlist mode, the request should be denied by Squid:

```bash
sudo -u child env \
  http_proxy=http://127.0.0.1:3128/ \
  https_proxy=http://127.0.0.1:3128/ \
  curl -I https://tiktok.com/
```

### Test that direct access fails

Remove the proxy variables for this command. The connection should fail because the controlled UID cannot connect directly to the network:

```bash
sudo -u child env \
  -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
  curl -I https://wikipedia.org/
```

## Verifying removal

After `When I remove the parental controls`, these commands should report that the service, table, and generated files are absent:

```bash
systemctl is-enabled damage-parental-control.service
systemctl is-active damage-parental-control.service
sudo nft list table inet damage_parental
ls -l /etc/damagebdd/parental-*
ls -l /etc/profile.d/damage-parental-proxy.sh
```

Users should start a new login session after removal so the old proxy environment is no longer inherited.

## Configuration

The minimum accepted controlled UID defaults to `1000`. Override it through the Damage application environment:

```erlang
[
    {damage, [
        {parental_control_min_uid, 1000}
    ]}
].
```

The module refuses to control:

- a UID below `parental_control_min_uid`;
- the UID running DamageBDD; or
- the Squid `proxy` UID.

These safeguards prevent accidentally cutting off the test runner, Squid itself, or protected system accounts.

## Squid policy details

The generated Squid configuration:

- binds only to `127.0.0.1:<port>`;
- runs network work under the `proxy` account;
- allows destination ports `80` and `443` only;
- allows `CONNECT` only to port `443`;
- denies IPv4 and IPv6 literal destinations;
- disables object caching;
- removes the forwarded client address; and
- ends with `http_access deny all`.

A blocklist entry such as `example.com` is stored as `.example.com`. An allowlist entry uses the same format. Inputs are lowercased, and leading or trailing dots are removed before validation.

## Troubleshooting

### `Admin privileges required to apply parental controls`

The DamageBDD execution context is not recognised as an administrator by `steps_utils:is_admin/1`. Execute the feature through an authenticated admin account.

### `sudo: a password is required`

The runner is not root and cannot use non-interactive sudo. Run the worker as root or grant only the required commands through a carefully scoped sudoers rule. The module invokes `sudo -n` and will not wait for a password.

### `protected_system_uid`

The selected user's UID is below the configured minimum. Select a normal login account or deliberately adjust `parental_control_min_uid`.

### `refusing_damagebdd_runner_uid`

The selected account has the same UID as the DamageBDD runner. Use a different, unprivileged account.

### `refusing_squid_proxy_uid`

The selected account is the Squid `proxy` account. Squid must remain outside the controlled UID set so it can reach the Internet on behalf of those users.

### `empty_allowlist_would_block_all_web_access`

At least one `I allow parental domain ...` step is required before applying allowlist mode.

### The service fails with an nftables “File exists” error

The `damage_parental` table already exists. With the current generated ruleset, remove the old policy before applying or manually restarting:

```bash
sudo systemctl stop damage-parental-control.service
sudo nft delete table inet damage_parental
sudo systemctl start damage-parental-control.service
```

For a policy change, prefer the DamageBDD remove step followed by a fresh apply execution.

### The browser has no network access after applying

Confirm all of the following:

1. the service is active;
2. Squid is listening on the configured loopback port;
3. the browser is using that exact HTTP and HTTPS proxy;
4. the user started a new login session; and
5. the required domain and any dependency domains are permitted.

Failing to configure the browser proxy is expected to produce no connectivity, because direct traffic is rejected.

### An allowed website is incomplete

Add the site's CDN, authentication, API, media, font, and other dependency domains to the allowlist. The module filters by destination hostname and does not infer related domains.

### A domain assertion passes but the website is still reachable

`parental domain ... should be blocked` checks the generated blocklist file only. Inspect Squid logs and perform the controlled-user request test to verify runtime enforcement.

## Security assumptions and limitations

- Controlled users must not have root, sudo, `CAP_NET_ADMIN`, or another privileged path that can alter nftables or run network software under a different UID.
- The policy is local to one Arch Linux host.
- The module controls domains, not URL paths, page content, search terms, application categories, or usage schedules.
- There is no TLS interception, content inspection, malware scanning, or certificate installation.
- Only ports `80` and `443` are permitted through Squid.
- Other loopback services are inaccessible to controlled UIDs while the policy is active.
- The profile script helps compatible applications discover the proxy, but nftables is the actual bypass-prevention boundary.
- The current ruleset should be removed before reapplication or manual service restart because it creates a fixed nftables table.

Keep a separate administrative session open while testing a new policy so it can be removed if the selected account or allowlist is incorrect.

## License

Apache-2.0, matching `steps_parental_control.erl`.
