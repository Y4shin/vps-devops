# VPS DevOps Plan (`vps-devops` repo)

This document describes the design and implementation plan for a separate `vps-devops` repository
that owns all production infrastructure for this project. The `reporting-tool` repo's only
responsibility is application code.

---

## Repository Structure

```
vps-devops/
  ansible/
    bootstrap.yml               # One-time server setup (run once on a fresh VPS)
    site.yml                    # Ongoing: converges all services to latest state
    inventory.yml               # Server connection details
  traefik/
    docker-compose.yml          # Traefik service + proxy network declaration
    traefik.yml                 # Static config: entrypoints, ACME, dashboard
    .env.sops.yaml              # SOPS-encrypted: TRAEFIK_DASHBOARD_USER, TRAEFIK_DASHBOARD_PASSWORD_HASH
  reporting-tool/
    docker-compose.yml          # Production compose (no ports, Traefik labels, external network)
    .env.sops.yaml              # SOPS-encrypted: all app secrets (SESSION_SECRET, ADMIN_PASSWORD, etc.)
    app/                        # Git submodule → Y4shin/reporting-tool, pinned to a specific commit
  scripts/
    backup.sh                   # Borg backup of SQLite database volume
  .sops.yaml                    # SOPS config: pins age recipient for all .env.sops.yaml files
```

---

## Secrets Management (SOPS + age)

- All secrets are stored as SOPS-encrypted YAML files (`*.env.sops.yaml`) committed to the repo.
  Plaintext `.env` files are never committed (`.gitignore` must cover `*.env`).
- Encryption uses `age`. A single age key pair is generated for this project.
- The age private key must be present at `~/.config/sops/age/keys.txt` on any machine
  that runs the Ansible playbooks (your local machine and the VPS).
- `.sops.yaml` at repo root specifies the age recipient so any authorized person can re-encrypt
  or add new keys:

```yaml
creation_rules:
  - path_regex: \.env\.sops\.yaml$
    age: age1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

### Secrets per service

**`traefik/.env.sops.yaml`**
```yaml
TRAEFIK_DASHBOARD_USER: admin
TRAEFIK_DASHBOARD_PASSWORD_HASH: <htpasswd hash>
```

**`reporting-tool/.env.sops.yaml`**
```yaml
ORIGIN: https://your-domain.example.com
DATABASE_URL: file:/data/app.db
SESSION_SECRET: <64 hex chars>
ADMIN_PASSWORD: <strong password>
# S3 (optional):
# S3_ENDPOINT: ...
# S3_ACCESS_KEY_ID: ...
# S3_SECRET_ACCESS_KEY: ...
```

---

## Traefik Setup

### Network

Traefik owns and creates the shared `proxy` Docker network. All proxied services join it as
an external network.

```yaml
# traefik/docker-compose.yml
networks:
  proxy:
    name: proxy
```

### Static config (`traefik/traefik.yml`)

```yaml
entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
  websecure:
    address: ":443"

certificatesResolvers:
  letsencrypt:
    acme:
      email: you@example.com
      storage: /letsencrypt/acme.json
      httpChallenge:
        entryPoint: web

api:
  dashboard: true

providers:
  docker:
    exposedByDefault: false
```

### Dashboard

The dashboard is exposed via a dedicated router with BasicAuth middleware. The username and
htpasswd-hashed password come from the SOPS-encrypted env for Traefik:

```yaml
# in traefik/docker-compose.yml labels on the traefik service itself
- "traefik.enable=true"
- "traefik.http.routers.dashboard.rule=Host(`traefik.your-domain.com`)"
- "traefik.http.routers.dashboard.tls.certresolver=letsencrypt"
- "traefik.http.routers.dashboard.service=api@internal"
- "traefik.http.routers.dashboard.middlewares=dashboard-auth"
- "traefik.http.middlewares.dashboard-auth.basicauth.users=${TRAEFIK_DASHBOARD_USER}:${TRAEFIK_DASHBOARD_PASSWORD_HASH}"
```

---

## App Compose (`reporting-tool/docker-compose.yml`)

```yaml
services:
  app:
    build: ./app              # submodule path
    env_file: .env            # decrypted from .env.sops.yaml at deploy time; never committed
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.reporting-tool.rule=Host(`your-domain.example.com`)"
      - "traefik.http.routers.reporting-tool.entrypoints=websecure"
      - "traefik.http.routers.reporting-tool.tls.certresolver=letsencrypt"
      - "traefik.http.services.reporting-tool.loadbalancer.server.port=3000"
    networks:
      - proxy
      - internal
    volumes:
      - db_data:/data
      - uploads:/app/uploads
    restart: unless-stopped

