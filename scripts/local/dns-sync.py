#!/usr/bin/env python3
"""
dns-sync — compare desired DNS state against the live Hetzner DNS zone and
apply changes interactively, with automatic encrypted backups.

Desired state is collected from dns-records.yaml files:
  - <repo-root>/dns-records.yaml
  - <repo-root>/*/dns-records.yaml  (direct children only)

Each file's 'records' list is concatenated and sorted by (type, name).
Every 'value' field is a Jinja2 template rendered against variables sourced
from secrets.sops.yaml (all top-level string keys are exposed).

DKIM records are fetched live from the server if the mail service is deployed;
they are injected automatically and do not need to appear in any dns-records.yaml.

Backups are stored in dns-backups.sops.yaml (SOPS-encrypted). A backup of the
entire live zone is taken automatically before any apply. Restoring a backup
also takes a backup first, so every edit is non-destructive.

Usage (via Taskfile):
  task dns:plan                    # dry run — show diff only
  task dns:sync                    # show diff, prompt, apply (+ auto backup)
  task dns:sync -- --prune         # also propose deletion of untracked RRSets
  task dns:sync -- --yes           # non-interactive apply
  task dns:backup:list             # list all stored backups
  task dns:backup:restore INDEX=0  # restore backup by index (+ auto backup)

Prerequisites:
  - secrets.sops.yaml must contain: domain, hetzner_dns_api_token, vps_ipv4, vps_ipv6
  - python3 with hcloud + jinja2 + pyyaml on PATH  (nix develop)
  - yq (go v4) on PATH                              (nix develop)
  - age.key present at repo root
"""

from __future__ import annotations

import argparse
import datetime
import glob
import json
import os
import re
import subprocess
import sys
import tempfile
from typing import Any

try:
    import hcloud
    from hcloud.zones.domain import ZoneRecord
    from hcloud.exp.zone import format_txt_record
except ImportError:
    print("hcloud Python library not found.\nEnter the Nix dev shell:  nix develop", file=sys.stderr)
    sys.exit(1)

try:
    from jinja2 import Environment, StrictUndefined, UndefinedError
except ImportError:
    print("jinja2 not found.\nEnter the Nix dev shell:  nix develop", file=sys.stderr)
    sys.exit(1)

try:
    import yaml
except ImportError:
    print("pyyaml not found.\nEnter the Nix dev shell:  nix develop", file=sys.stderr)
    sys.exit(1)

# ── Types ─────────────────────────────────────────────────────────────────────

FlatRecord   = dict           # keys: name, type, value, ttl
RRSetKey     = tuple[str, str]
DesiredRRSet = dict[RRSetKey, tuple[frozenset[str], int]]

# ── Constants ─────────────────────────────────────────────────────────────────

SKIP_PRUNE_TYPES  = {"SOA", "NS"}
BACKUP_FILE_NAME  = "dns-backups.sops.yaml"

# ── Terminal colours ──────────────────────────────────────────────────────────

_tty = sys.stdout.isatty()

def _c(code: str, text: str) -> str:
    return f"\033[{code}m{text}\033[0m" if _tty else text

def red(s: str) -> str:    return _c("31", s)
def green(s: str) -> str:  return _c("32", s)
def yellow(s: str) -> str: return _c("33", s)
def cyan(s: str) -> str:   return _c("36", s)
def bold(s: str) -> str:   return _c("1",  s)
def dim(s: str) -> str:    return _c("2",  s)

# ── TXT record normalisation ──────────────────────────────────────────────────

def normalize_txt(value: str) -> str:
    """
    Normalise a TXT record value for comparison.

    The Hetzner API returns TXT values with RFC 1035 quoting:
      - Single segment:  "v=spf1 a:mail.example.com -all"
      - Multi-segment:   "part1" "part2"   (split at 255 chars)

    Desired values in dns-records.yaml are plain unquoted strings.
    DKIM values fetched from the server are already concatenated without quotes.

    This function strips all double-quote characters and any whitespace between
    segments so that both representations compare equal.
    """
    # Remove all " characters then collapse runs of whitespace that were
    # only between quoted segments (i.e. between a closing and opening quote).
    # The simplest correct approach: extract all quoted segments and join them,
    # or if there are no quotes just return as-is.
    segments = re.findall(r'"((?:[^"\\]|\\.)*)"', value)
    if segments:
        return "".join(segments)
    return value


