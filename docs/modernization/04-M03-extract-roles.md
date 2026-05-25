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
