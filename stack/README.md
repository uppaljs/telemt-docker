# Traefik + Telemt MTProxy Stack

A production-ready, one-command deployment of [Telemt](https://github.com/telemt/telemt) (Rust MTProto proxy) behind [Traefik](https://traefik.io/) v3 as a TLS-passthrough reverse proxy.

---

## Architecture

```
Internet
  │
  ▼ :443 (TLS)
┌──────────────────────┐
│  Traefik v3.2        │
│  TLS passthrough     │
│  HostSNI(`*`)        │
└──────────┬───────────┘
           │ tcp (raw TLS)
           ▼
┌──────────────────────┐
│  Telemt (MTProxy)    │
│  Fake TLS mode       │
│  :1234 (internal)    │
└──────────────────────┘
```

Traefik accepts incoming TLS connections on port 443 and passes them **unmodified** (TLS passthrough) to the Telemt container. Telemt handles the MTProto protocol handshake, Fake TLS masking, and proxying to Telegram servers.

This means:
- Traefik never terminates TLS — it just routes raw TCP based on SNI
- The traffic looks like a normal HTTPS connection to the masking domain
- Telemt is never exposed directly to the internet

---

## Quick Start

### One-line install

```bash
curl -sSL https://raw.githubusercontent.com/uppaljs/telemt-docker/main/stack/install.sh | bash
```

The interactive installer will prompt you for:

1. **Listen port** — external port for the proxy (default: `443`)
2. **Fake TLS domain** — domain to masquerade as (default: `1c.ru`)
3. **Secret** — auto-generates a 32-hex-char secret, or you can provide your own
4. **Internal port** — Telemt's internal listen port (default: `1234`)

After confirming, it downloads all files, configures everything, starts the containers, and prints your `tg://proxy` link.

### Manual setup

```bash
git clone https://github.com/uppaljs/telemt-docker.git
cd telemt-docker/stack

# Copy and edit the config
cp telemt.toml.example telemt.toml

# Generate a secret and replace the placeholder
SECRET=$(openssl rand -hex 16)
sed -i "s/REPLACE_WITH_32_HEX_CHARS/${SECRET}/" telemt.toml

# Start
docker compose up -d
```

---

## Installer Commands

The install script supports multiple subcommands:

```bash
# Install (default) — interactive setup + start
bash install.sh install

# Show running container status and proxy link
bash install.sh status

# Print just the tg://proxy link
bash install.sh link

# Stop containers and delete all data (with confirmation)
bash install.sh uninstall

# Clean uninstall + fresh install in one step
bash install.sh reinstall

# Show help
bash install.sh --help
```

When run via `curl | bash`, the default command is `install`.

---

## Directory Layout

### Source (this repo)

```
stack/
├── README.md                 # This file
├── docker-compose.yml        # Traefik + Telemt service definitions
├── install.sh                # Interactive installer script
├── telemt.toml.example       # Sample Telemt configuration
└── traefik/
    ├── dynamic/
    │   └── tcp.yml           # Traefik TCP routing (TLS passthrough)
    └── static/
        └── .gitkeep          # Placeholder for static Traefik config
```

### Installed (on the server)

After running `install.sh`, the following is created at `$INSTALL_DIR` (default: `./mtproxy-data`):

```
mtproxy-data/
├── docker-compose.yml        # Configured compose file
├── telemt.toml               # Telemt config (with your secret + domain)
├── .secret                   # Your raw 32-hex secret
├── .port                     # Configured listen port
└── traefik/
    ├── dynamic/
    │   └── tcp.yml           # Configured TCP routing
    └── static/
```

---

## Configuration Reference

### Telemt (`telemt.toml`)

See [`telemt.toml.example`](telemt.toml.example) for the full template. Key settings:

| Section | Key | Default | Description |
|---|---|---|---|
| `[server]` | `port` | `1234` | Internal listen port (must match `tcp.yml`) |
| `[censorship]` | `tls_domain` | `1c.ru` | Domain for Fake TLS masking |
| `[censorship]` | `mask` | `true` | Enable traffic masking |
| `[censorship]` | `fake_cert_len` | `2048` | Fake certificate length in bytes |
| `[general]` | `fast_mode` | `true` | Enable fast mode |
| `[general]` | `use_middle_proxy` | `false` | Use Telegram middle proxies |
| `[general.modes]` | `tls` | `true` | Enable Fake TLS mode (ee prefix) |
| `[general.modes]` | `secure` | `false` | Enable Secure mode (dd prefix) |
| `[general.modes]` | `classic` | `false` | Enable Classic mode (no prefix) |
| `[access]` | `replay_check_len` | `65536` | Replay attack protection window |
| `[access.users]` | `<name>` | — | `"32-hex-char-secret"` per user |
| `[[upstreams]]` | `type` | `direct` | `direct` or `socks5` |

### Traefik TCP Routing (`traefik/dynamic/tcp.yml`)

```yaml
tcp:
  routers:
    mtproxy:
      rule: "HostSNI(`*`)"       # Match all SNI hostnames
      entryPoints:
        - websecure              # Port 443
      service: mtproxy
      tls:
        passthrough: true        # Do NOT terminate TLS
  services:
    mtproxy:
      loadBalancer:
        servers:
          - address: "telemt:1234"   # Forward to Telemt container
```

To restrict to a specific SNI domain, change `HostSNI(`*`)` to `HostSNI(`your-domain.com`)`.

### Environment Variables (Installer)

| Variable | Default | Description |
|---|---|---|
| `LISTEN_PORT` | `443` | External port exposed to the internet |
| `FAKE_DOMAIN` | `1c.ru` | Domain for Fake TLS SNI masking |
| `TELEMT_INTERNAL_PORT` | `1234` | Internal port Telemt listens on |
| `INSTALL_DIR` | `./mtproxy-data` | Installation directory |
| `REPO_RAW` | GitHub raw URL | Override to use a fork/mirror |

These can be set before running the installer for non-interactive use:

```bash
LISTEN_PORT=8443 FAKE_DOMAIN=example.com curl -sSL .../install.sh | bash
```

### Environment Variables (Runtime)

| Variable | Default | Description |
|---|---|---|
| `RUST_LOG` | `info` | Telemt log level (`debug`, `info`, `warn`, `error`, `trace`) |

---

## Container Hardening

The Telemt container runs with production security defaults:

| Setting | Value | Purpose |
|---|---|---|
| `security_opt` | `no-new-privileges:true` | Prevent privilege escalation |
| `cap_drop` | `ALL` | Drop all Linux capabilities |
| `cap_add` | `NET_BIND_SERVICE` | Allow binding to privileged ports |
| `read_only` | `true` | Read-only root filesystem |
| `tmpfs` | `/tmp` (16MB, nosuid, nodev, noexec) | Minimal writable tmpfs |
| `resources.limits` | 0.5 CPU, 256MB RAM | Prevent resource exhaustion |
| `logging` | json-file, 10MB x 3 | Log rotation |

The Telemt image itself is `gcr.io/distroless/static:nonroot` — no shell, no package manager, running as UID 65532.

---

## Operations

### View logs

```bash
cd mtproxy-data && docker compose logs -f
```

### Restart

```bash
cd mtproxy-data && docker compose restart
```

### Update to latest image

```bash
cd mtproxy-data && docker compose pull && docker compose up -d
```

### Change the secret

1. Generate a new secret: `openssl rand -hex 16`
2. Edit `mtproxy-data/telemt.toml` — update the value in `[access.users]`
3. Update `mtproxy-data/.secret` with the new value
4. Restart: `cd mtproxy-data && docker compose restart telemt`
5. Get the new link: `bash install.sh link`

### Change the port

1. Edit `mtproxy-data/docker-compose.yml` — change the `ports` mapping
2. Update `mtproxy-data/.port` with the new value
3. Restart: `cd mtproxy-data && docker compose up -d`

### Complete reinstall

```bash
bash install.sh reinstall
```

This stops containers, deletes all data, and runs a fresh interactive install.

---

## How Fake TLS Works

1. The client connects to your server on port 443
2. Traefik sees a TLS ClientHello with an SNI matching the masking domain
3. Traefik passes the raw TCP stream to Telemt (TLS passthrough)
4. Telemt recognizes the MTProto Fake TLS handshake (secret prefix `ee`)
5. Traffic is proxied to Telegram servers

To anyone inspecting the traffic, it looks like a normal HTTPS connection to the masking domain. The secret encodes both the authentication key and the domain:

```
ee<32-hex-secret><domain-in-hex>
```

---

## Troubleshooting

### Containers won't start

```bash
cd mtproxy-data && docker compose logs
```

### Port already in use

```bash
# Check what's using port 443
ss -tuln | grep :443

# Reinstall with a different port
LISTEN_PORT=8443 bash install.sh reinstall
```

### Connection refused / timeout

- Ensure the port is open in your firewall: `ufw allow 443/tcp`
- Verify containers are running: `bash install.sh status`
- Check Telemt logs for errors: `docker compose logs telemt`

### Link doesn't work in Telegram

- Ensure `tls_domain` in `telemt.toml` is a real, reachable domain with a valid TLS certificate
- The domain must serve HTTPS on port 443 normally (Telemt mimics its TLS handshake)
- Try a different masking domain if your ISP blocks the current one

---

## Useful Links

- **Telemt upstream:** https://github.com/telemt/telemt
- **Telemt Docker image:** https://hub.docker.com/r/uppal/telemt-docker
- **Traefik TCP routing docs:** https://doc.traefik.io/traefik/routing/routers/#configuring-tcp-routers
- **MTProxy ad tag bot:** https://t.me/mtproxybot
