# telemt-docker

[![Docker Image Size](https://img.shields.io/docker/image-size/uppal/telemt-docker?style=flat-square&logo=docker&color=blue)](https://hub.docker.com/r/uppal/telemt-docker)
[![Docker Pulls](https://img.shields.io/docker/pulls/uppal/telemt-docker?style=flat-square&logo=docker)](https://hub.docker.com/r/uppal/telemt-docker)
[![Architecture](https://img.shields.io/badge/arch-amd64%20%7C%20arm64-important?style=flat-square)](#)
[![Security: non-root](https://img.shields.io/badge/security-non--root-success?style=flat-square)](#)
[![Base Image](https://img.shields.io/badge/base-distroless%2Fstatic%3Anonroot-blue?style=flat-square)](https://github.com/GoogleContainerTools/distroless)
[![Upstream](https://img.shields.io/badge/upstream-telemt-orange?style=flat-square)](https://github.com/telemt/telemt)

A minimal, secure, and production-oriented Docker image for **Telemt** — a fast MTProto proxy server (MTProxy) written in **Rust + Tokio**.

Built as a **fully static** binary and shipped in a **distroless** runtime image, running as **non-root** by default.

---

## Features

- **Secure by default:** Distroless runtime + non-root user.
- **Multi-arch:** Supports `amd64` and `arm64`.
- **Fully static binary:** Designed for `gcr.io/distroless/static:nonroot`.
- **Config-driven:** You mount a single `/etc/telemt.toml` and go.
- **Metrics-ready:** Supports Telemt metrics port (`9090`) via config.
- **Build-time pinning:** Upstream repo/ref are configurable via build args.

---

## Important Notice

Telemt is a Telegram proxy (MTProto). Operating proxies may be restricted or monitored depending on your country/ISP and may carry legal/operational risks.

You are responsible for compliance with local laws and for safe deployment (firewalling, access control, logs, monitoring).

---

## Quick Start (Docker Compose)

### 1. Generate a Secret
Telemt users require a **32-hex-char secret** (16 bytes):

```bash
openssl rand -hex 16
```

### 2. Create `telemt.toml`

Refer to the upstream repository for the configuration format and examples:

> **https://github.com/telemt/telemt**

Place your configuration file as `./telemt.toml`.

### 3. Create `docker-compose.yml`

> Note: the container runs as **non-root**, but Telemt binds to **443** by default.
> To allow binding to privileged ports, we add `NET_BIND_SERVICE`.

```yaml
services:
  telemt:
    image: uppal/telemt-docker:latest
    container_name: telemt
    restart: unless-stopped

    environment:
      RUST_LOG: "info"

    volumes:
      - ./telemt.toml:/etc/telemt.toml:ro

    ports:
      - "443:443/tcp"
      # If you enable metrics_port=9090 in config:
      # - "127.0.0.1:9090:9090/tcp"

    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE
    read_only: true
    tmpfs:
      - /tmp:rw,nosuid,nodev,noexec,size=16m

    deploy:
      resources:
        limits:
          cpus: "0.50"
          memory: 256M

    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
```

### 4. Start

```bash
docker compose up -d
```

Logs:

```bash
docker compose logs -f
```

---

## Configuration

### Environment Variables

| Variable | Mandatory | Default | Description |
|---|:---:|---|---|
| `RUST_LOG` | No | — | Telemt log level (e.g. `info`, `debug`, `trace`). |

### Volumes

| Container Path | Purpose |
|---|---|
| **`/etc/telemt.toml`** | Main Telemt configuration file (you mount it from the host). |

### Ports

| Port | Purpose |
|---:|---|
| `443/tcp` | Main MTProxy listener (commonly used for TLS-like traffic). |
| `9090/tcp` | Metrics port (only if enabled in `telemt.toml`). |

---

## Container Behavior

- **ENTRYPOINT:** `telemt`
- **CMD (default):** `/etc/telemt.toml`

So the container effectively runs:

```text
telemt /etc/telemt.toml
```

To use a different config path, override the command:

```bash
docker run ... uppal/telemt-docker:latest /path/to/config.toml
```

---

## Traefik + Telemt Stack (One-Line Install)

The `stack/` directory contains a production-ready deployment with **Traefik** as a TLS-passthrough reverse proxy in front of Telemt.

### One-line install

```bash
curl -sSL https://raw.githubusercontent.com/uppaljs/telemt-docker/main/stack/install.sh | bash
```

The installer will:
1. Install Docker if not present
2. Ask for a listen port (default `443`) and Fake TLS domain (default `1c.ru`)
3. Generate a random secret
4. Download and configure all files
5. Start the stack and print your `tg://proxy` link

### Manual setup

```bash
git clone https://github.com/uppaljs/telemt-docker.git
cd telemt-docker/stack
cp telemt.toml.example telemt.toml
# Edit telemt.toml — replace REPLACE_WITH_32_HEX_CHARS with: openssl rand -hex 16
docker compose up -d
```

### Stack layout

```
stack/
├── docker-compose.yml        # Traefik + Telemt services
├── install.sh                # One-line installer script
├── telemt.toml.example       # Sample Telemt config
└── traefik/
    ├── dynamic/
    │   └── tcp.yml           # TLS passthrough routing to Telemt
    └── static/
        └── .gitkeep
```

### Environment variables (installer)

| Variable | Default | Description |
|---|---|---|
| `LISTEN_PORT` | `443` | External port for the proxy |
| `FAKE_DOMAIN` | `1c.ru` | Domain for Fake TLS masking |
| `TELEMT_INTERNAL_PORT` | `1234` | Internal Telemt listen port |
| `INSTALL_DIR` | `./mtproxy-data` | Where files are downloaded |

---

## Build

This Dockerfile supports pinning upstream Telemt source:

- `TELEMT_REPO` (default: `https://github.com/telemt/telemt.git`)
- `TELEMT_REF` (default: `main`)

### Multi-arch build (amd64 + arm64)

```bash
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t uppal/telemt-docker:latest \
  --push .
```

### Build a specific upstream tag/branch/commit

```bash
docker buildx build \
  --build-arg TELEMT_REF=v1.1.0.0 \
  -t uppal/telemt-docker:v1.1.0.0 \
  --push .
```

---

## Useful Links

- **Telemt upstream:** https://github.com/telemt/telemt
- **MTProxy ad tag bot:** https://t.me/mtproxybot
- **Distroless images:** https://github.com/GoogleContainerTools/distroless
