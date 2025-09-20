# INSTALL.md — DamageBDD Node & Verification Network (Windows/macOS/Linux)

This guide sets up a **DamageBDD Erlang node** and a **Verification Node** fronted by **Nginx**, with optional **IPFS gateway** integration for a self‑hosted verification network.

> TL;DR: On Linux/macOS use native packages. On Windows use **WSL2 (Ubuntu)**. Then install Erlang/OTP + rebar3, build the app, run as a system service, and front with Nginx + Let’s Encrypt.


---

## 0) Requirements & What You’ll Get

- **Erlang/OTP** (OTP 25+ recommended), **rebar3**
- **DamageBDD** application built from source
- **Verification Node** (HTTP) bound to `:8080` by default
- **Nginx** reverse proxy with TLS (Let’s Encrypt) to expose:
  - Web UI/static content (optional)
  - **IPFS/IPNS** gateway at `/ipfs` and `/ipns` (optional)
- **Systemd** services (Linux) or **launchd** (macOS) for auto‑start
- **Firewall** rules opened for 80/443 (Nginx) and internal 8080

> The provided Nginx layout in `damagebdd.conf` includes `run.damagebdd.com` upstreams to the Verification Node and `/.well-known/lnurlp/` proxy (Lightning) as examples. Reuse/adapt them. fileciteturn0file0


---

## 1) OS Baselines

### A. Linux (Ubuntu/Debian)
```bash
# Update
sudo apt update && sudo apt -y upgrade

# Erlang/OTP + rebar3 + build utils
sudo apt -y install erlang-base erlang-dev erlang-tools erlang-parsetools rebar3 \
  git curl build-essential

# Nginx + Certbot
sudo apt -y install nginx python3-certbot-nginx

# Optional: IPFS (Kubo)
# Download latest from https://dist.ipfs.tech/ and install to /usr/local/bin/ipfs
# Or use snap (older): sudo snap install ipfs
```

### B. Linux (Arch/Manjaro)
```bash
sudo pacman -Syu --noconfirm
sudo pacman -S --noconfirm erlang-nox erlang-tools rebar3 git base-devel nginx certbot
# Optional IPFS:
sudo pacman -S --noconfirm go ipfs
# If you maintain scripts, run: ./arch_packages.sh  # (optional helper)
```

### C. Linux (Fedora/RHEL/CentOS/Alma/Rocky)
```bash
sudo dnf -y update
sudo dnf -y install erlang rebar3 git @development-tools nginx certbot python3-certbot-nginx
# Optional IPFS: build Kubo from source or install via rpm if available.
```

### D. macOS (Apple Silicon or Intel)
```bash
# Install Homebrew first: https://brew.sh
brew update
brew install erlang rebar3 nginx
# Optional IPFS:
brew install ipfs
# Launch Nginx:
sudo brew services start nginx  # or: sudo nginx
```

### E. Windows (Recommended via WSL2 + Ubuntu)
1. Install **WSL2** and **Ubuntu** (Microsoft Store).
2. Inside Ubuntu, follow **Ubuntu/Debian** steps above.
3. Expose ports 80/443 via Windows Firewall (WSL integrates automatically in recent builds).  
   If running Nginx in WSL, use your Windows host IP or `localhost` to access.


---

## 2) Get the Source & Build

```bash
# Choose a working directory
mkdir -p ~/apps && cd ~/apps

# Clone your repo (replace with your origin)
git clone https://github.com/DamageBDD/DamageBDD.git
cd DamageBDD

# If you have bootstrap helpers:
#  - bootstrap_sudoers.sh (optional convenience for admin paths)
#  - setup.sh (install local prerequisites)
#  - setup-ipfs.sh (optional IPFS gateway config)
# Review before executing, then:
# chmod +x bootstrap_sudoers.sh setup.sh setup-ipfs.sh || true

# Build
rebar3 do clean, compile

# (Optional) Release
rebar3 as prod release
# Result typically under: _build/prod/rel/damagebdd/
```


---

## 3) Create Runtime Users, Paths & Permissions (Linux)

