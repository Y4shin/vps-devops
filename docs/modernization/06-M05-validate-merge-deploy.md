# M05 — Validate on prod, merge, go live

**Branch:** A · **Touches live infra:** YES (re-deploys refactored roles to prod)

## Goal

Ship the Ansible modernization to production. Because the disposable staging box
doesn't exist yet (it's in the OpenTofu branch, M08), the **config-parity gate is
promoted from a nicety to the merge gate** — it's what makes deploying a refactor
straight to prod acceptable.

## The tradeoff (read this)

This ships the refactor to prod **before** it's ever run on a clean disposable
box. We trade "prove on staging first" for "live ASAP." The gap is covered by:
the byte-identical parity diff, `--check` mode, per-service rollout, the
`check.yml` health snapshot, and the M01 backups. **If any service's parity diff
is not clean, hold that service back and ship the rest — do not force it.**

## Prerequisites

- M02–M04 complete. M01 backups confirmed.

## Implementation

1. **Render-diff every service**, old way vs. new role way, against the real prod
   vars. Each rendered `docker-compose.yml` + `.env` must be **byte-identical**
   (or differ only intentionally). This is the proof that re-running the roles
   won't churn or break anything live.

2. **Dry run** `site.yml` against prod and inspect:
   ```bash
   ansible-playbook -i ansible/inventories/prod ansible/site.yml --check --diff
   ```
   Expect no changes beyond the intended ones.

3. **Roll out service-by-service**, not all at once. After each, run the health
   check before continuing:
   ```bash
   task deploy:traefik && ansible-playbook -i ansible/inventories/prod ansible/check.yml
   task deploy:authentik && ansible-playbook -i ... ansible/check.yml
   # ... witness, n8n, conference-tool, foundry, mail
   ```

4. **Delete the obsolete fallback** once everything is green: remove
   `ansible/inventory.sops.yaml` and any per-service `.env.sops.yaml` now
   superseded by `group_vars/all/*.sops.yml`. Update `Taskfile.yml` so the
   `decrypt`/`defer rm inventory.yml` plumbing points at the new inventory.

5. **Merge to main:**
   ```bash
   git checkout main && git merge --no-ff feat/ansible-modernization
   ```
   The Ansible improvements are now live. ✅

## Verification gate

- Every service's parity diff was byte-identical (or intentionally different).
- `check.yml` is green after each service deploy.
- `task deploy:*` surface matches the M01 record.

## Rollback

- Per-service: re-deploy the previous compose from git history; data is
  bind-mounted/volumed and untouched.
- Whole branch: `git revert` the merge; restore `inventory.sops.yaml` from
  history. M01 backups are the floor if a service misbehaves.

## Definition of done

- Refactored roles deployed and healthy on prod.
- Old inventory/secret fallbacks removed.
- Branch merged to `main`; Ansible modernization is live.
