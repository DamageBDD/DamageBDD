# X.Org Security Hardening and Remediation Guide

This document is the remediation companion for DamageBDD's `steps_xorg_security` module. It explains how to resolve the findings produced by the strict X.Org/Xwayland security profile without weakening unrelated host security controls.

The module is deliberately stricter than many distribution defaults. A failed check should therefore be treated as one of three things:

1. **A real exposure** that should normally be removed, such as rootful Xorg, TCP listening, `xhost +`, XDMCP, `+iglx`, or `IgnoreABI`.
2. **A deliberate strict-profile restriction** that may break legacy software, such as disabling XTEST or byte-swapped clients.
3. **An observability failure**, such as DamageBDD being unable to read `/proc/<pid>/exe` or run `sshd -T`. Do not weaken unrelated protections merely to make an observability check pass.

The strict profile currently requires:

- Xorg **21.1.24 or newer**.
- Xwayland **24.1.13 or newer**, when present.
- A rootless X server with no effective Linux capabilities.
- No setuid or group/world-writable X server executable.
- No X11 TCP listener and no Linux abstract X11 socket.
- No XDMCP exposure.
- Private Xauthority authentication and enabled X access control.
- No broad `xhost` ACL entries.
- XTEST, RECORD, XFree86-DGA and XFree86-VidModeExtension disabled.
- Indirect GLX, ABI bypasses, non-local xvidtune and byte-swapped clients disabled.
- Root-controlled Xorg configuration and module paths.
- A safe `Xorg.wrap` policy.
- SSH X11 forwarding disabled by default.
- SELinux enforcing when SELinux is installed.

> **Important:** X11 does not provide strong isolation between normal trusted clients. Once a trusted X client can connect to a display, it can generally observe or interfere with other clients. For untrusted GUI applications, prefer Wayland, a separate/nested X server, or another isolation boundary rather than relying only on Xauthority.

---

## 1. Safe remediation workflow

X server changes can terminate the graphical session or make the display manager unable to start. Make changes from a console/TTY or with another recovery path available.

### 1.1 Record the current state

Before changing anything, capture the active process and configuration:

```sh
ps -eo user,pid,ppid,args | grep -E '[X]org|[X]wayland'

# Replace PID with the active X server process.
cat /proc/PID/status | grep -E '^(Uid|CapEff|NoNewPrivs|Seccomp):'

ss -ltnp | grep -E ':60[0-6][0-9]'
ss -lunp | grep ':177'
ss -lx | grep X11-unix

xhost
xdpyinfo -queryExtensions

sshd -T 2>/dev/null | grep -i '^x11'
ssh -G localhost | grep -Ei '^forwardx11|^forwardx11trusted'
```

Also save local overrides before editing them:

```sh
cp -a /etc/X11 /root/X11-config-backup
```

If `/etc/X11` is not present or you are not operating as root, back up only the files you intend to change.

### 1.2 Change one layer at a time

A practical order is:

1. Update Xorg/Xwayland packages.
2. Move the display server to rootless operation.
3. Correct `Xorg.wrap`.
4. Harden X server arguments and network transports.
5. Harden Xauthority and `xhost` policy.
6. Disable legacy/dangerous extensions.
7. Fix Xorg config/module ownership.
8. Disable SSH X11 forwarding.
9. Enable SELinux enforcement if SELinux is part of the host security model.
10. Re-run the DamageBDD audit after each major change.

Do not combine all changes into one reboot unless you have a reliable recovery console.

---

# 2. Recommended hardened baseline

The following is an intentionally strict baseline. Test application compatibility before deploying it broadly.

## 2.1 Xorg ServerFlags and extensions

Create a local administrator override such as:

`/etc/X11/xorg.conf.d/90-security.conf`

```text
Section "ServerFlags"
    Option "AllowNonLocalXvidtune" "false"
    Option "IndirectGLX" "false"
    Option "IgnoreABI" "false"
    Option "AllowByteSwappedClients" "false"
    Option "DisableVidModeExtension" "true"
EndSection

Section "Extensions"
    Option "XTEST" "Disable"
    Option "RECORD" "Disable"
    Option "XFree86-VidModeExtension" "Disable"
EndSection

Section "Module"
    SubSection "extmod"
        Option "omit XFree86-DGA"
    EndSubSection
EndSection
```

The strict DamageBDD profile also expects Xorg to be started with a transport/testing policy equivalent to:

```text
-nolisten tcp -nolisten local -tst -byteswappedclients
```

`-tst` disables testing extensions such as XTEST and RECORD. `-nolisten local` is significant on Linux because it disables the abstract local X11 transport that can otherwise bypass some filesystem/namespace isolation.

### Compatibility warning

