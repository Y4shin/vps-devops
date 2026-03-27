# Backup Architecture

This document describes the backup and restore architecture currently implemented
in this repo, with an emphasis on the `reporting-tool` ("Witness") deployment.

## Scope

Today, the repo contains real backup/restore workflows for Witness and
Authentik.

Covered:

- Witness SQLite database
- Witness S3-compatible object bucket
- Authentik PostgreSQL database dump
- Authentik bind-mounted persistent directories
- Backup metadata needed to identify what was captured

Not covered by an automated backup flow in this repo:

- Traefik runtime state such as ACME certificate storage
- Docker images and build cache
- The VPS itself as a machine image or block snapshot

## Goals

The current design optimizes for:

- Recovering Witness application data after a bad deploy or host loss
- Keeping backups encrypted at rest via Borg
- Keeping operator workflows simple and mostly scriptable
- Avoiding overlapping backup/restore runs

It does not currently optimize for:

- Point-in-time recovery
- Zero-downtime backup snapshots
- Whole-stack disaster recovery from one command

## Data Inventory

### Witness

Primary data:

- SQLite database in Docker volume `reporting-tool_db_data`
- Encrypted file objects in an S3-compatible bucket

Runtime/config data:

- App source synced to `/opt/vps-devops/reporting-tool/app`
- Generated compose file and temporary `.env`
- Last deployed commit marker `.last-deployed-commit`

Important note:

- The app supports a local filesystem fallback under `./uploads/` when `S3_*`
  variables are absent.
- The deployed Witness environment currently sets `S3_ENDPOINT`, `S3_BUCKET`,
  `S3_ACCESS_KEY_ID`, and `S3_SECRET_ACCESS_KEY`, so production is intended to
  use object storage rather than the local `uploads` volume.
- If those S3 variables are ever removed, the current backup script would no
  longer cover uploaded files stored locally.

### Traefik

Primary data:

- Repo-managed configuration templates
- Repo-managed encrypted dashboard credentials
- Docker named volume `letsencrypt` for ACME state

Operationally, most Traefik configuration is reconstructable from Git + SOPS.
The only runtime state that is worth backing up is the ACME certificate store.

### Authentik

Primary data:

- `/opt/vps-devops/authentik/data/postgresql`
- `/opt/vps-devops/authentik/data/media`
- `/opt/vps-devops/authentik/data/certs`
- `/opt/vps-devops/authentik/data/custom-templates`

Important note:

- `PG_PASS` and `AUTHENTIK_SECRET_KEY` are expected to live in
  `authentik/.env.sops.yaml`.
- Authentik's backup repo settings (`borg_path` and `borg_passphrase`) also
  live in `authentik/.env.sops.yaml`.
- The host-side `.env` is treated as ephemeral deploy-time material and can be
  reconstructed from repo-managed secrets.

The repo provides Authentik backup and restore scripts that create a logical
PostgreSQL dump and archive the bind-mounted data tree with Borg.

## Current Backup Flow

### 1. Provisioning and prerequisites

The base host playbook installs the backup/runtime dependencies on the VPS:

- `borgbackup`
- `jq`
- `whiptail`
- AWS CLI
- Docker

The Witness playbook then:

- decrypts the Borg SSH key locally and deploys it to the server
- writes a Borg environment file containing repo URL and passphrase
- initializes the remote Borg repo if it does not exist
- writes a backup environment file with the DB volume name, staging path, and
  S3 credentials

The Authentik playbook follows the same pattern, but points at a separate Borg
repository path on the same Hetzner storage box.

### 2. When backups run

Backups run in two ways:

- Automatically before a Witness deploy when the app source commit changed and
  there was a previous deployment
- Manually via `task witness:backup:perform`

Backups are also scheduled by Ansible-managed systemd timers:

- Authentik daily at `04:00`
- Witness (`reporting-tool`) daily at `04:30`

The backup scripts also take a shared cross-service lock under
`/opt/vps-devops/backups`, so the two scheduled jobs cannot run at the same
time even if one backup overruns its normal window.

### 3. What the backup script does

The Witness backup script performs a staged full backup:

1. Acquire an exclusive lock with `flock`
2. Check that the SQLite database exists
3. Prepare a local staging directory on the VPS
4. Stop the Witness container if it is running
5. Copy `app.db` from the Docker volume into staging
6. Mirror the full S3 bucket into staging with `aws s3 sync`
7. Write a manifest containing timestamp, host, bucket, DB volume, container,
   and deployed commit
8. Restart the app container before archival work
9. Create a Borg archive from the staged data
10. Prune old archives with this retention policy:
    - daily: 7
    - weekly: 4
    - monthly: 3

