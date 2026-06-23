# Headscale — Operator Guide

Self-hosted [Headscale](https://headscale.net) control server (the Tailscale
control plane). Nodes still run the official Tailscale clients; only the
coordination server is self-hosted here. For the design rationale and the
decisions behind this layout, see [headscale-plan.md](headscale-plan.md).

## What runs where

- **Role:** [`ansible/roles/headscale/`](../ansible/roles/headscale/) — renders
  `config.yaml` (secret-free) and the compose file, opens UFW `3478/udp`, wires
  the Borg backup, and brings the container up behind Traefik.
- **Container:** `headscale-headscale-1`, compose dir `/opt/vps-devops/headscale`.
- **Endpoints:**
  - `https://headscale.<domain>` → Traefik → container `:8080` (control protocol,
    OIDC callback, and embedded-DERP relay over WebSocket). **No forward-auth** —
    this is a machine API, and headscale is itself the OIDC client of Authentik.
  - `udp/3478` published directly on the host (STUN for embedded DERP; cannot go
    through Traefik). Opened in UFW by the role.
- **OIDC:** Authentik application/provider/group provisioned by the authentik role
  from [`headscale/authentik-blueprints/30-oidc.yaml.j2`](../headscale/authentik-blueprints/30-oidc.yaml.j2).
  Access is gated on the `headscale-access` Authentik group.
- **State:** docker volume `headscale_data` (`db.sqlite` + `noise_private.key` +
  `derp_server_private.key`). Backed up daily (03:30) via Borg.

## First deployment

1. Confirm the image tag in [`defaults/main.yml`](../ansible/roles/headscale/defaults/main.yml)
   matches a current stable release.
2. Ensure `vps_ipv4`/`vps_ipv6` exist in `sops_secrets` if you want the DERP IP
   hints and the DNS record (the `headscale` A/AAAA record uses them).
3. Create DNS: `task dns:sync` (adds the `headscale` record from
   [`headscale/dns-records.yaml`](../headscale/dns-records.yaml)).
4. `task deploy:authentik` — creates the OIDC app/provider/group.
5. `task deploy:headscale` — renders config, opens `3478/udp`, brings the
   container up, waits for `/health`.
6. `task headscale:configtest` — validate the rendered config against the binary.

The OIDC client secret lives in `sops_headscale_secrets.OIDC_CLIENT_SECRET` and is
injected at deploy time via an ephemeral `.env` as `HEADSCALE_OIDC_CLIENT_SECRET`
(headscale's viper binds it onto `oidc.client_secret`), so `config.yaml` never
holds the secret. **If OIDC login fails after deploy**, the most likely cause is
that this env-var binding didn't take — verify with `task headscale:configtest`
and the logs; the fallback is `oidc.client_secret_path`.

## Joining nodes

### OPNsense subnet router (home LAN)

```bash
task headscale:user:create NAME=home
task headscale:preauthkey:create USER=home          # one-shot, 1h expiry by default
```

On OPNsense (`os-tailscale` plugin): set login server `https://headscale.<domain>`,
paste the pre-auth key, advertise the home LAN CIDR, enable IP forwarding, and add
a firewall rule permitting tailscale→LAN. Then approve the route:

```bash
task headscale:routes                                # find the node ID + advertised CIDR
task headscale:routes:approve ID=<n> ROUTES=192.168.x.0/24
```

### Personal devices (OIDC)

Tailscale client → custom/alternate login server `https://headscale.<domain>` →
log in through Authentik (you must be in the `headscale-access` group) → enable
`--accept-routes`. iOS occasionally struggles with custom login servers; fall back
to a pre-auth key there.

## Embedded DERP

Embedded DERP is on by default (`headscale_derp_enabled: true`). The relay rides
`server_url:443` through Traefik (WebSocket); STUN is the direct `udp/3478` host
port. After nodes join, validate the relay path:

```bash
tailscale netcheck      # should list the "headscale" DERP region
tailscale status        # confirm direct/relayed connections
```

If DERP-over-Traefik misbehaves, the quick fallbacks are: add Tailscale's public
relays (`derp.urls: ["https://controlplane.tailscale.com/derpmap/default"]` in
the config template), or run a standalone DERP container on its own hostname/cert.

## Backups

Daily Borg backup at 03:30 (systemd timer), volume-copy with the container briefly
stopped for a consistent `db.sqlite` snapshot. Repo `./headscale` on the Hetzner
storage box; retention 7 daily / 4 weekly / 3 monthly.

```bash
task headscale:backup:info                 # repo info + archive list
task headscale:backup:perform              # run a backup now
task headscale:backup:restore              # interactive, triple-confirmed restore
```

Restore is authoritative (overwrites the live volume) and triple-confirmed.
Restoring an older archive also rolls the noise/DERP keys back to that point.

## Admin reference

```bash
task headscale:users
task headscale:nodes
task headscale:routes
task headscale:logs
task ssh:headscale                         # shell in the compose dir with a temp .env
```
