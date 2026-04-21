# TeamSpeak 3 Server — ARM64 (Box64)

```text
 _____ ____ _____                                 
|_   _/ ___|___ / ___  ___ _ ____   _____ _ __    
  | | \___ \ |_ \/ __|/ _ \ '__\ \ / / _ \ '__|   
  | |  ___) |__) \__ \  __/ |   \ V /  __/ |      
  |_| |____/____/|___/\___|_|    \_/ \___|_|      

        A R M 6 4  |  B O X 6  4
```

[![Docker Image](https://img.shields.io/badge/docker-ghcr.io-2496ED?logo=docker&logoColor=white)](https://github.com/ramius86/ts3server-arm64/pkgs/container/ts3server-arm64)
![Platform](https://img.shields.io/badge/platform-linux%2Farm64-blue)
![Base Image](https://img.shields.io/badge/base-debian%3Atrixie--slim-informational)
![License](https://img.shields.io/badge/license-MIT-green)
![TS3 Version](https://img.shields.io/badge/TS3%20version-3.13.7-orange)
![Last Commit](https://img.shields.io/github/last-commit/ramius86/ts3server-arm64)

[![Publish](https://github.com/ramius86/ts3server-arm64/actions/workflows/docker-publish.yml/badge.svg)](https://github.com/ramius86/ts3server-arm64/actions/workflows/docker-publish.yml)
[![Build](https://github.com/ramius86/ts3server-arm64/actions/workflows/docker-build.yml/badge.svg)](https://github.com/ramius86/ts3server-arm64/actions/workflows/docker-build.yml)
[![Smoke Test](https://github.com/ramius86/ts3server-arm64/actions/workflows/smoke-test.yml/badge.svg)](https://github.com/ramius86/ts3server-arm64/actions/workflows/smoke-test.yml)
[![Lint](https://github.com/ramius86/ts3server-arm64/actions/workflows/lint.yml/badge.svg)](https://github.com/ramius86/ts3server-arm64/actions/workflows/lint.yml)

A high-performance, containerized TeamSpeak 3 server for AArch64, leveraging **Box64** for transparent syscall translation and native library redirection — no x86_64 libraries required.

---

## Table of Contents
1. [Features](#features)
2. [Requirements](#requirements)
3. [Quick Start](#quick-start)
4. [Configuration](#configuration)
5. [Healthcheck](#healthcheck)
6. [Data Persistence & Logs](#data-persistence--logs)
7. [Troubleshooting](#troubleshooting)
8. [Advanced](#advanced)
   - [Debug Mode](#debug-mode)
   - [Project Structure](#project-structure)
   - [Architecture](#architecture)
   - [Automation](#automation)

---

## Features
- **Native Library Interop**: Unlike traditional emulation, it uses Box64 to redirect x86_64 calls to native ARM64 system libraries, significantly reducing memory overhead and improving performance.
- **Smart Permission Reconciliation**: Logic-driven startup script that skips recursive `chown` operations when volume ownership is already correct, preventing I/O bottlenecks on large persistent datasets.
- **Stream-based Observability**: Application logs are inverted to `stdout` for full compatibility with Docker logging drivers (Loki, ELK, Splunk), while maintaining on-disk persistence with automated 7-day TTL rotation.
- **Hardened Lifecycle**: Continuous integration with Trivy CVE scanning, immutable SHA-pinned Action workflows, and atomic privilege dropping via `gosu`.
- **Runtime Tuning**: Pre-configured with Box64 Dynarec and Strong Memory Model settings to ensure SQLite database stability under high concurrent load.

---

## Requirements
- ARM64 / aarch64 host machine (e.g. Oracle Cloud A1, Raspberry Pi 5)
- Docker + Docker Compose v2
- Tested on: **Oracle Cloud VPS — Ampere A1 (aarch64)**

---

## Quick Start
```bash
git clone https://github.com/ramius86/ts3server-arm64
cd ts3server-arm64
docker compose up -d
```

> **Note**: Box64 initialization may take 1–2 minutes on the first start while JIT-compiling the server binary.

### Retrieve Server Admin Token
```bash
docker logs teamspeak3 2>&1 | grep "token="
```

---

## Configuration
All options are controlled via environment variables in `docker-compose.yml`.

| Variable | Default | Description |
|----------|---------|-------------|
| `TIME_ZONE` | `UTC` | Container timezone (tz database format) |
| `PUID` | `1000` | Target UID for the non-privileged `ts` user (must be > 0) |
| `PGID` | `1000` | Target GID for the non-privileged `ts` group (must be > 0) |
| `INIFILE` | `0` | Boolean (0|1) to enable `ts3server.ini` generation/usage |
| `DEBUG` | `0` | Boolean (0|1) to skip server launch and hold the container for shell access |
| `TS3SERVER_LICENSE` | `accept` | Mandatory EULA acceptance |

---

## Healthcheck
The container monitors the **ServerQuery interface (10011/TCP)** to ensure the application layer is responsive.
- **Interval**: 1 minute
- **Start Period**: 2 minutes (compensates for Box64 initialization)

Current health can be verified via: `docker ps --filter "name=teamspeak3"`

---

## Data Persistence & Logs
The persistent volume is mounted at `/teamspeak/save/` and follows a structured reconciliation logic via symlinks.

### Persistence Logic
- `ts3server.sqlitedb`: Main application database (SQLite).
- `logs/`: Application-level logs with automated 7-day cleanup.
- `files/`: Binary assets (icons, avatars, file transfers).

### Log Inversion
The entrypoint uses a background tail process to forward rotating on-disk logs to the container's standard output stream, enabling native log aggregation without losing local files.

---

## Troubleshooting

| Symptom | Probable Cause | Resolution |
|---------|----------------|------------|
| Container Exit (Code 1) | License not accepted | Set `TS3SERVER_LICENSE=accept` |
| Clients cannot connect | Firewall / Security Group | Ensure `9987/UDP` is open on host and cloud ingress rules |
| Query Timeout | Localhost binding | Change `127.0.0.1:10011:10011` to `10011:10011` in compose to allow external access |
| Healthcheck 'starting' | Emulation overhead | Initial JIT compilation takes time; wait at least 2 minutes |

---

## Advanced

<details>
<summary><strong>Debug Mode</strong></summary>

Bypasses the application launch to allow manual environment inspection via `docker exec`.

**Activation:**
- Set `DEBUG=1` in environment variables.
- Or `touch ./data/debug` on the host volume and restart the container.
</details>

<details>
<summary><strong>Project Structure</strong></summary>

- `Dockerfile`: Multi-stage OCI-compliant build (Debian Trixie + Box64). The base image is strictly pinned by sha256 digest to guarantee deterministic builds.
- `docker-compose.yml`: Reference manifest with optimized Box64 Dynarec tuning.
- `entrypoint.sh`: PID 1 orchestration and stream-based log forwarding.
- `startup.sh`: Root-level system initialization and ownership reconciliation.
</details>

<details>
<summary><strong>Architecture</strong></summary>

### Process Management
Uses `tini` as a reaping init process to handle signal forwarding (SIGTERM) and prevent zombie process accumulation. Background processes like log forwarders are cleanly trapped and terminated during shutdown. Atomic privilege drop is handled via `gosu` after initial system setup (execution as root via PUID=0 is strictly blocked).

### Box64 Syscall Translation
Instead of full system emulation, Box64 intercepts x86_64 syscalls and redirects them to native ARM64 libraries. This provides near-native performance while maintaining a minimal container footprint (no x86 libs bundled).
</details>

<details>
<summary><strong>Automation</strong></summary>

### GitHub Actions Workflows
- `check-ts-version.yml`: Daily automated polling of TeamSpeak version API.
- `check-debian-update.yml`: Daily monitoring of Debian base image digests.
- `smoke-test.yml`: End-to-end functional validation (build + launch + healthcheck) on every PR.
- `docker-publish.yml`: Buildx multi-arch pipeline with Trivy security scanning.

### Supply Chain Security
All workflow dependencies are pinned to immutable commit SHAs, and images are scanned for vulnerabilities before publication.
</details>