Disabling XTEST can break tools that synthesize keyboard/mouse input, desktop automation, some remote-control software, accessibility helpers, and test tools such as `xdotool`-style automation. If a machine genuinely requires XTEST, document the exception and isolate that display rather than silently weakening a general-purpose workstation profile.

---

## 2.2 Xorg.wrap baseline

If `/etc/X11/Xwrapper.config` is used, prefer:

```text
allowed_users=console
needs_root_rights=auto
```

On a machine known to support rootless Xorg through KMS/systemd-logind, `needs_root_rights=no` can be used after testing.

Avoid:

```text
allowed_users=anybody
needs_root_rights=yes
```

The default wrapper behavior is designed to restrict X server startup to physical-console sessions and to drop elevated rights when they are not required.

---

## 2.3 SDDM rootless X11 baseline

For current SDDM installations that support unprivileged X11 sessions, create:

`/etc/sddm.conf.d/rootless-x11.conf`

```ini
[General]
DisplayServer=x11-user
```

Then place X server arguments in an administrator-owned SDDM drop-in if required by the installed SDDM version, for example:

```ini
[X11]
ServerArguments=-nolisten tcp -nolisten local -tst -byteswappedclients
```

Do **not** copy this blindly over an existing `ServerArguments=` line. Preserve any arguments required by the display manager or GPU stack and remove insecure flags individually.

After changing SDDM, verify:

```sh
ps -o user,pid,args -C Xorg
```

The active Xorg process must no longer run as UID 0 for the strict profile.

If SDDM is configured to use Wayland, prefer Wayland for the greeter/session and keep Xwayland only for legacy X11 applications where possible.

---

## 2.4 SSH baseline

### Server

Create an administrator drop-in such as:

`/etc/ssh/sshd_config.d/10-no-x11-forwarding.conf`

```text
X11Forwarding no
```

If the server does not require *any* SSH forwarding, a stronger policy is:

```text
DisableForwarding yes
```

Validate before reload:

```sh
sshd -t
sshd -T | grep -i '^x11forwarding'
```

Expected output:

```text
x11forwarding no
```

Then reload the SSH service using the mechanism appropriate for the distribution.

### Client

Create:

`/etc/ssh/ssh_config.d/10-no-x11-forwarding.conf`

```text
Host *
    ForwardX11 no
    ForwardX11Trusted no
```

Verify:

```sh
ssh -G localhost | grep -Ei '^forwardx11|^forwardx11trusted'
```

If X11 forwarding is required for a specific trusted host, keep the global default disabled and add a narrow per-host exception. Prefer untrusted `ssh -X` forwarding over trusted `ssh -Y` where the application works correctly.

---

# 3. Finding-by-finding remediation

## 3.1 `runtime_identity`: Xorg is running as root

Example finding:

```text
runtime_identity: Xorg pid 18305 is running as root; require a rootless X server
```

### Risk

A memory-corruption or protocol-parsing flaw in a root X server has a much larger impact than the same flaw in an unprivileged process. Rootless Xorg also reduces the amount of privileged device-management code exposed to clients.

### Preferred fix

Use a display manager/session mode that starts Xorg unprivileged and relies on KMS plus systemd-logind for device access.

For SDDM, current releases support:

```ini
[General]
DisplayServer=x11-user
```

For `startx`, use logind-compatible rootless startup rather than invoking Xorg as root.

### Do not

- Add the session user to broad hardware groups such as `disk` merely to avoid root Xorg.
- Set `needs_root_rights=yes` just to get the display working unless there is a documented hardware requirement.
- Run the entire desktop session as root.

### Verify

```sh
ps -o user,pid,args -C Xorg
```

The Xorg process should run as the login/display user, not root.

---

## 3.2 `runtime_identity`: effective Linux capabilities are retained

Example:

```text
runtime_identity: X server retains effective Linux capabilities: 0x...
```

### Risk

Capabilities can give an otherwise non-root process privileged operations. A rootless X server should normally complete privileged setup through logind/DRM interfaces without retaining broad capabilities.

### Preferred fix

Fix the launch model first. Moving from a root/capability-based server to a proper rootless logind/KMS session generally removes the capability requirement.

Inspect:

```sh
grep '^CapEff:' /proc/PID/status
```

Expected strict result:

```text
CapEff: 0000000000000000
```

Do not remove capabilities from a running X server with ad-hoc tools. Correct the service/display-manager configuration and restart the graphical session.

---

## 3.3 `runtime_identity`: NoNewPrivs or seccomp warning

Examples:

```text
X server does not have NoNewPrivs enabled
X server has no seccomp filter
```

These are **warnings**, not strict-profile errors in the module.

### Best practice