networks:
  proxy:
    external: true
    name: proxy
  internal: {}

volumes:
  db_data:
  uploads:
```

---

## Submodule Pinning Strategy

The `reporting-tool/app/` submodule is **pinned to a specific commit**, not tracking a branch.
Updates are made locally and committed to `vps-devops`, then `ansible-playbook ansible/site.yml`
converges the server to the new state.

**Workflow to deploy a new version of the app:**

```bash
cd reporting-tool/app
git fetch origin
git checkout <new-commit-sha>
cd ../..
git add reporting-tool/app
git commit -m "chore: update reporting-tool to <new-commit-sha>"
git push
ansible-playbook ansible/site.yml -i ansible/inventory.yml
```

---

## Ansible Playbooks

### `ansible/bootstrap.yml` — run once on a fresh VPS

Handles all one-time server configuration:

- apt update + full-upgrade
- Unattended-upgrades (security patches only)
- UFW (allow 22, 80, 443)
- SSH hardening (disable password auth, disable root login)
- fail2ban
- Docker (official repo)
- sops + age
- `deploy` user (added to `docker` group)
- Directory structure (`/opt/vps-devops`, `/opt/borg-backups`)

```bash
ansible-playbook ansible/bootstrap.yml -i ansible/inventory.yml
```

### `ansible/site.yml` — run to deploy or update anything

Idempotent. Pulls the latest repo state on the server and converges all services:

1. `git pull` + submodule sync on `/opt/vps-devops`
2. Ensure Traefik is running with current config
3. For each app:
   - Check if the deployed commit matches the current submodule commit
   - If changed: run backup → decrypt secrets → `docker compose up --build -d` → record commit → remove `.env`

```bash
ansible-playbook ansible/site.yml -i ansible/inventory.yml
```

---

## Backup (`scripts/backup.sh`)

Uses Borg to back up the SQLite database volume to a local Borg repository on the VPS.
Called by `site.yml` before every deploy. Can also be scheduled via cron on the VPS for
point-in-time recovery independent of deploys.

```bash
#!/usr/bin/env bash
set -euo pipefail

BORG_REPO="/opt/borg-backups/reporting-tool"
DB_VOLUME="reporting-tool_db_data"  # Docker volume name

# Dump a consistent snapshot of the live database using SQLite's online backup API.
# This avoids file-level copy of a potentially in-use WAL database.
docker run --rm \
  -v "${DB_VOLUME}:/data:ro" \
  -v "/tmp/db-snapshot:/snapshot" \
  keinos/sqlite3 \
  sqlite3 /data/app.db ".backup /snapshot/app.db"

borg create \
  --compression lz4 \
  "${BORG_REPO}::reporting-tool-{now:%Y-%m-%dT%H:%M:%S}" \
  /tmp/db-snapshot/

# Prune: keep 7 daily, 4 weekly, 3 monthly
borg prune \
  --keep-daily 7 \
  --keep-weekly 4 \
  --keep-monthly 3 \
  "${BORG_REPO}"

rm -f /tmp/db-snapshot/app.db
```

Initialize the Borg repo once on the VPS: `borg init --encryption=repokey /opt/borg-backups/reporting-tool`

---

## VPS Bootstrap Checklist

One-time steps to prepare a fresh VPS before the first deploy:

- [ ] Run `ansible/bootstrap.yml`
- [ ] Place age private key at `/home/deploy/.config/sops/age/keys.txt` (mode `600`)
- [ ] Clone `vps-devops` to `/opt/vps-devops` with `--recurse-submodules`
- [ ] Initialize Borg repo: `borg init --encryption=repokey /opt/borg-backups/reporting-tool`
  (store the Borg passphrase securely — consider also putting it in SOPS)
- [ ] Run `ansible/site.yml` for the first time
- [ ] (Optional) Add `backup.sh` to the `deploy` user's crontab for nightly backups