The resulting Borg archive contains:

- `db/app.db`
- `bucket/...`
- `manifest.json`

### 4. Storage layout

On the VPS:

- Staging directory: `/opt/vps-devops/backups/reporting-tool-staging`
- Backup scripts: `/opt/vps-devops/scripts`
- Witness deployment: `/opt/vps-devops/reporting-tool`

Remote backup target:

- Witness Borg repository over SSH using `borg_user` and `borg_host` from
  `secrets.sops.yaml` plus `borg_path` from `reporting-tool/.env.sops.yaml`
- Authentik Borg repository over SSH using `borg_user` and `borg_host` from
  `secrets.sops.yaml` plus `borg_path` from `authentik/.env.sops.yaml`

## Current Restore Flow

Restores are intentionally interactive and conservative.

The Witness restore script:

1. Acquires the same lock used by backups
2. Lets the operator select a Borg archive, or accepts one explicitly
3. Extracts the archive into the local staging directory
4. Verifies that `db/app.db` exists in the archive
5. Requires triple confirmation before an authoritative bucket restore
6. Stops the Witness container
7. Restores `app.db` into the Docker volume
8. Syncs the archived bucket contents back to object storage with `--delete`
9. Starts the Witness container again

The bucket restore is authoritative. Remote objects not present in the chosen
archive are deleted.

## Coverage Summary

### Backed up today

- Witness SQLite DB
- Witness object storage bucket
- Authentik PostgreSQL dump
- Authentik media, certs, and custom templates
- Witness backup metadata
- Authentik backup metadata
- Repo-managed config and secrets, via Git + SOPS rather than Borg

### Not backed up today

- Traefik `letsencrypt` volume
- Any local Witness `uploads/` data if S3 is disabled in production
- Host-level OS state

## Operational Commands

Useful task entry points:

- `task deploy:witness`
- `task witness:backup:perform`
- `task witness:backup:restore`
- `task witness:backup:info`
- `task ssh:reporting-tool-backup`
- `task deploy:authentik`
- `task authentik:backup:perform`
- `task authentik:backup:restore`
- `task authentik:backup:info`
- `task ssh:authentik-backup`

## Risks and Gaps

Current gaps worth tracking:

- Traefik ACME state is not backed up, so certificate re-issuance may be needed
  after host loss.
- The Witness backup is not point-in-time across SQLite and object storage; it
  is a staged snapshot assembled by script.
- The Authentik backup uses a logical PostgreSQL dump plus filesystem copies, so
  DB and file data are captured very close together but not as one atomic
  snapshot.
- The app is briefly stopped during DB copy, so backups trade availability for
  a cleaner SQLite snapshot.
- Authentik server and worker are briefly stopped during backup so the bound
  directories can be archived consistently.

## Recommended Next Steps

Reasonable next improvements, in priority order:

1. Add a small Traefik backup for the `letsencrypt` volume.
2. Decide whether local `uploads/` should be removed from the Witness compose
   file or explicitly backed up as a safety net.

## Authentik Backup Design

### What to capture

- A logical PostgreSQL dump from the `postgresql` container
- `/opt/vps-devops/authentik/data/media`
- `/opt/vps-devops/authentik/data/certs`
- `/opt/vps-devops/authentik/data/custom-templates`
- A manifest with timestamp, host, Authentik version, and deployed config info

### Preferred backup method

The implemented script:

1. Acquires a lock
2. Stops the Authentik `server` and `worker` containers
3. Runs `pg_dump -Fc` inside the `postgresql` container
4. Writes the dump and a manifest into `data/.backup-tmp`
5. Creates a Borg archive directly from the live data tree without staging the
   media/certs/templates elsewhere
6. Prunes only `authentik-*` archives
7. Removes temporary dump/manifest files and restarts the stopped containers

### Why `pg_dump` instead of copying the Postgres volume

- It is more portable across container/image changes
- It avoids relying on raw on-disk PostgreSQL files being copied in a fully
  consistent state
- It makes restore logic more explicit and testable

### Restore shape

A matching restore script would ideally:

1. Stop the Authentik `server` and `worker` containers
2. Extract the chosen Borg archive
3. Restore `data/media`, `data/certs`, and `data/custom-templates`
4. Reset the PostgreSQL database and restore the dump
5. Start the Authentik application containers again

## Source of Truth

For current behavior, prefer these files over older prose docs:

- `ansible/witness.yml`
- `scripts/backup-reporting-tool.sh`
- `scripts/restore-reporting-tool.sh`
- `ansible/authentik.yml`
- `ansible/traefik.yml`
- `ansible/base.yml`
