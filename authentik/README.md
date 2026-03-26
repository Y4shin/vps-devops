# Authentik

This directory contains the Authentik deployment templates.

The current setup deploys:

- `postgresql`
- `server`
- `worker`

and exposes Authentik through Traefik on `https://authentik.<domain>`.

Create `authentik/.env.sops.yaml` before deploying Authentik and provide at
least:

- `PG_PASS`
- `AUTHENTIK_SECRET_KEY`
- `AUTHENTIK_BOOTSTRAP_PASSWORD`
- `borg_path`
- `borg_passphrase`
- `AUTHENTIK_BOOTSTRAP_EMAIL` (optional)
- `AUTHENTIK_ADMIN_USERNAME` (optional)
- `AUTHENTIK_ADMIN_PASSWORD` (required if `AUTHENTIK_ADMIN_USERNAME` is set)
- `AUTHENTIK_ADMIN_EMAIL` (optional)

The playbook renders `/opt/vps-devops/authentik/.env` from those SOPS-managed
values during deployment, uses it for Docker Compose operations, and removes it
again afterward. `PG_PASS` and `AUTHENTIK_SECRET_KEY` are no longer generated
on the VPS.

Authentik backups use their own Borg repository path and passphrase from
`authentik/.env.sops.yaml`, while still connecting to the shared Hetzner
storage box configured in `secrets.sops.yaml`.

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

- `/opt/vps-devops/authentik/data/postgresql`
- `/opt/vps-devops/authentik/data/media`
- `/opt/vps-devops/authentik/data/certs`
- `/opt/vps-devops/authentik/data/custom-templates`

Backup and restore scripts are deployed to `/opt/vps-devops/scripts` and can be
run via:

- `task authentik:backup:perform`
- `task authentik:backup:restore`
- `task authentik:backup:info`

App-owned Authentik blueprints can live in `*/authentik-blueprints/` at the repo
root. The Authentik playbook deploys every `*.yaml` and `*.yaml.j2` file from
those directories into `/opt/vps-devops/authentik/blueprints/apps/<app>/`.

That lets each app contribute its own base groups, mappings, providers, or
applications without editing one central Authentik blueprint file.
