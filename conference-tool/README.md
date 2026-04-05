# Conference Tool

This directory contains deployment-side assets for the conference tool
(open-caucus). The app image is pulled from `ghcr.io/y4shin/open-caucus:latest`.

## Deployment

```bash
# First time: fill in real secrets
task secrets:edit FILE=conference-tool/.env.sops.yaml

# Deploy Authentik first (renders the OIDC blueprint)
task deploy:authentik

# Deploy the conference tool
task deploy:conference-tool
```

## Secrets

`conference-tool/.env.sops.yaml` must define:

| Key                  | Purpose                              |
|----------------------|--------------------------------------|
| `SESSION_SECRET`     | Signs session cookies (32+ chars)    |
| `OAUTH_CLIENT_SECRET`| Authentik OIDC client secret         |

## Authentik integration

Blueprints in `authentik-blueprints/`:

- `10-groups.yaml` — creates `conference-user` and `conference-admin` groups.
- `20-groups-claim.yaml` — OIDC scope mapping emitting only `conference-*` groups.
- `30-oidc.yaml.j2` — OAuth2 provider, application, and access policy
  (only rendered when `OAUTH_CLIENT_SECRET` is set in the SOPS file).

The app uses native OIDC (`/oauth/callback`). Users in the `conference-user`
Authentik group can log in; members of `conference-admin` get admin privileges.

Concrete committees and committee memberships are intentionally not declared
here. Those stay dynamic inside the conference tool itself.