For a rootless X server started through a controlled service, consider `NoNewPrivileges=yes` and a tested syscall filter. Graphics, input and device-management workloads are sensitive to over-aggressive systemd sandboxing, so test this separately from core Xorg hardening.

Do not copy a generic `SystemCallFilter=` profile into a display manager without testing GPU, input, VT switching, suspend/resume and hotplug behavior.

---

## 3.4 `executable`: X server executable cannot be resolved

Example:

```text
executable: Cannot resolve executable for X server pid 18305
```

### Meaning

This can be a real process-integrity problem, but it can also be an **audit visibility problem**. Linux `/proc/<pid>/exe` may be unreadable because of `hidepid`, ptrace restrictions, namespaces, or because DamageBDD runs as a different unprivileged user.

### Best practice

First check as an administrator:

```sh
readlink -e /proc/PID/exe
ls -l /proc/PID/exe
```

If the executable resolves for root but not for the DamageBDD service user, keep `/proc` hardening intact. Do **not** make `/proc` world-readable just to satisfy the audit.

Preferred approaches are:

- Run this host audit through a narrowly privileged local audit helper.
- Add a safe package-manager-backed version/integrity check to the module.
- Give only the minimum read access required by the host's `/proc` policy.

Avoid granting broad capabilities such as `CAP_SYS_PTRACE` to the full DamageBDD service unless the node's threat model explicitly requires it.

---

## 3.5 `executable`: setuid or writable X server binary

Examples:

```text
X server executable ... has the setuid bit set
X server executable ... is group/world writable
```

### Preferred fix

Package-managed Xorg binaries should be owned by root and not writable by group/other. Prefer restoring the package rather than hand-editing permissions in `/usr`.

On Arch Linux, package integrity can be checked with tools such as:

```sh
pacman -Qkk xorg-server
```

If the binary has unexpected mode/ownership, reinstall the package and investigate how it changed.

A setuid **wrapper** may exist on some systems, but the strict profile expects the actual Xorg executable itself not to be setuid and separately audits `Xorg.wrap` policy.

---

## 3.6 `version`: Xorg/Xwayland below the security baseline

Examples:

```text
version: Xorg version ... is below security baseline 21.1.24
version: Xwayland version ... is below security baseline 24.1.13
```

### Preferred fix

Install the distribution's current security updates. On a rolling distribution such as Arch Linux, update the system rather than selectively mixing server/driver versions:

```sh
pacman -Syu
```

The July 2026 X.Org security advisories state that the relevant X server flaws are fixed in Xorg 21.1.24 and Xwayland 24.1.13.

Also update `libXfont2`; July 2026 X.Org advisories include separate font parsing vulnerabilities fixed in `libXfont2 2.0.8`. The current DamageBDD module does not yet verify the libXfont2 version.

### Distribution backport caveat

Some stable distributions backport security fixes while retaining an older upstream version number. The strict module compares upstream version numbers and can therefore produce a false positive on a vendor-patched package. In that case, verify the vendor security advisory/package revision and add a distro-aware policy rather than downgrading the host.

---

## 3.7 `server_args`: `-ac`

Finding:

```text
-ac disables X access control
```

### Risk

`-ac` disables host-based access control and allows connections without the normal restriction. X.Org explicitly warns that this option should be used with extreme caution.

### Fix

Remove `-ac` from the display manager, `.xserverrc`, service unit, container entrypoint or custom Xorg launcher.

Use Xauthority cookies for authentication and leave access control enabled.

Verify with:

```sh
xhost
```

The first line should report that access control is enabled.

---

## 3.8 `server_args`: `+iglx` / `IndirectGLX`

Findings:

```text
+iglx enables indirect GLX...
IndirectGLX is enabled
```

### Risk

X.Org documents indirect GLX as a large protocol-parsing attack surface and disables it by default in current servers.

### Fix

Remove `+iglx`. Explicitly configure:

```text
Section "ServerFlags"
    Option "IndirectGLX" "false"
EndSection
```

Do not enable indirect GLX to support a legacy remote OpenGL application unless that application is isolated on a dedicated display/host.

---

## 3.9 `server_args`: byte-swapped clients are enabled or not explicitly disabled

Findings:

```text
+byteswappedclients permits opposite-endian clients
Byte-swapped X11 clients are not explicitly disabled
AllowByteSwappedClients is enabled
```

### Why the strict profile cares

Current Xorg permits byte-swapped clients by default unless they are explicitly prohibited. Supporting alternate-endian protocol parsing increases protocol surface and is rarely needed on modern homogeneous Linux desktops.

### Fix

Use either:

```text
-byteswappedclients
```

or:

```text
Section "ServerFlags"
    Option "AllowByteSwappedClients" "false"
EndSection
```

The DamageBDD strict profile deliberately requires an explicit disable rather than relying on an implicit distribution default.

