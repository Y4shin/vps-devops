# Foundry VTT

This directory contains the repo-managed deployment template for Foundry VTT.

## Required encrypted secrets

Create `foundry/.env.sops.yaml` before the first deploy with:

```yaml
FOUNDRY_USERNAME: your-foundry-account-email-or-username
FOUNDRY_PASSWORD: your-foundry-account-password
FOUNDRY_ADMIN_KEY: your-foundry-admin-key
borg_path: your-foundry-borg-repo-path
borg_passphrase: your-foundry-borg-passphrase
```

Instead of `FOUNDRY_USERNAME` and `FOUNDRY_PASSWORD`, you may provide:

```yaml
FOUNDRY_RELEASE_URL: your-timed-foundry-download-url
```

Optional keys supported by the playbook:

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

## Common commands

```bash
task deploy:foundry
task ssh:foundry
task foundry:backup:perform
task foundry:backup:info
task foundry:backup:restore
task foundry:migrate:data SOURCE=user@old-host:/path/to/data/foundry DELETE=1
```

The deployed data directory is `/opt/vps-devops/foundry/data`.

Foundry access is protected through Authentik forward-auth. The Authentik
resources create the `foundry-access` group and a `Foundry VTT` application.
Add users to `foundry-access` to grant access. The Authentik branding also uses
`foundry/foundry-logo.png` for the Foundry app tile and proxy-host login screen.
