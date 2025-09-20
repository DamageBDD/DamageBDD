# INSTALL.md — DamageBDD Node & Verification Network

This document explains how to install, configure, and secure a DamageBDD node across Linux, macOS, and Windows/WSL2.

---

## Requirements

- Erlang/OTP 25+
- rebar3
- Nginx (reverse proxy, TLS termination)
- Optional: IPFS (Kubo) for gateway routes

---

## Installation Steps

Follow the OS‑specific instructions (Ubuntu/Debian, Arch, Fedora, macOS, Windows/WSL2).  
(See baseline instructions in this repo).

---

## Configuration

### 1. `env` file

Use `/etc/damagebdd/env` for environment variables (port, bind address, paths).

### 2. `sys.config`

Advanced configuration is done via Erlang’s `sys.config`. Example:

```erlang
[
  {damagebdd, [
    {port, 8080},
    {bind_addr, "0.0.0.0"},
    {log_dir, "/var/log/damagebdd"},
    {data_dir, "/var/lib/damagebdd"},
    {upstreams, ["http://127.0.0.1:8080"]},
    {secrets_backend, encrypted_store}
  ]}
].
```

Save this to `/etc/damagebdd/sys.config` and ensure your service loads it:

```bash
ExecStart=/opt/damagebdd/bin/damagebdd foreground -config /etc/damagebdd/sys.config
```

### 3. Secrets

See README.md for secrets configuration (Bitcoin, Lightning, Nostr, SMTP).

---

## Nginx

Use the sample `damagebdd.conf` for a production proxy setup. Includes:

- Reverse proxy to verification node
- TLS via Let’s Encrypt
- Optional: `/ipfs` and `/ipns` routes
- Lightning endpoints (`/.well-known/lnurlp/`)

---

## Security Checklist

- Keep the node **non‑public**, expose only through Nginx
- Rotate TLS and secrets regularly
- Apply OS patches and enable firewall rules
- Run the node as a **dedicated system user** with minimal privileges
- Limit resource consumption via systemd (CPU/mem quotas)

---

## Logs and Health

- Application logs: `/var/log/damagebdd`
- Nginx logs: `/var/log/nginx`
- Health check: `curl http://127.0.0.1:8080/health`

---

## Operator Guide

- Build: `rebar3 as prod release`
- Start: `systemctl start damagebdd`
- Restart: `systemctl restart damagebdd`
- TLS renew: `certbot renew --dry-run`
