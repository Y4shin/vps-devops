# CLAUDE.md

This file provides guidance to Claude Code when working in this repository.

## Project Overview

This repository manages VPS infrastructure and application deployments using:

- Ansible playbooks
- Taskfile automation
- SOPS-encrypted secrets
- SSH-based helper scripts
- Service directories for Traefik, Authentik, and Witness

Treat this repo as an infrastructure and operations repo, not just an app repo.
Operational safety matters.

## Recommended Starting Points

Read these before making non-trivial changes:

- `docs/setup-guide.md`
- `docs/backup-architecture.md`
- `Taskfile.yml`

For service-specific work, also read:

- `ansible/authentik.yml`
- `ansible/witness.yml`
- `ansible/traefik.yml`

## Working Rules

- Prefer `task` commands over ad hoc command sequences.
- Keep SOPS-managed local secrets as the source of truth.
- Avoid introducing long-lived secrets that are generated only on the host.
- Preserve the temporary `.env` deployment model used for Authentik and Witness.
- Keep destructive restore operations guarded by explicit confirmation.
- Update docs when changing workflows, backup behavior, or secret requirements.

## Common Tasks

### Deployment

```bash
task deploy
task deploy:base
task deploy:traefik
task deploy:authentik
task deploy:witness
```

### Backup Operations

```bash
task witness:backup:perform
task witness:backup:info
task witness:backup:restore

task authentik:backup:perform
task authentik:backup:info
task authentik:backup:restore
```

### SSH Helpers

```bash
task ssh
task ssh:authentik
task ssh:witness
task ssh:scripts
```

## Secrets

All app/infra secrets are consolidated in one SOPS file, auto-decrypted by the
`community.sops` Ansible vars plugin (at inventory stage) and read by the local
helper scripts:

- Age key: `./age.key`
- All secrets: `ansible/inventories/prod/group_vars/all.sops.yaml` — namespaced
  top-level dicts: `sops_secrets` (global infra), `sops_authentik_secrets`,
  `sops_reporting_tool_secrets` (Witness), `sops_foundry_secrets`,
  `sops_conference_tool_secrets`, `sops_n8n_secrets`, `sops_mail_secrets`,
  `sops_connection` (`ansible_host`, `ansible_become_password`).
- Plaintext indirection (logical names → `sops_*` sources):
  `ansible/inventories/prod/group_vars/all.yml`.
- Deploy SSH key: `deploy_ssh_private_key.sops`
- Borg SSH key: `borg/ssh_key.sops`
- DNS backups: `dns-backups.sops.yaml`

Edit with `sops ansible/inventories/prod/group_vars/all.sops.yaml`.
Never commit decrypted material.

> Note: `traefik/.env.sops.yaml` is a deprecated leftover (old basic-auth
> dashboard creds, now behind Authentik forward-auth); not used by any code.

## Important File Paths

- `Taskfile.yml`
- `docs/setup-guide.md`
- `docs/backup-architecture.md`
- `scripts/backup-authentik.sh`
- `scripts/restore-authentik.sh`
- `scripts/backup-reporting-tool.sh`
- `scripts/restore-reporting-tool.sh`