---

## 3.10 `server_args`: `-allowNonLocalXvidtune`

Finding:

```text
-allowNonLocalXvidtune exposes the VidMode tuning interface to non-local clients
```

### Fix

Remove the command-line flag and enforce:

```text
Option "AllowNonLocalXvidtune" "false"
```

For a stricter host, disable the VidMode extension entirely as described in the extensions section below.

---

## 3.11 `server_args`: `-ignoreABI` / `IgnoreABI`

Findings:

```text
-ignoreABI allows potentially incompatible Xorg modules to load
IgnoreABI is enabled
```

### Risk

ABI checks exist to stop modules built for incompatible X server interfaces from being loaded. Ignoring those checks can turn a packaging mismatch into memory corruption or instability.

### Preferred fix

Remove `-ignoreABI` and set:

```text
Option "IgnoreABI" "false"
```

If Xorg then refuses to start, fix the mismatched video/input driver package. On a rolling distribution, perform a complete upgrade rather than pinning Xorg while upgrading drivers independently.

---

## 3.12 `server_args`: `-background none`

Finding:

```text
-background none may expose contents from a previous session during reset/startup
```

### Risk

The Xserver manual explicitly notes that this is not the default for security reasons because previous screen contents can become visible during startup/reset.

### Fix

Remove `-background none` from the display manager's X server arguments.

A brief black screen during server startup/reset is preferable to preserving prior framebuffer contents.

For SDDM, inspect all configuration layers:

```sh
grep -Rni 'ServerArguments\|background' /etc/sddm.conf /etc/sddm.conf.d 2>/dev/null
```

Do not edit packaged files under `/usr`; place local overrides in `/etc/sddm.conf.d/`.

---

## 3.13 `server_args`: `-core`

Finding:

```text
-core enables server core dumps which may disclose display/session memory
```

### Fix

Remove `-core` from the server command line.

As additional defense in depth, a service can use an appropriate core-dump policy or `LimitCORE=0`, but changing the system-wide coredump policy is separate from this DamageBDD check and should be assessed against debugging requirements.

---

## 3.14 `network`: X11 TCP listener

Examples:

```text
X display :0 has TCP transport exposed on port 6000
X server namespace has common X11 TCP listener(s)
```

### Risk

TCP exposure makes the X server reachable beyond the local Unix-domain transport and increases dependence on network ACL/cookie secrecy.

### Fix

Start Xorg with:

```text
-nolisten tcp
```

Verify:

```sh
ss -ltnp | grep -E ':60[0-6][0-9]'
```

There should be no X11 listener.

A firewall is useful defense in depth but is not a replacement for disabling the unused transport.

---

## 3.15 `abstract_socket`: Linux abstract X11 socket is exposed

Finding:

```text
Linux abstract X11 socket @/tmp/.X11-unix/X0 is enabled
```

### Risk

Linux abstract Unix sockets are not controlled by filesystem permissions and can cross some sandbox boundaries that successfully hide `/tmp/.X11-unix`.

### Fix

Start Xorg with:

```text
-nolisten local
```

For the strict profile, normally use both:

```text
-nolisten tcp -nolisten local
```

Test local clients carefully. The normal pathname-based Unix-domain X11 socket should remain available unless other transport settings disable it.

---

## 3.16 `xdmcp`: XDMCP enabled or UDP/177 exposed

Finding:

```text
XDMCP is enabled by command line or UDP/177 exposure
```

### Risk

XDMCP is an old network display-management protocol and should not be enabled on a workstation/node that does not explicitly provide network-managed X terminals.

### Fix

Remove X server arguments such as:

```text
-query
-broadcast
-multicast
-indirect
```

Disable XDMCP in the display manager and verify that UDP port 177 is closed:

```sh
ss -lunp | grep ':177'
```

Use the host firewall as an additional boundary, not as the only control.

---

## 3.17 `authorization`: no Xauthority file

Finding:

```text
No Xauthority file could be established; strict profile requires -auth or an explicit authority path
```

### Preferred fix

Let the display manager create and rotate MIT-MAGIC-COOKIE-1 credentials and pass the authority file to Xorg with `-auth`.

If DamageBDD cannot infer the correct file but you know it, the module supports an explicit audit context:

```gherkin
Given I use Xorg authority file "/run/.../xauth_..."
Given I audit the active Xorg server
Then Xorg authorization should be hardened
```

Do not hard-code a transient display-manager cookie file in permanent configuration.

---

## 3.18 `authorization`: Xauthority owner does not match the X server

Example from an SDDM-managed system:

```text
Xauthority file /run/sddm/xauth_... is owned by uid 942, not root/X server uid ...
```

### Interpretation

