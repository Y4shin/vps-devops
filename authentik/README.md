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
- `AUTHENTIK_ADMIN_USERNAME` (optional)
- `AUTHENTIK_ADMIN_PASSWORD` (required if `AUTHENTIK_ADMIN_USERNAME` is set)
- `AUTHENTIK_ADMIN_EMAIL` (optional)

This uses authentik's official automated-install bootstrap variables for the
default `akadmin` user. Per authentik's documentation, the bootstrap password
is only read on the first startup, so later password changes in the UI are not
overwritten by subsequent deploys.

If `AUTHENTIK_ADMIN_USERNAME` and `AUTHENTIK_ADMIN_PASSWORD` are configured,
the playbook also creates one additional local superuser via `ak shell` inside
the server container. That creation is idempotent and only happens when the
named user does not already exist, so later manual password changes are not
overwritten.

Persistent data is stored in:

- Docker named volume `authentik_database`
- `/opt/vps-devops/authentik/data`
- `/opt/vps-devops/authentik/certs`
- `/opt/vps-devops/authentik/custom-templates`

App-owned Authentik blueprints can live in `*/authentik-blueprints/` at the repo
root. The Authentik playbook deploys every `*.yaml` and `*.yaml.j2` file from
those directories into `/opt/vps-devops/authentik/blueprints/apps/<app>/`.

That lets each app contribute its own base groups, mappings, providers, or
applications without editing one central Authentik blueprint file.
