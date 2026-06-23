# Headscale — Implementation Plan

> **Status:** Planning only. Nothing here is deployed yet. This is a design record.
> It was rewritten on **2026-06-03** to match the current **roles-based** repo layout
> (`ansible/roles/<service>/` + `ansible/site.yml` tags), replacing an earlier draft
> that targeted the old per-service-playbook convention. It is grounded in the latest
> Headscale docs (juanfont/headscale `main`, Go 1.26, ~v0.27) and the repo's real
> conventions (n8n / conference-tool roles, the Authentik blueprint discovery, SOPS
> indirection, UFW, DNS sync, Taskfile).

## Goal

Run a self-hosted [Headscale](https://headscale.net) control server on the VPS (static
public IP) so the user can reach home services remotely. The home network is exposed by
an **OPNsense** firewall acting as a Tailscale **subnet router**; roaming devices
(phone/laptop) join the tailnet and reach home services by their LAN IPs.

Terminology: Headscale replaces only the Tailscale **control plane**. Nodes still run the
official **Tailscale clients**.

## Topology

```
                Internet
                   │  443/tcp (TS2021 control + OIDC callback + DERP-over-HTTPS) ─┐
                   │  3478/udp (STUN, direct to container, NOT via Traefik) ──────┤
                   ▼                                                              ▼
   ┌────────────────────────────────────────────────────────┐
   │  VPS (public IP)                                         │
   │   Traefik :443 ──► headscale :8080  (control + DERP)     │   websocket passthrough
   │   UFW allow 3478/udp ──► headscale :3478  (STUN)         │
   │   Authentik (OIDC IdP — headscale is the OIDC *client*)  │
   └────────────────────────────────────────────────────────┘
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
| Home-side node | **OPNsense** subnet router (`os-tailscale` plugin) | Survives reboots; exposes the whole LAN |
| Auth | **Hybrid**: pre-auth key for the OPNsense router **+** Authentik OIDC for personal devices | Both run simultaneously |
| DERP relay | **Self-hosted embedded DERP** on the VPS | Needs UFW `3478/udp`; relay rides Traefik `443` |
| Admin | **CLI** via `task headscale:*` (`docker exec`) | No web UI |
| Database | **SQLite** (WAL mode) | Postgres is "highly discouraged" in current headscale |

## Critical correctness notes (read first)

1. **No Authentik forward-auth in front of Headscale.** Every other browser-facing
   service in this repo (n8n, foundry, conference-tool UI) sits behind the
   `*-authentik` forward-auth middleware. **Headscale must NOT.** Its `:8080` endpoint
   is a *machine API* spoken by Tailscale clients (TS2021/noise, plus DERP and the OIDC
   callback). A forward-auth middleware would break client registration entirely.
   Headscale is itself the **OIDC client** of Authentik — auth happens *inside*
   headscale, not at the proxy. So the Traefik router for headscale carries **no
   `middlewares=` label**.

2. **WebSocket passthrough is required** (control protocol *and* embedded DERP relay).
   Traefik forwards WebSocket upgrades transparently by default, so no special label is
   needed — but it is the one thing to validate after deploy (`tailscale netcheck`,
   `tailscale status`). Cloudflare-style proxies do **not** work (no WS POST support);
   this matters only if a CDN is ever put in front.

3. **STUN (UDP 3478) cannot traverse Traefik.** It must be a direct published host port
   on the container **plus** a UFW `allow 3478/udp` rule. Only required because we run
   embedded DERP.

4. **`base_domain` must not be a suffix of the `server_url` host.** Headscale rejects it.
   Use `server_url: https://headscale.<domain>` with `dns.base_domain: tailnet.<domain>`.

5. **Authentik "Encryption Key" must be left unset** on the OIDC provider — Headscale
   does not support JSON Web Encryption (per headscale's OIDC docs / Authentik
   integration guide). The conference-tool OAuth2 blueprint we mirror already does not
   set one, so this is automatic if we copy that pattern.

