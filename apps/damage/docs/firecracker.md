# Firecracker script workers

`damage_firecracker` is an opt-in OTP service for one script per disposable
Firecracker microVM. `steps_firecracker` integrates it with DamageBDD's existing
step discovery and authenticated `node_admin` checks. Nothing changes for existing
Docker steps or feature execution. This version isolates **the script in the
Firecracker step**; it does not move the entire feature, other steps, the BEAM,
payment handling or consensus verification into a VM.

The baseline is the `apps/damage` source in the uploaded `latest-damage.tar.gz`
uploaded on 14 October 2026 (SHA-256
`1b1a2c603ce3899a693e091d2bbe38dc9331cf7f85e63731257b2070817ddf01`).

## Components and boundary

| Component | Runs as | Responsibility |
|---|---|---|
| `damage_firecracker.erl` | Existing unprivileged DamageBDD user | Admission, caller ownership, cancellation, deadlines, bounded results |
| `damage-firecracker-runner` | Root through one restricted sudo command | Validate root-owned policy, verify/copy images, launch/stop jailer in a transient systemd service |
| Firecracker + matching jailer | A reserved UID/GID per concurrent slot | KVM, jail, default seccomp, read-only root disk, vsock |
| `damage-fc-agent` | Guest root | Receive one bounded script, drop workload privileges, capture bounded output |
| `/bin/sh` script | Guest UID/GID 1000 | Execute the supplied script |

The host broker uses **Python 3 standard library only**, with isolated interpreter
mode (`-I`). The guest agent is a statically linked C executable; Python is not
needed in the guest. No command string or script is interpreted by a host shell.
The Firecracker API is disabled after configuration via `--no-api --config-file`.
There is no network interface, MMDS, Docker socket, shared directory or host secret
in the guest. Disk images are copied, hash checked and attached read-only. Guest
writes live in size-limited tmpfs mounts.

Systemd enforces memory (guest allocation + 256 MiB VMM allowance), no swap,
CPU quota, task count, start/stop timeouts and an independent runtime limit. The
jailer does not daemonize: systemd tracks its process through exec into Firecracker.
This version uses jailer's mount/filesystem isolation, without its optional
`--new-pid-ns` mode. Per-job slot locks and crash records prevent reuse of a VM's
UID before successful stop and cleanup. This is not a claim of immunity to
hypervisor, kernel or hardware vulnerabilities.

## Install on an execution host

Requirements: Linux x86-64 with accessible `/dev/kvm`, a systemd system manager,
cgroup v2, Python 3.10+, sudo, and a patched **matching pair** of statically linked
Firecracker/jailer binaries. Provision host CPU/microcode/kernel mitigations using
Firecracker's production guidance. Do not run the DamageBDD BEAM as root.

Install a reviewed Firecracker release at the following paths. The Firecracker
binary basename must be exactly `firecracker` because jail layout is derived
from it. Do not install setuid bits or give the DamageBDD user unrestricted sudo
access to jailer, systemd-run or systemctl.

```sh
sudo install -d -o root -g root -m 0755 /usr/local/libexec/firecracker /etc/damage
# Supply the verified matching release binaries here:
sudo install -o root -g root -m 0755 /path/to/firecracker /usr/local/libexec/firecracker/firecracker
sudo install -o root -g root -m 0755 /path/to/jailer /usr/local/libexec/firecracker/jailer
sudo install -o root -g root -m 0755 \
  apps/damage/priv/firecracker/damage-firecracker-runner \
  /usr/local/libexec/damage-firecracker-runner
sudo install -o root -g root -m 0600 \
  apps/damage/priv/firecracker/firecracker.json.example /etc/damage/firecracker.json
```

Reserve unused UID/GID values 41000 and 41001 for the two default slots. For
example, after confirming those IDs and names are unused:

```sh
sudo groupadd --gid 41000 damage-fc-0
sudo useradd --uid 41000 --gid 41000 --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin damage-fc-0
sudo groupadd --gid 41001 damage-fc-1
sudo useradd --uid 41001 --gid 41001 --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin damage-fc-1
```

Do not reuse these accounts for other host services. Increasing `max_jobs` also
requires reserving the additional contiguous IDs. Keep the same slot ID bases
while any job or quarantine exists.

Use `sudo visudo -f /etc/sudoers.d/damage-firecracker` to install the following
rule, substituting the actual DamageBDD service username if it is not `damage`:

```sudoers
damage ALL=(root) NOPASSWD: /usr/local/libexec/damage-firecracker-runner ""
```

