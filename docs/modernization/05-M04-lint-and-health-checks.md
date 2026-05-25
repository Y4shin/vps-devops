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