def quote_txt(value: str) -> str:
    """
    Return the properly quoted form of a TXT value for sending to the API.
    Uses hcloud's format_txt_record which splits at 255 chars and escapes quotes.
    """
    return format_txt_record(value)

# ── SOPS ──────────────────────────────────────────────────────────────────────

def sops_extract(key: str, file: str, age_key: str) -> str:
    env = {**os.environ, "SOPS_AGE_KEY_FILE": age_key}
    try:
        r = subprocess.run(
            ["sops", "-d", "--extract", key, file],
            capture_output=True, text=True, check=True, env=env,
        )
        return r.stdout.strip()
    except subprocess.CalledProcessError as exc:
        print(red(f"sops: failed to extract {key} from {file}"), file=sys.stderr)
        print(exc.stderr.strip(), file=sys.stderr)
        sys.exit(1)


def sops_decrypt_yaml(file: str, age_key: str) -> dict[str, Any]:
    env = {**os.environ, "SOPS_AGE_KEY_FILE": age_key}
    try:
        r = subprocess.run(
            ["sops", "-d", "--output-type", "json", file],
            capture_output=True, text=True, check=True, env=env,
        )
        return json.loads(r.stdout)
    except subprocess.CalledProcessError as exc:
        print(red(f"sops: failed to decrypt {file}"), file=sys.stderr)
        print(exc.stderr.strip(), file=sys.stderr)
        sys.exit(1)


def sops_encrypt_yaml(data: dict, dest: str, age_key: str) -> None:
    """Serialize data to YAML, encrypt with sops, write to dest."""
    env = {**os.environ, "SOPS_AGE_KEY_FILE": age_key}
    content = yaml.dump(data, default_flow_style=False, allow_unicode=True, sort_keys=False)

    with tempfile.NamedTemporaryFile(
        mode="w", suffix=".sops.yaml", delete=False, dir=os.path.dirname(dest) or "."
    ) as f:
        f.write(content)
        tmp_path = f.name

    try:
        r = subprocess.run(
            ["sops", "--encrypt", "--input-type", "yaml", "--output-type", "yaml", tmp_path],
            capture_output=True, text=True, check=True, env=env,
        )
        # Atomic write
        with open(dest, "w") as out:
            out.write(r.stdout)
    except subprocess.CalledProcessError as exc:
        print(red("sops: failed to encrypt backup file"), file=sys.stderr)
        print(exc.stderr.strip(), file=sys.stderr)
        sys.exit(1)
    finally:
        if os.path.exists(tmp_path):
            os.unlink(tmp_path)

# ── Backups ───────────────────────────────────────────────────────────────────

def load_backups(backup_path: str, age_key: str) -> list[dict]:
    """Decrypt and return the list of backup entries, or [] if file doesn't exist."""
    if not os.path.exists(backup_path):
        return []
    data = sops_decrypt_yaml(backup_path, age_key)
    return data.get("backups", [])


def take_backup(zone: Any, backup_path: str, age_key: str) -> str:
    """
    Snapshot all live RRSets (except SOA) and append to the encrypted backup file.
    Returns the timestamp string of the new backup.
    """
    live_rrsets = zone.get_rrset_all()
    timestamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    snapshot: dict[str, Any] = {
        "timestamp": timestamp,
        "zone": zone.name,
        "rrsets": sorted(
            [
                {
                    "name": r.name,
                    "type": r.type,
                    "ttl":  r.ttl,
                    "records": sorted(
                        [{"value": rec.value} for rec in (r.records or [])],
                        key=lambda x: x["value"],
                    ),
                }
                for r in live_rrsets
                if r.type not in {"SOA"}
            ],
            key=lambda r: (r["type"], "" if r["name"] == "@" else r["name"]),
        ),
    }

    existing = load_backups(backup_path, age_key)
    existing.append(snapshot)
    sops_encrypt_yaml({"backups": existing}, backup_path, age_key)
    return timestamp


def backup_to_desired(backup: dict) -> DesiredRRSet:
    """Convert a stored backup snapshot into a DesiredRRSet for diffing."""
    desired: DesiredRRSet = {}
    for r in backup.get("rrsets", []):
        if r["type"] in SKIP_PRUNE_TYPES:
            continue
        key: RRSetKey = (r["name"], r["type"])
        values = frozenset(rec["value"] for rec in r.get("records", []))
        desired[key] = (values, r["ttl"])
    return desired