The empty argument string explicitly permits **no command-line arguments**. The
helper accepts one bounded JSON request on stdin and reads all privileged paths,
image identities and resource policy from `/etc/damage/firecracker.json`.
The helper and every configuration/image path component must be root-owned,
non-symlink and not group/world writable. Do not place images under `/tmp`, home
directories or a writable repository checkout.

## Prepare a trusted guest image

Provide a Firecracker-compatible x86-64 `vmlinux` with virtio block, virtio vsock,
ext4, tmpfs, proc, sysfs and devtmpfs built in. There is no initrd in this backend.
Use a minimal, trusted Linux root directory with `/bin/sh`, `mount`, `chown`,
`id`, `test`, and the libraries those programs require. Include whatever build/test
binaries your named profile needs; guests have no package download access.

Build the agent on a compatible x86-64 toolchain:

```sh
make -C apps/damage/priv/firecracker
# Alternatively use a musl toolchain: make -C apps/damage/priv/firecracker CC=musl-gcc
```

Create a new image from that trusted root directory. These commands operate on
the paths you select; the directory must be a guest rootfs, not the host `/`.

```sh
set -eu
guest_root=/path/to/trusted-guest-rootfs
sudo mkdir -p "$guest_root/dev" "$guest_root/proc" "$guest_root/sys" \
  "$guest_root/run" "$guest_root/tmp" "$guest_root/work"
sudo install -D -m 0755 apps/damage/priv/firecracker/damage-fc-agent \
  "$guest_root/usr/local/sbin/damage-fc-agent"
sudo install -D -m 0755 apps/damage/priv/firecracker/damage-init \
  "$guest_root/sbin/damage-init"
# Use a fresh output filename; choose a larger size if your tools require it.
test ! -e shell.ext4
truncate -s 1G shell.ext4
sudo mkfs.ext4 -F -d "$guest_root" shell.ext4
sudo install -d -o root -g root -m 0755 /var/lib/damage-firecracker/images
sudo install -o root -g root -m 0444 /path/to/vmlinux /var/lib/damage-firecracker/images/vmlinux
sudo install -o root -g root -m 0444 shell.ext4 /var/lib/damage-firecracker/images/shell.ext4
sha256sum /var/lib/damage-firecracker/images/vmlinux /var/lib/damage-firecracker/images/shell.ext4
```

Set the exact hashes in `/etc/damage/firecracker.json`, check resource limits and
set its `enabled` to `true`. Images can contain approved tools/data, never wallet
keys, SSH credentials or the node's live `sys.config`. Image hashes identify what
was launched; they do not establish the truth of arbitrary guest output.

## Enable and call from Erlang

Merge `priv/config/firecracker.sys.config.example` into your existing `damage`
application configuration, using the `shell` profile and `{enabled, true}`. Restart
the node, or restart the `damage_firecracker` child under `damage_sup` after
updating application env. Both node configuration and privileged host policy must
enable the backend. An invalid configuration never silently falls back to Docker
or host execution.

```erlang
damage_firecracker:status().
%% #{enabled => true, running => 0, max_jobs => 2, profiles => [<<"shell">>]}
%% Status reports admission/configuration, not a live KVM health check.

damage_firecracker:run(
    <<"shell">>,
    <<"set -eu\nid\nprintf 'hello from Firecracker\\n'\n">>,
    #{timeout_ms => 30000}
).
%% {ok, #{exit_code => 0, output => <<...>>, output_truncated => false,
%%        vm_id => <<...>>, profile => <<"shell">>, kernel_sha256 => <<...>>,
%%        rootfs_sha256 => <<...>>, duration_ms => ...}}

{ok, JobId} = damage_firecracker:submit(<<"shell">>, <<"sleep 5\n">>, #{}).
%% The submitting process receives {damage_firecracker, JobId, Result}.
damage_firecracker:cancel(JobId).
```

Profiles and scripts are binaries. Only `timeout_ms` may be overridden per job;
callers cannot supply host paths, arbitrary Firecracker flags, networking or
credentials. Both policy layers bound runtime; a request exceeding the profile's
limit is rejected. Queueing is deliberately absent: saturated admission returns
`{error, busy}`. A nonzero guest exit is still `{ok, Result}` because execution
completed; assert `exit_code` in the caller/BDD feature.

`output` is combined stdout/stderr bytes, capped by the profile. If the guest
agent sees output beyond that cap it terminates the script process group and
returns `output_truncated => true`; callers must not treat truncated output as
complete evidence. Raw binary output may need base64 encoding for downstream
text-only consumers. `duration_ms` includes image staging and guest execution,
but excludes final host teardown.

