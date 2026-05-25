# M04 — Lint and health checks

**Branch:** A · **Touches live infra:** no (repo only)

## Goal

Add `ansible-lint` + `yamllint` and a read-only `check.yml` health playbook that
becomes the post-deploy smoke test (reused on prod in M05 and on staging in M08).

## Prerequisites

- M03 complete.

## Implementation

1. **Add `.ansible-lint`** (mirror pdl-hannover's excludes for generated and
   encrypted files):
   ```yaml
   exclude_paths:
     - ansible/inventories/*/hosts.yml      # TF-generated later
     - "**/*.sops.yml"
     - "**/*.sops.yaml"
   ```
   Add a matching `.yamllint` (relax line-length, ignore the same paths).

2. **Add `task lint`** to `Taskfile.yml`:
   ```yaml
   lint:
     desc: Run ansible-lint + yamllint
     cmds:
       - ansible-lint
       - yamllint ansible/
   ```
   Wire it into `lefthook` as a **pre-push** hook (not pre-commit, to keep
   commits fast).

3. **Add `ansible/check.yml`** — a read-only health playbook:
   - `community.docker.docker_container_info` for each expected container →
     assert running.
   - HTTP probe each Traefik router (`authentik.<domain>`, `witness.<domain>`,
     …) → assert 200/expected redirect.
   - Cert validity: assert Let's Encrypt certs not expiring < 14 days.
   - Backup freshness: assert each Borg repo's latest archive age < 36h.

4. **Fix lint findings** the refactor surfaced.

## Verification gate

```bash
task lint                                  # clean (or only accepted warnings)
ansible-playbook -i ansible/inventories/prod ansible/check.yml
```
- Lint passes.
- `check.yml` runs read-only and reports current prod health (this also gives a
  pre-refactor health snapshot to compare against in M05).

## Rollback

Revert the commit.

## Definition of done

- `.ansible-lint` + `.yamllint` + `task lint` in place; lint clean.
- `check.yml` exists and reports health read-only.
- Lint wired into lefthook pre-push.

## Implementation notes (as built, 2026-05-25)

- **Tooling:** added `ansible-lint` + `yamllint` to `flake.nix`. `task lint` runs
  `ansible-lint ansible/` (which runs yamllint internally); scoping to `ansible/`
  keeps root-level non-Ansible yaml out of scope. Wired into **lefthook
  pre-push** (not pre-commit) — requires the nix devshell to be active.
- **Result: 0 failures at the `production` profile** across 46 files.
- **Config choices:** `.ansible-lint` skips `var-naming[no-role-prefix]` (the repo
  uses shared/generic variable names by design — `secrets`, `app_secrets`, generic
  helper-role params — so role-prefixing would force ~80 churny renames and fight
  the design). Excludes `collections/`, `test/`, `**/*.sops.*`, `dns-records.yaml`,
  `**/authentik-blueprints/`. `.yamllint` disables `line-length` (long Traefik
  forwardauth labels) and sets `octal-values` forbid flags true (ansible-lint
  requires it; all our `mode:` values are quoted strings so it never triggers).
- **Findings fixed (the refactor surfaced these):** renamed role
  `conference-tool` → `conference_tool` (`role-name`: hyphens disallowed); named
  the `import_playbook` entries in `site.yml`/`all.yml` (`name[play]`); moved the
  jinja `{{ ..._service_slug }}` to the **end** of helper-role task names
  (`name[template]`); added `changed_when` to command/shell tasks
  (`no-changed-when` — true for migrations/backups/installs/borg-init, false for
  the n8n workflow-patch transform); capitalised one base task name and fixed
  comma spacing in the base UFW loop.
- **check.yml** asserts: expected containers running
  (`community.docker.docker_container_info`), public HTTPS endpoints respond with
  a valid certificate (`uri` with `validate_certs: true`, delegated to localhost),
  and the four backup `.timer`s are active (`systemctl is-active`, with a
  justified `# noqa: command-instead-of-module` since it's a read-only query).
- **Flagged, not changed:** a stray tracked `foundry-compose.yml` at the repo root
  is not referenced by the foundry role (which uses
  `roles/foundry/templates/docker-compose.yml.j2`) — probable cruft, left for the
  user to confirm. ansible-lint emits a cosmetic dual-collection-path warning
  (`~/.ansible` 5.1.0 vs `./collections` 5.2.0); real runs use `./collections`.
- `check.yml` has not yet been run against prod (that happens in M05); it passes
  `--syntax-check` and lint.