# ── DKIM fetch ────────────────────────────────────────────────────────────────

def fetch_dkim_records(repo_root: str, age_key: str) -> list[FlatRecord]:
    all_sops = os.path.join(repo_root, "ansible", "inventories", "prod", "group_vars", "all.sops.yaml")
    if "sops_mail_secrets" not in sops_decrypt_yaml(all_sops, age_key):
        return []

    ssh_run = os.path.join(repo_root, "scripts", "local", "ssh-run.sh")
    try:
        r = subprocess.run(
            [
                "bash", ssh_run,
                "cd /opt/vps-devops/mail && "
                "docker compose exec -T mailserver "
                "find /tmp/docker-mailserver/opendkim/keys -type f -name '*.txt' -exec cat {} \\;",
            ],
            capture_output=True, text=True, timeout=30,
            env={**os.environ, "SOPS_AGE_KEY_FILE": age_key},
        )
    except subprocess.TimeoutExpired:
        print(yellow("Warning: SSH timeout while fetching DKIM — skipping DKIM records"), file=sys.stderr)
        return []
    except FileNotFoundError:
        return []

    raw = r.stdout.strip()
    if not raw or r.returncode != 0:
        return []

    records: list[FlatRecord] = []
    for block in raw.split("\n\n"):
        block = block.strip()
        if not block:
            continue
        lines = [l for l in block.splitlines() if not l.startswith(";")]
        if not lines:
            continue
        first_tokens = lines[0].split()
        if not first_tokens:
            continue
        fqdn = first_tokens[0].rstrip(".")
        fragments = re.findall(r'"([^"]*)"', block)
        if not fragments:
            continue
        records.append({
            "name":       fqdn,
            "type":       "TXT",
            "value":      "".join(fragments),
            "ttl":        3600,
            "_dkim_fqdn": True,
        })

    return records

# ── Record loading ────────────────────────────────────────────────────────────

def load_yaml_records(path: str, jinja_vars: dict[str, Any]) -> list[FlatRecord]:
    try:
        r = subprocess.run(
            ["yq", "-o", "json", ".records", path],
            capture_output=True, text=True, check=True,
        )
    except FileNotFoundError:
        print(red("yq not found — enter the Nix dev shell:  nix develop"), file=sys.stderr)
        sys.exit(1)
    except subprocess.CalledProcessError as exc:
        print(red(f"yq failed to parse {path}"), file=sys.stderr)
        print(exc.stderr.strip(), file=sys.stderr)
        sys.exit(1)

    try:
        raw = json.loads(r.stdout)
    except json.JSONDecodeError as exc:
        print(red(f"Could not parse yq output for {path}: {exc}"), file=sys.stderr)
        sys.exit(1)

    if raw is None:
        return []

    jinja_env = Environment(undefined=StrictUndefined)
    out: list[FlatRecord] = []
    for i, rec in enumerate(raw):
        for field in ("name", "type", "value"):
            if field not in rec:
                print(red(f"{path}: record #{i+1} missing '{field}'"), file=sys.stderr)
                sys.exit(1)
        try:
            rendered_value = jinja_env.from_string(str(rec["value"])).render(jinja_vars)
            rendered_name  = jinja_env.from_string(str(rec["name"])).render(jinja_vars)
        except UndefinedError as exc:
            print(red(f"{path}: record #{i+1}: {exc}"), file=sys.stderr)
            sys.exit(1)
        out.append({
            "name":  rendered_name,
            "type":  str(rec["type"]).upper(),
            "value": rendered_value,
            "ttl":   int(rec.get("ttl", 3600)),
        })
    return out


