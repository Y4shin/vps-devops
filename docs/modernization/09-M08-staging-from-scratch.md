# M08 — Disposable staging from scratch

**Branch:** B · **Touches live infra:** yes (creates a throwaway VM; destroyed in M12)

## Goal

Build a fresh staging box entirely from the new TF code to validate the
**server-creation + cloud-init + inventory-generation** path before we import the
real server. As a bonus it re-confirms the already-live roles on a clean box.

> Note: unlike the original plan, this is no longer the *first* place the roles
> run — they're already live on prod from M05. Staging's primary job here is to
> de-risk the TF code that M09 will point at prod.

## Prerequisites

- M07 complete (state backend usable).

## Implementation

1. **`environments/staging/`** creates:
   - `tls_private_key` + `hcloud_ssh_key` (generated keypair).
   - one `hcloud_server` (ubuntu-24.04, cheap type e.g. `cx22`) with `cloud-init`
     that creates the `deploy` user **with sudo**.
   - a `local_sensitive_file` that **generates
     `ansible/inventories/staging/hosts.yml`** from the server IP + key.
   Model on pdl-hannover's `terraform/environments/staging/servers.tf` +
   `inventory.tf`.

2. **Apply:**
   ```bash
   source scripts/tf-load-secrets.sh staging
   tofu -chdir=terraform/environments/staging init
   tofu -chdir=terraform/environments/staging apply       # fresh box exists
   ```

3. **Run the live roles against it.** Staging uses **sudo**; prod uses
   `deploy`→`su`. Keep that difference in per-env `group_vars`, not in roles:
   ```bash
   ansible-playbook -i ansible/inventories/staging ansible/site.yml
   ansible-playbook -i ansible/inventories/staging ansible/check.yml
   ```

4. **Validate end-to-end:** bring up a couple of real services, confirm Traefik
   routing + a backup cycle work on the clean box.

5. **Leave staging running** until after the M09 cutover; destroy it in M12.

## Verification gate

- `tofu apply` creates the box with **no errors**.
- TF-generated `inventories/staging/hosts.yml` is valid; `site.yml` + `check.yml`
  pass against staging.
- This proves the server module, cloud-init, and inventory generation that M09
  relies on.

## Rollback

```bash
tofu -chdir=terraform/environments/staging destroy
```

## Definition of done

- Staging box stood up from scratch via TF.
- Roles + health check green on staging.
- TF server/inventory code validated for reuse in M09.
