# AGENTS.md

Guidance for coding agents working in this repository.

## Repo Overview

This repo manages VPS infrastructure and deployments with:

- Ansible playbooks in `ansible/`
- Taskfile automation in `Taskfile.yml`
- SOPS-encrypted secrets (`*.sops.yaml`, `*.sops`)
- Deploy and operator helper scripts in `scripts/`
- Service-specific config in `traefik/`, `authentik/`, and `reporting-tool/`

The main deployed services are:

- Traefik
- Authentik
- Witness (`reporting-tool`)

## Preferred Workflow

- Prefer `task` commands over invoking lower-level commands directly.
- Read `docs/setup-guide.md` for environment and control-node expectations.
- Read `docs/backup-architecture.md` before changing backup or restore flows.
- When changing Ansible playbooks, keep local secrets as the source of truth and avoid introducing host-generated long-lived secrets.

## Secrets And Access

- Secrets are decrypted locally with `SOPS_AGE_KEY_FILE=./age.key`.
- Do not commit plaintext secrets, temporary keys, or decrypted env files.
- The deploy SSH key is stored in `deploy_ssh_private_key.sops`.
- Borg SSH access uses `borg/ssh_key.sops`.

## Common Commands

### Deploy

```bash
task deploy
task deploy:base
task deploy:traefik
task deploy:authentik
task deploy:witness
```

### SSH / Operator Shells

```bash
task ssh
task ssh:authentik
task ssh:witness
task ssh:scripts
```

### Backups

```bash
task witness:backup:perform
task witness:backup:info
task witness:backup:restore

task authentik:backup:perform
task authentik:backup:info
task authentik:backup:restore
```

## Submodules

This repo uses deploy-key-backed submodule helpers.

After a normal `git pull`, use:

```bash
task submodule:checkout
```

That makes local submodule worktrees match the commits recorded by the
superproject.

If you intentionally want to advance submodules to newer upstream commits, use:

```bash
task submodule:update
```

That pulls inside the submodule and stages the new gitlink in the superproject.

## Editing Guidance

- Prefer updating docs when workflow changes.
- Keep backup and restore scripts conservative and explicit.
- Preserve the temporary `.env` deployment pattern for Authentik and Witness.
- Do not remove interactive safeguards from destructive restore flows unless the user explicitly asks.
- Prefer non-destructive git operations unless the user explicitly requests otherwise.

## Important Files

- `Taskfile.yml`
- `docs/setup-guide.md`
- `docs/backup-architecture.md`
- `ansible/base.yml`
- `ansible/traefik.yml`
- `ansible/authentik.yml`
- `ansible/witness.yml`
- `scripts/local/submodule.sh`