```bash
sudo useradd --system --home /var/lib/damagebdd --shell /usr/sbin/nologin damagebdd || true
sudo mkdir -p /var/lib/damagebdd /var/log/damagebdd /opt/damagebdd
sudo chown -R damagebdd:damagebdd /var/lib/damagebdd /var/log/damagebdd
# Install release (if you built one):
sudo rsync -a _build/prod/rel/damagebdd/ /opt/damagebdd/
sudo chown -R damagebdd:damagebdd /opt/damagebdd
```


---

## 4) Configure the Verification Node

Set your environment and ports. A common layout:

```bash
sudo mkdir -p /etc/damagebdd
sudo tee /etc/damagebdd/env <<'EOF'
# Listen interface/port for the Verification Node
PORT=8080
BIND_ADDR=0.0.0.0

# If your app reads config files:
CONFIG=/etc/damagebdd/damagebdd.conf
LOG_DIR=/var/log/damagebdd
DATA_DIR=/var/lib/damagebdd
EOF
sudo chmod 0644 /etc/damagebdd/env
```

Add your app config (keys, upstreams, etc.) into `/etc/damagebdd/damagebdd.conf`.


---

## 5) System Service (systemd – Linux)

Create a service to keep the node alive:

```bash
sudo tee /etc/systemd/system/damagebdd.service <<'EOF'
[Unit]
Description=DamageBDD Verification Node
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=damagebdd
EnvironmentFile=/etc/damagebdd/env
WorkingDirectory=/opt/damagebdd
ExecStart=/opt/damagebdd/bin/damagebdd start
ExecStop=/opt/damagebdd/bin/damagebdd stop
Restart=on-failure
RestartSec=5
StandardOutput=append:/var/log/damagebdd/stdout.log
StandardError=append:/var/log/damagebdd/stderr.log
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now damagebdd
sudo systemctl status damagebdd --no-pager
```

> If you don’t use `rebar3 release`, replace `ExecStart` with your app’s start command (e.g., `erl -pa _build/default/lib/*/ebin -noshell -s damagebdd_app start`).


---

## 6) Nginx Reverse Proxy + TLS

### 6.1 Minimal upstream to Verification Node
Create an Nginx server that forwards to the node at `:8080`. **Replace domains** with yours.

```nginx
# /etc/nginx/sites-available/damagebdd.conf
server {
    server_name run.damagebdd.com;
    server_tokens off;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_redirect off;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Scheme $scheme;
        proxy_read_timeout 300s;
        proxy_buffering off;
    }

    listen 80;
}
```

Enable & test:
```bash
sudo ln -s /etc/nginx/sites-available/damagebdd.conf /etc/nginx/sites-enabled/damagebdd.conf
sudo nginx -t && sudo systemctl reload nginx
```

### 6.2 Let’s Encrypt TLS
```bash
sudo certbot --nginx -d run.damagebdd.com
# Auto‑renews via system timer (check: systemctl list-timers | grep certbot)
```

### 6.3 Full featured layout (static UI, IPFS, Lightning, health)
If you want the full layout with static site roots, an IPFS gateway on `/ipfs` & `/ipns`, `/.well-known/lnurlp/` proxy, and stub status routes, adapt the `damagebdd.conf` included with this repo. It defines production `server` blocks for `damagebdd.com` and `run.damagebdd.com`, with TLS, CORS headers for static routes, IPFS reverse proxy to `127.0.0.1:8082`, and upstreams to your Verification Node hosts. fileciteturn0file0

> Remember to adjust: `resolver`, upstream hostnames (e.g., `node0`, `threadripper0.lan`), and filesystem paths (`/srv/http/damagebdd/`, Let’s Encrypt cert locations).


---

## 7) Optional: IPFS Gateway

If you want to serve `/ipfs` and `/ipns` via Nginx like in the sample config, run an IPFS daemon bound to the local HTTP gateway (e.g., `127.0.0.1:8082`).

**Quick start (Kubo/IPFS):**
```bash
ipfs init
# gateway on 127.0.0.1:8082 (edit ~/.ipfs/config Gateway/Addresses)
ipfs daemon &
```

If you maintain a helper script `setup-ipfs.sh`, review and run it to configure the gateway exactly as your Nginx expects.


---

## 8) macOS service (launchd)

Create a `launchd` plist to auto‑start your release on boot:

