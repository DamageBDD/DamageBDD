# Automatic local AWS helper initialization and health

This follow-up manages the **node's Python environment**, not an AWS account,
cloud deployment, image build, indexing dispatcher or blockchain transaction.
The existing account allowlist, TLS/origin checks and explicit approvals remain.

## Defaults and one-time configuration

With `compute_settings_enabled=true` and `aws_setup_enabled=true`, a supervised
`ecai_aws_setup_runtime` worker starts independently of dashboard requests.
Its installation work runs in an asynchronous local port; startup and HTTP
requests do not wait for pip. Failed initialization blocks AWS credential intake
but leaves the rest of ECAI running.

Use these entries in the existing ECAI application environment:

```erlang
{aws_setup_python, auto},
{aws_setup_runtime_auto_install, true},
```

Replace any previous explicit `/opt/ecai/.../bin/python` value with `auto` to
select managed initialization. An absolute `aws_setup_python` path is always
**check-only**: it is not created, repaired, reinstalled or deleted by this code.
Unset/omitted `aws_setup_python` also means auto.

The default managed root is:

```text
ecai_paths:runtime_dir()/python/aws-setup
```

`ecai_paths` retains the uploaded source's established precedence for ECAI,
Damage and XDG state directories. For example, an ECAI `state_dir` of
`/var/lib/damage/ecai` produces
`/var/lib/damage/ecai/runtime/ecai/python/aws-setup`.

An operator may choose a location inside the DamageBDD checkout instead:

```erlang
{aws_setup_runtime_dir, "/home/steven/DamageInc/DamageBDD/.venvs/ecai-aws-setup"},
```

Use an absolute, service-owned directory, not a group/world-writable directory
or a symlink at the managed root. Keep `.venvs/` out of Git. Do not use a location
that accepts uploads or arbitrary user-written files. The service identity needs
write permission here; the bootstrap does not invoke sudo or change ownership.
An immutable deployment can supply a prebuilt explicit interpreter instead.

## Automatic lifecycle

1. If automatic AWS setup is disabled, no interpreter, environment or installer
   is launched. The worker checks the enable setting again once per minute.
2. When enabled, the worker finds `aws_setup_bootstrap_python` (default `python3`).
3. Managed mode takes a filesystem lock, checks the requirements fingerprint,
   and verifies the selected environment. A healthy environment is reused with
   **no pip installation and no package-index request**.
4. A missing/broken managed environment is built at a new final generation path.
   Standard-library `venv` creates it; pip installs the bundled exact direct
   requirements using wheels only. System Python packages are never installed
   into or upgraded.
5. The candidate is checked in isolation: Python >=3.11, a real venv in managed
   mode, exact versions for declared requirements, boto3/botocore imports, and
   `pip check` for dependency consistency.
6. Only then is `current.json` replaced atomically. The venv itself is **not moved**.
   It remains at its final path, preserving absolute interpreter paths.
7. Rechecks run every five minutes. Failures retry after 60, 120, 240, 480 and then
   900 seconds. A check in progress temporarily gates new AWS helper sessions;
   existing subprocesses are not modified by the health check.

The generation fingerprint includes requirements bytes and bootstrap Python
identity. Changes trigger a new generation rather than upgrading one in use.
Regular interrupted/failed builds remove only the new generation created by that
attempt. Older generations are retained for existing sessions; a hard kill can
leave an incomplete generation for later operator cleanup. There is no automatic
pruning of older generations. Never remove one while a session uses it.

The existing `requirements.txt` is preserved (`boto3==1.43.18` in the upload).
Transitive packages are resolved within boto3's declared requirements and checked
by pip; this is **not** a complete transitive hash lock or a provenance guarantee.
Dependency changes still require review of the shipped requirements/artifacts.

## Network, offline mode and isolation

The initial managed install normally uses `https://pypi.org/simple`. It uses no
extra index and no source distribution builds. Subsequent healthy checks are
local. A fresh install needs DNS/TLS/egress unless a wheelhouse is configured.

```erlang
{aws_setup_wheelhouse, "/srv/ecai/aws-wheels"},
```

The wheelhouse must contain compatible wheels for the pinned direct requirement
and all dependencies. It selects `--no-index --find-links` and performs no package
index fallback. It is operator-controlled, not a dashboard parameter.

Optional settings:

