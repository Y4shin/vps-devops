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

- Age key: `./age.key`
- Global infra secrets: `secrets.sops.yaml`
- Authentik secrets: `authentik/.env.sops.yaml`
- Witness secrets: `reporting-tool/.env.sops.yaml`
- Deploy SSH key: `deploy_ssh_private_key.sops`
- Borg SSH key: `borg/ssh_key.sops`

Never commit decrypted material.

## Submodules

Use the helper tasks instead of manually juggling deploy keys.

After pulling changes in the superproject:

```bash
task submodule:checkout
```

If you intentionally want to bump submodules to newer upstream commits:

```bash
task submodule:update
```

The difference matters:

- `submodule:checkout` matches local worktrees to the commits already recorded in the repo
- `submodule:update` advances submodules and stages new gitlink changes

## Important File Paths

- `Taskfile.yml`
- `docs/setup-guide.md`
- `docs/backup-architecture.md`
- `scripts/local/submodule.sh`
- `scripts/backup-authentik.sh`
- `scripts/restore-authentik.sh`
- `scripts/backup-reporting-tool.sh`
- `scripts/restore-reporting-tool.sh`