def load_all_records(repo_root: str, jinja_vars: dict[str, Any], age_key: str) -> list[FlatRecord]:
    paths: list[str] = []

    root_file = os.path.join(repo_root, "dns-records.yaml")
    if os.path.exists(root_file):
        paths.append(root_file)

    for child_file in sorted(glob.glob(os.path.join(repo_root, "*", "dns-records.yaml"))):
        paths.append(child_file)

    if not paths:
        print(red("No dns-records.yaml files found in repo root or direct subdirectories."), file=sys.stderr)
        sys.exit(1)

    all_records: list[FlatRecord] = []
    for p in paths:
        recs = load_yaml_records(p, jinja_vars)
        if recs:
            print(cyan(f"  {os.path.relpath(p, repo_root)}: {len(recs)} record(s)"))
        all_records.extend(recs)

    print(cyan("  Fetching DKIM from server..."))
    dkim_records = fetch_dkim_records(repo_root, age_key)
    domain = jinja_vars.get("domain", "")
    for r in dkim_records:
        if r.pop("_dkim_fqdn", False) and domain:
            suffix = f".{domain}"
            if r["name"].endswith(suffix):
                r["name"] = r["name"][: -len(suffix)]
        all_records.append(r)
    if dkim_records:
        print(cyan(f"  DKIM: {len(dkim_records)} record(s)"))
    else:
        print(cyan("  DKIM: none (mail not deployed or unreachable)"))

    def sort_key(r: FlatRecord) -> tuple[str, str]:
        return (r["type"], "" if r["name"] == "@" else r["name"])

    all_records.sort(key=sort_key)
    return all_records

# ── RRSet grouping ────────────────────────────────────────────────────────────

def group_into_rrsets(flat: list[FlatRecord]) -> DesiredRRSet:
    rrsets: dict[RRSetKey, tuple[set[str], int]] = {}
    for r in flat:
        key: RRSetKey = (r["name"], r["type"])
        if key in rrsets:
            values, ttl = rrsets[key]
            if ttl != r["ttl"]:
                print(red(f"TTL conflict for {r['name']} {r['type']}: {ttl} vs {r['ttl']}"), file=sys.stderr)
                sys.exit(1)
            values.add(r["value"])
        else:
            rrsets[key] = ({r["value"]}, r["ttl"])
    return {k: (frozenset(v), ttl) for k, (v, ttl) in rrsets.items()}

# ── Diff ──────────────────────────────────────────────────────────────────────

class Change:
    __slots__ = ("key", "kind", "old_values", "new_values", "old_ttl", "new_ttl", "live_rrset")

    def __init__(self, key, kind, old_values=None, new_values=None,
                 old_ttl=None, new_ttl=None, live_rrset=None):
        self.key        = key
        self.kind       = kind
        self.old_values = old_values
        self.new_values = new_values
        self.old_ttl    = old_ttl
        self.new_ttl    = new_ttl
        self.live_rrset = live_rrset


def compute_diff(desired: DesiredRRSet, live_rrsets: list, prune: bool) -> list[Change]:
    live_by_key: dict[RRSetKey, Any] = {(r.name, r.type): r for r in live_rrsets}
    changes: list[Change] = []

    def live_value_set(rrset: Any) -> frozenset[str]:
        """Return normalised values from a live RRSet for comparison."""
        norm = normalize_txt if rrset.type == "TXT" else (lambda v: v)
        return frozenset(norm(r.value) for r in (rrset.records or []))

    for (name, rtype), (des_values, des_ttl) in desired.items():
        key: RRSetKey = (name, rtype)
        if key not in live_by_key:
            changes.append(Change(key, "create", new_values=des_values, new_ttl=des_ttl))
        else:
            live        = live_by_key[key]
            live_values = live_value_set(live)
            live_ttl    = live.ttl
            v_changed   = live_values != des_values
            t_changed   = live_ttl    != des_ttl
            if v_changed and t_changed:
                changes.append(Change(key, "update_both",
                    old_values=live_values, new_values=des_values,
                    old_ttl=live_ttl, new_ttl=des_ttl, live_rrset=live))
            elif v_changed:
                changes.append(Change(key, "update_values",
                    old_values=live_values, new_values=des_values,
                    old_ttl=live_ttl, live_rrset=live))
            elif t_changed:
                changes.append(Change(key, "update_ttl",
                    old_ttl=live_ttl, new_ttl=des_ttl, live_rrset=live))
            else:
                changes.append(Change(key, "unchanged",
                    old_values=live_values, old_ttl=live_ttl))

    for (name, rtype), live in live_by_key.items():
        if rtype in SKIP_PRUNE_TYPES:
            continue
        if (name, rtype) not in desired:
            live_values = live_value_set(live)
            kind = "delete" if prune else "untracked"
            changes.append(Change((name, rtype), kind,
                old_values=live_values, old_ttl=live.ttl, live_rrset=live))

    def sort_key(c: Change) -> tuple[str, str]:
        name, rtype = c.key
        return (rtype, "" if name == "@" else name)

    changes.sort(key=sort_key)
    return changes

