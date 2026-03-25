# Authentik

This directory contains the Authentik deployment templates.

The current setup deploys:

- `postgresql`
- `server`
- `worker`

and exposes Authentik through Traefik on `https://authentik.<domain>`.

The first deploy generates the required `PG_PASS` and `AUTHENTIK_SECRET_KEY`
directly on the VPS and stores them in `/opt/vps-devops/authentik/.env`.

Create `authentik/.env.sops.yaml` before deploying Authentik and provide at
least:

- `AUTHENTIK_BOOTSTRAP_PASSWORD`
- `AUTHENTIK_BOOTSTRAP_EMAIL` (optional)

This uses authentik's official automated-install bootstrap variables for the
default `akadmin` user. Per authentik's documentation, the bootstrap password
is only read on the first startup, so later password changes in the UI are not
overwritten by subsequent deploys.

Persistent data is stored in:

- Docker named volume `authentik_database`
- `/opt/vps-devops/authentik/data`
- `/opt/vps-devops/authentik/certs`
- `/opt/vps-devops/authentik/custom-templates`