Do **not** immediately `chown` the live SDDM-generated file. Display managers generate ephemeral authority files and will recreate them.

This finding often accompanies a rootful X server. A better fix is to make the display server rootless so the X server identity and display-manager authority ownership model align.

For SDDM, first evaluate:

```ini
[General]
DisplayServer=x11-user
```

Then restart the graphical login and re-run the audit.

If the authority file is a persistent manually managed file, it should be:

- a regular file, not a symlink;
- non-empty;
- owned by root or the X server identity expected by the strict policy;
- not readable or writable by group/other, normally mode `0600`.

Never log, print or copy the cookie contents into build artifacts.

---

## 3.19 `authorization`: insecure authority permissions

Findings:

```text
Xauthority file ... has group/other permissions ...
Xauthority file ... is a symlink
Xauthority file ... is empty
```

### Fix

For a persistent user-managed authority file:

```sh
chmod 0600 /path/to/Xauthority
```

Set ownership to the identity that actually runs the X server/session.

For display-manager files under `/run`, fix the display manager or tmpfiles/session configuration rather than applying a one-off `chmod` after every boot.

Symlinks should be avoided for authentication databases because they complicate ownership and path-integrity guarantees.

---

## 3.20 `xhost`: access control disabled

Finding:

```text
xhost reports access control disabled
```

### Fix

Re-enable access control:

```sh
xhost -
```

Then remove scripts or desktop startup files that call `xhost +`.

`xhost -` does not replace Xauthority; use cookie-based authorization for clients.

Restarting the X session after correcting startup configuration is preferable because existing client connections are not necessarily terminated merely by changing the host ACL.

---

## 3.21 `xhost`: broad ACL entries

Finding:

```text
Broad xhost ACL entries are present
```

The strict profile considers broad entries such as `local:`, INET/INET6 hosts and unresolved host ACL entries unsafe. It permits narrowly scoped `SI:localuser:<user>` entries.

### Preferred fix

Remove broad grants rather than adding more exceptions:

```sh
xhost -local:
xhost -hostname.example
```

Prefer Xauthority authentication.

If a local application cannot operate without an `xhost` exception, scope it to a specific OS user when possible:

```sh
xhost +SI:localuser:username
```

Even a local-user exception expands who can connect to the display, so keep it narrow and documented.

---

## 3.22 `xhost`: `/etc/Xn.hosts` contains entries

Finding:

```text
Legacy host ACL file /etc/X0.hosts contains active host-based access entries
```

### Fix

Remove legacy host entries if the host does not explicitly require host-based X authentication. Prefer Xauthority cookies instead.

If the file is unnecessary, remove it or leave it empty and root-controlled.

---

## 3.23 `socket_dir`: `/tmp/.X11-unix` ownership/sticky bit

Findings:

```text
/tmp/.X11-unix is owned by uid ... instead of root
/tmp/.X11-unix is not sticky
```

### Expected state

The strict profile expects `/tmp/.X11-unix` to be:

- a directory;
- owned by root;
- sticky.

A conventional mode is `1777` with root ownership.

Before manually changing it, inspect the distribution's tmpfiles configuration. On a system where the directory is genuinely misconfigured, restore root ownership and the sticky bit from a recovery console or before starting X.

Do not make the directory more restrictive without testing, because multiple users/sessions may need to create X socket entries.

---

## 3.24 `extensions`: XTEST or RECORD advertised

Finding:

```text
Dangerous/legacy X extensions are advertised: [XTEST, RECORD, ...]
```

### Strict fix

Use:

```text
-tst
```

The Xserver manual documents `-tst` as disabling testing extensions including XTEST and RECORD.

You can additionally disable extensions in the `Extensions` section:

```text
Section "Extensions"
    Option "XTEST" "Disable"
    Option "RECORD" "Disable"
EndSection
```

### Compatibility

XTEST is widely used by desktop automation and synthetic-input tools. If required, consider running that workload on a dedicated X server instead of re-enabling it on a display that handles secrets, privileged sessions or unrelated applications.

---

## 3.25 `extensions`: XFree86-DGA advertised

### Fix

Use the Xorg module configuration documented by X.Org:

```text
Section "Module"
    SubSection "extmod"
        Option "omit XFree86-DGA"
    EndSubSection
EndSection
```

DGA is a legacy direct-access interface and is rarely required by modern desktops.

---

## 3.26 `extensions`: XFree86-VidModeExtension advertised

### Fix

At minimum disable the mode-changing parts:

```text
Option "DisableVidModeExtension" "true"
```

The strict profile expects the extension not to be advertised, so also disable the extension when the server supports that configuration:

```text
Section "Extensions"
    Option "XFree86-VidModeExtension" "Disable"
EndSection
```