# ── Display ───────────────────────────────────────────────────────────────────

def _fmt_values(values: frozenset[str] | None) -> str:
    if not values:
        return ""
    sv = sorted(values)
    return sv[0] if len(sv) == 1 else "[" + ", ".join(sv) + "]"


def print_plan(domain: str, changes: list[Change]) -> None:
    cont = " " * (2 + 8 + 2)  # align continuation lines under the value column
    col_n, col_t = 32, 7

    print()
    print(bold(f"Proposed DNS changes for {domain}:"))
    print()
    for c in changes:
        name, rtype = c.key
        prefix = f"{name:<{col_n}}  {rtype:<{col_t}}"
        if c.kind == "create":
            print(f"  {green('+ CREATE')}  {prefix}  {_fmt_values(c.new_values)}  TTL={c.new_ttl}")
        elif c.kind == "update_values":
            print(f"  {yellow('~ VALUES')}  {prefix}")
            print(f"{cont}  {red(_fmt_values(c.old_values))}  TTL={c.old_ttl}")
            print(f"{cont}  {green(_fmt_values(c.new_values))}  TTL={c.old_ttl}")
        elif c.kind == "update_ttl":
            print(f"  {yellow('~   TTL')}  {prefix}")
            print(f"{cont}  TTL {red(str(c.old_ttl))}")
            print(f"{cont}  TTL {green(str(c.new_ttl))}")
        elif c.kind == "update_both":
            print(f"  {yellow('~  BOTH')}  {prefix}")
            print(f"{cont}  {red(_fmt_values(c.old_values))}  TTL {red(str(c.old_ttl))}")
            print(f"{cont}  {green(_fmt_values(c.new_values))}  TTL {green(str(c.new_ttl))}")
        elif c.kind == "delete":
            print(f"  {red('- DELETE')}  {prefix}  {_fmt_values(c.old_values)}  TTL={c.old_ttl}")
        elif c.kind == "untracked":
            print(f"  {dim('? EXTRA ')}  {prefix}  {_fmt_values(c.old_values)}  TTL={c.old_ttl}")
        elif c.kind == "unchanged":
            print(f"  {dim('  ok    ')}  {prefix}  {dim(_fmt_values(c.old_values))}  {dim(f'TTL={c.old_ttl}')}")
    print()
    creates   = sum(1 for c in changes if c.kind == "create")
    updates   = sum(1 for c in changes if c.kind.startswith("update"))
    deletes   = sum(1 for c in changes if c.kind == "delete")
    untracked = sum(1 for c in changes if c.kind == "untracked")
    unchanged = sum(1 for c in changes if c.kind == "unchanged")
    parts: list[str] = []
    if creates:   parts.append(green(f"+ {creates} to create"))
    if updates:   parts.append(yellow(f"~ {updates} to update"))
    if deletes:   parts.append(red(f"- {deletes} to delete"))
    if untracked: parts.append(dim(f"? {untracked} untracked (use --prune to delete)"))
    if unchanged: parts.append(dim(f"  {unchanged} unchanged"))
    print("  " + "  ".join(parts))
    print()

# ── Apply ─────────────────────────────────────────────────────────────────────

def make_records(rtype: str, values: frozenset[str]) -> list[ZoneRecord]:
    """Build ZoneRecord list, quoting TXT values for the API."""
    prepare = quote_txt if rtype == "TXT" else (lambda v: v)
    return [ZoneRecord(value=prepare(v)) for v in sorted(values)]


