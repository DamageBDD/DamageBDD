# Node security verification: local production baseline

## Install and run

This is an incremental addition to the feature-driven Verify workspace and its
catalogue-discovery fix. It does not change the dashboard, router, supervisor,
wallet, secrets implementation, application configuration or security policy.

Apply `damage-node-security-verification.patch` from the umbrella repository root:

```sh
PATCH="$HOME/Downloads/damage-node-security-verification.patch"
git apply --check "$PATCH" &&
git apply "$PATCH" &&
rebar3 compile &&
rebar3 eunit --module=damage_node_security_tests,damage_verification_catalog_tests,damage_verification_tests,damage_nwc_payment_policy_tests
```

Rebuild/restart the node through its normal development or release procedure so
both the new module and updated step implementation are loaded. Open
`/dashboard#verification-tab`, select **Refresh catalog**, and choose
**Verify this node's security baseline**. Review and approve the normal execution
estimate. The checker itself sends no payments, but normal DamageBDD execution
charges and report publication still apply.

With a custom `verification_feature_dir`, deploy `node-security.feature` to that
administrator-controlled directory instead. The catalogue does not automatically
merge custom and packaged directories.

There are no feature descriptors, new browser inputs or new configuration files.
The feature supplies its title, description, tags, scenario and step. The selected
node is the BEAM node executing the run; an account/context variable cannot change
it, choose another filesystem path or weaken the baseline. This is not a remote
scan of a URL entered into context.

## Deliberately strict profile

`linux-local-loopback-v1` is a production baseline for a Linux node behind a
**same-host reverse proxy**. Every TCP listener owned by this BEAM must be on
loopback. It deliberately flags wildcard, private-LAN and public bindings,
including legitimate public TLS or clustered-distribution listeners. It does not
infer that a security group, firewall or TLS setting makes such listeners safe.
Those deployments need a separately specified policy, not an exception checkbox
that silently turns this baseline green.

The check can fail on a development `rebar3 shell`; that is expected. It never
silently switches to a more permissive development profile.

## Controls and actual evidence

The collector evaluates all 15 controls and writes all findings, rather than
stopping measurement on the first failed control.

| Control | Pass condition / scope |
| --- | --- |
| Process UID | The four UID fields in `/proc/self/status` are nonzero. |
| Process capabilities | Effective, permitted, inheritable and ambient capability sets are zero. |
| No new privileges | `NoNewPrivs` is `1`. |
| Creation permissions | Umask masks all group/other permissions, normally `0077`. |
| OS core size limit | The current soft core-file size limit is zero. |
| Core collector | No piped kernel core handler is configured. A piped handler is **unknown**, not a pass: its effective storage policy is outside this collector. |
| BEAM crash-dump setting | `ERL_CRASH_DUMP_SECONDS=0` or `ERL_CRASH_DUMP_BYTES=0` is explicitly present. |
| Credential environment | The fixed password/cloud/release credential environment variables listed below are absent or empty. |
| Cookie arguments | No `-setcookie` init argument, including arguments expanded from an args file. This does not check cookie entropy or cookie-file permissions. |
| Node keystore | Actual path from `secrets:keystore_path/0` satisfies the file checks below. |
| Secrets database | Actual path from `secrets:secrets_dets_path/0` satisfies those checks. |
| BEAM TCP listeners | Listening sockets observed in procfs and correlated with this process's socket FDs bind to loopback. Outbound established connections are not treated as listeners. |
| EPMD TCP listener | All observed listeners at `ERL_EPMD_PORT` (default `4369`) in this network namespace bind to loopback. No listener observed is explicitly `not_applicable`. |
| Secure-cookie configuration | The existing `damage.cookie_secure` setting is `true`, using its existing true default. This is a configuration observation, not an HTTP cookie/HTTPS test. |
| Automatic code reload | `code_reload` and `operator_hotcode` explicitly have `{enabled,false}`, no registered `damage_reload` process exists and the legacy `sync` application is not running. Missing or ambiguous configuration is unknown. |

The checked credential environment variable names are `DAMAGE_SECRET_KEY`,
`DAMAGE_NSECBUNKER_VAULT_PASSPHRASE`, `AWS_ACCESS_KEY_ID`,
`AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`, `GITHUB_TOKEN`, and `GH_TOKEN`.
Their values are never returned or serialized. This is not an exhaustive secret
scanner and does not inspect Git history, secret-store records, logs or memory.

Storage checks inspect metadata only. Each resolved file must be nonempty,
regular, owned by the service filesystem UID, owner-readable, have no executable,
special or group/other permission bits, and have exactly one hard link. Its
immediate parent must be private to its owner. Ancestors must be owned by root or
the service UID and not group/other-writable; a root-owned sticky ancestor such as
`/tmp` is allowed above the private immediate parent. Symlinks in the file or any
ancestor are rejected. The collector does not follow a failed resolver with a
hardcoded legacy path. Older secrets modules without the path APIs yield unknown.
It does not read or decrypt either file, prove encryption correctness, inspect
POSIX ACLs, or prove historical absence of leakage.

Socket observation handles IPv4, IPv6 and IPv4-mapped loopback addresses using
native-endian procfs words. Missing/unreadable/malformed socket tables or inability
to inspect file descriptors produce unknown. Both TCP tables are required by
this implementation; a kernel without `/proc/self/net/tcp6` is not silently
certified. FD sets are sampled before and after the tables to reduce races; this
is not an atomic freeze of the process or network namespace.