```bash
sudo tee /Library/LaunchDaemons/com.damagebdd.node.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.damagebdd.node</string>
  <key>ProgramArguments</key>
  <array>
    <string>/opt/damagebdd/bin/damagebdd</string>
    <string>start</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/var/log/damagebdd/stdout.log</string>
  <key>StandardErrorPath</key><string>/var/log/damagebdd/stderr.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PORT</key><string>8080</string>
    <key>BIND_ADDR</key><string>0.0.0.0</string>
  </dict>
</dict>
</plist>
EOF

sudo launchctl load -w /Library/LaunchDaemons/com.damagebdd.node.plist
```


---

## 9) Windows Service (if running natively)

Running Erlang and Nginx natively on Windows is possible but less battle‑tested for production. Prefer **WSL2**. If you must run native:

- Install **Erlang/OTP for Windows** from Erlang Solutions.
- Install **rebar3** (escript) and add to PATH.
- Install **Nginx for Windows** (zip), configure `nginx.conf` similarly to Linux (no Certbot; use a CDN or terminate TLS elsewhere).
- Use **NSSM** or **Windows Service Manager** to register your `damagebdd` start command as a service.

**Strong recommendation:** Reverse proxy via a Linux box or WSL2 for TLS + stability.


---

## 10) Firewall & SELinux/AppArmor

- Open ports **80/tcp** and **443/tcp** to the world.
- Keep **8080** bound to `127.0.0.1` or firewalled if only behind Nginx.
- On SELinux systems, allow Nginx to proxy to your ports:
  ```bash
  sudo setsebool -P httpd_can_network_connect 1
  ```


---

## 11) Health Checks & Logs

- Nginx stub status can be exposed at `/metrics` or `/stub_status` (see sample). fileciteturn0file0
- Tail logs:
  ```bash
  sudo journalctl -u damagebdd -f
  sudo tail -F /var/log/nginx/access.log /var/log/nginx/error.log
  ```


---

## 12) Typical Topology

```
Internet
   │ 443/80
[Nginx + TLS]
   ├─ / → static site (optional)
   ├─ /ipfs, /ipns → IPFS gateway (optional)
   └─ run.damagebdd.com → http://127.0.0.1:8080  (Verification Node)
```


---

## 13) Quick Commands (Operator Cheatsheet)

```bash
# Build / Release
rebar3 do clean, compile
rebar3 as prod release

# Start/Stop (systemd)
sudo systemctl restart damagebdd
sudo systemctl status damagebdd

# Nginx
sudo nginx -t && sudo systemctl reload nginx

# TLS
sudo certbot renew --dry-run
```


---

## 14) Troubleshooting

- **502 Bad Gateway**: Verify node is listening on the configured upstream (e.g., `curl http://127.0.0.1:8080/health`), and Nginx `proxy_pass` host/port match.
- **TLS issues**: Ensure DNS points to your server **before** running Certbot; check file paths in Nginx.
- **Permission denied**: Ensure `damagebdd` user owns `/opt/damagebdd`, `/var/lib/damagebdd`, and log paths.
- **IPFS gateway**: Confirm IPFS is running and listening on `127.0.0.1:8082` to match Nginx config.
- **macOS port binding**: macOS may block low ports without root. Prefer running Nginx via `brew services` (root).

---

## 15) Notes on Provided Repo Files

- `damagebdd.conf` — full Nginx example with prod/staging/dev servers, IPFS gateway routes, Lightning LNURL endpoint, and Certbot TLS blocks. Use as a base and adapt to your hosts. fileciteturn0file0
- `rebar.config` — build config for Erlang/rebar3.
- `setup.sh`, `bootstrap_sudoers.sh`, `setup-ipfs.sh`, `arch_packages.sh` — optional helpers. **Review before running** and adapt to your OS.

---

## 16) Security Checklist (Minimal)

- Regular OS patching; `fail2ban` for Nginx (optional).
- Rate‑limit public endpoints in Nginx where appropriate.
- Keep Verification Node non‑public; expose via Nginx only.
- Rotate TLS and app secrets; restrict SSH (keys only).

---

**You’re set.** Your DamageBDD node should now be reachable at `https://run.<your-domain>/` via Nginx with the Verification Node running behind it. Ship tests, verify, and scale out nodes behind your proxy.