6. **OIDC `client_secret` handling.** To honour the repo's "no long-lived host-only
   secrets / temporary `.env`" rule, the secret is **not** written into the persisted
   `config.yaml`. Instead it is injected via the **ephemeral `.env`** as the env var
   `HEADSCALE_OIDC_CLIENT_SECRET` (Headscale uses viper, which binds `HEADSCALE_`-prefixed
   env vars onto nested config keys), exactly like n8n's `N8N_ENCRYPTION_KEY`. The `.env`
   is written `0600`, used by `docker compose up`, then deleted in an `always:` block.
   **Build-time check:** confirm viper env-binding actually overrides `oidc.client_secret`
   for the pinned image; if not, fall back to `oidc.client_secret_path` pointing at a file
   the compose entrypoint writes from the env var. (`config.yaml` itself stays
   secret-free and can persist on disk read-only.)

## Feasibility summary / risk ranking

1. **Embedded DERP through Traefik — the one part to validate.** Control (TS2021) and OIDC
   over 443 are standard. DERP *relay* over a reverse proxy works but relies on
   DERP-over-WebSocket passing cleanly through Traefik — test with `tailscale netcheck`.
   Self-hosted DERP also means relayed traffic uses VPS bandwidth and is a single point of
   failure (vs. zero-config, globally distributed public DERP). Re-adding public relays as
   fallback is one line (`derp.urls`).
2. **Personal devices via OIDC + custom login server.** Android/Windows/macOS/Linux: well
   supported. **iOS** is historically finicky — fall back to a pre-auth key there.
3. **OPNsense subnet router.** Lowest risk; the `os-tailscale` plugin has explicit fields
   for login server, auth key, advertised routes, accept-routes. Also needs IP forwarding
   and a firewall rule permitting tailscale→LAN.
4. **Route-approval CLI.** Current headscale uses `headscale nodes list-routes` and
   `headscale nodes approve-routes --identifier <id> --routes <cidr>` (the old
   `headscale routes enable` is gone). Pin the image; write tasks to match.
5. **Repo-rule deviation.** Headscale's noise/DERP/db keys are generated on first run into
   the data volume (not SOPS). Mitigate by optionally adding the data volume to Borg.

---

## Files to create

Layout mirrors the current roles convention (compare `ansible/roles/n8n/` +
`n8n/authentik-blueprints/` + `n8n/dns-records.yaml`).

| Path | Purpose |
|---|---|
| `ansible/roles/headscale/tasks/main.yml` | assert secrets → ensure `proxy` network → render `config.yaml` + compose → UFW `3478/udp` → temp `.env` (`HEADSCALE_OIDC_CLIENT_SECRET`) → `docker_compose_v2` up → health-wait → `always:` remove `.env` |
| `ansible/roles/headscale/templates/docker-compose.yml.j2` | `headscale/headscale` container; mounts `config.yaml` RO + `data` volume; publishes `3478/udp`; Traefik router (NO forward-auth); `proxy` + `internal` networks |
| `ansible/roles/headscale/templates/config.yaml.j2` | Headscale server config, secret-free (see snippet) |
| `ansible/roles/headscale/defaults/main.yml` | image pin, server_url, base_domain, derp/region settings, `headscale_backup_enabled: false` |
| `headscale/authentik-blueprints/30-oidc.yaml.j2` | OAuth2/OIDC provider + application + `headscale-access` group + access policy binding (mirror `conference-tool/.../30-oidc.yaml.j2`) |
| `headscale/dns-records.yaml` | `headscale` A/AAAA → `vps_ipv4`/`vps_ipv6` (copy `n8n/dns-records.yaml`) |
| `docs/headscale.md` | operator walkthrough (supersedes this plan once built) |

