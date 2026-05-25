# Headscale — Implementation Plan (draft)

> **Status:** Planning only. Nothing here is deployed yet. This document is a design
> record so the work survives a likely repo refactor before implementation. Treat the
> file paths below as "the current per-service convention" — if the repo layout changes,
> keep the *intent* and remap paths accordingly.

## Goal

Run a self-hosted [Headscale](https://headscale.net) control server on the VPS (static
public IP) so the user can reach home services remotely. The home network is exposed by
an **OPNsense** firewall acting as a Tailscale **subnet router**; roaming devices
(phone/laptop) join the tailnet and reach home services by their LAN IPs.

Terminology: Headscale replaces only the Tailscale **control plane**. The nodes still run
the official **Tailscale clients**.

## Topology

```
                Internet
                   │  443/tcp (control, OIDC callback, DERP-over-HTTPS) ─┐
                   │  3478/udp (STUN, direct to container) ──────────────┤
                   ▼                                                      ▼
   ┌──────────────────────────────────────────┐
   │  VPS (public IP)                           │
   │   Traefik :443  ──►  headscale :8080       │   <- control + embedded DERP
   │   UFW allow 3478/udp ─► headscale :3478    │   <- STUN
   │   Authentik (OIDC IdP for personal devices)│
   └──────────────────────────────────────────┘
                   ▲                         ▲
   pre-auth key    │                         │  OIDC login (Authentik)
                   │                         │
   ┌───────────────┴───────────┐     ┌───────┴───────────────┐
   │ OPNsense (subnet router)   │     │ phone / laptop         │
   │  --advertise-routes=LAN    │     │  --accept-routes       │
   └────────────┬───────────────┘     └────────────────────────┘
                │ home LAN (e.g. 192.168.x.0/24)
        home services
```

## Confirmed design decisions

| Area | Decision | Notes |
|---|---|---|
| Home-side node | **OPNsense** subnet router (`os-tailscale` plugin) | Survives server reboots; exposes the whole LAN |
| Auth | **Hybrid**: pre-auth keys for the OPNsense router **+** Authentik OIDC for personal devices | Both run simultaneously |
| DERP relay | **Self-hosted embedded DERP** on the VPS | Needs UFW `3478/udp`; relay rides Traefik `443` |
| Admin | **CLI** via `task headscale:*` (docker exec) | No web UI |

## Feasibility summary

Feasible and a clean fit for the repo's Traefik / Ansible / SOPS / Authentik-blueprint
conventions. Risk ranking:

1. **Embedded DERP through Traefik — the one part to validate.** Control protocol (TS2021)
   and OIDC over 443 via Traefik are standard. DERP *relay* over a reverse proxy works but
   relies on DERP-over-websocket passing cleanly through Traefik — test with
   `tailscale netcheck` / `tailscale status` after deploy. STUN (UDP 3478) cannot traverse
   Traefik and must be a direct host port + UFW rule. Self-hosted DERP also means relayed
   traffic uses VPS bandwidth and is a single point of failure (vs. zero-config, globally
   distributed public DERP). Re-adding public relays as fallback is one line
   (`derp.urls`).
2. **Personal devices via OIDC + custom login server.** Android/Windows/macOS/Linux: well
   supported. **iOS** is the historically finicky one — fall back to pre-auth keys there.
3. **OPNsense subnet router.** Lowest risk; the plugin has explicit fields for login
   server, auth key, advertised routes, accept-routes. Also requires IP forwarding and a
   firewall rule permitting tailscale→LAN.
4. **Route-approval CLI drift.** Headscale changed route management across versions
   (`routes enable` → `nodes approve-routes`). Pin a version; write task commands to match.
5. **`base_domain` constraint.** Headscale rejects a `base_domain` that is a suffix of the
   `server_url` host. Use `tailnet.<domain>` while the server is `headscale.<domain>`.
6. **Repo-rule deviation.** Headscale's noise/DERP/db keys are generated on first run in
   the container volume (not SOPS), a minor departure from "no host-only long-lived
   secrets." Mitigate by adding the data volume to Borg (optional/deferred).

## Files to create

Following the existing per-service convention:

| Path | Purpose |
|---|---|
| `headscale/config.yaml.j2` | Headscale server config (see snippet below) |
| `headscale/docker-compose.yml.j2` | `headscale/headscale` container, Traefik labels, `3478/udp` publish |
| `headscale/dns-records.yaml` | `headscale` A/AAAA → `vps_ipv4`/`vps_ipv6` |
| `headscale/authentik-blueprints/10-headscale-oidc.yaml.j2` | OAuth2/OIDC provider + application + `headscale-access` group + policy binding |
| `headscale/.env.sops.yaml` | encrypted `OIDC_CLIENT_SECRET` |
| `ansible/headscale.yml` | deploy playbook (render config+compose, UFW 3478/udp, compose up, health-wait, ensure default pre-auth user) |
| `docs/headscale.md` | operator walkthrough (replaces/augments this plan once built) |

## Files to edit

- **`ansible/authentik.yml`** — load `headscale/.env.sops.yaml` (optional, like
  foundry/conference-tool); add vars `headscale_oidc_client_id: "headscale"` and
  `headscale_access_group: "headscale-access"`; assert the client secret when the file
  exists; seed `headscale-access` from existing superusers when empty (mirror the Foundry
  seeding task).
