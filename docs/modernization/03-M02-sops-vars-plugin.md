# M02 — SOPS vars-plugin + secrets indirection

**Branch:** A · **Touches live infra:** no (repo only)

## Goal

Replace the repeated `set_fact` + `lookup('community.sops.sops', …)` + `no_log`
blocks in every playbook with the `community.sops` **vars plugin**, and decouple
roles from where a secret lives via the `sops_`-prefix indirection pattern.

## Prerequisites

- M01 complete.

## Implementation

1. **Restructure inventory into the pdl-hannover layout:**
   ```
   ansible/
     ansible.cfg
     inventories/
       prod/
         hosts.yml                # hand-written here (single host); TF generates it in M09
         group_vars/
           all/
             main.yml             # plaintext: logical mappings + non-secret config
             secrets.sops.yml     # was secrets.sops.yaml
             authentik.sops.yml   # was authentik/.env.sops.yaml
             witness.sops.yml     # was reporting-tool/.env.sops.yaml
             foundry.sops.yml
             conference.sops.yml
             n8n.sops.yml
             mail.sops.yml
   ```
   `hosts.yml` carries the single `vps` host migrated out of the encrypted
   `ansible/inventory.sops.yaml`, including `ansible_user: deploy`,
   `ansible_become_method: su`, and `ansible_become_password:
   "{{ sops_bootstrap_root_password }}"`.

2. **Enable the vars plugin** in `ansible/ansible.cfg`:
   ```ini
   [defaults]
   vars_plugins_enabled = host_group_vars, community.sops.sops
   ```
   Any `group_vars/all/*.sops.yml` now auto-decrypts at runtime — no lookups.

3. **Apply the `sops_` indirection.** In each `*.sops.yml`, prefix keys
   (`sops_domain`, `sops_pg_pass`, `sops_s3_bucket`, …). In
   `group_vars/all/main.yml`, map logical → concrete:
   ```yaml
   domain: "{{ sops_domain }}"
   pg_pass: "{{ sops_pg_pass }}"
   s3_bucket: "{{ sops_s3_bucket }}"
   # ... one line per secret consumed by playbooks/roles
   ```
   Roles and playbooks reference only the logical names (`domain`, `pg_pass`).

4. **Update `.sops.yaml` creation rules** so `inventories/**/*.sops.yml` paths
   match the same age + YubiKey recipients as today's files. Re-encrypt:
   ```bash
   task secrets:updatekeys
   ```

5. **Strip the dead decryption blocks** from each playbook — e.g.
   `ansible/authentik.yml:78-107` and the equivalent `set_fact`/lookup blocks in
   witness, foundry, conference-tool, n8n, mail. (Full role conversion happens in
   M03; here just remove the now-redundant secret-loading.)

6. **Keep the old `inventory.sops.yaml` in place** for now as a fallback until
   M03/M05 are proven; delete it in M05.

## Verification gate

```bash
ansible-inventory -i ansible/inventories/prod --graph
ansible -i ansible/inventories/prod vps -m debug -a "var=domain"
```
- Inventory graph resolves with the single `vps` host.
- `domain` (and a spot-check secret) resolve to the correct values.
- `lefthook` encrypted-files pre-commit check still passes (no plaintext secrets).

## Rollback

Revert the commit; the inline-lookup playbooks and `inventory.sops.yaml` return.

## Definition of done

- `inventories/prod/` layout in place; vars plugin enabled.
- All global + per-service secrets moved to `group_vars/all/*.sops.yml` with
  `sops_` prefixes and logical mappings in `main.yml`.
- Playbooks reference logical names only; no remaining inline SOPS lookups.
- Inventory + a secret resolve via the plugin.