> No `headscale/.env.sops.yaml`: the OIDC client secret lives in the consolidated SOPS
> file (`sops_headscale_secrets`), consistent with the post-modernization "single SOPS
> source" model — not a per-service `.env.sops.yaml`.

## Files to edit

- **`ansible/site.yml`** — add a play after Authentik (headscale's OIDC app must exist
  first):
  ```yaml
  - name: Headscale control server
    hosts: vps
    tags: headscale
    roles:
      - headscale
  ```
- **`ansible/inventories/prod/group_vars/all.yml`** — add the indirection alias:
  ```yaml
  headscale_secrets: "{{ sops_headscale_secrets }}"
  headscale_enabled: true
  ```
- **`ansible/inventories/prod/group_vars/all.sops.yaml`** — add (edit via
  `sops ...all.sops.yaml`):
  ```yaml
  sops_headscale_secrets:
      OIDC_CLIENT_SECRET: "<openssl rand -hex 32>"
      # later, only if Borg backup is enabled:
      # borg_path: "<repo path on the Hetzner box>"
      # borg_passphrase: "<...>"
  ```
- **`ansible/roles/authentik/defaults/main.yml`** — add the OIDC identity vars (alongside
  the existing `conference_tool_*` / `n8n_*` entries):
  ```yaml
  headscale_oidc_client_id: "headscale"
  headscale_application_slug: "headscale"
  headscale_access_group: "headscale-access"
  ```
