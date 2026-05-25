# M10 — DNS into OpenTofu

**Branch:** B · **Touches live infra:** zone import + record reconciliation

## Goal

Move DNS off `dns-sync.py` into OpenTofu using `hcloud_zone` /
`hcloud_zone_rrset`. The zone import is easy; DKIM is handled as captured data so
TF never has to exec into the mail container.

## Prerequisites

- M09 complete (provider + state established).

## Implementation

1. **Import the zone** using pdl-hannover's auto-discovery pattern (no manual ID):
   ```hcl
   data "hcloud_zones" "all" {}
   locals {
     existing = { for z in data.hcloud_zones.all.zones : z.name => z.id if z.name == var.domain }
   }
   import {
     for_each = local.existing
     id       = each.value
     to       = hcloud_zone.apex[each.key]
   }
   resource "hcloud_zone" "apex" {
     for_each = toset([var.domain])
     name     = each.value
     mode     = "primary"
     lifecycle { prevent_destroy = true }
   }
   ```

2. **Static records** (apex A/AAAA, per-service A/AAAA, MX, SPF, DMARC) become
   `hcloud_zone_rrset` resources computed in `deploy_config` from `topology.yaml`
   + the VPS IPs — replacing the per-service `dns-records.yaml` files.

3. **DKIM — capture as data, don't fetch live.** The DKIM public key is generated
   once by docker-mailserver, stable until rotated, and **public** (not a
   secret). So:
   - Add `task mail:dkim:export` that reads the current DKIM TXT from the mail
     container and writes it to a committed `terraform/dkim.auto.tfvars` (or a
     topology field).
   - TF manages that DKIM TXT as a normal `hcloud_zone_rrset`.
   - Rotating DKIM = re-run the export task, then `tofu apply`.

4. **Migration ordering to avoid an outage:**
   - Import the zone first (existing records stay put).
   - Add rrset resources; `plan` should show **no-ops/imports** for records that
     already match and **create** only genuinely new ones.
   - Verify record-by-record in `plan` before `apply`.
   - Retire `dns-sync.py` + `dns-records.yaml` only after TF cleanly owns the
     zone (keep them as a fallback until then).

## Verification gate

- `tofu plan` shows the zone imported and existing records as no-ops (no
  unexpected deletes/changes).
- `dig` spot-checks (A/AAAA/MX/SPF/DMARC/DKIM) resolve unchanged after `apply`.
- Mail still sends and passes SPF/DKIM/DMARC alignment.

## Rollback

`dns-sync.py` remains functional until retired — re-run it to restore records
from the encrypted `dns-backups.sops.yaml` snapshot if TF reconciliation goes
wrong.

## Definition of done

- Zone imported; all records (incl. DKIM) managed by TF.
- `task mail:dkim:export` documented for rotation.
- `dns-sync.py` + `dns-records.yaml` retired.