def apply_changes(zone: Any, changes: list[Change]) -> int:
    errors = 0
    for c in changes:
        if c.kind == "untracked":
            continue
        name, rtype = c.key
        try:
            if c.kind == "create":
                zone.create_rrset(name=name, type=rtype, ttl=c.new_ttl,
                                  records=make_records(rtype, c.new_values))
                print(f"  {green('✓ created')}  {name} {rtype}")
            elif c.kind == "update_values":
                c.live_rrset.set_rrset_records(make_records(rtype, c.new_values))
                print(f"  {yellow('✓ updated')}  {name} {rtype} (values)")
            elif c.kind == "update_ttl":
                c.live_rrset.change_rrset_ttl(c.new_ttl)
                print(f"  {yellow('✓ updated')}  {name} {rtype} (TTL {c.old_ttl} → {c.new_ttl})")
            elif c.kind == "update_both":
                c.live_rrset.set_rrset_records(make_records(rtype, c.new_values))
                c.live_rrset.change_rrset_ttl(c.new_ttl)
                print(f"  {yellow('✓ updated')}  {name} {rtype} (values + TTL)")
            elif c.kind == "delete":
                zone.delete_rrset(c.live_rrset)
                print(f"  {red('✓ deleted')}  {name} {rtype}")
        except Exception as exc:
            print(f"  {red('✗ failed')}   {name} {rtype}: {exc}", file=sys.stderr)
            errors += 1
    return errors

# ── Shared setup (secrets + zone) ─────────────────────────────────────────────

def setup(repo_root: str) -> tuple[str, str, str, Any, str]:
    """
    Decrypt secrets, validate required keys, connect to hcloud, look up zone.
    Returns (token, domain, age_key, zone, backup_path).
    """
    age_key = os.path.join(repo_root, "age.key")
    all_sops = os.path.join(repo_root, "ansible", "inventories", "prod", "group_vars", "all.sops.yaml")

    print(cyan("Reading secrets..."))
    secrets_data = sops_decrypt_yaml(all_sops, age_key).get("sops_secrets", {})
    jinja_vars: dict[str, Any] = {
        k: v for k, v in secrets_data.items()
        if isinstance(v, (str, int, float))
    }

    required = ("hetzner_dns_api_token", "domain", "vps_ipv4", "vps_ipv6")
    missing  = [k for k in required if not jinja_vars.get(k)]
    if missing:
        print(red("Missing required keys in group_vars/all.sops.yaml (sops_secrets):"), file=sys.stderr)
        for k in missing:
            print(red(f"  - {k}"), file=sys.stderr)
        print("Edit them in ansible/inventories/prod/group_vars/all.sops.yaml", file=sys.stderr)
        sys.exit(1)

    token  = str(jinja_vars["hetzner_dns_api_token"])
    domain = str(jinja_vars["domain"])

    print(cyan(f"Looking up zone for {bold(domain)}..."))
    client = hcloud.Client(token=token)
    zones  = client.zones.get_all(name=domain)
    if not zones:
        print(red(f"Zone '{domain}' not found in your Hetzner account."), file=sys.stderr)
        sys.exit(1)
    zone = zones[0]
    print(cyan(f"Zone ID: {zone.id}"))

    backup_path = os.path.join(repo_root, BACKUP_FILE_NAME)
    return token, domain, age_key, zone, backup_path, jinja_vars

# ── Subcommands ───────────────────────────────────────────────────────────────

def cmd_sync(args: Any, repo_root: str) -> None:
    token, domain, age_key, zone, backup_path, jinja_vars = setup(repo_root)

    print(cyan("Loading dns-records.yaml files..."))
    flat_records = load_all_records(repo_root, jinja_vars, age_key)
    desired      = group_into_rrsets(flat_records)

    print(cyan("Fetching current DNS records..."))
    live_rrsets = zone.get_rrset_all()

    changes   = compute_diff(desired, live_rrsets, args.prune)
    actionable = [c for c in changes if c.kind not in ("untracked", "unchanged")]

    if not changes:
        print(green("No changes needed — DNS is up to date."))
        return
    if not actionable:
        print_plan(domain, changes)
        print(yellow("No changes to apply. Use --prune to delete untracked records."))
        return

    print_plan(domain, changes)

    if args.dry_run:
        print(yellow("Dry run — no changes applied."))
        return

    if not args.yes:
        try:
            answer = input("Apply these changes? [y/N] ").strip().lower()
        except (KeyboardInterrupt, EOFError):
            print("\nAborted.")
            return
        if answer != "y":
            print("Aborted.")
            return

    print(cyan("Taking backup of current zone state..."))
    ts = take_backup(zone, backup_path, age_key)
    print(cyan(f"Backup saved ({ts})"))

    print()
    errors = apply_changes(zone, changes)
    print()

    if errors:
        print(red(f"{errors} operation(s) failed."))
        sys.exit(1)
    else:
        print(green("All changes applied successfully."))