Modern display configuration normally uses RandR rather than xvidtune/VidMode.

---

## 3.27 `extensions`: DISPLAY or XAUTHORITY unknown

Examples:

```text
Cannot inspect X extensions because DISPLAY is unknown
Cannot inspect X extensions because XAUTHORITY is unknown
```

These are primarily **audit observability failures**.

### Diagnose DISPLAY

Inspect the actual X server command line and sockets:

```sh
tr '\0' ' ' < /proc/PID/cmdline; echo
ls -l /tmp/.X11-unix/
```

Some display managers use `-displayfd` or other launch mechanisms instead of placing a literal `:0` argument in the process command line. In that case the current module may not infer the display correctly.

Do not change a correctly configured X server merely to add a cosmetic `:0` argument for the auditor. Enhance the audit to derive the display from `-displayfd`, socket state or the display manager, or supply a verified display through the test harness once process selection supports that launch style.

### Diagnose XAUTHORITY

Inspect the Xorg command line for `-auth` and the display manager's session state. Do not read or print the cookie content.

---

## 3.28 `xorg_config`: `AllowNonLocalXvidtune` enabled

Set:

```text
Option "AllowNonLocalXvidtune" "false"
```

and remove `-allowNonLocalXvidtune` from the command line.

---

## 3.29 `xorg_config`: `IndirectGLX` enabled

Set:

```text
Option "IndirectGLX" "false"
```

and remove `+iglx` from server arguments.

---

## 3.30 `xorg_config`: `IgnoreABI` enabled

Set:

```text
Option "IgnoreABI" "false"
```

Then fix the driver/server package mismatch if Xorg can no longer load a module.

Do not keep ABI bypasses as a permanent workaround for a partially upgraded system.

---

## 3.31 `paths`: Xorg configuration/module path not root controlled

Findings include:

```text
Xorg path ... is owned by uid ..., not root
Xorg path ... is group/world writable
Security-sensitive Xorg path ... is a symlink
```

### `/etc` configuration

Local Xorg configuration should normally be root-owned and not writable by unprivileged users. Typical modes are:

- directories: `0755` or stricter;
- configuration files: `0644` or stricter;
- no group/world write permission.

Use targeted corrections. Avoid recursive permission commands across `/etc/X11` unless you have reviewed every file.

### `/usr/lib*/xorg/modules`

Treat module directories as package-managed content. If ownership, mode or path structure differs from the distribution package, verify/reinstall the package instead of manually rewriting the entire tree.

The strict module treats symlinks in security-sensitive Xorg paths conservatively. Some distributions may legitimately package symlinks; verify them against the package database before changing them. A verified package symlink may require a distro-specific audit exception rather than destructive replacement.

---

## 3.32 `wrapper`: `allowed_users=anybody`

Finding:

```text
Xorg.wrap allows anybody to start Xorg
```

### Fix

Use:

```text
allowed_users=console
```

or, on a system where only root should ever invoke the wrapper:

```text
allowed_users=rootonly
```

`console` is the normal balanced choice for desktop systems.

---

## 3.33 `wrapper`: `needs_root_rights=yes`

Finding:

```text
Xorg.wrap forces root rights with needs_root_rights=yes
```

### Fix

Prefer:

```text
needs_root_rights=auto
```

After confirming KMS/logind support, a strict rootless system can use:

```text
needs_root_rights=no
```

If the GPU/driver stack genuinely cannot operate rootless, document the exception and consider Wayland/Xwayland or hardware/driver modernization rather than normalizing permanent root Xorg.

---

## 3.34 `sshd`: effective `X11Forwarding` is not `no`

Finding:

```text
sshd effective configuration does not have X11Forwarding no
```

### Fix

Set:

```text
X11Forwarding no
```

in an administrator-owned `sshd_config.d` drop-in.

Validate with:

```sh
sshd -t
sshd -T | grep -i '^x11forwarding'
```

Do not rely only on a commented default in `sshd_config`; the audit checks the effective configuration.

---

## 3.35 `sshd`: `sshd -T` fails because host keys are missing

Example:

```text
Cannot verify sshd effective X11 policy: sshd: no hostkeys available
```

### If this machine is intended to run an SSH server

Restore/generate host keys using the distribution-supported mechanism, then verify `sshd -T` and set `X11Forwarding no`.

On many OpenSSH installations the administrative command is:

```sh
ssh-keygen -A
```

Only do this when the host is intentionally an SSH server and the host-key lifecycle is understood.

### If this machine should not run an SSH server

Do **not** generate host keys solely to make the Xorg audit pass. Disable/uninstall the SSH server component or refine the audit so an installed but intentionally unconfigured server is treated as not applicable.

This is a good example of an observability/configuration-state failure rather than proof that X11 forwarding is enabled.