Caller death, explicit cancellation and manager termination close the launcher's
input pipe. This requests host cleanup; cancellation returns before cleanup is
necessarily finished. Slot locks still prevent the privileged launcher from
oversubscribing or reusing the VM UID. Systemd's runtime limit is independent of
the Erlang process and launcher. No jobs are resumed/replayed after a crash.

## BDD

Only authenticated node admins can discover or invoke these steps. A context's
self-declared `roles` value cannot grant access. Use the included
`priv/firecracker/smoke.feature` or:

```gherkin
Feature: Isolated build tooling
  Scenario: Run the approved shell image
    When I run a Firecracker script with profile "shell"
      """
      set -eu
      test "$(id -u)" = 1000
      printf 'isolated guest ready\n'
      """
    Then the Firecracker exit code should be "0"
    Then the Firecracker output should contain "isolated guest ready"
```

The result is stored as `firecracker_result` in the ordinary step context, so
existing report formatting can consume the VM ID and image digests alongside
assertions. This module does not create IPFS reports, grant customer execution
rights, alter token pricing or settle payments independently. Customer access
requires a separate approved authorization/budget policy.

## Cleanup and recovery

Successful jobs are stopped before success is returned and their jail is deleted.
The broker never mounts guest filesystems on the host. Root-only slot records are
under `/run/damage-firecracker`; jails are under
`/srv/damage-firecracker/firecracker/<generated-vm-id>`.

A stop/cleanup failure returns `cleanup_failed_slot_quarantined`. A crash can also
leave a nonempty slot record. This deliberately blocks reuse rather than guessing
that a VM has exited. Disable admission, read the affected root-owned slot record,
stop its **exact recorded unit**, and verify its service/cgroup is empty before
removing its exact jail and truncating that slot record. Do not delete a locked
slot file: replacing its inode defeats the lock. Reboot clears `/run` but stale
jails under `/srv` may still require operator cleanup.

Useful error distinctions:

| Result | Meaning |
|---|---|
| `{error, disabled}` | Optional OTP service is not started |
| `{error, invalid_job}` | Invalid/unapproved profile, script or request options |
| `{error, busy}` | Node admission limit reached |
| `busy_or_quarantined` | Privileged slots busy or awaiting recovery |
| `image_digest_mismatch` | Trusted image content changed |
| `vm_exited_before_guest_ready` | Jailer/Firecracker/guest boot failed |
| `timeout` | Deadline exceeded, including staging and guest startup |
| `invalid_guest_response` | Guest violated the bounded wire protocol |
| `cleanup_failed_slot_quarantined` | Stop/deletion could not be confirmed |

For host failures, inspect the installed binaries, `/dev/kvm`, root-owned policy,
cgroup v2, system manager availability and image compatibility. Guest console
output is discarded rather than sent into host logs without a bound.

## Verification

```sh
rebar3 eunit --module=damage_firecracker_tests
python3 -m unittest discover -s apps/damage/test/firecracker -v
make -C apps/damage/priv/firecracker
```

Validation of this patch: 9 Erlang EUnit tests passed on OTP 25 using JSX 3.1.0;
20 Python broker tests passed; production Erlang modules compiled with warnings
as errors; the static C agent compiled with `-Wall -Wextra -Werror`.

The focused Erlang tests use the real module, real OS ports and JSX with a fake
broker; they do not launch VMs. Python tests cover policy, digest checks, slot
limits/quarantine, bounded socket protocol, EOF cancellation and mocked
systemd lifecycle/cleanup. The C agent is built with warnings as errors.
A complete umbrella release and a live KVM boot must additionally be checked on
the actual execution host; this source archive does not include the umbrella's
other applications or build configuration.

Host acceptance should run the smoke feature, a nonzero exit, output overflow,
a timeout and caller death, and confirm no VM unit remains active and no slot or
jail remains for successfully cleaned jobs. Exercise an intentionally broken
kernel/rootfs profile and verify it fails without executing the script on the host.

References:
- https://github.com/firecracker-microvm/firecracker/blob/main/docs/jailer.md
- https://github.com/firecracker-microvm/firecracker/blob/main/docs/prod-host-setup.md
- https://github.com/firecracker-microvm/firecracker/blob/main/docs/vsock.md
- https://github.com/firecracker-microvm/firecracker/blob/main/src/firecracker/swagger/firecracker.yaml
- https://www.freedesktop.org/software/systemd/man/latest/systemd-run.html
