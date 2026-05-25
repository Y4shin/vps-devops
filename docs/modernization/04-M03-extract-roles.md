# M03 — Extract roles

**Branch:** A · **Touches live infra:** no (repo only)

## Goal

Collapse the 11 flat playbooks into reusable roles. The exploration found these
patterns repeated across authentik/witness/foundry/conference-tool/n8n/mail:
secret validation, Borg key deploy, Borg env-file write, backup script + systemd
timer, docker network creation, the temp-`.env` `block/always`, and
`docker_compose_v2` deploy.

## Prerequisites

- M02 complete (logical var names available to roles).

## Implementation

1. **Shared helper roles** (the duplication):
   - `roles/borg_target/` — deploy the Borg SSH key from `borg/ssh_key.sops`,
     write `<svc>-borg-env`, init the repo if absent. Vars: `svc`, `borg_path`,
     `borg_passphrase`.
   - `roles/backup_unit/` — render `backup-<svc>.sh` + `.service` + `.timer`,
     enable the timer. Vars: `svc`, `schedule` (e.g. `*-*-* 04:00:00`).
   - `roles/docker_service/` — create network(s), render
     `docker-compose.yml.j2`, write the temp `.env` in a `block/always`, run
     `community.docker.docker_compose_v2`. Vars: `project`, `compose_template`,
     `env_content`.

2. **Per-service roles** (`base`, `traefik`, `authentik`, `witness`, `foundry`,
   `conference_tool`, `n8n`, `mail`) holding service-specific config and
   `include_role`-ing the helpers. Move each service's
   `docker-compose.yml.j2`, blueprints, and `dns-records.yaml` into its role's
   `templates/`/`files/`.

3. **Rewrite `ansible/site.yml`** as a thin orchestrator importing roles in
   today's dependency order: base → traefik → mail → authentik → n8n → witness →
   conference_tool → foundry. Preserve the existing `task deploy` chain.

4. **Add `ansible/requirements.yml`** pinning the collections currently
   installed via the bash string in `Taskfile.yml:143`:
   ```yaml
   collections:
     - name: community.sops
       version: ">=1.6.0"
     - name: community.docker
       version: ">=3.10.0"
     - name: community.general
       version: ">=8.0.0"
     - name: ansible.posix
       version: ">=1.5.0"
   ```

   **Harden the Nix runtime (in lieu of an Execution Environment).** Change
   `flake.nix`'s `shellHook` to install from this file *without* `--upgrade`:
   `ansible-galaxy collection install -r ansible/requirements.yml
   --collections-path ./collections`. This pins collection versions instead of
   floating to latest. We are deliberately NOT adopting containerized EEs
   (ansible-builder/ansible-navigator) — the Nix devshell is the reproducible
   runtime. See README "Decisions locked in".

5. **Config-parity gate (set up here, enforced in M05).** For each service, make
   it possible to render the compose/`.env` both the old way and the new role way
   against the same prod vars, so M05 can `diff` them. The roles must produce
   byte-identical output (or only-intended differences) — this is what makes
   deploying straight to prod in M05 safe.

## Verification gate

```bash
ansible-galaxy install -r ansible/requirements.yml
ansible-lint ansible/site.yml          # syntax/structure sane (full lint config in M04)
ansible-playbook -i ansible/inventories/prod ansible/site.yml --syntax-check
```
- `site.yml` and all roles parse.
- A render-diff of at least one service (old vs. new) is byte-identical.

## Rollback

Revert the commit; the flat playbooks return. (Keep them in git history until
M05 merge.)

## Definition of done

- Helper roles + per-service roles exist; `site.yml` imports them.
- `requirements.yml` pins collections.
- Render-diff harness ready for M05.

## Implementation notes (as built, 2026-05-25)

- **Collections pinned exactly** in `ansible/requirements.yml` (sops 2.3.0,
  docker 5.2.0, general 13.0.0, posix 2.2.0). `flake.nix` shellHook + the
  `setup:debian:trixie` task install from it without `--upgrade`.
- **Two shared helper roles only:** `borg_target` (Borg key + `<svc>-borg-env` +
  repo init) and `backup_unit` (shared backups dir/lock + optional staging +
  `<svc>-backup-env` + backup/restore scripts + systemd service/timer).
  **No monolithic `docker_service` role** — the 3 recreate strategies (always /
  conditional / digest) + in-block provisioning for mail & authentik made it
  net-negative; each service role keeps its own compose/temp-env/hash logic.
- **All 8 services are roles** (`base`, `traefik`, `mail`, `authentik`, `n8n`,
  `witness`, `conference-tool`, `foundry`) under `ansible/roles/`. Each
  `ansible/<svc>.yml` is now a 5-line `roles: [<svc>]` wrapper, so
  `task deploy:<svc>` and `site.yml` (which imports the wrappers) keep working
  unchanged. `base.yml` keeps play-level `become: true`.
- **Templates `git mv`d** into `roles/<svc>/templates/` (byte-identical renames);
  `n8n/workflow.json` → `roles/n8n/files/`. Backup/restore scripts STAY in
  `scripts/` (passed as absolute `src` to `backup_unit`). Authentik branding
  copies and blueprint discovery keep absolute `{{ repo_root }}/...` paths (they
  reference other services' dirs).
- **Shared globals** moved to `group_vars/all.yml`: `repo_root`, `deploy_user`,
  `deploy_group`, `borg_rsh`.
- **Stat-gating replaced (M02 follow-up, done):** added `*_enabled` flags
  (`mail_enabled`, `foundry_enabled`, `conference_tool_enabled`,
  `reporting_tool_enabled`, `n8n_enabled`, all true) to `group_vars/all.yml`.
  Service roles validate their own secrets via `assert` (dropped the per-service
  `stat`+`fail` on `<svc>/.env.sops.yaml`); authentik/conference-tool gate
  cross-service integration on the flags instead of other services' file
  existence. **The old `<svc>/.env.sops.yaml` files are now unused and can be
  deleted in M05** (no longer needed for gating; secrets live in
  `group_vars/all.sops.yaml`).
- **Verified:** all 11 playbooks pass `--syntax-check`; every moved template is a
  byte-identical git rename; every service's `env_content` block diffs clean vs
  HEAD (only conference-tool/authentik differ by the intended `mail_enabled`
  gate); borg-env/backup-env/systemd-unit content identical by construction;
  lefthook sops check green. Net −476 lines. Full runtime render-parity is the
  M05 gate.