---

## 3.36 `ssh_client`: trusted X11 forwarding enabled

Finding:

```text
OpenSSH client enables trusted X11 forwarding
```

### Risk

Trusted forwarding gives remote X clients full access to the local X display. OpenSSH warns that a compromised remote host may then interact with the local display, including potentially monitoring input.

### Fix

Set global defaults:

```text
Host *
    ForwardX11 no
    ForwardX11Trusted no
```

Use explicit per-host exceptions only when needed.

Avoid `ssh -Y` for general administration. If X forwarding is unavoidable and the application supports it, prefer `ssh -X` with the SECURITY extension's untrusted model.

---

## 3.37 `mac`: SELinux present but not enforcing

Finding:

```text
SELinux is present but not enforcing
```

### Fix

If SELinux is part of the distribution security model, move from permissive/disabled to enforcing using the distribution's documented process. This can require policy fixes, relabeling and a reboot.

Do not switch to enforcing on a production graphical system without first reviewing AVC denials in permissive mode.

If the host uses AppArmor or another MAC system instead, note that the current module does not treat that as a substitute for the SELinux-specific check because the SELinux finding only applies when `/sys/fs/selinux` is present.

---

# 4. Prioritized remediation for the example audit output

The observed audit contained these failures:

```text
runtime_identity: Xorg is running as root
runtime_identity: X server retains effective Linux capabilities
executable: Cannot resolve executable
version: Cannot verify Xorg version
server_args: -background none
server_args: Byte-swapped clients not explicitly disabled
authorization: SDDM Xauthority owner does not match root Xorg
extensions: DISPLAY unknown
xorg_config: IgnoreABI enabled
wrapper: allowed_users=anybody
wrapper: needs_root_rights=yes
sshd: sshd -T fails because no host keys are available
ssh_client: trusted X11 forwarding enabled
```

A sensible repair sequence is:

### 1. Update packages

Bring Xorg/Xwayland and related X.Org libraries fully up to date. This removes known vulnerabilities before configuration work begins.

### 2. Move SDDM/Xorg to rootless mode

Use SDDM's unprivileged X11 mode where supported:

```ini
[General]
DisplayServer=x11-user
```

This should address both the root UID and capability findings and may also align the authority-file ownership with the active server identity.

### 3. Correct Xorg.wrap

Replace:

```text
allowed_users=anybody
needs_root_rights=yes
```

with:

```text
allowed_users=console
needs_root_rights=auto
```

or `needs_root_rights=no` after rootless operation has been proven.

### 4. Remove insecure Xorg options

Remove `-background none` and `-ignoreABI` from any launch/config layer.

Add:

```text
-nolisten tcp -nolisten local -tst -byteswappedclients
```

and configure the ServerFlags/Extensions baseline from this document.

### 5. Fix package/driver ABI compatibility

Because `IgnoreABI` is currently enabled, confirm that the installed video/input drivers match the current Xorg package. Do not simply remove `IgnoreABI` and declare success if Xorg then fails to start.

### 6. Resolve audit visibility without weakening `/proc`

Investigate why DamageBDD cannot resolve `/proc/<pid>/exe` and why DISPLAY is not inferred. If host `/proc` restrictions are responsible, preserve them and improve the audit's observation mechanism rather than making `/proc` globally readable.

### 7. Disable SSH X11 forwarding

Set both SSH server and client defaults to no. If `sshd` is intentionally unused/unconfigured, do not generate host keys only for this check; treat the server check as not applicable or uninstall the server component.

### 8. Re-run the strict profile

```gherkin
Feature: X.Org strict security verification

  Scenario: Active Xorg satisfies the strict security profile
    Given I audit the active Xorg server
    Then Xorg should satisfy the strict security profile
    And I print the Xorg security audit
```

If the entire strict profile is too aggressive for a workstation that intentionally needs a legacy capability, run the focused assertions so the exception is explicit:

```gherkin
Scenario: Xorg core host protections remain enforced
  Given I audit the active Xorg server
  Then Xorg should be rootless
  And Xorg network transports should be hardened
  And Xorg authorization should be hardened
  And Xorg XDMCP should be disabled
  And Xorg SSH X11 forwarding should be disabled
  And Xorg configuration and module paths should be root controlled
  And Xorg should include current upstream security fixes
```

Do not silently remove a strict check simply because an application depends on the insecure behavior. Record the exception and isolate the application when practical.

---

# 5. Verification checklist

After remediation, verify all of the following.

## Runtime

```sh
ps -o user,pid,args -C Xorg
grep -E '^(Uid|CapEff|NoNewPrivs|Seccomp):' /proc/PID/status
```

Expected strict state:

- UID is not 0.
- `CapEff` is zero.

