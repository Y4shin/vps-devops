# Foundry VTT Migration And Operations

This repo now has an opt-in Foundry VTT deployment at `task deploy:foundry`.

It is intentionally separate from the default `task deploy` flow so the
existing stack does not suddenly require Foundry secrets before you are ready to
cut over.

## Secrets

Create `foundry/.env.sops.yaml` with:

```yaml
FOUNDRY_USERNAME: your-foundry-account-email-or-username
FOUNDRY_PASSWORD: your-foundry-account-password
FOUNDRY_ADMIN_KEY: your-foundry-admin-key
borg_path: your-foundry-borg-repo-path
borg_passphrase: your-foundry-borg-passphrase
```

You can use `FOUNDRY_RELEASE_URL` instead of `FOUNDRY_USERNAME` and
`FOUNDRY_PASSWORD`.

Optional values supported by the playbook:

- `FOUNDRY_PUBLIC_HOSTNAME`
- `FOUNDRY_LICENSE_KEY`
- `FOUNDRY_PASSWORD_SALT`
- `FOUNDRY_WORLD`
- `FOUNDRY_PROXY_PORT`
- `FOUNDRY_PROXY_SSL`
- `FOUNDRY_UPNP`
- `CONTAINER_CACHE`
- `CONTAINER_PRESERVE_CONFIG`
- `TZ`

## Initial deploy

```bash
task deploy:foundry
```

The playbook will:

1. Create `/opt/vps-devops/foundry` and `/opt/vps-devops/foundry/data`
2. Render the compose file for the `felddy/foundryvtt:13.351` image
3. Configure Traefik routing for `foundry.<domain>` by default
4. Initialize a dedicated Borg repository for Foundry backups
5. Install a daily `foundry-backup.timer` at `05:00`

## Migration workflow

1. Deploy Foundry once on the new VPS:

```bash
task deploy:foundry
```

2. Stop Foundry on the old VPS so no more writes happen.

3. Sync the old data directory to the new VPS. `SOURCE` can be either a local
directory or a remote rsync source:

```bash
task foundry:migrate:data SOURCE=user@old-host:/path/to/data/foundry DELETE=1
```

4. Validate that the worlds, systems, modules, and assets are present on the
new host.

5. Point DNS or your external reverse proxy at the new VPS.

6. In Authentik, add the allowed users to the `foundry-access` group.

The migration helper stages data locally first and then pushes it to
`/opt/vps-devops/foundry/data` on the VPS. That keeps the data copy explicit and
lets you use your normal SSH access to the old server.

## Authentik access

Foundry is protected through the same Traefik forward-auth pattern used for the
Traefik dashboard, but with its own Authentik proxy application and group:

- Authentik application: `Foundry VTT`
- Authentik group: `foundry-access`

Users must be members of `foundry-access` to reach the Foundry hostname.

Note: unlike the Traefik and Foundry proxy flows, Witness admin login uses
OIDC against the central `authentik.<domain>` host. That means the Witness app
can get a dashboard tile icon, but the actual Authentik login screen is not as
cleanly brandable per-app as the proxy-protected hosts are.

## Backups

Useful commands:

```bash
task foundry:backup:perform
task foundry:backup:info
task foundry:backup:restore
task ssh:foundry-backup
```

The backup script briefly stops the Foundry container, stages a copy of the
bind-mounted data directory, writes a manifest, restarts Foundry, and then
creates a Borg archive.
