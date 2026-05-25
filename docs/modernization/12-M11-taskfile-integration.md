# M11 — Taskfile integration

**Branch:** B · **Touches live infra:** no (wiring only)

## Goal

Wire OpenTofu into the `task` workflow so day-to-day operation is `task up
ENV=…`, and update the control-node setup to install the new tooling.

## Prerequisites

- M09 (and ideally M10) complete.

## Implementation

1. **`tf-*` tasks** (per-env via `ENV=`), each sourcing `tf-load-secrets.sh` and
   `defer`-cleaning any decrypted material (mirroring today's
   `defer: rm -f ansible/inventory.yml`):
   ```yaml
   tf-init:   { cmds: ["bash scripts/tf-load-secrets.sh {{.ENV}} && tofu -chdir=terraform/environments/{{.ENV}} init"] }
   tf-plan:   { cmds: ["... && tofu -chdir=terraform/environments/{{.ENV}} plan"] }
   tf-apply:  { cmds: ["... && tofu -chdir=terraform/environments/{{.ENV}} apply"] }
   tf-destroy:{ cmds: ["... && tofu -chdir=terraform/environments/{{.ENV}} destroy"] }
   ```
   Default `ENV` to `prod`.

2. **`task up ENV=…`** = `tf apply` (regenerates the inventory) → `ansible-playbook
   site.yml`. Keep the existing `task deploy:*` per-service targets pointed at the
   role-based playbooks.

3. **Inventory plumbing** — the TF-generated `inventories/<env>/hosts.yml` is
   gitignored; remove any remaining encrypted-inventory decrypt/`defer rm` steps
   left from the old model.

4. **Update `setup:debian:trixie`** to also install `opentofu` and the `hcloud`
   CLI, and run `ansible-galaxy install -r ansible/requirements.yml`.

## Verification gate

```bash
task tf-plan ENV=prod        # clean, 0 changes
task up ENV=staging          # provisions + deploys end-to-end on staging
```
- `task up` works against staging end-to-end.
- `task tf-plan ENV=prod` is clean (no drift).
- A fresh control node bootstrapped via `setup:debian:trixie` has tofu + hcloud +
  collections.

## Rollback

Repo-only; revert the commit. Existing `task deploy:*` targets still work
directly.

## Definition of done

- `tf-*` + `up` tasks exist and work per-env.
- Setup task installs tofu + hcloud + collections.
- Old inventory-decrypt plumbing removed.
