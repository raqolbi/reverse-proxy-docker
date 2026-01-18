# Docker Nginx Reverse Proxy Generator (ENV-Driven)

## Overview

This project is an **ENV-driven Nginx reverse proxy generator** for Docker environments.

All Nginx configuration, SSL (Certbot), logging, rate limiting, performance tuning, Docker networking, and `docker-compose.yml`
are **generated automatically** from a single `.env` file by running `setup.sh`.

There is **no manual Nginx configuration editing**.

This tool is designed for **explicit, deterministic, production-grade setups** where debugging and observability matter.

---

## Core Principles (Must Read)

Before using this project, understand these rules:

1. `.env` is the **single source of truth**
2. `setup.sh` is a **generator**, not a runtime service
3. `generated/` is **output-only** (safe to delete anytime)
4. `docker-compose.yml` is **generated**, never edited manually
5. Nginx communicates **only via Docker service names + internal ports**
6. Docker network is **created automatically and idempotently**
7. All logging and performance behavior is **explicitly controlled via ENV**

Violating these rules will lead to undefined behavior.

---

## Architecture

```
Client (Internet / LAN)
        |
        v
Nginx Reverse Proxy (Docker)
        |
        v
Application Containers (PHP / API / etc)
```

- Nginx acts purely as a reverse proxy
- Applications expose **internal ports only**
- All traffic flows through a **Docker bridge network**
- No host-port coupling between application containers

---

## Project Structure

```
project-root/
│
├── .env                  # ACTIVE CONFIG (DO NOT COMMIT)
├── .env.example          # FULL CONFIG TEMPLATE
├── setup.sh              # CONFIG GENERATOR
│
├── generated/            # AUTO-GENERATED (DO NOT EDIT)
│   ├── docker-compose.yml
│   └── nginx/
│       ├── nginx.conf
│       └── conf.d/
│           ├── 00-http.conf
│           └── *.conf
│
└── README.md
```

You may safely delete `generated/` at any time and regenerate it.

---

## Supported Features

- HTTP path routing (LAN / internal access)
- HTTP domain routing
- Optional HTTPS per service (Certbot)
- Global and per-service rate limiting
- **Global logging + per-service logging**
- **Auto-created log directories (fail-fast)**
- Global proxy timeout & performance tuning
- Docker network auto-creation (idempotent)
- Deterministic regeneration

---

## Step-by-Step Usage

### 1. Prepare Application Containers

Your backend containers **must already exist**.

Example (PHP app):

```yaml
services:
  php-app:
    image: php:8.3-apache
    expose:
      - "80"
```

Rules:
- Do **NOT** use `ports`
- Use `expose` only
- Service name is used directly by Nginx

---

### 2. Create `.env`

Copy the template:

```bash
cp .env.example .env
```

Then edit `.env` according to your environment.

> **Important:**  
> All required variables **must be present**.  
> Missing or invalid values will cause `setup.sh` to **fail fast**.

---

### 3. Generate Configuration

```bash
chmod +x setup.sh
./setup.sh
```

What happens:

- Docker network is created (if missing)
- Log directories are auto-created
- All Nginx configs are generated
- No containers are started automatically

---

### 4. Start Reverse Proxy

```bash
cd generated
docker compose up -d
```

Verify:

```bash
docker compose ps
```

---

### 5. Access Services

Examples:

```
https://example.com
http://server-ip/api
```

---

### 6. Apply Changes

Whenever `.env` changes:

```bash
./setup.sh
cd generated
docker compose restart nginx
```

Only **Nginx** needs restart.

---

## Logging System (FULL DEBUG MODE)

### Global Logging

Controlled by:

```env
NGINX_LOG_MODE=file|stdout
NGINX_GLOBAL_ACCESS_LOG=true|false
NGINX_GLOBAL_ERROR_LOG=true|false
NGINX_ERROR_LOG_LEVEL=debug|info|notice|warn|error|crit
NGINX_LOG_BASE_PATH=/host/path
```

Behavior:

- `stdout` → Docker logs
- `file` → logs written to host filesystem
- Log directory is **auto-created**
- If creation fails → **setup.sh stops immediately**

---

### Per-Service Logging

Controlled by:

```env
SERVICE_X_ACCESS_LOG=true|false
SERVICE_X_ERROR_LOG=true|false
SERVICE_X_LOG_PATH=/host/path
```

Behavior:

- Each service may have its own log directory
- Access & error logs are isolated per service
- Directories are auto-created (fail-fast)

Example layout:

```
/mnt/data/Coding/WebServer/logs/
├── access.log              # global
├── error.log               # global
├── home/
│   ├── access.log
│   └── error.log
└── api/
    ├── access.log
    └── error.log
```

---

## Rate Limiting

### Global

```env
NGINX_RATE_LIMIT_ENABLED=true
NGINX_RATE_LIMIT_ZONE_NAME=global_limit
NGINX_RATE_LIMIT_RATE=10r/s
NGINX_RATE_LIMIT_BURST=20
```

### Per Service

```env
SERVICE_X_RATE_LIMIT=true
```

---

## Path Routing Rules (IMPORTANT)

- `SERVICE_X_PATH=/`
  - That service becomes the **root**
  - No fallback `/` handler is generated
- If **no service uses `/`**
  - A fallback endpoint responds:
    ```
    reverse-proxy: ok
    ```

Duplicate `location /` is **explicitly prevented**.

---

## Certbot Behavior

- Enabled globally via:
  ```env
  CERTBOT_ENABLED=true
  ```
- HTTPS generated only for:
  ```env
  SERVICE_X_SSL=true
  ```
- Auto-renew controlled per service:
  ```env
  SERVICE_X_CERTBOT_RENEW=true
  ```
- Renewal runs in a dedicated container (if enabled)

---

## Common Mistakes

❌ Editing files inside `generated/`  
❌ Using host ports in application containers  
❌ Running `docker compose` from project root  
❌ Defining multiple services with `SERVICE_X_PATH=/`  
❌ Expecting hot reload without regeneration  

---

## Design Intentions

- Deterministic infrastructure
- Explicit configuration
- No hidden defaults
- Fail-fast on misconfiguration
- Production-grade debugging

---

## Limitations (Intentional)

- No hot reload
- No dynamic service discovery
- Regeneration required for changes

These are **design decisions**, not missing features.

---

## Summary

This project provides a **production-safe, fully debuggable Nginx reverse proxy generator**
for Docker environments.

If you control your `.env`,  
this tool will never surprise you.