- **`ansible/site.yml`** — add `- import_playbook: headscale.yml` **after** `authentik.yml`.
- **`Taskfile.yml`** — add:
  - `deploy:headscale` (run `ansible/headscale.yml`)
  - `ssh:headscale` (cd `/opt/vps-devops/headscale`)
  - `headscale:users`, `headscale:user:create NAME=`, `headscale:preauthkey:create USER=`,
    `headscale:nodes`, `headscale:routes`, `headscale:routes:approve`, `headscale:logs`
    — all via `scripts/local/ssh-run.sh "docker exec headscale headscale …"`.
- **`CLAUDE.md`** — add headscale to Secrets, Common Tasks, and file paths.
- **`.sops.yaml`** — no change needed; `path_regex: \.sops\.yaml$` already matches
  `headscale/.env.sops.yaml`.

## Key config (verified against current `config-example.yaml`)

`headscale/config.yaml.j2` essentials:

```yaml
server_url: https://headscale.{{ secrets.domain }}
listen_addr: 0.0.0.0:8080
metrics_listen_addr: 127.0.0.1:9090
grpc_listen_addr: 127.0.0.1:50443
grpc_allow_insecure: false

noise:
  private_key_path: /var/lib/headscale/noise_private.key

prefixes:
  v4: 100.64.0.0/10
  v6: fd7a:115c:a1e0::/48

derp:
  server:
    enabled: true
    region_id: 999
    region_code: "headscale"
    region_name: "Headscale Embedded DERP"
    stun_listen_addr: "0.0.0.0:3478"
    private_key_path: /var/lib/headscale/derp_server_private.key
    automatically_add_embedded_derp_region: true
    ipv4: {{ secrets.vps_ipv4 }}
    ipv6: {{ secrets.vps_ipv6 }}
  urls: []          # fully self-hosted; add https://controlplane.tailscale.com/derpmap/default for public fallback
  paths: []
  auto_update_enabled: true
  update_frequency: 24h

database:
  type: sqlite
  sqlite:
    path: /var/lib/headscale/db.sqlite

dns:
  magic_dns: true
  base_domain: tailnet.{{ secrets.domain }}   # MUST NOT be a suffix of server_url host
  nameservers:
    global: [1.1.1.1, 1.0.0.1]

# Rendered only when headscale/.env.sops.yaml provides OIDC_CLIENT_SECRET
oidc:
  only_start_if_oidc_is_available: false      # don't block startup on a brief Authentik outage
  issuer: https://authentik.{{ secrets.domain }}/application/o/headscale/
  client_id: headscale
  client_secret: {{ headscale_secrets.OIDC_CLIENT_SECRET }}
  scope: ["openid", "profile", "email"]
  pkce:
    enabled: true
    method: S256
  # allowed_groups: ["headscale-access"]      # optional gate via Authentik group
```

Authentik blueprint mirrors `conference-tool/authentik-blueprints/30-oidc.yaml.j2`:
OAuth2/OpenID provider, `client_type: confidential`, `client_id: headscale`, redirect URI
`https://headscale.{{ secrets.domain }}/oidc/callback` (strict), scopes openid/email/profile,
`signing_key: !Find [authentik_crypto.certificatekeypair, [name, authentik Self-signed Certificate]]`,
plus a `headscale-access` group and policy binding.

## Firewall / DNS / secrets

- **UFW:** add `allow 3478/udp` (inside `ansible/headscale.yml` so the service stays
  self-contained; `base.yml` only opens 22/80/443).
- **DNS:** `headscale/dns-records.yaml` adds `headscale` A/AAAA; apply with `task dns:sync`.
- **Secrets:** `headscale/.env.sops.yaml` holds `OIDC_CLIENT_SECRET` (generate with
  `openssl rand -hex 32`, encrypt with the repo Age key). The same value must reach both
  the headscale config (via `ansible/headscale.yml`) and the Authentik blueprint (via
  `ansible/authentik.yml`).

## Operational steps (once built)

1. `task dns:sync` — create the `headscale` record.
2. `task deploy:authentik` — create the OIDC application/provider/group.
3. `task deploy:headscale` — deploy the control server (opens 3478/udp).
4. `task headscale:preauthkey:create USER=home` — generate a key for OPNsense.
5. **OPNsense:** install `os-tailscale`; set login server `https://headscale.<domain>`, the
   pre-auth key, and advertise the home LAN CIDR; enable IP forwarding; add a firewall rule
   permitting tailscale→LAN.
6. `task headscale:routes:approve` — approve the advertised subnet route.
7. **Personal devices:** Tailscale app → custom/alternate login server
   `https://headscale.<domain>` → log in via Authentik; enable accept-routes. (iOS: use a
   pre-auth key if OIDC is troublesome.)
8. Add yourself to the Authentik `headscale-access` group (or rely on superuser seeding).

## Suggested phased rollout

1. DNS + Traefik route + Headscale on **public DERP** (`derp.urls` = Tailscale default);
   verify a laptop joins via pre-auth key.
2. OPNsense subnet router + route approval; verify reaching a home service.
3. Authentik OIDC for personal devices.
4. Switch on **embedded DERP** + STUN; re-verify with `tailscale netcheck`.
5. Optional: Borg backup of the headscale data volume (db.sqlite + keys) for parity with
   other stateful services.

## Open items to resolve at build time

- Pin the `headscale/headscale` image version and confirm its route-approval CLI syntax
  (`headscale routes …` vs `headscale nodes approve-routes …`).
- Decide whether to include the optional Borg backup now or defer.
- Confirm the home LAN CIDR to advertise (needed only at the OPNsense step).