- **`ansible/roles/authentik/tasks/main.yml`** — add an assert mirroring the
  conference-tool one, so blueprint rendering fails fast if the secret is missing:
  ```yaml
  - name: Require headscale OIDC client secret for Authentik blueprint rendering
    ansible.builtin.assert:
      that:
        - headscale_secrets.OIDC_CLIENT_SECRET is defined
        - (headscale_secrets.OIDC_CLIENT_SECRET | trim) != ""
      fail_msg: >-
        group_vars/all.sops.yaml (sops_headscale_secrets) must define OIDC_CLIENT_SECRET
        so Authentik can render the headscale OIDC application.
    when: headscale_enabled | default(true)
    no_log: true
  ```
  (The blueprint file is picked up automatically — the role's "Discover Authentik
  blueprint files" `find` matches any `*/authentik-blueprints/*.yaml*`.)
- **`Taskfile.yml`** — add (mirror the `deploy:n8n` / `ssh:*` style; admin tasks go
  through `scripts/local/ssh-run.sh "docker exec ..."`):
  - `deploy:headscale` → `bash ./scripts/local/run-playbook.sh ansible/site.yml --tags headscale`
  - `ssh:headscale` → `bash ./scripts/local/ssh-shell.sh /opt/vps-devops/headscale "" <env-builder?>`
    (no env-builder needed if no persistent `.env`; can use a plain shell)
  - `headscale:users` → `ssh-run.sh "docker exec headscale-headscale-1 headscale users list"`
  - `headscale:user:create NAME=` → `... headscale users create {{.NAME}}`
  - `headscale:preauthkey:create USER=` → `... headscale preauthkeys create --user {{.USER}} --expiration 1h`
  - `headscale:nodes` → `... headscale nodes list`
  - `headscale:routes` → `... headscale nodes list-routes`
  - `headscale:routes:approve ID= ROUTES=` → `... headscale nodes approve-routes --identifier {{.ID}} --routes {{.ROUTES}}`
  - `headscale:logs` → `ssh-run.sh "docker logs --tail 100 -f headscale-headscale-1"`
  > Container name is `headscale-headscale-1` (compose project = dir `headscale`, service
  > `headscale`), matching the `n8n-n8n-1` precedent.
- **`CLAUDE.md`** — add headscale to Secrets (`sops_headscale_secrets`), Common Tasks, and
  Important File Paths.

## `config.yaml.j2` essentials (secret-free; verify keys against the pinned image)

```yaml
server_url: https://headscale.{{ secrets.domain }}
listen_addr: 0.0.0.0:8080
metrics_listen_addr: 127.0.0.1:9090
grpc_listen_addr: 127.0.0.1:50443       # localhost only; we admin via docker exec
grpc_allow_insecure: false

# Traefik terminates TLS; headscale speaks plain HTTP behind it.
# (leave tls_cert_path / tls_key_path empty)
trusted_proxies:
  - {{ secrets.proxy_subnet }}          # honour X-Forwarded-For from Traefik only

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
    ipv4: {{ secrets.vps_ipv4 }}        # confirm exact var name (dns-records uses vps_ipv4)
    ipv6: {{ secrets.vps_ipv6 }}
  urls: []        # fully self-hosted; add controlplane.tailscale.com/derpmap/default for public fallback
  paths: []
  auto_update_enabled: true
  update_frequency: 24h

database:
  type: sqlite
  sqlite:
    path: /var/lib/headscale/db.sqlite
    write_ahead_log: true

dns:
  magic_dns: true
  base_domain: tailnet.{{ secrets.domain }}   # MUST NOT be a suffix of the server_url host
  nameservers:
    global: [1.1.1.1, 1.0.0.1]

oidc:
  only_start_if_oidc_is_available: false        # don't block startup on a brief Authentik outage
  issuer: https://authentik.{{ secrets.domain }}/application/o/{{ headscale_application_slug }}/
  client_id: {{ headscale_oidc_client_id }}
  # client_secret comes from the ephemeral .env as HEADSCALE_OIDC_CLIENT_SECRET (viper env binding)
  scope: ["openid", "profile", "email"]
  pkce:
    enabled: true
    method: S256
  # allowed_groups: ["{{ headscale_access_group }}"]   # optional hard gate on the Authentik group
```

## `docker-compose.yml.j2` shape (mirror `roles/n8n/templates`, minus forward-auth)

```yaml
services:
  headscale:
    image: {{ headscale_image }}          # pinned tag, e.g. headscale/headscale:0.27.x
    restart: unless-stopped
    command: serve
    env_file: .env                        # provides HEADSCALE_OIDC_CLIENT_SECRET
    dns:
      - {{ secrets.proxy_dns_ip }}        # resolve the Authentik issuer via CoreDNS, house style
    ports:
      - "0.0.0.0:3478:3478/udp"           # STUN — public (UFW-gated), cannot go via Traefik
    networks:
      - proxy
      - internal
    volumes:
      - ./config.yaml:/etc/headscale/config.yaml:ro
      - data:/var/lib/headscale
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://localhost:8080/health || exit 1"]   # confirm path at build
      start_period: 10s
      interval: 30s
      timeout: 5s
      retries: 5
    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=proxy"
      - "traefik.http.routers.headscale.rule=Host(`headscale.{{ secrets.domain }}`)"
      - "traefik.http.routers.headscale.entrypoints=websecure"
      - "traefik.http.routers.headscale.tls.certresolver=letsencrypt"
      - "traefik.http.services.headscale.loadbalancer.server.port=8080"
      # NO middlewares= label — this is a machine API, not a browser app.

networks:
  proxy:
    external: true
    name: proxy
  internal: {}

volumes:
  data:
```

> Health-wait in `tasks/main.yml`: mirror n8n's `ansible.builtin.uri` poll against
> `http://127.0.0.1:8080/health` (confirm the exact endpoint; alternative is
> `docker exec headscale-headscale-1 headscale health`). 9090 stays localhost-only — no
> need to publish it.

## Authentik blueprint (`headscale/authentik-blueprints/30-oidc.yaml.j2`)

Copy `conference-tool/authentik-blueprints/30-oidc.yaml.j2` and adapt:

- `oauth2provider`: `client_type: confidential`,
  `client_id: {{ headscale_oidc_client_id | to_json }}`,
  `client_secret: {{ headscale_secrets.OIDC_CLIENT_SECRET | to_json }}`,
  `redirect_uris: [{ url: https://headscale.{{ secrets.domain }}/oidc/callback, matching_mode: strict }]`,
  property mappings openid/email/profile,
  `signing_key: !Find [authentik_crypto.certificatekeypair, [name, authentik Self-signed Certificate]]`.
  **Do not set an Encryption Key.**
- a `headscale-access` group, an expression policy "headscale requires
  {{ headscale_access_group }}", an application (`slug: {{ headscale_application_slug }}`),
  and a policy binding — same shape as the conference-tool / n8n blueprints. Seed the
  group with `akadmin` (as n8n's `10-access.yaml.j2` does) so you're not locked out.

## Firewall / DNS / secrets

- **UFW:** add a task in `roles/headscale/tasks/main.yml` (base only opens 22/80/443):
  ```yaml
  - name: Allow Headscale STUN (UDP 3478)
    community.general.ufw:
      rule: allow
      port: "3478"
      proto: udp
      comment: "Headscale embedded DERP STUN"
  ```
- **DNS:** `headscale/dns-records.yaml` adds `headscale` A/AAAA; apply with `task dns:sync`.
- **Secrets:** `OIDC_CLIENT_SECRET` (`openssl rand -hex 32`) in `sops_headscale_secrets`.
  The same value reaches headscale (ephemeral `.env`) and the Authentik blueprint
  (rendered by the authentik role) — both read `headscale_secrets.OIDC_CLIENT_SECRET`.

## Operational steps (once built)

1. `sops ansible/inventories/prod/group_vars/all.sops.yaml` — add `sops_headscale_secrets.OIDC_CLIENT_SECRET`.
2. `task dns:sync` — create the `headscale` record.
3. `task deploy:authentik` — create the OIDC application/provider/group.
4. `task deploy:headscale` — deploy the control server (renders config, opens 3478/udp).
5. `task headscale:user:create NAME=home` then
   `task headscale:preauthkey:create USER=home` — key for OPNsense.
6. **OPNsense:** install `os-tailscale`; set login server `https://headscale.<domain>`,
   the pre-auth key, advertise the home LAN CIDR; enable IP forwarding; add a firewall
   rule permitting tailscale→LAN.
7. `task headscale:routes` then `task headscale:routes:approve ID=<n> ROUTES=<cidr>`.
8. **Personal devices:** Tailscale → custom login server `https://headscale.<domain>` →
   Authentik login; enable `--accept-routes`. (iOS: pre-auth key if OIDC is troublesome.)
9. Add yourself to the Authentik `headscale-access` group.

## Suggested phased rollout

1. DNS + Traefik route + Headscale on **public DERP** (`derp.urls` = Tailscale default,
   `derp.server.enabled: false`); verify a laptop joins via pre-auth key.
2. OPNsense subnet router + route approval; verify reaching a home service.
3. Authentik OIDC for personal devices.
4. Switch on **embedded DERP** + STUN (UFW 3478/udp); re-verify with `tailscale netcheck`.
5. Optional: Borg backup of the headscale data volume (`db.sqlite` + keys) via the shared
   `borg_target` + `backup_unit` roles, gated on `headscale_backup_enabled` — parity with
   the witness/foundry/conference-tool backup pattern.

## Open items to resolve at build time

- **Pin the image tag** (`headscale_image`) and confirm against it: viper env-binding for
  `HEADSCALE_OIDC_CLIENT_SECRET`, the `/health` endpoint path, and the route-approval CLI
  (`nodes approve-routes`).
- **Home LAN CIDR** to advertise (needed at the OPNsense step).
- **Borg backup now or defer?** (decides whether `sops_headscale_secrets` also needs
  `borg_path`/`borg_passphrase` and whether to wire `borg_target`/`backup_unit`).
- **`ssh:headscale`**: a plain interactive shell is enough (no persistent `.env` to
  rebuild), so it likely doesn't need an entry under `scripts/local/env-builders/`.
```
