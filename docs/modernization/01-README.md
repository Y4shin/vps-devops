# vps-devops Modernization

This directory holds the end-to-end plan to modernize `vps-devops` by adopting
the patterns proven in the newer `pdl-hannover-infra` repository:

1. **Ansible modernization** — SOPS vars-plugin + secrets indirection, real
   roles instead of monolithic per-service playbooks, and linting.
2. **OpenTofu adoption** — infrastructure-as-code for the Hetzner resources,
   with careful **import** of the already-running production VPS.

Each implementation step has its own file (numbered `MYY`). Read this README
first, then work the steps in order.

## Why

`vps-devops` today is a single-host, monolithic-playbook setup (e.g.
`ansible/authentik.yml` is ~1069 lines) with a battle-tested operational layer
(Borg backups, restore, ephemeral `.env`). `pdl-hannover-infra` is what you'd
build today: role-based, multi-environment, OpenTofu-provisioned with
TF-generated inventory, a SOPS vars-plugin + indirection layer, and
`ansible-lint`. This plan imports the best of that without a rewrite, and
without recreating the live server.

## The cardinal safety rule

The production VPS **already exists**. The single catastrophic failure mode is
`tofu apply` recreating it.

> **A `tofu plan` against prod must show `0 to add, 0 to destroy, 0 to replace`
> for the server, storage box, and every stateful resource before you ever run
> `apply`.**

This is enforced three ways in the import step: code proven on a disposable
staging box first, `lifecycle { prevent_destroy = true }` as a hard stop, and a
mandatory plan-review gate.

## Decisions locked in

- **Validation:** build a disposable staging VM from scratch with the new TF
  code before importing prod.
- **DNS:** move DNS into OpenTofu (`hcloud_zone` / `hcloud_zone_rrset`), with
  DKIM captured as committed data rather than fetched live from the container.
- **Scope:** full Ansible modernization (vars-plugin + roles + lint) **and**
  OpenTofu.
- **Execution Environments:** NOT adopted. Unlike pdl-hannover (which runs all
  Ansible inside an `ansible-builder`/`ansible-navigator` Docker EE), vps-devops
  uses the **Nix devshell** as its reproducible Ansible runtime. To close the
  reproducibility gap we pin collections via `ansible/requirements.yml` and drop
  the flake `shellHook`'s `--upgrade` install (M03). No Docker EE, no navigator.

## Branch strategy

The Ansible work ships to production **first**, on its own branch, so the
improvements go live ASAP. OpenTofu follows on a second branch cut from the
updated `main`.

```
main
 ├─ feat/ansible-modernization   M01–M05  ──► validate on prod ──► merge ──► live
 │
main (now carries the Ansible improvements)
 └─ feat/opentofu                M06–M12  (branched fresh from updated main)
```

Because the disposable staging box only exists in the OpenTofu branch (M08),
the refactored roles are validated against prod directly in **M05**, made safe
by the byte-identical config-parity gate. See M05 for the tradeoff.

## Steps

| File | Step | Branch | Summary |
|------|------|--------|---------|
| `02-M01-branch-and-baseline.md`     | M01 | A | Branch, capture prod baseline, fresh backups |
| `03-M02-sops-vars-plugin.md`        | M02 | A | SOPS vars-plugin + secrets indirection + inventory layout |
| `04-M03-extract-roles.md`           | M03 | A | Extract repeated logic into roles; rewrite `site.yml` |
| `05-M04-lint-and-health-checks.md`  | M04 | A | `ansible-lint`/`yamllint` + `check.yml` health playbook |
| `06-M05-validate-merge-deploy.md`   | M05 | A | Parity gate, validate on prod, merge, go live |
| `07-M06-opentofu-scaffolding.md`    | M06 | B | TF providers, topology, modules, state encryption; capture resource IDs |
| `08-M07-bootstrap-state-bucket.md`  | M07 | B | Create the tfstate bucket (bootstrap env) |
| `09-M08-staging-from-scratch.md`    | M08 | B | Disposable staging VM; validate TF + re-confirm roles |
| `10-M09-import-prod.md`             | M09 | B | Import the live VPS / storage box / bucket (the careful part) |
| `11-M10-dns-into-opentofu.md`       | M10 | B | Zone import + records + DKIM-as-data |
| `12-M11-taskfile-integration.md`    | M11 | B | `tf-*` tasks, `task up`, setup updates |
| `13-M12-cutover-and-docs.md`        | M12 | B | Destroy staging, update docs, merge |

## How to use these docs

- Each step file is self-contained: **Goal**, **Prerequisites**,
  **Implementation**, **Verification gate**, **Rollback**, **Definition of
  done**.
- Don't advance past a step until its verification gate passes.
- Commit one step per commit so any step is independently revertible.

## Reference

Comparison source: `../../../pdl-hannover-infra` (sibling repo). Key files worth
reading there: `terraform/environments/shared/dns.tf` (import pattern),
`terraform/environments/prod/servers.tf`, `scripts/tf-load-secrets.sh`,
`ansible/ansible.cfg` (vars plugins), `ansible/README.md` (indirection).