def cmd_list_backups(args: Any, repo_root: str) -> None:
    age_key     = os.path.join(repo_root, "age.key")
    backup_path = os.path.join(repo_root, BACKUP_FILE_NAME)

    backups = load_backups(backup_path, age_key)
    if not backups:
        print("No backups found.")
        return

    print()
    print(bold(f"Stored DNS backups ({len(backups)} total):"))
    print()
    for i, b in enumerate(backups):
        rrset_count  = len(b.get("rrsets", []))
        record_count = sum(len(r.get("records", [])) for r in b.get("rrsets", []))
        marker = green("← most recent") if i == len(backups) - 1 else ""
        print(f"  [{i:>3}]  {b['timestamp']}  {b['zone']}  "
              f"{dim(f'({rrset_count} RRSets, {record_count} records)')}  {marker}")
    print()
    print(dim(f"Restore with: task dns:backup:restore INDEX=<n>"))
    print()


def cmd_restore(args: Any, repo_root: str) -> None:
    token, domain, age_key, zone, backup_path, _ = setup(repo_root)

    backups = load_backups(backup_path, age_key)
    if not backups:
        print(red("No backups found."), file=sys.stderr)
        sys.exit(1)

    index = args.index
    if index < 0 or index >= len(backups):
        print(red(f"Index {index} out of range (0 – {len(backups) - 1})"), file=sys.stderr)
        sys.exit(1)

    backup = backups[index]
    print(cyan(f"Restoring backup [{index}] from {backup['timestamp']}"))

    desired     = backup_to_desired(backup)
    live_rrsets = zone.get_rrset_all()

    # Restore is always a full reconcile: prune=True so extra live records are removed
    changes   = compute_diff(desired, live_rrsets, prune=True)
    actionable = [c for c in changes if c.kind not in ("untracked", "unchanged")]

    if not actionable:
        print(green("No changes needed — zone already matches this backup."))
        return

    print_plan(domain, changes)

    if not args.yes:
        try:
            answer = input("Apply this restore? [y/N] ").strip().lower()
        except (KeyboardInterrupt, EOFError):
            print("\nAborted.")
            return
        if answer != "y":
            print("Aborted.")
            return

    print(cyan("Taking backup of current zone state before restoring..."))
    ts = take_backup(zone, backup_path, age_key)
    print(cyan(f"Backup saved ({ts})"))

    print()
    errors = apply_changes(zone, changes)
    print()

    if errors:
        print(red(f"{errors} operation(s) failed."))
        sys.exit(1)
    else:
        print(green("Restore applied successfully."))

# ── Entry point ───────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Sync DNS records to Hetzner and manage encrypted zone backups",
    )
    sub = parser.add_subparsers(dest="command")

    # sync (default)
    p_sync = sub.add_parser("sync", help="Sync dns-records.yaml files to Hetzner DNS")
    p_sync.add_argument("--dry-run", action="store_true", help="Show diff without applying")
    p_sync.add_argument("--prune",   action="store_true", help="Also delete untracked RRSets")
    p_sync.add_argument("--yes", "-y", action="store_true", help="Skip confirmation prompt")

    # list-backups
    sub.add_parser("list-backups", help="List all stored zone backups")

    # restore
    p_restore = sub.add_parser("restore", help="Restore a zone backup by index")
    p_restore.add_argument("--index", "-i", type=int, required=True, help="Backup index (see list-backups)")
    p_restore.add_argument("--yes", "-y", action="store_true", help="Skip confirmation prompt")

    # If called with no subcommand, default to sync for backwards compat with Taskfile
    if len(sys.argv) == 1 or sys.argv[1].startswith("-"):
        # Inject 'sync' so the sync parser handles flags
        sys.argv.insert(1, "sync")

    args = parser.parse_args()

    repo_root = os.path.normpath(
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
    )

    if args.command == "sync":
        cmd_sync(args, repo_root)
    elif args.command == "list-backups":
        cmd_list_backups(args, repo_root)
    elif args.command == "restore":
        cmd_restore(args, repo_root)
    else:
        parser.print_help()


if __name__ == "__main__":
    main()