## X server arguments

The active process should not include:

```text
-ac
+iglx
+byteswappedclients
-allowNonLocalXvidtune
-ignoreABI
-background none
-core
-query
-broadcast
-multicast
-indirect
```

It should include or otherwise enforce the equivalent of:

```text
-nolisten tcp
-nolisten local
-byteswappedclients
-tst
```

## Network

```sh
ss -ltnp | grep -E ':60[0-6][0-9]'
ss -lunp | grep ':177'
```

Both should return no X-related listener.

## Authentication

```sh
xhost
```

Access control must be enabled and there should be no broad ACL entries.

Inspect authority **metadata only**:

```sh
stat /path/to/Xauthority
```

Do not print its contents in CI/report logs.

## Extensions

```sh
xdpyinfo -queryExtensions | grep -E 'XTEST|RECORD|XFree86-DGA|XFree86-VidModeExtension'
```

The strict profile expects no matches.

## Wrapper

```sh
cat /etc/X11/Xwrapper.config
```

Preferred:

```text
allowed_users=console
needs_root_rights=auto
```

## SSH

```sh
sshd -T | grep -i '^x11forwarding'
ssh -G localhost | grep -Ei '^forwardx11|^forwardx11trusted'
```

Expected:

```text
x11forwarding no
forwardx11 no
```

## MAC

When SELinux is installed:

```sh
getenforce
```

Expected:

```text
Enforcing
```

---

# 6. Do not fix audit failures by weakening stronger controls

Avoid these anti-patterns:

- Do not make `/proc` globally readable to resolve `Cannot resolve executable`.
- Do not grant the DamageBDD service broad ptrace capabilities solely for this audit.
- Do not `chown` transient `/run/sddm/xauth_*` files after each boot instead of fixing the launch model.
- Do not generate SSH host keys on a machine that should not run `sshd` just to make `sshd -T` work.
- Do not set `IgnoreABI` to keep mismatched packages running.
- Do not re-enable TCP X11 and rely only on a firewall.
- Do not use `xhost +` as a workaround for Xauthority problems.
- Do not set `needs_root_rights=yes` unless rootful Xorg is a documented hardware requirement.
- Do not make Xorg module/configuration directories writable by service accounts for convenience.

A security verifier is most valuable when an exception remains visible instead of being hidden by a weaker system configuration.

---

# 7. Longer-term architecture recommendations

## Prefer Wayland for untrusted desktop workloads

Where the desktop/application stack supports it, prefer a Wayland compositor and use Xwayland only for applications that still require X11. Keep Xwayland patched to the module's minimum baseline or newer.

## Separate untrusted X11 applications

If an application must run with XTEST, DGA-like behavior, broad local access, or other legacy functionality, consider a dedicated nested X server or separate user/session rather than enabling those capabilities on the primary desktop display.

## Keep package updates part of the BDD security contract

The X.Org security baseline changes as new advisories are published. The minimum versions in `steps_xorg_security` should be reviewed whenever X.Org publishes a new server/Xwayland advisory.

A future extension to the module should also verify security-sensitive X.Org libraries such as `libXfont2`, because not all X.Org vulnerabilities live in the X server executable itself.

## Treat display-manager policy as code

Store `/etc/sddm.conf.d`, `/etc/X11/xorg.conf.d`, Xwrapper, SSH drop-ins and any systemd overrides under configuration management. The DamageBDD feature then becomes continuous regression verification that the runtime still matches the intended policy.

---

# 8. References

The following upstream/current documentation informs the recommendations in this guide:

- X.Org Security Advisories: https://www.x.org/Development/Security/
- X.Org security/access-control documentation: https://www.x.org/Development/Documentation/Security/
- X.Org communication and trusted-client model: https://www.x.org/guide/communication/
- Xserver manual: https://man.archlinux.org/man/Xserver.1
- Xorg manual: https://man.archlinux.org/man/Xorg.1
- xorg.conf manual: https://man.archlinux.org/man/xorg.conf.5
- Xorg.wrap / Xwrapper.config manual: https://man.archlinux.org/man/Xorg.wrap.1
- ArchWiki Xorg hardening/rootless guidance: https://wiki.archlinux.org/title/Xorg
- ArchWiki SDDM rootless guidance: https://wiki.archlinux.org/title/SDDM
- OpenSSH `sshd_config`: https://man.openbsd.org/sshd_config
- OpenSSH `ssh_config`: https://man.openbsd.org/ssh_config
- Xsecurity: https://www.x.org/docs/man/man.pdf

The current DamageBDD version baseline is intentionally tied to the July 8, 2026 X.Org advisory: Xorg server 21.1.24 and Xwayland 24.1.13. Keep this document and the module baseline synchronized when newer advisories are released.