```erlang
{aws_setup_bootstrap_python, "/usr/bin/python3"},
{aws_setup_runtime_timeout_seconds, 600},  %% range 10..1800
{aws_setup_runtime_auto_install, false},  %% check existing managed env only
```

Install/check children receive a minimal environment without AWS credentials,
Python injection variables, proxy credentials or package-index overrides.
Pip configuration is disabled and its output is not relayed into logs or the UI.
Environments never contain customer setup keys. Runtime AWS session helpers keep
the existing workload credential chain; the installer does not change it.

Kernel file locking serializes concurrent initializers sharing a managed root on
a local filesystem with working flock support. Do not rely on this lock on an
unverified network filesystem.
Timeout or closed Erlang stdin cancels the bootstrap, kills its active child
process group and releases the lock. This is node-local POSIX/Linux code, not a
Windows environment manager.

Missing OS Python, venv/ensurepip support, mount permissions or offline packages
still require operator action. The node does not install operating-system packages
or build the worker's container image automatically.

## Dashboard and diagnostics

Compute → AWS Batch → Automatic setup reports the local phase, SDK versions,
readiness or a sanitized error and retry time. Refresh is read-only. Polling runs
while that view is open; it does not start an installation or a cloud operation.

The exact interpreter path is omitted from the dashboard's runtime status. From
the trusted node Erlang shell:

```erlang
ecai_aws_setup_runtime:status().
ecai_aws_setup_runtime:python().
ecai_aws_setup_runtime:recheck().
ecai_aws_setup_config:ready().
```

`recheck/0` schedules a local check and immediately returns; it is not a web API.
In-progress initialization is single-flight. Config/requirements changes invalidate
cached readiness; a normal timer or explicit operator recheck applies them.
When changing startup config, restart the updated release as usual. Do not expect
`rebar3 compile` by itself to reload `sys.config` or add the supervised child to a
running supervisor tree.

A ready local helper is **not** proof of AWS credentials, coordinator IAM trust,
worker-image availability, cloud permissions or production indexing dispatch.
Those are still validated through the separate setup workflow.

## Tests and validation boundary

```sh
python3 apps/ecai/test/test_aws_runtime.py
python3 apps/ecai/test/test_aws_setup.py
python3 apps/ecai/test/test_aws_setup_browser.py --dom-only
rebar3 eunit --module=ecai_aws_setup_runtime_tests,ecai_aws_setup_tests
```

The Python runtime suite includes actual venv creation and pip installation from
**synthetic offline SDK wheels**. It tests install/reuse, two initializer processes,
failed-build isolation, cancellation, timeouts, unsafe paths, configuration input
rejection, check-only external interpreters and environment sanitization. This
fixture verifies installation mechanics, not the real SDK's implementation.
The existing provisioning suite uses boto3 and botocore stubs with no AWS traffic.
Browser tests use mocked authenticated APIs and production wizard markup/JS;
`--dom-only` does not test real HTTP, TLS, authentication or proxy deployment.

Native tests cover configuration modes, supervisor readiness transitions and
failure/backoff with a protocol fixture. They do not run a real package install.
Run compilation/EUnit in the complete DamageBDD checkout; no Erlang runtime was
available in the editing environment. No live AWS resources are created by these
tests or by local environment initialization.

## Implementation references

- Python venv (environments are not relocatable): https://docs.python.org/3/library/venv.html
- pip install: https://pip.pypa.io/en/stable/cli/pip_install/
- Erlang gen_server: https://www.erlang.org/doc/apps/stdlib/gen_server.html

### Validation in the editing environment

Passed: 23 local-runtime tests, 28 existing AWS provisioning/stub tests, seven
compute dashboard/Node-backed contract tests, and 11 mocked Chromium wizard
tests (including two new runtime-status cases). JavaScript syntax and Python
compilation checks passed. Forward/reverse patch and changed-file byte checks
are included in the delivery validation.

An additional installation using an **offline repack of already installed real
SDK distributions** created a fresh managed venv and passed imports and pip check
with Python 3.13.5, boto3 1.43.18 and botocore 1.43.18. This confirms the local
runtime path with real SDK code; it is not a fresh PyPI download or an upstream
wheel provenance check. PyPI DNS was unavailable in this environment. Native
Erlang compilation/EUnit and live AWS/authentication remain untested here.
