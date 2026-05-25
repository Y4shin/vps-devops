# M12 — Cutover, teardown, and docs

**Branch:** B · **Touches live infra:** destroys staging only

## Goal

Finish the migration: tear down the disposable staging box, document the new
model, and merge the OpenTofu branch.

## Prerequisites

- M06–M11 complete; `tofu plan ENV=prod` clean.

## Implementation

1. **Destroy staging:**
   ```bash
   source scripts/tf-load-secrets.sh staging
   tofu -chdir=terraform/environments/staging destroy
   ```
   Remove the staging inventory if no longer wanted.

2. **Docs:**
   - Update `docs/setup-guide.md` and `docs/backup-architecture.md`: the new
     inventory model (TF-generated), the TF workflow, and the DKIM-export step.
   - Add `docs/terraform-import.md` recording the import IDs and the cardinal
     "plan must show 0 destroy/replace" rule for future hands.
   - Refresh `CLAUDE.md`: roles layout, `group_vars` secrets indirection, the
     `task tf-*`/`up` commands, and the `prevent_destroy` invariant.
   - Mark this `docs/modernization/` plan as completed (or move to an
     `archive/` subfolder).

3. **Final verification** before merge:
   ```bash
   task lint
   task tf-plan ENV=prod                 # clean
   ansible-playbook -i ansible/inventories/prod ansible/check.yml
   ```

4. **Merge:**
   ```bash
   git checkout main && git merge --no-ff feat/opentofu
   ```

## Verification gate

- Staging destroyed; no stray Hetzner resources billing.
- `tofu plan ENV=prod` clean; `check.yml` green.
- Docs updated; `CLAUDE.md` reflects the new workflow.

## Rollback

Repo/doc-only at this point. Prod state is established and clean; staging
teardown is the only infra action and is the intended end state.

## Definition of done

- Staging gone; prod fully managed by OpenTofu + role-based Ansible.
- Docs + `CLAUDE.md` current.
- `feat/opentofu` merged to `main`. Migration complete.