The process-status fields are observations from the thread-group leader's
`/proc/self/status`; this is not an audit of every thread, NIF, child process or
service. Non-Linux systems report unsupported/unknown and cannot pass.

## Authorization, side effects and evidence

The new clause is in the existing `steps_verification` module, which already
requires `node_admin`. The implementation also calls `steps_utils:is_admin/1`
before inspection or evidence generation. Feature tags and a supplied
`node_admin=true` map value do not replace the existing authoritative role check.
The implementation never uses a supplied `node_security_report` to decide a pass;
it measures anew on every invocation.

`damage_verification_runner:revision/0` now includes the collector's module digest,
so a code change invalidates a previously quoted observation of this implementation.
The patch does not otherwise change approval, costing, settlement or scheduling.

There are no shell commands, HTTP requests, network scans, secret getters, account
mutations, service restarts, permission changes to inspected files, or remediation
operations. Only ordinary runner artifacts and the new redacted evidence file are
written. Normal DamageBDD billing/report-network activity remains the runner's
responsibility, not this collector's.

The collector has a ten-second observation deadline and bounded procfs reads/FD
enumeration. Timeout requests collector termination and allows at most one second
for reaping; a blocked native call may defer final resource cleanup. A collector
error or timeout cannot pass. It is linked to the execution caller while
collecting, so abnormal caller termination also requests its termination. It
unlinks before returning and is unlinked before timeout termination.

A fixed `node-security.json` file is written in the trusted runner `run_dir`,
using exclusive creation, mode `0600`, write/sync/close checking. An existing file
or symlink is not overwritten. Failure to write evidence blocks a pass. Use a new
run for each execution; do not repeat this aggregate step within the same run.
No run directory can be supplied through context.

The JSON contains policy version, observation time, scope, overall result and
fixed control IDs/statuses/reasons/remediation text. It contains no credential
values, raw environment, process arguments, raw procfs data, secret paths, IP
addresses or secret-file contents. `node_security_report` in the result context
contains the same redacted report. Existing run/report logging behaviour is not
replaced by this patch.

`failed` means a measured setting violates this profile. `unknown` means a control
could not be established. Both fail the overall step; neither becomes a warning
that still allows a green result. `not_applicable` is used only when no listener
at the configured EPMD port was observed. The Gherkin assertion runs after all
findings have been collected and persisted.

The existing workspace shows the feature and run outcome; the detailed findings
are in the native run artifacts as `node-security.json`. This patch deliberately
does not add a special node-security dashboard or change generic result rendering.

A trusted operator can also inspect the redacted snapshot in the Erlang shell:

```erlang
damage_node_security:inspect().
```

That function does not write a file, execute a feature, charge the account or
publish a report. Shell/Erlang execution is already inside the node trust boundary.

## Remediation and limits

Use approved operational changes, not this checker, to address failures. Examples
of existing settings expected by this profile, inside the existing `damage`
application configuration, are:

```erlang
{cookie_secure, true},
{code_reload, [{enabled, false}]},
{operator_hotcode, [{enabled, false}]}
```

Apply process identity, capability, umask, no-new-privileges and dump controls
through the service manager. Do not blindly change listener bindings on a
production cluster: this profile assumes local-only backend listeners. Do not
remove a bootstrap password before ensuring the approved unlock/recovery path
works. This patch does not change these settings automatically.

Passing these observations does **not** establish host integrity, absence of
malware or CVEs, patch currency, external firewall/security-group rules, reverse
proxy TLS/header/cookie behaviour, cloud IAM/IMDS security, other host services,
UDP exposure, custom EPMD/proxy behaviour, container-host security, complete secret
inventory, encryption correctness, financial custody or an independently attested
release. A compromised host can falsify self-observation. Reports remain
point-in-time, node-local evidence; the runner provides their normal provenance.

## Tests and validation

`damage_node_security_tests` includes pure assessment and parsing tests, multi-
failure aggregation, missing-evidence cases, IPv4/IPv6/native-order socket parsing,
private filesystem fixtures, symlink/hardlink rejection, exclusive evidence writes,
redaction, collector deadlines, real role-check rejection of a forged principal,
and real Gherkin/catalogue integration. The existing workspace parser test also
loads the new feature through the extended `steps_verification` catalogue.

These tests do not require production secrets, AWS, Nostr relays or a Lightning
payment. Fixtures are disposable synthetic files; no real secret store is opened.

See the bundle's `validation/RESULTS.md` for what was actually run in the delivery
environment. Source inspection and patch checks are not Erlang compilation or
live deployment validation.

### Reference semantics

- Erlang distributed-node security: `https://www.erlang.org/docs/27/system/distributed.html`
- Erlang crash-dump controls: `https://www.erlang.org/doc/apps/erts/erl_cmd.html`
- Linux procfs fields: `https://www.kernel.org/doc/html/latest/filesystems/proc.html`
- Linux no-new-privileges: `https://www.kernel.org/doc/html/latest/userspace-api/no_new_privs.html`
- Core dump limits and piped handlers: `https://man7.org/linux/man-pages/man5/core.5.html`

These references describe the mechanisms. They do not attest any DamageBDD
installation or substitute for running its checks.
