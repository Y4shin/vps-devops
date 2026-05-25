# M01 — Branch, baseline, and backups

**Branch:** A (`feat/ansible-modernization`) · **Touches live infra:** no (read-only + backups)

## Goal

Create the Ansible branch, capture the current production truth so we can later
match it exactly on import and detect drift, and take a fresh backup floor
before any change.

## Prerequisites

- Working `task` + `sops` + `age.key` setup (`task check:unix:key` passes).
- `hcloud` CLI authenticated against the project (`hcloud context list`).

## Implementation

1. **Create the branch:**
   ```bash
   git checkout -b feat/ansible-modernization
   ```

2. **Capture the Hetzner resource baseline** into a SOPS-encrypted file committed
   to the repo (`docs/modernization/migration-baseline.sops.yaml` — matches the
   `.+\.sops\.yaml$` creation rule, so it gets the age + YubiKey recipients).
   These IDs/attributes are not needed until the OpenTofu import (M09), but
   capturing them now records the pre-migration state. Run hcloud via the nix
   devshell (`nix develop --command hcloud …`), reusing `hetzner_dns_api_token`
   as `HCLOUD_TOKEN` (it is a unified token):
   ```bash
   hcloud server list -o columns=id,name,server_type,location,datacenter,image,ipv4,ipv6
   hcloud ssh-key list
   hcloud network list
   hcloud primary-ip list
   hcloud firewall list          # expect EMPTY — you use on-host UFW, not hcloud firewall
   hcloud storage-box list       # record the Borg box ID (use the API if your CLI predates it)
   ```
   Also note the Object Storage bucket name (`s3_bucket` in `secrets.sops.yaml`).

3. **Take fresh backups** of every stateful service. This migration should not
   touch data, but the backup is the floor:
   ```bash
   task authentik:backup:perform
   task witness:backup:perform
   task foundry:backup:perform
   task conference-tool:backup:perform
   ```
   Confirm each with the matching `*:backup:info`.

4. **Record the current deploy command surface** — list the `task deploy:*`
   targets so M05 can verify the same surface still works after the refactor.

## Verification gate

- `docs/modernization/migration-baseline.sops.yaml` exists and is encrypted
  (the lefthook `check-sops-encrypted.sh` hook passes).
- Each `*:backup:info` shows a new archive dated today.

## Rollback

Nothing changed on infra; delete the branch if abandoning.

## Definition of done

- Branch `feat/ansible-modernization` exists.
- Baseline facts captured (server ID, storage box ID, bucket name, IPs).
- Fresh backups confirmed for all stateful services.
