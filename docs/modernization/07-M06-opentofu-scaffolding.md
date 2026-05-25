# M06 — OpenTofu scaffolding

**Branch:** B (`feat/opentofu`, cut from updated `main`) · **Touches live infra:** no (`validate` only)

## Goal

Author the OpenTofu structure (providers, topology, modules, state encryption,
secret loading) scaled to the vps-devops footprint. Nothing is applied here.

## Prerequisites

- M05 merged to `main`. Branch from it:
  ```bash
  git checkout main && git pull && git checkout -b feat/opentofu
  ```
- M01 baseline facts (server ID, storage box ID, bucket name, IPs) on hand. If
  not captured, re-run the M01 `hcloud …` commands now — they're needed for M09.

## Implementation

1. **Layout:**
   ```
   terraform/
     topology.yaml                # source of truth: domain, subdomains, server spec, buckets
     modules/
       deploy_config/             # pure-compute: topology.yaml → FQDNs, records, bucket names
       server/                    # reusable hcloud_server + inventory output
     environments/
       bootstrap/                 # creates the tfstate bucket; local encrypted state (M07)
       prod/                      # IMPORTS the existing VPS (M09)
       staging/                   # creates a throwaway VPS from scratch (M08)
   scripts/tf-load-secrets.sh     # sops → env vars
   ```

2. **Providers (`versions.tf`)** — the modern pdl-hannover stack:
   - `hetznercloud/hcloud ~> 1.62` — server, SSH key, **native DNS**
     (`hcloud_zone`/`hcloud_zone_rrset`), and **storage box**
     (`hcloud_storage_box`), all via one provider + one `HCLOUD_TOKEN`.
   - `aminueza/minio ~> 3.0` — Hetzner Object Storage buckets (no native API).
   - `tls`, `random`, `local` for keygen / inventory files.

3. **`topology.yaml`** — encode the real layout: `domain`, the seven subdomains
   (traefik/authentik/witness/foundry/conference/n8n/mail), the existing
   server's `type`/`location`, and the app bucket name.

4. **`modules/deploy_config/`** — pure computation (no resources): parse
   `topology.yaml` → FQDNs, DNS record maps, prefixed bucket names. Model it on
   pdl-hannover's `terraform/modules/deploy_config/main.tf`.

5. **TF secrets** — `terraform/environments/<env>/secrets.sops.yaml` holding:
   ```yaml
   state_encryption_passphrase: <openssl rand -base64 32>
   s3:
     access_key_id:     <Hetzner Console → Security → S3 Credentials>
     secret_access_key: <...>
   ```
   `HCLOUD_TOKEN` goes in a gitignored `.env` (Console → Security → API tokens,
   Read & Write). Add these paths to `.sops.yaml` creation rules.

6. **State encryption** — copy pdl-hannover's OpenTofu-native `encryption {}`
   block (pbkdf2 + aes_gcm, `enforced = true`) into each env.

7. **`scripts/tf-load-secrets.sh`** — port it: decrypt the env's
   `secrets.sops.yaml` and export `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`,
   `TF_VAR_s3_*`, and build `TF_ENCRYPTION` JSON. Validate `HCLOUD_TOKEN` is set.

## Verification gate

```bash
source scripts/tf-load-secrets.sh prod
tofu -chdir=terraform/environments/prod validate     # (init may need the backend from M07)
tofu fmt -recursive -check terraform/
```
- `validate`/`fmt` pass.
- `tf-load-secrets.sh` exports the expected env vars (spot-check with `env | grep TF_`).

## Rollback

Repo-only; revert the commit.

## Definition of done

- `terraform/` scaffolding authored; providers pinned.
- `topology.yaml` reflects real layout; `deploy_config` computes FQDNs/buckets.
- TF secret files + state encryption + `tf-load-secrets.sh` in place.
- `tofu validate`/`fmt` clean.
