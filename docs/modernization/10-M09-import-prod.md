# M09 — Import the existing prod VPS

**Branch:** B · **Touches live infra:** state only; `apply` gated on a 0-destroy plan

## Goal

Bring the live Hetzner resources (server, storage box, Object Storage bucket)
into OpenTofu state **without recreating them**. This is the highest-risk step;
it is protected by code proven on staging (M08), `prevent_destroy`, and a
mandatory plan-review gate.

## The cardinal rule

> A `tofu plan` against prod must show `0 to add, 0 to destroy, 0 to replace`
> for the server, storage box, and bucket before you ever run `apply`. If `plan`
> proposes a replace or destroy, **stop** and fix the config to match reality.

## Prerequisites

- M08 complete (TF server/inventory code validated on staging).
- M01 baseline IDs on hand.

## Implementation

We use `import {}` blocks (reviewable in `plan`) rather than blind CLI imports.

### 9a. The server — match exactly, then guard

In `environments/prod/servers.tf`, mirror the captured attributes and guard
against replacement:
```hcl
import {
  to = hcloud_server.vps
  id = "PROD_SERVER_ID"          # from M01 `hcloud server list`
}

resource "hcloud_server" "vps" {
  name        = "EXISTING_NAME"
  server_type = "EXISTING_TYPE"   # MUST match (replacement-forcing)
  location    = "EXISTING_LOC"    # MUST match (replacement-forcing)
  image       = "EXISTING_IMAGE"

  lifecycle {
    prevent_destroy = true        # hard error instead of destroy
    ignore_changes  = [image, user_data, ssh_keys]
  }
}
```
`image`, `user_data`, `server_type`, `location` are replacement-forcing in the
hcloud provider. `prevent_destroy` is the seatbelt; `ignore_changes` keeps the
unknowable attributes (set at original creation) from ever proposing a replace.

### 9b. Plan-only first

```bash
source scripts/tf-load-secrets.sh prod
tofu -chdir=terraform/environments/prod init
tofu -chdir=terraform/environments/prod plan      # MUST read: 1 import, 0 destroy, 0 replace
```
Only when the plan is a pure import do you `apply`.

### 9c. Storage Box + Object Storage bucket — same pattern

```hcl
import { to = hcloud_storage_box.borg, id = "BOX_ID" }
resource "hcloud_storage_box" "borg" {
  # match name/type/location
  lifecycle { prevent_destroy = true; ignore_changes = [password] }  # never reset the Borg password
}

import { to = minio_s3_bucket.app, id = "EXISTING_BUCKET_NAME" }
resource "minio_s3_bucket" "app" {
  bucket = "EXISTING_BUCKET_NAME"
  lifecycle { prevent_destroy = true }
}
```
`ignore_changes = [password]` on the storage box is essential — you don't know
the existing password and must not let TF rotate it (that breaks every Borg
backup).

### 9d. SSH key (optional, low stakes)

If `hcloud ssh-key list` shows your deploy key in the project, import it;
otherwise let TF manage it going forward. Either way it can't break a running
server.

### 9e. Prod inventory from TF, preserving `deploy`→`su`

Generate `inventories/prod/hosts.yml` from the imported server, but keep prod's
connection model in `inventories/prod/group_vars/all/main.yml`:
```yaml
ansible_user: deploy
ansible_become_method: su
ansible_become_password: "{{ sops_bootstrap_root_password }}"
```
(Staging differs — sudo — so these live per-env, not in a role.)

### 9f. Inventory swap (near-no-op)

The roles are already live on prod (from M05). The only change is swapping the
inventory source from the hand-written `hosts.yml` to the TF-generated one.
**Diff the two inventories** to confirm they match, then run:
```bash
ansible-playbook -i ansible/inventories/prod ansible/check.yml
```
Expect green and no container churn.

## Verification gate

- `tofu plan` showed pure imports, `0 destroy / 0 replace`, for server + storage
  box + bucket.
- After `apply`, `tofu plan` is clean (no drift).
- TF-generated prod inventory matches the hand-written one; `check.yml` green.

## Rollback

TF imports don't modify infrastructure. Worst case: `rm` the prod state file and
the live resources are untouched. The inventory swap is reversible (keep the
hand-written `hosts.yml` until the diff is confirmed).

## Definition of done

- Live server, storage box, and bucket are in prod state with `prevent_destroy`.
- `tofu plan` clean against prod.
- Prod inventory sourced from TF; health check green.
