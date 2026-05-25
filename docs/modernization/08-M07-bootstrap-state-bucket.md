# M07 — Bootstrap the state bucket

**Branch:** B · **Touches live infra:** yes (creates one new bucket only)

## Goal

Solve the chicken-and-egg: the S3 backend needs a bucket before it can store
state. Create that bucket with a minimal bootstrap env that keeps its own state
local (encrypted, committed).

## Prerequisites

- M06 complete. `HCLOUD_TOKEN` + S3 credentials available via
  `tf-load-secrets.sh`.

## Implementation

1. **`environments/bootstrap/`** defines one `minio_s3_bucket` (e.g.
   `vps-devops-tfstate`) with versioning enabled, using **local** state
   (encrypted via the native `encryption {}` block, committed to git — it holds
   only bucket metadata, no real secrets). Model on pdl-hannover's
   `terraform/environments/bootstrap/main.tf`.

2. **Apply:**
   ```bash
   source scripts/tf-load-secrets.sh bootstrap
   tofu -chdir=terraform/environments/bootstrap init
   tofu -chdir=terraform/environments/bootstrap plan     # 1 bucket to add
   tofu -chdir=terraform/environments/bootstrap apply
   ```

3. **Point `prod` and `staging` at the bucket** — set their `backend "s3"`
   blocks to the new bucket with distinct keys:
   - prod: `key = "prod/terraform.tfstate"`
   - staging: `key = "staging/terraform.tfstate"`
   Use Hetzner's S3 endpoint + the `use_path_style`/`skip_*` flags from
   pdl-hannover's `backend.tf`.

> **Shortcut:** if you'd rather skip a bootstrap env, create the bucket once by
> hand in the Console and go straight to the S3 backend. The bootstrap env is the
> clean, reproducible version.

## Verification gate

- Bucket exists (`hcloud` / Console / `mc ls`), versioning enabled.
- `tofu -chdir=terraform/environments/prod init` succeeds against the S3 backend.

## Rollback

Delete the bucket (and its versioned objects) via Console/`mc`; remove the
bootstrap env. No other infra affected.

## Definition of done

- `vps-devops-tfstate` bucket exists with versioning.
- `prod` and `staging` backends initialize against it.
